# -*- coding: utf-8 -*-
"""検査用。作図の手順と同じ計算を torch で行い、autograd で勾配を出す。

作図の実行（vcpu）とは別に書く。値と勾配は float64 で、Dyad の小さな分母なら誤差は出ない。
扱う語は D と B のワイヤに働く語（no ha ti se za gu ge zi he ho hu sw so hi mo）。
so と hi の勾配は assemble.py の冒頭の規則 s(t) = (1/2) [t² ≤ 1] を torch の Function で与える。
"""
import random
from fractions import Fraction

import torch

from ..assemble import Wires, _step, check


def slope(t):
    return 0.5 * (t * t <= 1).to(t.dtype)


class _Positive(torch.autograd.Function):
    @staticmethod
    def forward(ctx, x):
        ctx.save_for_backward(x)
        return (x > 0).to(x.dtype)

    @staticmethod
    def backward(ctx, g):
        x, = ctx.saved_tensors
        return g * slope(x)


class _LessEq(torch.autograd.Function):
    @staticmethod
    def forward(ctx, u, v):
        ctx.save_for_backward(v - u)
        return (u <= v).to(u.dtype)

    @staticmethod
    def backward(ctx, g):
        d, = ctx.saved_tensors
        s = g * slope(d)
        return -s, s


def evaluate(recipe, xs):
    """手順を x_0 … x_{n-1} に当てる。xs は 0 次元か 1 次元の Tensor の並び。"""
    w = list(xs)
    one = torch.ones_like(xs[0].detach())
    for name, k in recipe:
        if name == "hu":
            w.insert(k, one.clone())
        elif name == "he":
            w.insert(k + 1, w[k])
        elif name == "ho":
            w.pop(k)
        elif name == "sw":
            w[k], w[k + 1] = w[k + 1], w[k]
        elif name == "no":
            w[k:k + 2] = [w[k] + w[k + 1]]
        elif name == "ti":
            w[k:k + 2] = [w[k] * w[k + 1]]
        elif name == "za":
            w[k:k + 2] = [(w[k] + w[k + 1]) / 2]
        elif name == "zi":
            w[k:k + 2] = [w[k + 1]]
        elif name == "ha":
            w[k] = -w[k]
        elif name == "se":
            w[k] = (w[k] + 1) / 2
        elif name == "gu":
            w[k] = 2 * w[k] - 1
        elif name == "ge":
            w[k] = one.clone()
        elif name == "so":
            w[k] = _Positive.apply(w[k])
        elif name == "hi":
            w[k:k + 2] = [_LessEq.apply(w[k], w[k + 1])]
        elif name == "mo":
            pass
        else:
            raise ValueError(name)
    return w


def value_and_grad(recipe, leaves):
    xs = [torch.tensor(float(v), dtype=torch.float64, requires_grad=True) for v in leaves]
    y = evaluate(recipe, xs)[0]
    if y.requires_grad:
        g = torch.autograd.grad(y, xs, allow_unused=True)
    else:
        g = [None] * len(xs)
    return [Fraction(float(v)) for v in [y] + [0.0 if t is None else t for t in g]]


def graph(recipe, leaves):
    """手順を Fraction の値を持つ図にする。頂点は (種類, 引数の頂点, 値)。入力の頂点の番号は 0 … n-1。

    複製した値は同じ頂点を指す（共有）。同じ頂点を二つの引数に取る箱は、ワイヤが二本になる。
    """
    nodes = []

    def new(kind, args, val):
        nodes.append((kind, args, val))
        return len(nodes) - 1

    rule = {"no": lambda a, b: a + b, "ti": lambda a, b: a * b, "za": lambda a, b: (a + b) / 2,
            "ha": lambda a: -a, "se": lambda a: (a + 1) / 2, "gu": lambda a: 2 * a - 1,
            "ge": lambda a: Fraction(1), "zi": lambda a, b: b, "so": lambda a: Fraction(int(a > 0)),
            "hi": lambda a, b: Fraction(int(a <= b)), "mo": lambda a: a}
    arity = {"no": 2, "ti": 2, "za": 2, "zi": 2, "hi": 2, "ha": 1, "se": 1, "gu": 1, "ge": 1, "so": 1, "mo": 1}
    w = [new("leaf", (), Fraction(v)) for v in leaves]
    for name, k in recipe:
        if name == "hu":
            w.insert(k, new("one", (), Fraction(1)))
        elif name == "he":
            w.insert(k + 1, w[k])
        elif name == "ho":
            w.pop(k)
        elif name == "sw":
            w[k], w[k + 1] = w[k + 1], w[k]
        else:
            r = arity[name]
            args = tuple(w[k:k + r])
            w[k:k + r] = [new(name, args, rule[name](*[nodes[a][2] for a in args]))]
    return nodes, w[0]


def _slope_exact(t):
    return Fraction(1, 2) if t * t <= 1 else Fraction(0)


def _local(nodes, i):
    """頂点 i の入力ごとの微分（式 2.1、2.4）と、分岐の境界の規則。"""
    kind, args, _ = nodes[i]
    v = [nodes[a][2] for a in args]
    return {"no": lambda: [1, 1], "ti": lambda: [v[1], v[0]], "za": lambda: [Fraction(1, 2)] * 2,
            "ha": lambda: [-1], "se": lambda: [Fraction(1, 2)], "gu": lambda: [2], "ge": lambda: [0],
            "zi": lambda: [0, 1], "mo": lambda: [1], "so": lambda: [_slope_exact(v[0])],
            "hi": lambda: [-_slope_exact(v[1] - v[0]), _slope_exact(v[1] - v[0])]}[kind]()


def path_sum(nodes, out, n):
    """出力から入力までの全経路について、微分の積を足す（式 4.3）。"""
    grad = [Fraction(0)] * n

    def walk(i, c):
        kind, args, _ = nodes[i]
        if kind == "leaf":
            grad[i] += c
        elif kind != "one":
            for a, ci in zip(args, _local(nodes, i)):
                walk(a, c * ci)

    walk(out, Fraction(1))
    return grad


def _reachable(step, types):
    """位置 k の算術は、左の k 本を飛び越えて係数を運ぶので、その k 本が D だけのときに限る。"""
    w, k = step
    return w in ("hu", "he", "ho", "sw") or all(t == "D" for t in types[:k])


WORDS = ("hu", "he", "ho", "sw", "no", "ti", "za", "ha", "se", "gu", "ge", "zi", "so", "hi", "mo")


def mixed_depth_hi(recipe, n, shift=0):
    """hi の二つの入力の深度が 0 と 1 以上の組になる手順か。commonc の比べ方はこの組で値どおりでなくなる
    （chain._hi）。torch の計算は値どおりに比べるので、この手順は比べない。"""
    fr = Wires()
    fr.ty, fr.d = ["D"] * n, [shift] * n
    for w, k in recipe:
        if w == "hi" and (fr.d[k] == 0) != (fr.d[k + 1] == 0):
            return True
        _step(fr, w, k)
    return False


def random_recipe(rng, n, length, words=WORDS):
    """正しい形で、終わりにワイヤが 1 本残る手順を、乱数で作る。D と B の語だけを使う。"""
    recipe = []
    for _ in range(length):
        cand = [(w, k) for w in words for k in range(4)]
        rng.shuffle(cand)
        for step in cand:
            try:
                before, after = check(recipe + [step], n)
                if not after or not _reachable(step, before[-1]):
                    continue
            except ValueError:
                continue
            recipe.append(step)
            break
    while len(check(recipe, n)[1]) > 1:
        cand = [("no", 0), ("ti", 0), ("mo", 0), ("ho", 0)]
        rng.shuffle(cand)
        for step in cand:
            try:
                if not check(recipe + [step], n)[1]:
                    continue
            except ValueError:
                continue
            recipe.append(step)
            break
    return recipe
