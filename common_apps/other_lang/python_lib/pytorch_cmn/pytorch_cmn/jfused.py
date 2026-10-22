# -*- coding: utf-8 -*-
"""段の表を、解釈せずに配列の演算として出す。

## なぜ一本の長い配列を使わないか

`gvcpu` は lane64 の命令を一つずつ実行するプログラムで、命令は「配列の $n$ 番目を読む」
「$n$ 番目に書く」の形しかない。$n$ は整数なので、全部の値を一本の配列に並べ、どの値が
どこにあるかを整数で持つ必要がある。段の表の各行が持つ数は、その整数と、レーンごとに
何個ずつずらすかになる。

配列の演算として出す側には、その制約が無い。中間の値はそれぞれ独立した配列でよい。
一本にしたまま jax へ写すと、段ごとにその配列を丸ごと作り直すので、実行時間が仕事の量
ではなく配列の大きさに比例する（実測: 同じ表で 0.098 GB なら 0.057 秒、1.574 GB なら
0.244 秒）。

だからここでは `Build.spans`（割り当ての記録）ごとに配列を分ける。一段が書き直すのは
その置き場だけになる。

## 段の形

    値 = Σ_{j<K} M[w + j]·M[x + j] + M[a] + M[ g + M[t] ],   フラグ = [ θ ≤ 値 ]

歩幅と先頭は組んだときに決まっているので、段は静的な形の演算に落ちる。

    (W,1,0)  → 連続した区間
    (st,0,0) → 行ごとの値を W 回ずつ繰り返す
    (0,q,0)  → 列ごとの値を 行数 回ずつ並べる
    (0,0,0)  → 一つの値

係数が $(0,q,0)$、入力が $(\\mathrm{st},0,0)$ の段は行列の積そのものになる。

    acc[rW+c] = Σ_j M[w_b+qc+j]·M[x_b+st·r+j] = (X Wᵀ)[r,c]

## 使い方

`xp` に numpy を渡すと `Build.simulate` と同じ値が出る（置き場の中に限る。置き場の外は
支持の外のレーンが書く枠で、エンジンでも決まった値にならない）。`jax.numpy` を渡して
`jax.jit` で包むと、XLA が段をまとめる。

    from pytorch_cmn import jfused
    out = jfused.go(B)
"""
import bisect

import numpy as np

from . import graph

ROMLO = graph.ROMLO

# 内積の項を何本ずつ束ねるか。`K` 項をそのまま並べると graph が膨れて compile が終わらない
CHUNK = 256

# 切り分け用の取り外し。どこに時間が行っているかを差で測るときだけ使う。
# "mm" 内積を外す、"pull" 引きの項を外す、"write" 書きを外す、"spread" 読みの形を外す
DROP = set()


def slabs(B):
    """置き場ごとの (先頭, 語数)。割り当ての記録をそのまま使う。"""
    got = sorted(B.spans)
    if not got:
        return [(0, max(1, B.n))]
    if got[0][0] != 0:
        got = [(0, got[0][0])] + got
    return got


def start(B):
    """置いた中身を載せた、走る前の置き場の並び。"""
    shape_at = getattr(B, "shape_at", {})
    # タイルに切った行列積は `out + t·W` へ書くので、記録した先頭と一致しない。
    # 含んでいる置き場を探す
    _sk = sorted(shape_at)

    def shape_of(head):
        i = bisect.bisect_right(_sk, head) - 1
        if i < 0:
            return (0, 0), 0
        h = _sk[i]
        rr, cc = shape_at[h]
        st = -(-max(1, cc) // W) * W
        if head - h >= max(1, rr) * st:
            return (0, 0), 0
        return (rr, cc), head - h
    sl = slabs(B)
    heads = [h for h, _ in sl]
    out = [np.zeros((n,), dtype=np.int64) for _, n in sl]
    for h, a in B.blocks:
        k = min(bisect.bisect_right(heads, h) - 1, len(heads) - 1)
        off = h - heads[k]
        m = min(a.size, out[k].size - off)
        if m > 0:
            out[k][off:off + m] = a[:m]
    return out


def _lanes(B):
    """レーンの三つの番号。"""
    ids = np.arange(B.lanes, dtype=np.int64)
    C = B.groups
    return (ids // (C * B.width), (ids // C) % B.width, ids % C)


class Row(object):
    """一段ぶんの読み方。表の語から先に取り出しておく。"""

    __slots__ = ("ob", "os", "K", "wb", "ws", "xb", "xs", "ab", "as_", "fb",
                 "th", "gate", "gb", "tb", "ts", "ln", "pwb", "lad", "mx",
                 "waves")

    def __init__(self, r):
        g = lambda k: int(r[k])
        h = lambda k: g(k) - ROMLO
        self.ob, self.os = h(0), (g(1), g(2), g(3))
        self.K = g(4)
        self.wb, self.ws = h(5), (g(6), g(7), g(8))
        self.xb, self.xs = h(9), (g(10), g(11), g(12))
        self.ab, self.as_ = h(13), (g(14), g(15), g(16))
        self.fb, self.th, self.gate = h(17), g(18), g(24)
        self.gb, self.tb, self.ts = h(19), h(20), (g(21), g(22), g(23))
        self.ln, self.pwb = g(25), h(26)
        self.lad = (g(27), g(28), g(29), g(30), g(31), g(32))
        self.mx = (g(33), g(34))
        self.waves = max(1, g(35))


def plan(B):
    """表を一つの関数へ落とす。返りは `run(xp, RO, RW) -> RW`。

    `RO` は読むだけの置き場（重みと定数。型ごとに一本へまとめてある）、`RW` は書かれる
    置き場の並び。分けるのは、一つにまとめると入力と出力を同時に持って板に載らないため。
    """
    rows = [Row(r) for r in B.rows]
    i1n, i2n, i3n = _lanes(B)
    A, u, W, C, L = B.A, B.unroll, B.width, B.groups, B.lanes
    # レーンが覆う行数。**切り上げる。** レーン数が詰め幅の倍数でないとき、切り捨てると
    # 最後の何本かが欠ける
    R1 = -(-L // W)
    shape_at = getattr(B, "shape_at", {})
    # タイルに切った行列積は `out + t·W` へ書くので、記録した先頭と一致しない。
    # 含んでいる置き場を探す
    _sk = sorted(shape_at)

    def shape_of(head):
        i = bisect.bisect_right(_sk, head) - 1
        if i < 0:
            return (0, 0), 0
        h = _sk[i]
        rr, cc = shape_at[h]
        st = -(-max(1, cc) // W) * W
        if head - h >= max(1, rr) * st:
            return (0, 0), 0
        return (rr, cc), head - h
    sl = slabs(B)
    heads = [h for h, _ in sl]
    sizes = [n for _, n in sl]

    def reach(Rw):
        """その段が実際に使う $i_1$ の数。

        出す枠が (行, 列) で、行の歩幅が $s^o_1$ なら

            i₁ の範囲 = 行 · ⌈列/W⌉ · W / s^o_1

        タイルに切った行列積は $s^o_1=	ext{tiles}\cdot W$ なので $i_1$ は行そのもの。
        ここを格子いっぱい（108）にすると、8 行の段で 13.5 倍の無駄になる。
        """
        (rr, cc), _off = shape_of(Rw.ob)
        if not rr or not cc or not Rw.os[0]:
            return None
        tiles = -(-cc // W)
        return max(1, (rr * tiles * W) // Rw.os[0])

    def find(addr):
        """その位置がどの置き場の何番目か。組んだときに決まる。"""
        k = min(bisect.bisect_right(heads, addr) - 1, len(heads) - 1)
        return k, addr - heads[k]

    # **読むだけの置き場と、書かれる置き場を分ける。**
    #
    # 重みと定数は読むだけなので、呼びの入出力にする必要が無い。一つの並びにまとめると
    # 入力 5.05 GB と出力 5.05 GB を同時に持つことになり、16 GB の板に載らない。
    wr = set()
    for Rw in rows:
        for kw in range(Rw.waves):
            wr.add(find(Rw.ob + kw * A * W)[0])
            if Rw.gate:
                wr.add(find(Rw.fb + kw * A * W)[0])
            if Rw.os[:2] != (W, 1) or Rw.os[2] or C != 1:
                wr.add(find(Rw.ob)[0])
                if Rw.gate:
                    wr.add(find(Rw.fb)[0])
    rw_ix = sorted(wr)
    ro_ix = [k for k in range(len(sl)) if k not in wr]
    # **読むだけの分は一本にまとめる。** 書き換えが起きないので、一本でも写し直しが
    # 起きない。別々に送ると 364 個で 0.44 GB/秒しか出ないが、一本なら一度の転送になる
    base = start(B)
    ro_dtype = dict((k, _fits(base[k])) for k in ro_ix)
    ro_types = sorted(set(ro_dtype.values()), key=lambda t: np.dtype(t).name)
    ro_slot = dict((t, j) for j, t in enumerate(ro_types))
    ro_off, run_t = {}, {}
    for k in ro_ix:
        t = ro_dtype[k]
        ro_off[k] = run_t.get(t, 0)
        run_t[t] = ro_off[k] + sizes[k]
    ro_len = sum(run_t.values())
    pos = {}
    for k in ro_ix:
        pos[k] = (0, ro_off[k])
    for j, k in enumerate(rw_ix):
        pos[k] = (1, j)

    def run(xp, RO, RW):
        RW = list(RW)
        box = (RO, RW)

        def S(k):
            w, j = pos[k]
            # 読むだけの分は一本の中の区間。jit の中なら切り出しは消える
            if w == 0:
                # 読むだけの分は狭い型で持っている。切り出してから広げる
                return box[0][ro_slot[ro_dtype[k]]][j:j + sizes[k]].astype("int64")
            return box[1][j]

        def setS(k, v):
            box[1][pos[k][1]] = v

        i1o, i2, i3 = xp.asarray(i1n), xp.asarray(i2n), xp.asarray(i3n)

        def fit(v, want):
            """長さを `want` へ揃える。足りなければ 0 で埋める。"""
            n = int(v.shape[0])
            if n == want:
                return v
            if n > want:
                return v[:want]
            return xp.concatenate([v, xp.zeros((want - n,), v.dtype)])

        def take(base, span, step=1):
            """一つの置き場から連続した区間を取る。外へ出る分は落とす。

            支持の外のレーンは置き場の外を読む。その値は使われないので落としてよい
            （`check/joint` がノードの置き場の中だけを見るのはこのため）。
            """
            k, off = find(base)
            lo, hi = max(0, off), min(sizes[k], off + span)
            return S(k)[lo:hi:step] if hi > lo else S(k)[:0]

        def spread(base, st, kA):
            """歩幅の形から (L,) の並びを作る。当たらなければ None。"""
            s1, s2, s3 = st
            if s3 or C != 1:
                return None
            if (s1, s2) == (W, 1):
                return fit(take(base + kA * W, L), L)
            if (s1, s2) == (0, 0):
                k, off = find(base)
                return S(k)[min(max(off, 0), sizes[k] - 1)]
            if s2 == 0 and s1:                               # 行ごとの値
                return fit(xp.repeat(fit(take(base + s1 * kA, s1 * R1, s1), R1), W), L)
            if s1 == 0 and s2:                               # 列ごとの値
                return fit(xp.tile(fit(take(base, s2 * W, s2), W), R1), L)
            return None

        def pick(base, st, kA):
            """速い道が無い段のために、位置を組み立てて読む。"""
            k, off = find(base)
            idx = off + st[0] * (i1o + kA) + st[1] * i2 + st[2] * i3
            return S(k)[xp.clip(idx, 0, sizes[k] - 1)]

        def read(base, st, kA):
            v = spread(base, st, kA)
            return pick(base, st, kA) if v is None else v

        for Rw in rows:
            hi = reach(Rw)
            for kw in range(Rw.waves):
                kA = kw * A
                # その波が実際の行の外なら、丸ごと要らない
                if hi is not None and kA >= hi:
                    continue
                KU = Rw.K * u
                # 行に沿った最大。和より先に回す（エンジンと同じ順）
                # 混ぜない段では回さない。既定は (1, 0) で、結果を捨てるのに一回
                # 読んでいた
                mxn = int(Rw.mx[0]) if Rw.mx[1] else 0
                mxv = None
                if mxn:
                    for t in range(mxn + 1):
                        v = read(Rw.xb + t, Rw.xs, kA)
                        mxv = v if mxv is None else mxv + (mxv <= v) * (v - mxv)
                # 内積
                if (C == 1 and Rw.ws[2] == 0 and Rw.xs[2] == 0 and Rw.ws[0] == 0
                        and Rw.ws[1] and Rw.xs[1] == 0 and Rw.xs[0] and KU > 1):
                    q, st = Rw.ws[1], Rw.xs[0]
                    # **出力の本当の大きさで回す。** レーン格子いっぱい（R1 × W）で
                    # 回すと、attention の QKᵀ が 8x8 で足りるところを 108x512 ぶん
                    # 計算する。実寸の層で 20 倍の無駄になっていた
                    (rr, cc), _off = shape_of(Rw.ob)
                    rN = min(R1, max(1, (hi - kA) if hi is not None else R1))
                    cN = min(W, max(1, cc)) if cc else W
                    Wm = fit(take(Rw.wb, q * cN), q * cN).reshape(cN, q)[:, :KU]
                    X = fit(take(Rw.xb + st * kA, st * rN), st * rN).reshape(rN, st)[:, :KU]
                    y = X @ Wm.T
                    if cN < W:
                        y = xp.concatenate(
                            [y, xp.zeros((rN, W - cN), y.dtype)], axis=1)
                    acc = fit(y.reshape(-1), L)
                else:
                    w0, x0 = spread(Rw.wb, Rw.ws, kA), spread(Rw.xb, Rw.xs, kA)
                    if w0 is not None and x0 is not None and KU == 1:
                        acc = w0 * x0
                    else:
                        acc = None
                        for j in range(KU):
                            p = read(Rw.wb + j, Rw.ws, kA) * read(Rw.xb + j, Rw.xs, kA)
                            acc = p if acc is None else acc + p
                if "mm" in DROP:
                    acc = i1o * 0
                acc = acc + read(Rw.ab, Rw.as_, kA)
                # 引きの項。ここだけは位置が実行時に決まる
                if "pull" in DROP:
                    acc = acc + i1o * 0
                if "pull" not in DROP:
                    t0 = read(Rw.tb, Rw.ts, kA)
                    gk, goff = find(Rw.gb)
                    acc = acc + S(gk)[xp.clip(goff + t0, 0, sizes[gk] - 1)]
                if mxn:
                    acc = acc + Rw.mx[1] * (mxv - acc)
                # 桁ごとに立てる閉包。`rshift` `recip` `isqrt` が全部この形
                lA, lLc, lLk, lBc, lBk, useq = Rw.lad
                # 混ぜない段では回さない。既定は ln=1・useq=0 で、64 bit の除算を
                # 一回して捨てていた（層一枚 460 段のうち 345 段がこれ）
                if Rw.ln and useq:
                    sg = 2 * (acc >= 0) - 1
                    r = acc * sg
                    lim, bco = lLc + lLk * r, lBc + lBk * r
                    top = (1 << int(Rw.ln)) - 1
                    # 桁を上から立てて得る $q$ は、$t(\lambda t+b)\le\ell$ を満たす
                    # $2^n$ 未満の最大値になる。閉じた式で解ける（閉包の正規化、§10）。
                    # 反復で出すと一段あたり `ln` 回の演算が並び、層一枚で 8094 回になる
                    sh = _shift(lA, lLc, lLk, lBc, lBk)
                    if sh is not None:
                        # `rshift` は $\ell=r$、$b=2^m$ なので $q=r\gg m$。$b$ を実行時の
                        # 値のまま渡すと XLA が 64 bit の除算を出し、一カーネル 250 µs に
                        # なる。2 の冪はシフトで済む
                        qq = xp.minimum(r >> sh, top)
                    elif lA == 0:
                        qq = xp.minimum(_div(xp, lim, bco), top)
                    elif lA == 1 and lBc == 0 and lBk == 0:
                        qq = xp.minimum(_isqrt(xp, lim), top)
                    else:
                        pk, poff = find(Rw.pwb)
                        qq = xp.zeros_like(acc)
                        for kk in range(int(Rw.ln) - 1, -1, -1):
                            pp = S(pk)[min(max(poff + kk, 0), sizes[pk] - 1)]
                            t = qq + pp
                            qq = qq + (t * (lA * t + bco) <= lim) * pp
                    acc = acc + useq * (qq * sg - acc)
                if "write" not in DROP:
                    _write(xp, S, setS, find, sizes, Rw.ob, Rw.os, kA, acc, W, L, C,
                           i1o, i2, i3)
                if Rw.gate:
                    f = (acc >= Rw.th).astype(acc.dtype)
                    _write(xp, S, setS, find, sizes, Rw.fb, Rw.os, kA, f, W, L, C,
                           i1o, i2, i3)
        return RW

    run.ro = ro_ix
    run.rw = rw_ix
    run.ro_len = ro_len
    run.ro_dtype = ro_dtype
    run.ro_types = ro_types
    return run


def _write(xp, S, setS, find, sizes, base, st, kA, val, W, L, C, i1o, i2, i3):
    """出す枠へ書く。書き直すのはその置き場だけ。"""
    if C == 1 and st[:2] == (W, 1) and st[2] == 0:
        k, off = find(base + kA * W)
        m = min(L, sizes[k] - off)
        if m <= 0 or off < 0:
            return
        a = S(k)
        setS(k, a.at[off:off + m].set(val[:m]) if hasattr(a, "at")
             else _put_slice(a, off, val[:m]))
        return
    k, off = find(base)
    a = S(k)
    idx = xp.clip(off + st[0] * (i1o + kA) + st[1] * i2 + st[2] * i3, 0, sizes[k] - 1)
    setS(k, a.at[idx].set(val) if hasattr(a, "at") else _put(a, idx, val))


def _shift(lA, lLc, lLk, lBc, lBk):
    """桁の閉包が右シフトそのものなら、そのシフト量を返す。"""
    if lA == 0 and lBk == 0 and lLk == 1 and lLc == 0 and lBc > 0 and not (lBc & (lBc - 1)):
        return int(lBc).bit_length() - 1
    return None


def _div(xp, lim, bco):
    """$t\,b\le\ell$ を満たす最大の $t\ge0$。$b\le0$ のところは 0 にする。"""
    b = xp.where(bco > 0, bco, 1)
    q = xp.where(bco > 0, lim // b, 0)
    return xp.where(q > 0, q, 0)


def _isqrt(xp, lim):
    """$t^2\le\ell$ を満たす最大の $t\ge0$。float64 で当たりを付けて整数で直す。"""
    v = xp.maximum(lim, 0)
    g = xp.floor(xp.sqrt(v.astype("float64"))).astype(v.dtype)
    g = xp.maximum(g - 2, 0)
    for _ in range(4):                       # $2^{62}$ でも 4 回で届く
        g = g + ((g + 1) * (g + 1) <= v)
    return g


def _put_slice(a, off, val):
    a[off:off + val.shape[0]] = val
    return a


def _put(a, idx, val):
    """numpy の置き方。重なった位置は後ろのレーンが残る（`simulate` と同じ）。"""
    a[idx] = val
    return a


NARROW = (np.int8, np.int16, np.int32, np.int64)


def _fits(a):
    """その並びが入る一番狭い型。Common の数は 15 bit ほどしか使わないのに、
    lane64 の解釈器が 64 bit の語しか読めないので 8 byte で持っていた。"""
    v = int(np.max(np.abs(a))) if a.size else 0
    for t in NARROW:
        if v <= np.iinfo(t).max:
            return t
    return np.int64


def split(run, S):
    """置き場の並びを、読むだけの分（型ごとに一本）と、書かれる分へ分ける。"""
    if not run.ro:
        return [np.zeros((1,), dtype=np.int64)], [S[k] for k in run.rw]
    by = {}
    for k in run.ro:
        t = run.ro_dtype[k]
        by.setdefault(t, []).append(np.asarray(S[k]).astype(t, copy=False))
    # jax は辞書の鍵を並べ替えるので、型の名前の順で並びにする
    return ([np.concatenate(by[t]).astype(t, copy=False) for t in run.ro_types],
            [S[k] for k in run.rw])


def merge(run, S, RW):
    """書かれた分を並びへ戻す。"""
    out = list(S)
    for j, k in enumerate(run.rw):
        out[k] = RW[j]
    return out


def flat(B, S):
    """置き場の並びを一本の配列として読み直す。`simulate` と突き合わせるために使う。"""
    out = np.zeros((B.n + 64,), dtype=np.int64)
    for (h, n), a in zip(slabs(B), S):
        v = np.asarray(a)
        out[h:h + min(n, v.size)] = v[:n]
    return out


# ---- jax で包む ----------------------------------------------------------
#
# `plan` が返す関数は Python の `for` で段を並べるだけなので、`jax.jit` に通すと XLA が
# 段をまとめる。層の段の並びはどの層も同じなので、一度 compile して使い回せる。

_JIT = {}


def jitted(B):
    """層ぶんの段の並びを一度だけ compile する。"""
    import jax
    jax.config.update("jax_enable_x64", True)          # 分子は 2^62 まで伸びる
    key = (id(B), len(B.rows), B.lanes, B.A)
    if key not in _JIT:
        run = plan(B)
        # 書かれる分だけを donate する。重みと定数は読むだけなので二重に持たない
        f = jax.jit(lambda RO, RW: run(jax.numpy, RO, RW), donate_argnums=1)
        f.run = run
        _JIT[key] = f
    return _JIT[key]


def go(B, S=None):
    """走らせて、置き場の並びを numpy で返す。"""
    import jax.numpy as jnp
    f = jitted(B)
    S = start(B) if S is None else S
    ro, rw = split(f.run, S)
    got = merge(f.run, S, [np.asarray(a) for a in f(jnp.asarray(ro),
                                                   [jnp.asarray(a) for a in rw])])
    return [np.asarray(a) for a in got]
