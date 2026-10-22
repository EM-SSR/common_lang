# -*- coding: utf-8 -*-
"""int32 の配列を並べた多倍長の整数（JAX）。

一つの値は、lane の並び (W,) の int32 配列を K 本並べたもの（python の list）になる。

    値 = Σ_k l[k] · 2^(15 k)

正規形は、下位の K−1 本が [0, 2^15)、最上位の 1 本が符号つき。足し算・引き算は本ごとに行い、
繰り上がりは norm が運ぶ。積は 15 bit の本どうしで 2^30 未満になるので、int32 で溢れない。
K は呼ぶ側が決める。値が K 本に収まらなければ、結果は正しくない（検査はしない）。
"""

import jax.numpy as jnp

BITS = 15
BASE = 1 << BITS
MASK = BASE - 1


def norm(ls):
    """繰り上がりを運んで正規形にする。長さは変えない。"""
    out, c = [], jnp.zeros_like(ls[0])
    for l in ls[:-1]:
        t = l + c
        out.append(t & MASK)
        c = t >> BITS
    out.append(ls[-1] + c)
    return out


def from_int(v, K, like):
    """python の整数 v（負でもよい）を K 本の正規形へ。like は形を借りる配列。"""
    z = jnp.zeros_like(like)
    out = []
    for _ in range(K - 1):
        out.append(z + (v & MASK))
        v >>= BITS
    out.append(z + v)
    return out


def sign(a):
    return a[-1] < 0


def extend(a, K):
    """K 本へ伸ばす（K が長ければ零を足して繰り上がりを直す）。"""
    if len(a) >= K:
        return a
    return norm(a + [jnp.zeros_like(a[0])] * (K - len(a)))


def fit(a, K):
    """K 本に合わせる。短ければ伸ばし、長ければ上を捨てる（符号は最上位の本へ移す）。"""
    if len(a) <= K:
        return extend(a, K)
    neg = a[-1] < 0
    low = list(a[:K])
    low[-1] = low[-1] - jnp.where(neg, BASE, 0)
    return low


def add(a, b, K):
    a, b = fit(a, K), fit(b, K)
    return norm([x + y for x, y in zip(a, b)])


def neg(a):
    return norm([-x for x in a])


def shl(a, s, K):
    """2^s 倍（s は python の整数）。"""
    q, r = divmod(s, BITS)
    z = jnp.zeros_like(a[0])
    ls = [z] * q + [x << r for x in a]
    return fit(norm(ls + [z]), K)


def where(c, a, b):
    return [jnp.where(c, x, y) for x, y in zip(a, b)]


def absval(a):
    n = sign(a)
    return where(n, neg(a), a), n


def mul(a, b, K):
    """a·b を K 本で返す（上は捨てる）。"""
    aa, na = absval(a)
    bb, nb = absval(b)
    acc = [jnp.zeros_like(a[0]) for _ in range(K)]
    for i in range(min(len(aa), K)):
        for j in range(len(bb)):
            if i + j < K:
                acc[i + j] = acc[i + j] + aa[i] * bb[j]
        acc = norm(acc)
    return where(na ^ nb, neg(acc), acc)


def eq(a, b):
    K = max(len(a), len(b))
    a, b = extend(a, K), extend(b, K)
    r = a[0] == b[0]
    for x, y in zip(a[1:], b[1:]):
        r = r & (x == y)
    return r


def lt(a, b):
    """a < b（符号つき）。正規形の辞書式比較。"""
    K = max(len(a), len(b))
    a, b = extend(a, K), extend(b, K)
    r = a[0] < b[0]
    for x, y in zip(a[1:], b[1:]):
        r = (x < y) | ((x == y) & r)
    return r


def low_int(a):
    """番地として読む。下位 2 本（30 bit）まで。"""
    if len(a) == 1:
        return a[0]
    return a[0] + (a[1] << BITS)


def to_python(limbs):
    """limbs: 長さ K の整数の列（正規形）→ python の整数。"""
    v = 0
    for k, l in enumerate(limbs):
        v += int(l) << (BITS * k)
    return v
