# -*- coding: utf-8 -*-
"""lane64 の三本めの道。W 枚の lane を numpy の配列に束ね、block を一度に走らせる。

doc: casm.lane64.sem casm.lane64.merge casm.lane64.cost casm.simd

    解釈器   vcpu.Interp     式 (2.1) の mask 付き意味。これが定義になる
    翻訳器   vcpu.run_lane   block を Python の code object へ落とす。一枚
    束ね     ここ            同じ block を走る lane を配列の一次元に並べる

命題 6.1 が束ねの根拠になる。lane の作業領域は式 (1.2) で交わらないので、
(mask, pc) の組を pc 昇順に進める観測は、lane を一本ずつ走らせた観測に一致する。
だから組を「lane の添字」で持ってよく、mask の bit 演算は要らない。

20 章 §0.4 は「大整数の欄へ W 個を詰める」形を退けている。乗算が欄をまたいで
畳み込み、LD と ST は lane ごとに番地が違うためになる。配列はその制限を受けない。
gather と scatter が LD と ST をそのまま運ぶので、頭打ちの式 (0.3) は効かない。

作業領域は (語数, W) に取る。(W, 語数) では定数番地が stride になり、可変番地の
gather も遅くなる（W=1024 で 5.95 対 7.80 ns）。

    重さ = 語数 x W x 8 byte。W=256 で 語数 70000 なら 143 MB

語は Z（多倍長）が仕様（§0.3）だが、配列は int64 になる。だから `overflow` が
溢れを見る。溢れたら翻訳器の道へ落とす。証とソルバーの語は在庫・金・手数・
区画の番号なので 2^62 に遠く及ばない。commonc の compile はここへ載せない。
"""

import numpy as np

try:                      # パッケージとして使うとき
    from . import vcpu
    from .vcpu import (ADD, EQ, HALT, JMP, KO, LD, LT, MAT, MUL, NEG, OK, PUT, ST,
                       LANDMARKS, NAME, R_END, R_KO, R_OK, blocks)
except ImportError:       # このディレクトリを sys.path に入れて使うとき
    import vcpu
    from vcpu import (ADD, EQ, HALT, JMP, KO, LD, LT, MAT, MUL, NEG, OK, PUT, ST,
                      LANDMARKS, NAME, R_END, R_KO, R_OK, blocks)

GUARD = 1 << 62          # これを越えた語が出たら int64 の巻き戻しを疑う


class LaneVec(object):
    """W 枚の lane（式 1.1 の Σ_lane64 を W 本）。

    R[a] が landmark a の lane 方向のベクトル、M[c] が語 c の lane 方向のベクトルになる。
    どちらも第一軸が番号なので、定数番地は連続した W 語になる。
    """

    def __init__(self, width, words):
        self.W = width
        self.R = np.zeros((LANDMARKS, width), dtype=np.int64)
        self.M = np.zeros((words, width), dtype=np.int64)
        self.ix = np.arange(width, dtype=np.int64)
        self.OUT = [[] for _ in range(width)]
        self.report = [None] * width
        self.blocks = 0

    def seed(self, addr, values):
        """語 addr へ lane ごとの値を置く。put_input と違い、こちらは一語だけ動かす"""
        self.M[addr] = values

    def put_input(self, data, base):
        """18 章 §7.1 と同じ置き方（式 8.2）。全 lane へ同じ入力を配る"""
        n = min(len(data), self.M.shape[0] - base)
        self.M[0] = n
        self.M[1] = base
        self.M[base:base + n] = np.asarray(data[:n], dtype=np.int64)[:, None]
        return n

    def overflow(self):
        """int64 の巻き戻しを疑う語があるか。無ければ False"""
        return bool(np.abs(self.R).max() >= GUARD or np.abs(self.M).max() >= GUARD)


# ===== 分岐 =====
#
# 閉じの判定は lane ごとに割れる。三通りを返す。
#
#   全部が真     行き先ひとつ
#   全部が偽     行き先ひとつ
#   割れた       (真の lane の印, 真の行き先, 偽の行き先)
#
# 割れた先は run_vec が組へ足す。命題 6.1 により pc 昇順で進めれば観測は変わらない。

def _br(cond, yes, no):
    if cond.all():
        return yes
    if not cond.any():
        return no
    return (cond, yes, no)


# ===== block を numpy の文へ落とす =====
#
# 局所の値番号付けは翻訳器（vcpu._block）と同じ。違いは三つだけになる。
#
#   landmark   R[a][s]        s は組の印。全 lane なら slice(None) で view になる
#   作業領域   M[c][s]        番地が定数のとき。連続した W 語
#              M[addr, ixs]   番地がワイヤの値のとき。gather / scatter
#   即値       そのまま置く。numpy が broadcast する

def _block_vec(prog, k, body, term, stop, idx, n, out_live=None, dead=None, scan=None):
    steps = list(body) + ([] if term is None else [term])
    reg, mem, tmp = {}, {}, [0]
    out = ['def _v%d(R, M, OUT, ixs, s):' % k]

    # 定数番地の Load は M[c][s] になる。s が slice(None) のとき、これは写しではなく
    # view になる。同じ block が後で M[c][s] へ書くと、先に読んだ名前の中身が一緒に
    # 動く。翻訳器の道では M[c] が Python の int なので起きない。
    #
    #   t1 = M[A][s]        view
    #   M[A][s] = t2
    #   M[B][s] = t1 + t2   t1 は既に t2。Fibonacci が 2 の冪へ化ける
    #
    # 後ろに Store がある Load だけ写しを取る。番地がワイヤの値のときは
    # fancy indexing が写しを返すので、そのままでよい。
    last_st = -1
    for _p, _i in enumerate(body):
        if prog[_i][0] == ST:
            last_st = _p

    def get(r):
        if r not in reg:
            reg[r] = 'R[%d][s]' % r
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

    for pos, i in enumerate(body):
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
                reg[a] = fresh(('M[%s][s].copy()' if pos < last_st else 'M[%s][s]') % addr
                               if v is not None else 'M[%s,ixs]' % addr)
                if v is not None:
                    mem[v] = reg[a]
        elif op == ST:
            addr, val = get(b), get(c)
            v = lit(addr)
            if not (dead is not None and v in dead):
                out.append('    M[%s][s]=%s' % (addr, val) if v is not None
                           else '    M[%s,ixs]=%s' % (addr, val))
            if v is not None:
                mem[v] = val
            else:
                mem.clear()
        elif op == PUT:
            # 出力は lane ごとに別の列になるので、ここだけは Python の loop になる。
            # ixs が lane の実番号を持つので、組が割れていても行き先を取り違えない
            out.append('    _o=%s' % get(b))
            out.append('    for _p in range(len(ixs)): OUT[int(ixs[_p])].append(int(_o[_p])&255)')
        else:
            raise ValueError('直線部分に置けない箱: %s' % NAME[op])

    keep = set(reg) if out_live is None else (set(reg) & out_live)
    for r in sorted(keep):
        if reg[r] != 'R[%d][s]' % r:
            out.append('    R[%d][s]=%s' % (r, reg[r]))

    def to(t):
        return idx[t] if 0 <= t < n and t in idx else R_END

    if term is None:
        out.append('    return %d' % (idx[stop] if stop < n else R_END))
    else:
        op, _a, b, c, sb, sc, im = prog[term]
        if op == OK:
            out.append('    return %d' % R_OK)
        elif op == KO:
            out.append('    return %d' % R_KO)
        elif op in (HALT,):
            out.append('    return %d' % R_END)
        elif op == JMP:
            out.append('    return %d' % to(term + im))
        else:
            x, y = shifted(b, sb), shifted(c, sc)
            vx, vy = lit(x), lit(y)
            if vx is not None and vy is not None:
                taken = (vx == vy) if op == EQ else (vx < vy)
                out.append('    return %d' % (to(term + im) if taken else to(term + 1)))
            else:
                rel = '==' if op == EQ else '<'
                out.append('    return _br(%s%s%s,%d,%d)' % (x, rel, y, to(term + im), to(term + 1)))
    return out + ['']


def translate(prog, wires=None):
    """image を numpy の block 関数の表へ落とす。引数は vcpu.translate と同じ意味になる。

    wires = (lo, hi) はワイヤの区間。他のどの block も読まない Store を落とす。
    """
    ent, idx, bl = blocks(prog)
    n = len(prog)
    live = vcpu._liveness(prog, bl, idx, n)
    dead = None
    if wires is not None:
        lo, hi = wires
        read = set()
        for k, (pc, body, term, stop) in enumerate(bl):
            _block_vec(prog, k, body, term, stop, idx, n, live[k], scan=read)
        dead = set(c for c in range(lo, hi) if c not in read)
    lines = []
    for k, (pc, body, term, stop) in enumerate(bl):
        lines += _block_vec(prog, k, body, term, stop, idx, n, live[k], dead=dead)
    lines.append('TAB = (' + ''.join('_v%d,' % k for k in range(len(bl))) + ')')
    src = chr(10).join(lines)
    ns = {'_br': _br, 'np': np}
    exec(compile(src, '<lane64-vec>', 'exec'), ns)
    return src, ns['TAB']


# ===== 組を進める（命題 6.1）=====
#
# 組は (lane の印, block 番号) の対で持つ。印は slice(None) か添字の配列になる。
# slice(None) のときは R も M も view を返すので、fancy indexing の写しが出ない。
# 組が割れたら添字の配列になり、同じ block 番号の組は一つへ合わせる。
#
# 「pc 昇順」は block 番号の昇順で足りる。block の入口は pc の昇順に並ぶので
# （vcpu.entries が sorted を返す）、番号の順序が pc の順序に一致する。

_ALL = slice(None)


def _join(groups, fresh):
    """同じ block 番号の組を合わせる（式 3.3 の reconvergence）"""
    for sel, b in fresh:
        for k, (s2, b2) in enumerate(groups):
            if b2 == b:
                if s2 is _ALL or sel is _ALL:
                    groups[k] = (_ALL, b)
                else:
                    groups[k] = (np.union1d(s2, sel), b)
                break
        else:
            groups.append((sel, b))
    return groups


def run(tab, lv, budget=1 << 32):
    """W 枚を束ねて走らせる。返りは lane ごとの報告の列。

    報告は翻訳器と同じ値を使う。0 が tu、42 が te、None が停止になる。
    """
    R, M, OUT, ix = lv.R, lv.M, lv.OUT, lv.ix
    groups = [(_ALL, 0)]
    steps = 0
    while groups:
        steps += 1
        if steps > budget:
            raise RuntimeError('組の歩数上限 %d を越えた' % budget)
        # 最も小さい block 番号の組を取る（命題 6.1）
        k = 0 if len(groups) == 1 else min(range(len(groups)), key=lambda i: groups[i][1])
        sel, b = groups.pop(k)
        ixs = ix if sel is _ALL else ix[sel]
        r = tab[b](R, M, OUT, ixs, sel)
        if isinstance(r, tuple):
            cond, yes, no = r
            base = ix if sel is _ALL else ix[sel]
            groups = _join(groups, [(base[cond], yes), (base[~cond], no)])
            continue
        if r >= 0:
            groups = _join(groups, [(sel, r)])
            continue
        rep = 0 if r == R_OK else (42 if r == R_KO else None)
        if sel is _ALL:
            lv.report = [rep] * lv.W
        else:
            for l in sel:
                lv.report[int(l)] = rep
    lv.blocks = steps
    return lv.report


# ===== 突き合わせ（命題 6.1 の検査）=====

def agrees(image, seeds, words, need=None, watch=()):
    """束ねの道と翻訳器の道が同じ観測を返すか。

    命題 6.1 の最後が「二つの観測が一致することが、この package の検査の一つになる」
    と言う。seeds は lane ごとの {番地: 値}。返りは (合うか, 束ねの報告, 翻訳器の報告)。
    """
    prog = vcpu.decode(image)
    W = len(seeds)
    lv = LaneVec(W, words)
    for l, s in enumerate(seeds):
        for a, v in s.items():
            lv.M[a, l] = v
    _src, tabv = translate(prog, wires=(64, need) if need else None)
    rep_v = list(run(tabv, lv))
    val_v = [[int(lv.M[a, l]) for a in watch] for l in range(W)]

    _src2, tab = vcpu.translate(prog, wires=(64, need) if need else None)
    rep_s, val_s = [], []
    for s in seeds:
        lane = vcpu.Lane(words)
        for a, v in s.items():
            lane.M[a] = v
        rep_s.append(vcpu.run_lane(tab, lane))
        val_s.append([lane.M[a] for a in watch])
    ok = (rep_v == rep_s and val_v == val_s and not lv.overflow())
    return ok, rep_v, rep_s
