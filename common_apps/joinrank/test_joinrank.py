# -*- coding: utf-8 -*-
"""接合秩の文を走らせて、定理 4.1 の二つの主張を突き合わせる。

    python test_joinrank.py

1. ρ は値の行列の F2 階数に等しい
2. 平文が出した分離積が元の関数を復元する

       F[α][β] = ⊕_{r<ρ} p_r(α)·q_r(β)

期待値は Python で別に計算する。検査のためだけで、平文の側は語しか受け取らない。
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

sys.path.insert(0, os.path.join(HERE, "svg"))

import build  # noqa: E402
import draw   # noqa: E402


def f2rank(rows):
    """検査用。掃き出しで F2 階数を出す"""
    rows, rank = [r[:] for r in rows], 0
    ncol = len(rows[0]) if rows else 0
    for c in range(ncol):
        piv = next((i for i in range(rank, len(rows)) if rows[i][c]), None)
        if piv is None:
            continue
        rows[rank], rows[piv] = rows[piv], rows[rank]
        for i in range(len(rows)):
            if i != rank and rows[i][c]:
                rows[i] = [(a ^ b) for a, b in zip(rows[i], rows[rank])]
        rank += 1
    return rank


def matrix(table, n, cut):
    na, nb = 1 << cut, 1 << (n - cut)
    return [[table[a + na * b] for b in range(nb)] for a in range(na)]


def check(name, table, n, cut):
    F = matrix(table, n, cut)
    want = f2rank(F)
    rho, p, q = build.joinrank(table, n, cut)
    back = [[0] * len(F[0]) for _ in F]
    for r in range(rho):
        for a in range(len(F)):
            for b in range(len(F[0])):
                back[a][b] ^= p[r][a] & q[r][b]
    ok = (rho == want) and (back == F)
    print("%-26s n=%d κ=%d   ρ=%-2d 期待 %-2d   分離積で復元 %s   %s"
          % (name, n, cut, rho, want, "一致" if back == F else "ちがう", "tu" if ok else "te"))
    return ok


def bits(v, n):
    return [(v >> k) & 1 for k in range(n)]


def table_of(n, fn):
    return [fn(bits(v, n)) for v in range(1 << n)]


def geometry(n, cut, table):
    """図の交点が本当に曲線の上に乗り、境界の上に乗るかを数で確かめる。"""
    R = 300.0
    fig = build.figure(table, n, cut)
    bad = []
    yout = draw.xy(0.5, -math.pi / 2.0, R)
    for t in fig["anf"]:
        pa = draw.xy(draw.radius(t), draw.angle(t, n), R)
        ctl = draw.mid_ctrl(pa, yout, 26.0 if pa[0] >= 0 else -26.0)
        x = draw.cross_at(pa, ctl, yout, draw.f_axis)
        if x is None or abs(x[1]) > 1e-6:
            bad.append(("E_plus が実軸を渡らない", t))
    thc = draw.cut_angle(cut)
    fcut = draw.f_cut(thc)
    ncross = 0
    for r in range(fig["rho"]):
        rr = 0.40 + 0.22 * (r + 1) / (fig["rho"] + 1)
        ap = draw.mean_angle(fig["psup"][r], n, thc, math.pi)
        aq = draw.mean_angle(fig["qsup"][r], n, 0.0, thc)
        pp, pq = draw.xy(rr, ap, R), draw.xy(rr, aq, R)
        x = draw.cross_at(pq, draw.mid_ctrl(pq, pp, 0.0), pp, fcut)
        if x is None or abs(fcut(x)) > 1e-6 or x[1] > 1e-6:
            bad.append(("太弦がカットを渡らない", r))
        else:
            ncross += 1
    ok = (not bad) and ncross == fig["rho"]
    print("%-26s n=%d κ=%d   交点は曲線と境界の上 %s   太弦 %d 本 = ρ %d   %s"
          % ("図の交点", n, cut, "はい" if not bad else bad[:2], ncross, fig["rho"],
             "tu" if ok else "te"))
    return ok


def main():
    cases = []

    # 分離する関数。カットを渡る情報は一本しか要らない
    cases.append(("x0·x1 ⊕ x2·x3 の積形 (x0x1)(x2x3)", 4, 2,
                  table_of(4, lambda x: (x[0] & x[1]) & (x[2] & x[3]))))
    # 和。左右それぞれ一本ずつと定数で ρ = 2
    cases.append(("x0x1 ⊕ x2x3", 4, 2,
                  table_of(4, lambda x: (x[0] & x[1]) ^ (x[2] & x[3]))))
    # 内積。カットを渡る本数が入力の半分だけ要る
    cases.append(("内積 ⊕_k x_k·y_k (k<2)", 4, 2,
                  table_of(4, lambda x: (x[0] & x[2]) ^ (x[1] & x[3]))))
    cases.append(("内積 ⊕_k x_k·y_k (k<3)", 6, 3,
                  table_of(6, lambda x: (x[0] & x[3]) ^ (x[1] & x[4]) ^ (x[2] & x[5]))))
    # 等しいか。ρ は 2^(n/2) まで上がる
    cases.append(("等しいか [x=y] (2 bit)", 4, 2,
                  table_of(4, lambda x: int(x[0] == x[2] and x[1] == x[3]))))
    # 線形。どのカットでも ρ ≤ 2
    cases.append(("排他和 x0⊕x1⊕x2⊕x3", 4, 2,
                  table_of(4, lambda x: x[0] ^ x[1] ^ x[2] ^ x[3])))
    cases.append(("全部の積 x0x1x2x3x4", 5, 2,
                  table_of(5, lambda x: x[0] & x[1] & x[2] & x[3] & x[4])))
    # 定数
    cases.append(("零", 4, 2, table_of(4, lambda x: 0)))
    cases.append(("一", 4, 2, table_of(4, lambda x: 1)))
    # 同じ関数を別のカットで見る
    t = table_of(6, lambda x: (x[0] & x[1]) ^ (x[2] & x[3]) ^ (x[4] & x[5]))
    for k in (1, 2, 3, 4, 5):
        cases.append(("x0x1⊕x2x3⊕x4x5 のカット %d" % k, 6, k, t))

    bad = 0
    for name, n, cut, table in cases:
        if not check(name, table, n, cut):
            bad += 1
    print("")
    for n, cut, fn in ((4, 2, lambda x: (x[0] & x[1]) ^ (x[2] & x[3])),
                       (6, 3, lambda x: (x[0] & x[3]) ^ (x[1] & x[4]) ^ (x[2] & x[5])),
                       (4, 2, lambda x: int(x[0] == x[2] and x[1] == x[3]))):
        if not geometry(n, cut, table_of(n, fn)):
            bad += 1
    print("te %d 本ちがう" % bad if bad else "tu  すべて一致")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
