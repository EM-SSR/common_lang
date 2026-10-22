# -*- coding: utf-8 -*-
"""接合秩の図を一式そろえる。頂点値の表を作って draw.py に渡すだけ。

    python figures.py [--out build]

出す図は四枚。どれも同じ座標系（定義 4.1）で、カットと接合秩だけが違う。

| 図 | 関数 | カット | rho | 見どころ |
|---|---|---|---|---|
| sep | (x0 x1)(x2 x3) | 2 | 1 | 分離する関数。渡る影響は一本 |
| sum | x0 x1 + x2 x3 | 2 | 2 | 分離積が二本 |
| ip | 内積 3 bit | 3 | 3 | 本数が入力の半分に比例する |
| eq | 等しいか 2 bit | 2 | 4 | 上限 2^|A|。カットを渡る情報が最大 |
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "svg"))

import draw  # noqa: E402


def bits(v, n):
    return [(v >> k) & 1 for k in range(n)]


def table(n, fn):
    return "".join(str(fn(bits(v, n))) for v in range(1 << n))


FIGS = [
    ("sep", 4, 2, lambda x: (x[0] & x[1]) & (x[2] & x[3]), "積の形。渡る影響は一本"),
    ("sum", 4, 2, lambda x: (x[0] & x[1]) ^ (x[2] & x[3]), "和の形。分離積が二本"),
    ("ip", 6, 3, lambda x: (x[0] & x[3]) ^ (x[1] & x[4]) ^ (x[2] & x[5]), "内積。本数は入力の半分"),
    ("eq", 4, 2, lambda x: int(x[0] == x[2] and x[1] == x[3]), "等しいか。上限まで上がる"),
]


def main():
    ap = argparse.ArgumentParser(description="接合秩の図を一式作る")
    ap.add_argument("--out", default=os.path.join(HERE, "build"))
    ap.add_argument("--theme", choices=("light", "dark"), default="light")
    ap.add_argument("--view", choices=("raw", "factor", "both"), default="both")
    opt = ap.parse_args()
    os.path.isdir(opt.out) or os.makedirs(opt.out)
    for name, n, cut, fn, note in FIGS:
        path = os.path.join(opt.out, "joinrank_%s.svg" % name)
        draw.main(["--table", table(n, fn), "--cut", str(cut), "--out", path,
                   "--theme", opt.theme, "--view", opt.view,
                   "--title", "%s   %s" % (name, note)])


if __name__ == "__main__":
    main()
