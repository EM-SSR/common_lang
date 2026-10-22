# -*- coding: utf-8 -*-
"""lane64 の実行台。

仕様は docs/common-compiler/arch/20。標準機能だけで書く。

道は二本ある。

  解釈器  式 (2.1) の mask 付き意味をそのまま持つ。これが定義になる
  翻訳器  block を Python の code object へ落とす。速い道になる

命題 6.1 が二本の一致を保証し、test_vcpu.py がそれを実際に確かめる。
lane の作業領域は式 (1.2) で交わらないので、翻訳器の道は lane を process へ配れる。

  python vcpu.py image.bin --lanes 8 --words 65536 --procs 6 --in corpus.txt
"""

import os
import sys
import time

INSN = 16

HALT, MAT, ADD, MUL, NEG, EQ, LT, JMP, LD, ST, OK, KO, PUT = range(13)

NAME = ('HALT', 'MAT', 'ADD', 'MUL', 'NEG', 'EQ', 'LT', 'JMP',
        'LD', 'ST', 'OK', 'KO', 'PUT')

# block を閉じる箱（20 章 式 7.4）
TERM = frozenset([EQ, LT, JMP, OK, KO, HALT])

# 報告の返り値。block の番号と混ざらないよう負で持つ
R_OK, R_KO, R_END = -1, -2, -3

LANDMARKS = 256


# ===== 復号（20 章 §2）=====

def decode(image):
    """image を欄の組の並びへ開く。

    固定 16 byte なので、長さを数える走査が要らない。欄の並びは
    op / a / b / c / s_b / s_c / imm で、全部 little endian になる。
    """
    if len(image) % INSN:
        raise ValueError('image の byte 数が %d の倍数でない: %d' % (INSN, len(image)))
    prog = []
    for k in range(0, len(image), INSN):
        w = image[k:k + INSN]
        prog.append((w[0], w[1], w[2], w[3],
                     w[4] | (w[5] << 8), w[6] | (w[7] << 8),
                     int.from_bytes(w[8:16], 'little', signed=True)))
    return prog


def encode(prog):
    """復号の逆（式 40.1、30.4）。二つを往復させると image が戻る。"""
    out = bytearray()
    for (op, a, b, c, sb, sc, im) in prog:
        out += bytes([op, a, b, c, sb & 255, sb >> 8, sc & 255, sc >> 8])
        out += int(im).to_bytes(8, 'little', signed=True)
    return bytes(out)


def disasm(prog):
    out = []
    for i, (op, a, b, c, sb, sc, im) in enumerate(prog):
        out.append('%5d  %-4s a=%-3d b=%-3d c=%-3d sb=%-2d sc=%-2d imm=%d'
                   % (i, NAME[op] if op < len(NAME) else '?', a, b, c, sb, sc, im))
    return out


# ===== block（20 章 §7.3）=====

def entries(prog):
    """block の入口（式 7.4）。分岐の行き先と、分岐の次が入口になる。"""
    n = len(prog)
    e = set([0])
    for i, (op, _a, _b, _c, _sb, _sc, im) in enumerate(prog):
        if op in TERM:
            e.add(i + 1)
            if op in (EQ, LT, JMP):
                e.add(i + im)
    return sorted(x for x in e if 0 <= x < n)


def blocks(prog):
    """(入口, 直線部分の箱, 閉じる箱 or None, 次の入口) の並び。

    閉じる箱が None のときは、次の入口へそのまま落ちる。
    """
    ent = entries(prog)
    n = len(prog)
    out = []
    for k, pc in enumerate(ent):
        stop = ent[k + 1] if k + 1 < len(ent) else n
        j = pc
        body = []
        while j < stop and prog[j][0] not in TERM:
            body.append(j)
            j += 1
        out.append((pc, body, j if j < stop else None, stop))
    return ent, dict((pc, k) for k, pc in enumerate(ent)), out


# ===== 層（20 章 §7.1）=====

def layers(prog, body):
    """直線部分の因果深度（式 7.1）と層（式 7.2）。

    実行の速さには効かない。効くのは「並べ替えてよい」という保証のほうで、
    それが block を直線に書き下せる根拠になる（定理 21.1）。層の幅は
    その保証がどれだけ広いかの目安として出す。
    """
    depth, last, lay = {}, {}, []
    for i in body:
        op, a, b, c = prog[i][0], prog[i][1], prog[i][2], prog[i][3]
        pred = ()
        if op in (ADD, MUL):
            pred = (b, c)
        elif op in (NEG, LD):
            pred = (b,)
        elif op in (ST, PUT):
            pred = (b, c) if op == ST else (b,)
        d = 0
        for r in pred:
            if r in last:
                d = max(d, last[r] + 1)
        depth[i] = d
        if op in (MAT, ADD, MUL, NEG, LD):
            last[a] = d
        while len(lay) <= d:
            lay.append([])
        lay[d].append(i)
    return lay


# ===== 層を同時に走らせる（定理 21.1）=====
#
# 層の中の箱は互いに独立なので、どの順で走らせても、同時に走らせても観測が変わらない。
#
#   (C1 ⊗ id);(id ⊗ C2) = C1 ⊗ C2                          定理 21.1
#
# 配るのは値の箱だけになる。作業領域を触る箱は番地がワイヤの値なので別名を排除できず
# （§19）、本文の順のまま置く。だから値の箱の連なりを先に切り出し、その中でだけ
# 層を作る。
#
# 割に合うかは箱一つの重さで決まる。分子が Z なので、深い作図では一つの ⋆ が
# 多倍長の乗算になり、配る費用を上回る。

_ARITH = frozenset([MAT, ADD, MUL, NEG])


def _box(job):
    """値の箱を一つ。ワイヤの値だけを受けるので、worker は state を持たない。"""
    op, a, u, v, sb, sc, im = job
    if op == MUL:
        return a, u * v
    if op == ADD:
        return a, (u << sb) + (v << sc)
    if op == MAT:
        return a, im
    if op == NEG:
        return a, -u
    raise ValueError('値の箱ではない: %s' % NAME[op])


def _runs(prog, body):
    """値の箱の連なりと、作業領域を触る箱を、本文の順に切り分ける。"""
    out, cur = [], []
    for i in body:
        if prog[i][0] in _ARITH:
            cur.append(i)
        else:
            if cur:
                out.append((True, cur))
                cur = []
            out.append((False, i))
    if cur:
        out.append((True, cur))
    return out


def _layers_hz(prog, seg):
    """並べ替えてよい層。式 (7.1) の Pred に WAR と WAW を足す。

    landmark は allocator が使い回す（13 §13 の wire-to-landmark embedding）ので、
    RAW だけでは並べ替えの根拠にならない。定理 21.1 の独立性はワイヤの上の話であり、
    割り当ての後まで自動では届かない。
    """
    lastw, lastr, lay = {}, {}, []
    for i in seg:
        rs, w = _regs(prog, i)
        d = 0
        for r in rs:
            if r in lastw:
                d = max(d, lastw[r] + 1)
        if w is not None:
            if w in lastw:
                d = max(d, lastw[w] + 1)
            if w in lastr:
                d = max(d, lastr[w] + 1)
        for r in rs:
            lastr[r] = max(lastr.get(r, -1), d)
        if w is not None:
            lastw[w] = d
        while len(lay) <= d:
            lay.append([])
        lay[d].append(i)
    return lay


def _job(prog, R, i):
    op, a, b, c, sb, sc, im = prog[i]
    return (op, a, R[b], R[c], sb, sc, im)


def run_lane_par(prog, lane, pool=None, minw=2, budget=1 << 34):
    """block を層の順に走らせ、幅のある層を pool へ配る。"""
    R, M, OUT = lane.R, lane.M, lane.OUT
    _ent, idx, bl = blocks(prog)
    n, b = len(prog), 0
    for step in range(budget):
        _pc, body, term, stop = bl[b]
        for arith, seg in _runs(prog, body):
            if not arith:
                op, a, u, v = prog[seg][0], prog[seg][1], prog[seg][2], prog[seg][3]
                if op == LD:
                    R[a] = M[R[u]]
                elif op == ST:
                    M[R[u]] = R[v]
                elif op == PUT:
                    OUT.append(R[u] & 255)
                else:
                    raise ValueError('直線部分に置けない箱: %s' % NAME[op])
                continue
            for L in _layers_hz(prog, seg):
                outs = [prog[i][1] for i in L]
                wide = (pool is not None and len(L) >= minw
                        and len(set(outs)) == len(outs))
                if wide:
                    for a, val in pool.map(_box, [_job(prog, R, i) for i in L]):
                        R[a] = val
                else:
                    for i in L:
                        a, val = _box(_job(prog, R, i))
                        R[a] = val
        lane.blocks = step + 1
        if term is None:
            if stop < n:
                b = idx[stop]
                continue
            lane.report = None
            return None
        op, _a, bb, cc, sb, sc, im = prog[term]
        if op == OK:
            lane.report = 0
            return 0
        if op == KO:
            lane.report = 42
            return 42
        if op == HALT:
            lane.report = None
            return None
        if op == JMP:
            t = term + im
        else:
            u, v = R[bb] << sb, R[cc] << sc
            t = term + im if ((u == v) if op == EQ else (u < v)) else term + 1
        if 0 <= t < n and t in idx:
            b = idx[t]
        else:
            lane.report = None
            return None
    raise RuntimeError('block の歩数上限 %d を越えた' % budget)


# ===== 翻訳（20 章 §7.2）=====

# ===== 定理 21.1 の回収 =====
#
# 層分解（式 7.1、7.2）は block を「state を共有しない独立 chamber の積」だと言う。
#
#   (C1 ⊗ id);(id ⊗ C2) = C1 ⊗ C2                          定理 21.1
#
# だから block の中で landmark file を辿る必要が無い。読む前に書かない landmark を
# 入口で local へ写し、書いた landmark を出口で戻せば、間は local variable で足りる。
# CPython では R[k] が LOAD_FAST + LOAD_CONST + BINARY_SUBSCR、local は LOAD_FAST 一つ。
#
# 作業領域 M は別。番地がワイヤの値なので別名を排除できない（§19）。

def _regs(prog, i):
    """(読む landmark, 書く landmark)。M と OUT はここに現れない。"""
    op, a, b, c = prog[i][0], prog[i][1], prog[i][2], prog[i][3]
    if op == MAT:
        return (), a
    if op in (ADD, MUL):
        return (b, c), a
    if op in (NEG, LD):
        return (b,), a
    if op == ST:
        return (b, c), None
    if op in (PUT,):
        return (b,), None
    if op in (EQ, LT):
        return (b, c), None
    return (), None


def _shift(name, r, s):
    return name(r) if s == 0 else '(%s<<%d)' % (name(r), s)


def _stmt(prog, i, name=None):
    if name is None:
        name = lambda r: 'R[%d]' % r
    op, a, b, c, sb, sc, im = prog[i]
    if op == MAT:
        return '%s=%d' % (name(a), im)
    if op == ADD:
        return '%s=%s+%s' % (name(a), _shift(name, b, sb), _shift(name, c, sc))
    if op == MUL:
        return '%s=%s*%s' % (name(a), name(b), name(c))
    if op == NEG:
        return '%s=-%s' % (name(a), name(b))
    if op == LD:
        return '%s=M[%s]' % (name(a), name(b))
    if op == ST:
        return 'M[%s]=%s' % (name(b), name(c))
    if op == PUT:
        return 'OUT.append(%s&255)' % name(b)
    raise ValueError('直線部分に置けない箱: %s' % NAME[op])


def _tail(prog, i, stop, idx, n, name=None):
    """block の閉じ。行の並びを返す。"""
    if name is None:
        name = lambda r: 'R[%d]' % r
    if i is None:
        return ['return %d' % idx[stop]] if stop < n else ['return %d' % R_END]

    def to(t):
        return idx[t] if 0 <= t < n and t in idx else R_END

    op, _a, b, c, sb, sc, im = prog[i]
    if op == OK:
        return ['return %d' % R_OK]
    if op == KO:
        return ['return %d' % R_KO]
    if op == HALT:
        return ['return %d' % R_END]
    if op == JMP:
        return ['return %d' % to(i + im)]
    rel = '==' if op == EQ else '<'
    return ['if %s%s%s: return %d'
            % (_shift(name, b, sb), rel, _shift(name, c, sc), to(i + im)),
            'return %d' % to(i + 1)]


def _succ(prog, term, stop, idx, n):
    """block の後続。_tail の行き先と同じ。"""
    if term is None:
        return [idx[stop]] if stop < n else []

    def to(t):
        return idx[t] if 0 <= t < n and t in idx else None

    op, _a, _b, _c, _sb, _sc, im = prog[term]
    if op in (OK, KO, HALT):
        return []
    if op == JMP:
        return [x for x in [to(term + im)] if x is not None]
    return [x for x in [to(term + im), to(term + 1)] if x is not None]


def _liveness(prog, bl, idx, n):
    """block ごとの live-out（後続が読む landmark の合併）。

    block を出た landmark file を読むのは後続 block だけであり、実行台は
    作業領域と OUT しか見ない。だから最後の block の live-out は空になる。
    """
    use, dfs, succ = [], [], []
    for pc, body, term, stop in bl:
        w, u = set(), set()
        for i in list(body) + ([] if term is None else [term]):
            rs, d = _regs(prog, i)
            u |= set(r for r in rs if r not in w)
            if d is not None:
                w.add(d)
        use.append(u)
        dfs.append(w)
        succ.append(_succ(prog, term, stop, idx, n))
    live_in = [set() for _ in bl]
    live_out = [set() for _ in bl]
    moved = True
    while moved:
        moved = False
        for k in range(len(bl) - 1, -1, -1):
            o = set()
            for t in succ[k]:
                o |= live_in[t]
            i = use[k] | (o - dfs[k])
            if o != live_out[k] or i != live_in[k]:
                live_out[k], live_in[k] = o, i
                moved = True
    return live_out


def _block(prog, k, body, term, stop, idx, n, out_live=None, dead=None, scan=None):
    """block ひとつを関数の行へ落とす。

    block の中では値を記号で追う（局所の値番号付け）。doc: casm.lane64.vn

      landmark   reg[r] は入口の値 R[r]、即値、または局所変数の名前
      作業領域   mem[c] は定数番地 c へこの block が書いた値。次の Load はその名前を使う

    即値どうしの算術は畳む。commonc の lane64 版はワイヤを語 64 + w に置き、
    一箱が MAT・LD・ST の往復に開くので（back_lane64.cam の覆い）、この追跡で
    往復が消え、綴った数は一つの即値に畳まれる。Store は他の block が読むので残す。
    ただし dead に入った番地への Store は落とす（他のどの block も読まないワイヤ）。
    scan を渡すと文を出さず、この block が読む定数番地のうち、自分の Store より前に
    読むものを scan へ集める（translate の一巡目）。
    意味は式 (2.1) の解釈器が定義であり、test_vcpu.py が両者の一致を確かめる。
    """
    steps = list(body) + ([] if term is None else [term])
    reg = {}
    mem = {}
    tmp = [0]
    out = ['def _b%d(R, M, OUT):' % k]

    def get(r):
        if r not in reg:
            reg[r] = 'R[%d]' % r
        return reg[r]

    def lit(e):
        try:
            return int(e)
        except ValueError:
            return None

    def shifted(r, sh):
        e = get(r)
        v = lit(e)
        if sh == 0:
            return e
        if v is not None:
            return str(v << sh)
        return '(%s<<%d)' % (e, sh)

    def fresh(expr):
        tmp[0] += 1
        name = 't%d' % tmp[0]
        out.append('    %s=%s' % (name, expr))
        return name

    def fold2(x, y, f, sym):
        vx, vy = lit(x), lit(y)
        if vx is not None and vy is not None:
            return str(f(vx, vy))
        return fresh('%s%s%s' % (x, sym, y))

    for i in body:
        op, a, b, c, sb, sc, im = prog[i]
        if op == MAT:
            reg[a] = str(im)
        elif op == ADD:
            reg[a] = fold2(shifted(b, sb), shifted(c, sc), lambda x, y: x + y, '+')
        elif op == MUL:
            reg[a] = fold2(get(b), get(c), lambda x, y: x * y, '*')
        elif op == NEG:
            e = get(b)
            v = lit(e)
            reg[a] = str(-v) if v is not None else fresh('-%s' % e)
        elif op == LD:
            addr = get(b)
            v = lit(addr)
            if v is not None and v in mem:
                reg[a] = mem[v]
            else:
                if scan is not None:
                    scan.add(v)
                reg[a] = fresh('M[%s]' % addr)
                if v is not None:
                    mem[v] = reg[a]
        elif op == ST:
            addr, val = get(b), get(c)
            v = lit(addr)
            if not (dead is not None and v in dead):
                out.append('    M[%s]=%s' % (addr, val))
            if v is not None:
                mem[v] = val
            else:
                mem.clear()
        elif op == PUT:
            out.append('    OUT.append(%s&255)' % get(b))
        else:
            raise ValueError('直線部分に置けない箱: %s' % NAME[op])
    keep = set(reg) if out_live is None else (set(reg) & out_live)
    for r in sorted(keep):
        if reg[r] != 'R[%d]' % r:
            out.append('    R[%d]=%s' % (r, reg[r]))
    if term is None:
        tail = _tail(prog, None, stop, idx, n)
    else:
        op, _a, b, c, sb, sc, im = prog[term]
        if op in (EQ, LT):
            rel = '==' if op == EQ else '<'
            x, y = shifted(b, sb), shifted(c, sc)
            vx, vy = lit(x), lit(y)
            to = lambda t: idx[t] if 0 <= t < n and t in idx else R_END
            if vx is not None and vy is not None:
                taken = (vx == vy) if op == EQ else (vx < vy)
                tail = ['return %d' % (to(term + im) if taken else to(term + 1))]
            else:
                tail = ['if %s%s%s: return %d' % (x, rel, y, to(term + im)),
                        'return %d' % to(term + 1)]
        else:
            tail = _tail(prog, term, stop, idx, n)
    out += ['    ' + t for t in tail]
    return out + ['']


def translate(prog, wires=None):
    """image を Python の source と code object へ落とす。

    block ひとつが関数ひとつになる。式 (0.1) の B は block を実行した回数であり、
    箱の数ではない。landmark file は block の入口と出口だけで触る（定理 21.1）。

    wires = (lo, hi) を渡すと、その区間の語は commonc のワイヤ（語 64 + w、19 §3.3）とみなし、
    他のどの block も読まない Store を落とす。ワイヤは箱の番号で名指しされるので、
    平文の側から計算した番地で読まれることは無い（toolchain が作業領域をワイヤの上に置く）。
    区間の外の語（出口 0..63、作業領域、退避語）は残す。
    """
    ent, idx, bl = blocks(prog)
    n = len(prog)
    live = _liveness(prog, bl, idx, n)
    dead = None
    if wires is not None:
        lo, hi = wires
        read = set()
        for k, (pc, body, term, stop) in enumerate(bl):
            _block(prog, k, body, term, stop, idx, n, live[k], scan=read)
        dead = set(c for c in range(lo, hi) if c not in read)
    lines = []
    for k, (pc, body, term, stop) in enumerate(bl):
        lines += _block(prog, k, body, term, stop, idx, n, live[k], dead=dead)
    lines.append('TAB = (' + ''.join('_b%d,' % k for k in range(len(bl))) + ')')
    src = chr(10).join(lines)
    ns = {}
    exec(compile(src, '<lane64>', 'exec'), ns)
    return src, ns['TAB']


# ===== lane 一枚（翻訳器の道）=====

class Lane(object):
    """Σ_lane64 の一枚（20 章 式 1.1）。語は Z なので巻き戻さない（§0.3）。"""

    def __init__(self, words):
        self.R = [0] * LANDMARKS
        self.M = [0] * words
        self.OUT = []
        self.report = None
        self.blocks = 0

    def put_input(self, data, base):
        """18 章 §7.1 と同じ置き方（式 8.2）。"""
        n = min(len(data), len(self.M) - base)
        self.M[0] = n
        self.M[1] = base
        self.M[base:base + n] = data[:n]
        return n


def run_lane(tab, lane, budget=1 << 34):
    """block を辿る。式 (0.1) の T_trans がこの loop になる。"""
    R, M, OUT = lane.R, lane.M, lane.OUT
    b = 0
    try:
        for k in range(budget):
            b = tab[b](R, M, OUT)
            if b < 0:
                lane.blocks = k + 1
                lane.report = 0 if b == R_OK else (42 if b == R_KO else None)
                return lane.report
    except IndexError:
        # 語番号が作業領域を越えた。式 (50.4) の image 実現不能にあたる。
        # try は例外が飛ばない限り費用ゼロなので、速い道の邪魔にならない
        raise IndexError('語番号が作業領域を越える（語数 %d）。--words を増やす'
                         % len(M))
    raise RuntimeError('block の歩数上限 %d を越えた' % budget)


# ===== 解釈器（式 2.1、3.1、3.2、3.3）=====
#
# active relation は W bit の整数一個で持つ。m1 = m & c、m0 = m & ~c が
# それぞれ一演算になる。速さのためではなく、意味の定義を一箇所に置くために書く。

class Interp(object):

    def __init__(self, prog, lanes=1, words=4096):
        self.prog = prog
        self.W = lanes
        self.R = [[0] * LANDMARKS for _ in range(lanes)]
        self.M = [[0] * words for _ in range(lanes)]
        self.OUT = [[] for _ in range(lanes)]
        self.report = [None] * lanes
        self.steps = 0

    def put_input(self, lane, data, base):
        m = self.M[lane]
        n = min(len(data), len(m) - base)
        m[0] = n
        m[1] = base
        m[base:base + n] = data[:n]
        return n

    _one = (0,)

    def _active(self, m):
        return [l for l in range(self.W) if (m >> l) & 1]

    def run(self, budget=1 << 30):
        prog, n = self.prog, len(self.prog)
        groups = [(((1 << self.W) - 1), 0)]
        while groups:
            self.steps += 1
            if self.steps > budget:
                raise RuntimeError('歩数上限 %d を越えた' % budget)
            if len(groups) == 1:
                msk, pc = groups.pop()          # 判定が割れるまでは組が一つ
            else:
                k = min(range(len(groups)), key=lambda i: groups[i][1])
                msk, pc = groups.pop(k)
            if msk == 0 or pc < 0 or pc >= n:
                continue
            op, a, b, c, sb, sc, im = prog[pc]
            act = (self._one if msk == 1 else self._active(msk))
            if op == HALT:
                continue
            if op == OK or op == KO:
                for l in act:
                    self.report[l] = 0 if op == OK else 42
                continue
            if op == JMP:
                groups = _merge(groups, [(msk, pc + im)])
                continue
            if op == EQ or op == LT:
                cm = 0
                for l in act:
                    R = self.R[l]
                    u, v = R[b] << sb, R[c] << sc
                    if (u == v) if op == EQ else (u < v):
                        cm |= 1 << l
                m1, m0 = msk & cm, msk & ~cm     # 式 (3.2)
                groups = _merge(groups, [(m1, pc + im), (m0, pc + 1)])
                continue
            # 値の箱。mask を外れた lane は動かない（式 2.1）
            for l in act:
                R = self.R[l]
                if op == MAT:
                    R[a] = im
                elif op == ADD:
                    R[a] = (R[b] << sb) + (R[c] << sc)
                elif op == MUL:
                    R[a] = R[b] * R[c]
                elif op == NEG:
                    R[a] = -R[b]
                elif op == LD:
                    R[a] = self.M[l][R[b]]
                elif op == ST:
                    self.M[l][R[b]] = R[c]
                elif op == PUT:
                    self.OUT[l].append(R[b] & 255)
            groups = _merge(groups, [(msk, pc + 1)])
        return self.report


def _merge(groups, fresh):
    """reconvergence（式 3.3）。pc が同じ組は mask を合わせて一つにする。"""
    if not groups and len(fresh) == 1 and fresh[0][0]:
        return list(fresh)                      # 割れていない間はそのまま渡す
    out = list(groups)
    for msk, pc in fresh:
        if msk == 0:
            continue
        for k, (m2, p2) in enumerate(out):
            if p2 == pc:
                out[k] = (m2 | msk, pc)
                break
        else:
            out.append((msk, pc))
    return out


# ===== lane を process へ配る（20 章 §0.5）=====
#
# 立ち上げに 600 ms かかるので、pool は host の寿命だけ持ち続ける。
# lane の作業領域が式 (1.2) で交わらないから、持ち回しても state が混ざらない。

_W = {}          # worker の中の束縛。image ごとに一度だけ翻訳する


def _worker_init():
    _W.clear()


def _worker_run(job):
    image, words, data, in_base, head, emit, count = job
    # 束縛の鍵は image そのものにする。長さや id で引くと、同じ大きさの別の
    # image が前の翻訳を拾う
    tab = _W.get(image)
    if tab is None:
        tab = translate(decode(image))[1]
        _W[image] = tab
    res = []
    for _ in range(count):
        lane = Lane(words)
        if data is not None:
            lane.put_input(data, in_base)
        rep = run_lane(tab, lane)
        emitted = None
        if emit:
            base, ln = lane.M[1], lane.M[2]
            if base and ln:
                emitted = bytes(v & 255 for v in lane.M[base:base + ln])
        res.append((rep, bytes(lane.OUT), list(lane.M[:head]), emitted, lane.blocks))
    return res


def _run_share(tab, count, words, data, in_base, head, emit):
    """同じ image を lane 何本か分だけ回す。lane の作業領域は式 (1.2) で
    交わらないので、この呼びは互いに独立になる（定理 21.1）。"""
    out = []
    for _ in range(count):
        lane = Lane(words)
        if data is not None:
            lane.put_input(data, in_base)
        rep = run_lane(tab, lane)
        emitted = None
        if emit:
            base, ln = lane.M[1], lane.M[2]
            if base and ln:
                emitted = bytes(v & 255 for v in lane.M[base:base + ln])
        out.append((rep, bytes(lane.OUT), list(lane.M[:head]), emitted,
                    lane.blocks))
    return out


class VCPU(object):
    """常駐の実行台。pool を作り直さない（式 0.4）。

    lane を配る先は二つある。process は写す量が要るかわりに本当に同時に走る。
    thread は image の翻訳を共有できるので配る費用がほぼ無い。どちらを取るかは
    lane 一本の仕事量で決まるので、両方を持って測れるようにする。
    """

    def __init__(self, procs=1, threads=1):
        self.P = max(1, int(procs))
        self.T = max(1, int(threads))
        self.pool = None
        self.tpool = None
        self._tab = {}

    def close(self):
        if self.pool is not None:
            self.pool.close()
            self.pool.join()
            self.pool = None
        if self.tpool is not None:
            self.tpool.shutdown()
            self.tpool = None

    def _ensure(self):
        if self.pool is None and self.P > 1:
            import multiprocessing as mp
            self.pool = mp.Pool(self.P, initializer=_worker_init)
        return self.pool

    def _threads(self):
        """立ち上げたら畳まない。次の run は待機中の worker がそのまま拾う。"""
        if self.tpool is None and self.T > 1:
            from concurrent.futures import ThreadPoolExecutor
            self.tpool = ThreadPoolExecutor(self.T)
            list(self.tpool.map(lambda _: None, range(self.T)))
        return self.tpool

    def _shares(self, lanes, n):
        return [c for c in (lanes // n + (1 if k < lanes % n else 0)
                            for k in range(n)) if c]

    def _table(self, image):
        tab = self._tab.get(image)
        if tab is None:
            tab = translate(decode(image))[1]
            self._tab[image] = tab
        return tab

    def run(self, image, lanes=1, words=4096, data=None, in_base=64,
            head=64, emit=False):
        """lane を P 本の process へ均等に配る。返りは lane ごとの組になる。

        組は (報告, Put の byte 列, 先頭 head 語, 取り出した image, block 数)。
        作業領域まるごとを持ち帰らないのは、process 間で写す量を抑えるためになる。
        """
        if lanes > 1 and self.T > 1:
            tab = self._table(image)
            futs = [self._threads().submit(_run_share, tab, c, words, data,
                                           in_base, head, emit)
                    for c in self._shares(lanes, self.T)]
            res = []
            for f in futs:
                res.extend(f.result())
            return res
        if self.P <= 1 or lanes == 1:
            return _run_share(self._table(image), lanes, words, data, in_base,
                              head, emit)
        jobs = [(image, words, data, in_base, head, emit, c)
                for c in self._shares(lanes, self.P)]
        res = []
        for part in self._ensure().map(_worker_run, jobs):
            res.extend(part)
        return res


# ===== CLI =====

def _usage():
    sys.stderr.write(
        'vcpu <image.bin> [option]\n'
        '  --lanes W    lane 数。既定 1（20 章 式 1.1）\n'
        '  --words S    lane あたりの語数。既定 4096\n'
        '  --procs P    lane を配る process の本数。既定 1\n'
        '  --in F       全 lane の作業領域へ F を写す。語 0 が byte 数、語 1 が基底\n'
        '  --in-base B  本文の基底語番号。既定 64\n'
        '  --dump N     復帰後に語 0..N-1 を出す\n'
        '  --emit F     lane 0 が組んだ image を取り出す（19 章 §3.1）\n'
        '  --interp     式 (2.1) の mask 付き解釈器で走らせる\n'
        '  --cupy       語も述語も bit のまま GPU で走らせる（cuvcpu）\n'
        '  --bits NB    --cupy の語の幅。既定 32\n'
        '  --list       image を逆アセンブルして並べる\n'
        '  --source     翻訳した Python を出す\n')


def main(argv):
    if len(argv) < 2:
        _usage()
        return 2
    img_path = argv[1]
    lanes, words, procs, dump, in_base, threads = 1, 4096, 1, 0, 64, 1
    par = 0
    bits = 32
    in_path = emit_path = None
    listing = interp = source = cupy = False
    i = 2
    while i < len(argv):
        a = argv[i]
        if a in ('--lanes', '--words', '--procs', '--dump', '--in-base',
                 '--threads', '--par', '--bits'):
            i += 1
            v = int(argv[i])
            if a == '--lanes':
                lanes = v
            elif a == '--words':
                words = v
            elif a == '--procs':
                procs = v
            elif a == '--threads':
                threads = v
            elif a == '--par':
                par = v
            elif a == '--bits':
                bits = v
            elif a == '--dump':
                dump = v
            else:
                in_base = v
        elif a == '--in':
            i += 1
            in_path = argv[i]
        elif a == '--emit':
            i += 1
            emit_path = argv[i]
        elif a == '--list':
            listing = True
        elif a == '--interp':
            interp = True
        elif a == '--cupy':
            cupy = True
        elif a == '--source':
            source = True
        else:
            _usage()
            return 2
        i += 1

    with open(img_path, 'rb') as f:
        image = f.read()
    prog = decode(image)

    if listing:
        for ln in disasm(prog):
            print(ln)
        return 0
    if source:
        print(translate(prog)[0])
        return 0

    data = None
    if in_path is not None:
        with open(in_path, 'rb') as f:
            data = f.read()

    t0 = time.perf_counter()
    if interp:
        m = Interp(prog, lanes=lanes, words=words)
        if data is not None:
            for l in range(lanes):
                m.put_input(l, data, in_base)
        rep = m.run()
        res = [(rep[l], bytes(m.OUT[l]), m.M[l][:max(dump, 3)], None, 0)
               for l in range(lanes)]
        note = '解釈器 %d 歩' % m.steps
    elif cupy:
        try:
            from . import cuvcpu
        except ImportError:
            import cuvcpu
        res = cuvcpu.run(prog, lanes=lanes, words=words, bits=bits, data=data,
                         in_base=in_base, head=max(dump, 4),
                         emit=emit_path is not None)
        note = 'GPU %d bit  %d 歩' % (bits, res[0][4])
    elif par:
        import multiprocessing as mp
        tab = None
        pool = mp.Pool(par)
        lane = Lane(words)
        if data is not None:
            lane.put_input(data, in_base)
        rep = run_lane_par(prog, lane, pool)
        pool.close()
        pool.join()
        res = [(rep, bytes(lane.OUT), list(lane.M[:max(dump, 4)]), None,
                lane.blocks)]
        note = '層並列 block %d 回' % lane.blocks
        del tab
    else:
        vm = VCPU(procs, threads)
        res = vm.run(image, lanes=lanes, words=words, data=data,
                     in_base=in_base, head=max(dump, 4), emit=emit_path is not None)
        vm.close()
        note = '翻訳器 block %d 回' % sum(r[4] for r in res)
    el = time.perf_counter() - t0

    bad = 0
    for l, (rep, out, head, _em, _b) in enumerate(res):
        tag = 'tu' if rep == 0 else ('te' if rep == 42 else '報告なし')
        if rep != 0:
            bad += 1
        if lanes <= 8 or l < 2 or l == lanes - 1:
            print('lane %-4d %s' % (l, tag))
    print('%s   %.3f 秒   lane %d   process %d   thread %d'
          % (note, el, lanes, procs, threads))

    rep0, out0, head0, em0, _ = res[0]
    if out0:
        print('out    : %d byte  %s' % (len(out0), out0.decode('latin-1')))
    for k in range(dump):
        v = head0[k]
        # 分子は Z なので、深い作図では十進へ落とすほうが計算より重くなる
        if v.bit_length() > 4096:
            print('  w[%d] = %d bit の整数' % (k, v.bit_length()))
        else:
            print('  w[%d] = %d' % (k, v))
    if emit_path is not None:
        if em0 is None:
            sys.stderr.write('image が空（語1=%d 語2=%d）\n' % (head0[1], head0[2]))
            return 1
        with open(emit_path, 'wb') as f:
            f.write(em0)
        print('image  : %s  %d byte' % (emit_path, len(em0)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
