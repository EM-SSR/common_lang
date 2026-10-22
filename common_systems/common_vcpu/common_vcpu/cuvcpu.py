# -*- coding: utf-8 -*-
"""lane64 の GPU 実行台。語も述語も bit のまま持つ。

仕様は docs/common-compiler/arch/20。式 (2.1) の mask 付き意味をそのまま持ち、
lane の向きだけ bit へ詰める。命題 6.1 の一致は解釈器と同じ理由で成り立つ。

  語     NB 枚の bit 平面。平面ひとつが lane 軸を詰めた uint8 の列になる
  述語   lane の bit 列。選択は (new & m) | (old & ~m) の一行になる
  加算   XOR と AND の桁上がり。Kogge-Stone で log NB 段に畳む
  乗算   部分積を carry-save で潰し、最後に一度だけ桁上がりを流す
  比較   引き算の借りと符号から取る

lane の bit がそのまま述語 mask になるので、20 §5 の式 (2.1) と §6 の
式 (3.2) が bit 演算そのものになる。整数の配列へ載せ替える段が要らない。

  V ∈ B^{NB × W}        値。lane 軸を uint8 の bit へ詰めて (NB, LB)
  m ∈ B^{W}             述語。(LB,)

語の幅 NB は引数になる。lane64 の語は ℤ なので（20 §0.3）、この道は
NB bit を越えた時点で core 意味論と離れる。越えたら桁上がりを見て報告する。
"""

import sys

INSN = 16
HALT, MAT, ADD, MUL, NEG, EQ, LT, JMP, LD, ST, OK, KO, PUT = range(13)
LANDMARKS = 256

# block を閉じる箱（20 式 7.4）と同じ分類を使う
TERM = frozenset([EQ, LT, JMP, OK, KO, HALT])


def _cp():
    import cupy
    return cupy


# ===== bit 平面の道具 =====
#
# lane ℓ は byte ℓ//8 の bit ℓ%8 に入る。packbits の bitorder='little' が
# その並びになる。以後どの演算も uint8 の bit 演算だけで閉じる。

def lane_bytes(w):
    return (w + 7) // 8


def lane_mask(cp, w):
    """lane 0..W-1 だけを立てた bit 列。端数の byte の上位は落とす。"""
    flags = cp.ones(lane_bytes(w) * 8, dtype=cp.uint8)
    flags[w:] = 0
    return cp.packbits(flags, bitorder='little')


def zeros(cp, nb, lb):
    return cp.zeros((nb, lb), dtype=cp.uint8)


def const(cp, value, nb, lb, full):
    """即値を bit 平面へ広げる。lane で同じ値なので、平面ごとに全 bit か零になる。"""
    out = zeros(cp, nb, lb)
    v = int(value) & ((1 << nb) - 1)
    for k in range(nb):
        if (v >> k) & 1:
            out[k] = full
    return out


def select(new, old, m):
    """(new & m) | (old & ~m)。式 (2.1) の mask 付き遷移そのものになる。"""
    return (new & m) | (old & ~m)


def shl(cp, a, s, nb):
    """左シフト。平面の番号がそのまま桁なので、並べ替えだけで済む。"""
    if s <= 0:
        return a
    out = cp.zeros_like(a)
    if s < nb:
        out[s:] = a[:nb - s]
    return out


def addc(cp, a, b, cin, nb):
    """桁上がり先読みの加算。返りは和と最上位から出た桁上がりになる。

    g = a & b が桁を生み、p = a ^ b が桁を通す。Kogge-Stone は
    (g, p) の結合を倍々に畳むので、段数が log NB になる。
    """
    g = a & b
    p = a ^ b
    if cin is not None:
        g = g.copy()
        g[0] = g[0] | (p[0] & cin)
    d = 1
    while d < nb:
        g2 = g.copy()
        p2 = p.copy()
        g2[d:] = g[d:] | (p[d:] & g[:nb - d])
        p2[d:] = p[d:] & p[:nb - d]
        g, p = g2, p2
        d <<= 1
    carry = cp.zeros_like(a)
    if cin is not None:
        carry[0] = cin
    carry[1:] = g[:nb - 1]
    return (a ^ b) ^ carry, g[nb - 1]


def negate(cp, a, nb, full):
    """二の補数。反転して 1 を足す。"""
    return addc(cp, ~a, cp.zeros_like(a), full, nb)[0]


def sub(cp, a, b, nb, full):
    """a − b。借りは桁上がりの補になる。"""
    return addc(cp, a, ~b, full, nb)


def mul(cp, a, b, nb):
    """部分積を carry-save で潰す。3 本を 2 本へ畳むので桁上がりが流れない。

    最後の一回だけ addc で桁上がりを通す。乗算の深さが O(log NB) に収まる。
    """
    terms = []
    for k in range(nb):
        t = cp.zeros_like(a)
        if k < nb:
            t[k:] = a[:nb - k] & b[k]
        terms.append(t)
    while len(terms) > 2:
        nxt = []
        i = 0
        while i + 2 < len(terms):
            x, y, z = terms[i], terms[i + 1], terms[i + 2]
            s = x ^ y ^ z
            c = (x & y) | (y & z) | (x & z)
            up = cp.zeros_like(a)
            up[1:] = c[:nb - 1]
            nxt.append(s)
            nxt.append(up)
            i += 3
        nxt.extend(terms[i:])
        terms = nxt
    if len(terms) == 1:
        return terms[0]
    return addc(cp, terms[0], terms[1], None, nb)[0]


def or_reduce(cp, x):
    """平面軸を or で畳む。二分で寄せるので段数が log NB になる。

    CuPy の ufunc.reduce は bitwise を持たないので、切って重ねる。
    """
    n = x.shape[0]
    while n > 1:
        h = n // 2
        if n % 2:
            x = cp.concatenate([x[:h] | x[h:h + h], x[h + h:h + h + 1]], axis=0)
            n = h + 1
        else:
            x = x[:h] | x[h:]
            n = h
    return x[0]


def eq_mask(cp, a, b):
    """一致する lane の bit を立てる。平面の差を畳んでから否定する。"""
    return ~or_reduce(cp, a ^ b)


def lt_mask(cp, a, b, nb, full):
    """符号つきの大小。引き算の符号を、あふれで直す。"""
    d, _ = sub(cp, a, b, nb, full)
    sa, sb, sd = a[nb - 1], b[nb - 1], d[nb - 1]
    over = (sa ^ sb) & (sa ^ sd)
    return sd ^ over


# ===== 語の取り出し =====
#
# 番地は lane ごとに違ってよいが、compile 時に決まる覆い（19 式 6.1）では
# どの lane も同じ語を指す。同じなら平面が全 bit か零のどちらかになるので、
# 一度の畳みで見分けて、そのまま添字にする。

def uniform(cp, v, m, nb):
    """active な lane で値が揃っていれば Python の整数を返す。"""
    hit = v & m
    zero = (hit == 0).all(axis=1)
    ones = (hit == m).all(axis=1)
    if not bool((zero | ones).all()):
        return None
    bits = cp.asnumpy(ones)
    out = 0
    for k in range(nb):
        if bits[k]:
            out |= 1 << k
    return out


def lane_values(cp, v, nb, w):
    """lane ごとの値を並べる。番地が揃わないときだけ使う遅い道になる。"""
    # CuPy の unpackbits は軸を取らないので、平らにしてから並べ直す
    flat = cp.unpackbits(v.ravel(), bitorder='little').reshape(v.shape[0], -1)
    host = cp.asnumpy(flat[:, :w])
    return [sum(1 << k for k in range(nb) if host[k][l]) for l in range(w)]


def active_lanes(cp, m, w):
    flags = cp.asnumpy(cp.unpackbits(m, bitorder='little')[:w])
    return [l for l in range(w) if flags[l]]


class CuLane(object):
    """Σ_lane64 を bit のまま持つ（20 式 1.1）。

    R は landmark、M は作業領域。どちらも (語, NB, LB) の bit 平面になる。
    lane の作業領域は式 (1.2) で交わらないので、lane 軸を詰めても混ざらない。
    """

    def __init__(self, prog, lanes=1, words=4096, bits=32):
        cp = self.cp = _cp()
        self.prog = prog
        self.W = lanes
        self.NB = bits
        self.LB = lane_bytes(lanes)
        self.full = lane_mask(cp, lanes)
        self.R = cp.zeros((LANDMARKS, bits, self.LB), dtype=cp.uint8)
        self.M = cp.zeros((words, bits, self.LB), dtype=cp.uint8)
        self.words = words
        self.OUT = [[] for _ in range(lanes)]
        self.report = [None] * lanes
        self.steps = 0
        self.over = cp.zeros(self.LB, dtype=cp.uint8)
        self._imm = {}

    # ---- host からの受け渡し（20 式 8.2）----

    def put_input(self, data, base):
        cp = self.cp
        n = min(len(data), self.words - base)
        self._store_const(0, n)
        self._store_const(1, base)
        for k in range(n):
            self._store_const(base + k, data[k])
        return n

    def _store_const(self, addr, value):
        self.M[addr] = const(self.cp, value, self.NB, self.LB, self.full)

    def word(self, addr):
        """語ひとつを lane ごとに読む。符号は最上位の平面が持つ。"""
        vals = lane_values(self.cp, self.M[addr], self.NB, self.W)
        top = 1 << (self.NB - 1)
        return [v - (1 << self.NB) if v & top else v for v in vals]

    # ---- 即値。同じ image の中で何度も出るので束ねる ----

    def imm(self, value):
        got = self._imm.get(value)
        if got is None:
            got = const(self.cp, value, self.NB, self.LB, self.full)
            self._imm[value] = got
        return got

    # ---- 一歩（20 §5 の式 2.1、§6 の式 3.2、3.3）----

    def run(self, budget=1 << 24):
        cp, nb, full = self.cp, self.NB, self.full
        prog, n = self.prog, len(self.prog)
        groups = [(full, 0)]
        while groups:
            self.steps += 1
            if self.steps > budget:
                raise RuntimeError('歩数上限 %d を越えた' % budget)
            k = 0 if len(groups) == 1 else min(
                range(len(groups)), key=lambda i: groups[i][1])
            m, pc = groups.pop(k)
            if pc < 0 or pc >= n:
                continue
            op, a, b, c, sb, sc, im = prog[pc]
            if op == HALT:
                continue
            if op == OK or op == KO:
                for l in active_lanes(cp, m, self.W):
                    self.report[l] = 0 if op == OK else 42
                continue
            if op == JMP:
                groups = _merge(cp, groups, [(m, pc + im)])
                continue
            if op == EQ or op == LT:
                u = shl(cp, self.R[b], sb, nb)
                v = shl(cp, self.R[c], sc, nb)
                cm = eq_mask(cp, u, v) if op == EQ else lt_mask(cp, u, v, nb, full)
                groups = _merge(cp, groups,
                                [(m & cm, pc + im), (m & ~cm, pc + 1)])
                continue
            self._value(op, a, b, c, sb, sc, im, m)
            groups = _merge(cp, groups, [(m, pc + 1)])
        return self.report

    def _value(self, op, a, b, c, sb, sc, im, m):
        cp, nb, full = self.cp, self.NB, self.full
        if op == MAT:
            self.R[a] = select(self.imm(im), self.R[a], m)
            return
        if op == ADD:
            u = shl(cp, self.R[b], sb, nb)
            v = shl(cp, self.R[c], sc, nb)
            r, carry = addc(cp, u, v, None, nb)
            # 同符号どうしで符号が変われば桁が足りない。巻き戻さず記録する
            bad = (~(u[nb - 1] ^ v[nb - 1])) & (u[nb - 1] ^ r[nb - 1])
            self.over |= bad & m
            self.R[a] = select(r, self.R[a], m)
            return
        if op == MUL:
            self.R[a] = select(mul(cp, self.R[b], self.R[c], nb), self.R[a], m)
            return
        if op == NEG:
            self.R[a] = select(negate(cp, self.R[b], nb, full), self.R[a], m)
            return
        if op == PUT:
            low = self.R[b][:8]
            vals = lane_values(cp, low, 8, self.W)
            for l in active_lanes(cp, m, self.W):
                self.OUT[l].append(vals[l] & 255)
            return
        if op == LD:
            addr = uniform(cp, self.R[b], m, nb)
            if addr is not None:
                self.R[a] = select(self.M[addr], self.R[a], m)
            else:
                self._load_spread(a, b, m)
            return
        if op == ST:
            addr = uniform(cp, self.R[b], m, nb)
            if addr is not None:
                self.M[addr] = select(self.R[c], self.M[addr], m)
            else:
                self._store_spread(b, c, m)
            return
        raise ValueError('未知の op %d' % op)

    # ---- 番地が lane ごとに違う場合。lane を一本ずつ当たる ----

    def _lane_bit(self, l):
        cp = self.cp
        one = cp.zeros(self.LB, dtype=cp.uint8)
        one[l // 8] = 1 << (l % 8)
        return one

    def _load_spread(self, a, b, m):
        cp = self.cp
        addrs = lane_values(cp, self.R[b], self.NB, self.W)
        for l in active_lanes(cp, m, self.W):
            bit = self._lane_bit(l)
            self.R[a] = select(self.M[addrs[l]], self.R[a], bit)

    def _store_spread(self, b, c, m):
        cp = self.cp
        addrs = lane_values(cp, self.R[b], self.NB, self.W)
        for l in active_lanes(cp, m, self.W):
            bit = self._lane_bit(l)
            self.M[addrs[l]] = select(self.R[c], self.M[addrs[l]], bit)

    def overflowed(self):
        return bool((self.over != 0).any())


def _merge(cp, groups, fresh):
    """reconvergence（式 3.3）。pc が同じ組は bit 列を合わせて一つにする。"""
    out = list(groups)
    for m, pc in fresh:
        if not bool((m != 0).any()):
            continue
        for k, (m2, p2) in enumerate(out):
            if p2 == pc:
                out[k] = (m2 | m, pc)
                break
        else:
            out.append((m, pc))
    return out


def run(prog, lanes=1, words=4096, bits=32, data=None, in_base=64,
        head=4, emit=False):
    """一枚の image を W lane 分だけ走らせる。返りは vcpu.VCPU.run と同じ形。"""
    lane = CuLane(prog, lanes=lanes, words=words, bits=bits)
    if data is not None:
        lane.put_input(data, in_base)
    rep = lane.run()
    if lane.overflowed():
        sys.stderr.write('語 %d bit を越えた。--bits を増やす\n' % bits)
    top = [lane.word(k) for k in range(max(head, 3))]
    out = []
    for l in range(lanes):
        emitted = None
        if emit:
            base, ln = top[1][l], top[2][l]
            if base and ln:
                emitted = bytes(v & 255 for v in
                                (lane.word(base + k)[l] for k in range(ln)))
        out.append((rep[l], bytes(lane.OUT[l]), [t[l] for t in top],
                    emitted, lane.steps))
    return out
