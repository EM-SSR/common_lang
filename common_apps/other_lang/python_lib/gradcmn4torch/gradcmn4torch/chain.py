# -*- coding: utf-8 -*-
"""手順（語と位置の並び）を、箱（ops.py）の列として窓の上で実行する。連鎖律と共有の合流は autograd が担当する。

窓は左端から並んだスロット (型, 値, 深度)。
    D、B   値の Tensor（形 (L,)）。B は 0/1 の D として持つ。深度 δ は手順から決まる Common の型（assemble と同じ規則）で、
           D から 𝒬 へ持ち上げるときだけ使う
    Q      (n, d) の二つの D。commonc が持つ判定値の大きさ n/d
    X      (分子, 分母) の二つの D。除算 ba の出口
    他     値は None。D から値が届かない型（Point、Trace、Reflection、Noun、Region、Chain）は微分の対象にならない

複数の手順を同時に進められる。ある時刻に同じ語を使う手順のスロットを lane の向きにつなげて、箱を 1 回だけ実行する。

𝒬 の語は、commonc が置く Dyad の原子（文書 §8.3 の「降下後の意味 DAG」）に開いて、原子ごとの箱を通す。
式は次のとおり。check/test_chain.py が、commonc の語と同じ値を出すことを確かめる。

    lin(h, x)  = 1 ⊕ h ⋆ (x ⊖ 1)
    ar(U, V)   = V = 0 なら ([U = 0], 1)。そうでなければ s = sign V、g = [U s ≤ |V|] として g ? (U s, |V|) : (1, 1)
               = (lin(g, U s) ⊕ [V = 0][U = 0],  lin(g, |V|) ⊕ [V = 0])
    to(x, y)   = ar(P, Q) ⋆ ar(Q, P),   P = y 2^(δx+δy),  Q = x 2^(δx+δy)
    na(x)      = to(x, 1)        ni(x) = to(x, 0)        nu(p, q) = (n_p n_q, d_p d_q)
    yu(p, q)   = q ⊕ L ⋆ (p ⊖ q),   L = [n_q d_p ≤ n_p d_q]
    ye(a, c)   = yo(c, a) = (lin(H, u), lin(H, v)),   u = n_c d_a,  v = d_c n_a,  H = [u ≤ v][0 < v]
    ra(p, q)   = [n_p d_q ≤ n_q d_p]      go(q) = ne(q) = [0 < n_q]      ru(q) = q
    ba(x, y)   = (Q s, P s),   s = sign P
"""
import numpy as np
import torch

from . import ops as _real
from .words import OPEN, WORDS, D, B, Q, X

ops = _real                       # 検査では普通の torch の関数に差し替える（run_batch の ops 引数）
_bad = []                         # 直前の apply が見つけた実行時の失敗（lane ごとの真偽）。ba の零除算
ACTIVE_TYPES = (D, B, Q, X)       # 値を持つスロットの型
SPECIAL = ("mi", "mu", "du", "me", "di", "ya", "yi")        # 作業領域、出力、報告、閉包の語。プログラムごとに 1 つずつ処理する
MEMORY = 32                       # 作業領域の語 0 … 31 を模す。hi と so の退避語は 32 以上にある


def _one(like):
    return torch.ones_like(like)


def sub(a, b):
    return ops.Sub.apply(a, b)


def lin(h, x):
    return ops.Lin.apply(h, x)


def pos(x):
    return ops.So.apply(x)


def le(a, b):
    return ops.Hi.apply(a, b)


def sign(x):
    return ops.Sign.apply(x)


def eqz(x):
    return ops.Eqz.apply(x)


def _ar(U, V):
    sg = sign(V)
    zV = eqz(V)
    b = ops.Ti.apply(V, sg)
    n1 = ops.Ti.apply(U, sg)
    g = le(n1, b)
    zU = eqz(U)
    n = ops.No.apply(lin(g, n1), ops.Ti.apply(zV, zU))
    d = ops.No.apply(lin(g, b), zV)
    return n, d


def _pq(x, y, m):
    k = torch.as_tensor(2.0 ** m, dtype=x.dtype, device=x.device).expand_as(x)
    return ops.Ti.apply(x, k), ops.Ti.apply(y, k)


def to(x, dx, y, dy):
    q, p = _pq(x, y, dx + dy)
    n1, d1 = _ar(p, q)
    n2, d2 = _ar(q, p)
    return ops.Ti.apply(n1, n2), ops.Ti.apply(d1, d2)


def nu(p, q):
    return ops.Ti.apply(p[0], q[0]), ops.Ti.apply(p[1], q[1])


def yu(p, q):
    L = le(ops.Ti.apply(q[0], p[1]), ops.Ti.apply(p[0], q[1]))
    return ops.No.apply(q[0], ops.Ti.apply(L, sub(p[0], q[0]))), ops.No.apply(q[1], ops.Ti.apply(L, sub(p[1], q[1])))


def residual(a, c):
    u = ops.Ti.apply(c[0], a[1])
    v = ops.Ti.apply(c[1], a[0])
    H = ops.Ti.apply(le(u, v), pos(v))
    return lin(H, u), lin(H, v)


def _hi(x, dx, y, dy):
    """[x ≤ y]。commonc は桁そろえを 256 − 深度（8 bit）で出すので、深度が 0 の側は 256 でなく 0 になる。
    深度が 0 と 1 以上で組になると、0 の側は他方より無限に小さい値として比べられる。
        dx = 0 < dy:  [0 < y] ⊕ [y = 0] ⋆ [x ≤ 0]        dx > 0 = dy:  [x < 0] ⊕ [x = 0] ⋆ [0 ≤ y]
    それ以外は値どおりの比べ方になる。"""
    mixed_a = (dx == 0) & (dy > 0)
    mixed_b = (dx > 0) & (dy == 0)
    plain = ops.Hi.apply(x, y)
    if not (mixed_a.any() or mixed_b.any()):
        return plain
    zero = torch.zeros_like(x)
    case_a = ops.No.apply(pos(y), ops.Ti.apply(eqz(y), ops.Hi.apply(x, zero)))
    case_b = ops.No.apply(pos(ops.Ha.apply(x)), ops.Ti.apply(eqz(x), ops.Hi.apply(zero, y)))
    wa = torch.as_tensor(mixed_a, dtype=x.dtype, device=x.device)
    wb = torch.as_tensor(mixed_b, dtype=x.dtype, device=x.device)
    wp = 1 - wa - wb
    return ops.No.apply(ops.No.apply(ops.Ti.apply(wp, plain), ops.Ti.apply(wa, case_a)), ops.Ti.apply(wb, case_b))


def ra(p, q):
    return le(ops.Ti.apply(p[0], q[1]), ops.Ti.apply(q[0], p[1]))


def ba(x, dx, y, dy):
    q, p = _pq(x, y, dx + dy)
    s = sign(p)
    return ops.Ti.apply(q, s), ops.Ti.apply(p, s)


def apply(w, a, like):
    """語 w を、入力のスロット a（lane の向きにつなげたもの）に当てる。返りは出口のスロットの並び。
    深度は lane ごとの numpy の整数列で、同じ手順の lane は同じ値を持つ。"""
    zero = a[0][2] * 0 if a else np.zeros(len(like), dtype=np.int64)
    if w == "hu":
        return [(D, _one(like), zero)]
    if w == "he":
        x, y = ops.Dup.apply(a[0][1])
        return [(a[0][0], x, a[0][2]), (a[0][0], y, a[0][2])]
    if w == "ho":
        return []
    if w == "sw":                                   # 入れ替えは he、no、ha の組なので、深度が大きい方にそろう
        m = np.maximum(a[0][2], a[1][2])
        return [(a[1][0], a[1][1], m), (a[0][0], a[0][1], m)]
    if w == "no":
        return [(D, ops.No.apply(a[0][1], a[1][1]), np.maximum(a[0][2], a[1][2]))]
    if w == "ti":
        return [(D, ops.Ti.apply(a[0][1], a[1][1]), a[0][2] + a[1][2])]
    if w == "zi":
        return [(D, a[1][1], a[1][2])]
    if w == "za":
        return [(D, ops.Za.apply(a[0][1], a[1][1]), np.maximum(a[0][2], a[1][2]) + 1)]
    if w == "ha":
        return [(D, ops.Ha.apply(a[0][1]), a[0][2])]
    if w == "se":
        return [(D, ops.Za.apply(a[0][1], _one(a[0][1])), a[0][2] + 1)]
    if w == "gu":
        return [(D, ops.Gu.apply(a[0][1]), a[0][2] - 1)]
    if w == "ge":
        return [(D, ops.Ge.apply(a[0][1]), zero)]
    if w == "so":
        return [(B, ops.So.apply(a[0][1]), zero)]
    if w == "hi":
        return [(B, _hi(a[0][1], a[0][2], a[1][1], a[1][2]), zero)]
    if w == "mo":
        return [(D, a[0][1], zero)]
    if w == "to":
        return [(Q, to(a[0][1], a[0][2], a[1][1], a[1][2]), zero)]
    if w in ("na", "ni"):
        y = _one(a[0][1]) if w == "na" else torch.zeros_like(a[0][1])
        return [(Q, to(a[0][1], a[0][2], y, zero), zero)]
    if w == "ba":
        y = ba(a[0][1], a[0][2], a[1][1], a[1][2])
        _bad.append(y[1] == 0)                      # 零で割ると commonc は失敗を報告する
        return [(X, y, zero)]
    if w == "nu":
        return [(Q, nu(a[0][1], a[1][1]), zero)]
    if w == "yu":
        return [(Q, yu(a[0][1], a[1][1]), zero)]
    if w == "ye":
        return [(Q, residual(a[0][1], a[1][1]), zero)]
    if w == "yo":
        return [(Q, residual(a[1][1], a[0][1]), zero)]
    if w == "ru":
        return [a[0]]
    if w in ("go", "ne"):
        return [(B, pos(a[0][1][0]), zero)]
    if w == "ra":
        return [(B, ra(a[0][1], a[1][1]), zero)]
    return [(t, None, zero) for t in WORDS[w][1]]    # D から値が届かない型の語


def _cat(slots, sizes):
    """スロットを lane の向きにつなぐ。"""
    vals = [s[1] for s in slots]
    if vals[0] is None:
        v = None
    elif isinstance(vals[0], tuple):
        v = tuple(torch.cat([x[i] for x in vals]) for i in range(len(vals[0])))
    else:
        v = torch.cat(vals)
    return (slots[0][0], v, np.concatenate([np.full(n, s[2]) for n, s in zip(sizes, slots)]))


def _split(slot, sizes):
    t, v, dep = slot
    parts = [None] * len(sizes) if v is None else (
        list(zip(*[torch.split(x, sizes) for x in v])) if isinstance(v, tuple) else list(torch.split(v, sizes)))
    deps = np.split(dep, np.cumsum(sizes)[:-1])
    return [(t, p, int(d[0]) if len(d) else 0) for p, d in zip(parts, deps)]


_CONSTANTS = {}


def _constants(recipe, i, n, shift, types, k):
    """D から値が届かない語が値を持つ型（B、Q、D）を出すとき、その値は手順だけで決まる。
    手順の先頭 i+1 語を commonc で実行して、位置 k のスロットの出口の語を読む。結果は覚える。"""
    key = (tuple(map(tuple, recipe[:i + 1])), n, shift, k)
    if key not in _CONSTANTS:
        _CONSTANTS[key] = _read_constants(recipe, i, n, shift, types, k)
    return _CONSTANTS[key]


def _read_constants(recipe, i, n, shift, types, k):
    from . import assemble, run as runner
    built = assemble.value(recipe[:i + 1], n, shift)
    word = sum(OPEN[t] for t in types[:k])
    width = 1 if types[k] in (D, B) else 2
    for leaves in ([1] * n, [3 + 2 * i for i in range(n)], [-5 + 7 * i for i in range(n)]):      # 値は入力に依らない。零除算を避ける
        try:
            out = runner.run_one(built.text, leaves, len(built.depths))
            return [float(out[word + j]) / 2.0 ** built.depths[word + j] for j in range(width)]
        except RuntimeError:
            continue
    raise RuntimeError("手順の先頭を実行できない")


def _numerator(slot):
    """スロットの値の分子（値 × 2^深度）。整数でなければ None。"""
    n = slot[1].detach() * 2.0 ** slot[2]
    return n if bool((n == torch.round(n)).all()) else None


def _special(w, k, wins, p, mems, leaves, shift, failed, unsupported):
    """作業領域、出力、報告、閉包の語を 1 つの手順に当てる。
    作業領域は語 0 … 31 を (lane, 語) の Tensor で持ち、入力の分子を語 1、2、4、… に置く。"""
    s = wins[p]
    if w == "du":                                           # 1 byte を出力へ送る。値には効かない
        s.pop(k)
    elif w in ("me", "di"):                                 # me は出口を書かずに実行を閉じ、di は失敗する。どちらも答えを出さない
        failed[p] = True
    elif w == "ya":                                         # 閉包は繰り返しの回数が入力で決まる。箱の列では表さない
        unsupported[p] = True
    elif w == "yi":
        unsupported[p] = True
        s.pop(k)
    else:
        if mems[p] is None:
            like = leaves[p][0].detach()
            cols = [torch.zeros_like(like) for _ in range(MEMORY)]
            for i, x in enumerate(leaves[p]):
                cols[1 << i] = ops.Ti.apply(x, torch.full_like(x.detach(), 2.0 ** shift))
            mems[p] = torch.stack(cols, 1)
        addr = _numerator(s[k])
        if addr is None or bool(((addr < 0) | (addr >= MEMORY)).any()):
            unsupported[p] = True                           # 作業領域の外や、ワイヤの帯は模さない
            addr = torch.zeros_like(s[k][1].detach())
        idx = addr.long()[:, None]
        if w == "mi":
            s[k] = (D, mems[p].gather(1, idx).squeeze(1), 0)
        else:
            val = ops.Ti.apply(s[k + 1][1], torch.full_like(s[k + 1][1].detach(), 2.0 ** s[k + 1][2]))
            mems[p] = mems[p].scatter(1, idx, val[:, None])
            s[k:k + 2] = []


def run_batch(recipes, leaves, shift=0, ops=None):
    """手順の並びを同時に進める。leaves[p] は手順 p の入力（形 (L_p,) の Tensor の並び）。
    返りは (手順ごとの最後の窓（スロットの並び）, 実行時の失敗の有無, 箱の列で表せない手順か)。
    ops は箱の組（検査用に差し替えられる）。"""
    prev = globals()["ops"]
    if ops is not None:
        globals()["ops"] = ops
    try:
        wins = [[(D, x, shift) for x in xs] for xs in leaves]
        sizes = [len(xs[0]) for xs in leaves]
        failed = [False] * len(recipes)
        unsupported = [False] * len(recipes)
        mems = [None] * len(recipes)
        for t in range(max(len(r) for r in recipes)):
            groups = {}
            for p, r in enumerate(recipes):
                if t < len(r):
                    if r[t][0] in SPECIAL:
                        _special(r[t][0], r[t][1], wins, p, mems, leaves, shift, failed, unsupported)
                    else:
                        groups.setdefault(r[t][0], []).append(p)
            for w, ps in groups.items():
                n_in = 2 if w == "sw" else len(WORDS[w][0])
                ls = [sizes[p] for p in ps]
                like = torch.cat([leaves[p][0].detach() for p in ps])
                args = [_cat([wins[p][recipes[p][t][1] + i] for p in ps], ls) for i in range(n_in)]
                del _bad[:]
                split = [_split(o, ls) for o in apply(w, args, like)]
                if _bad:
                    for p, flag in zip(ps, torch.split(_bad[0], ls)):
                        failed[p] = failed[p] or bool(flag.any())
                for j, p in enumerate(ps):
                    k = recipes[p][t][1]
                    wins[p][k:k + n_in] = [s[j] for s in split]
                    for jj in range(len(split)):
                        slot = wins[p][k + jj]
                        if slot[1] is None and slot[0] in ACTIVE_TYPES:
                            v = _constants(recipes[p], t, len(leaves[p]), shift, [q[0] for q in wins[p]], k + jj)
                            like = leaves[p][0].detach()
                            vals = [torch.full_like(like, x) for x in v]
                            wins[p][k + jj] = (slot[0], vals[0] if len(vals) == 1 else tuple(vals), 0)
        return wins, failed, unsupported
    finally:
        globals()["ops"] = prev


def run_all(recipe, xs, shift=0, ops=None):
    """一つの手順を xs（Tensor の並び、形 (L,)）に当てる。返りは (最後の窓, 実行時の失敗か, 箱の列で表せないか)。"""
    wins, failed, unsupported = run_batch([recipe], [xs], shift, ops)
    return wins[0], failed[0], unsupported[0]


def run(recipe, xs, shift=0, ops=None):
    """一つの手順を xs（Tensor の並び、形 (L,)）に当てる。返りは最後の窓。"""
    return run_all(recipe, xs, shift, ops)[0]
