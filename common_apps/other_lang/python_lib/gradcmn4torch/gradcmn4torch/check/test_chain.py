# -*- coding: utf-8 -*-
"""手順を箱の列として実行する chain の検査。

    値の保存   chain の値が commonc の語の出口と一致する（式 9.1）。𝒬 の語は入力の格子全体で、型つきの乱数の手順でも
    局所箱     cmn の箱で出した勾配が、普通の torch の演算（plain_ops）で出した勾配と一致する
    前後一致   前向き（jvp）と逆向きの微分が同じ値を与える（式 5.2）
"""
import itertools

import numpy as np
import pytest
import torch
import torch.autograd.forward_ad as fwAD

from gradcmn4torch import assemble, chain, run
from gradcmn4torch.check import plain_ops
from gradcmn4torch.synth import problem as pb
from gradcmn4torch.synth import syntax

WIDTH = {"D": 1, "B": 1, "Q": 2, "X": 2}          # 微分の対象になる出口の語の数

GRID = np.array(list(itertools.product(range(-2, 3), repeat=4)), dtype=np.int64)
TO2 = [("to", 0), ("to", 1)]                       # 窓 [x0 x1 x2 x3] → 𝒬 が二つ
CASES = {                                          # 語 → (主作図の手順, 入力の数, 比べる出口の語の数)
    "to": ([("ho", 0), ("ho", 0), ("to", 0)], 4, 2),
    "na": ([("ho", 0), ("ho", 0), ("ho", 0), ("na", 0)], 4, 2),
    "ni": ([("ho", 0), ("ho", 0), ("ho", 0), ("ni", 0)], 4, 2),
    "ba": ([("ho", 0), ("ho", 0), ("ba", 0)], 4, 2),
    "ru": ([("ho", 0), ("ho", 0), ("ho", 0), ("na", 0), ("ru", 0)], 4, 2),
    "go": ([("ho", 0), ("ho", 0), ("ho", 0), ("na", 0), ("go", 0)], 4, 1),
    "ne": ([("ho", 0), ("ho", 0), ("ho", 0), ("na", 0), ("ne", 0)], 4, 1),
    "nu": (TO2 + [("nu", 0)], 4, 2),
    "yu": (TO2 + [("yu", 0)], 4, 2),
    "ye": (TO2 + [("ye", 0)], 4, 2),
    "yo": (TO2 + [("yo", 0)], 4, 2),
    "ra": (TO2 + [("ra", 0)], 4, 1),
}


def words(slot):
    t, v, _ = slot
    return [v] if t in ("D", "B") else list(v)


@pytest.mark.parametrize("shift", [0, 3])
@pytest.mark.parametrize("name", sorted(CASES))
def test_q_word_same_as_commonc(name, shift):
    recipe, n, compare = CASES[name]
    grid = GRID[GRID[:, 3] != 0] if name == "ba" else GRID          # 零で割ると commonc は失敗を報告する
    built = assemble.value(recipe, n, shift)
    want = run.run_lanes(built.text, grid, len(built.depths)).astype(np.float64) / np.array([2.0 ** d for d in built.depths])
    xs = [torch.tensor(grid[:, i] / 2.0 ** shift) for i in range(n)]
    got = torch.stack(words(chain.run(recipe, xs, shift)[0]), 1).numpy()
    assert (got[:, :compare] == want[:, :compare]).all(), name


def program(seed):
    rng = np.random.default_rng(seed)
    while True:
        tokens = syntax.random_tokens(rng, int(rng.integers(1, 7)))
        if tokens is None:
            continue
        recipe = syntax.to_recipe(tokens)
        try:
            return rng, recipe, assemble.layered(syntax.to_layers(tokens), recipe, pb.N_LEAF, pb.BITS)
        except (OverflowError, ValueError):
            continue


def leaves(rng, count=64):
    return [torch.tensor(rng.integers(-3 * 8, 3 * 8 + 1, count) / 8.0, requires_grad=True) for _ in range(pb.N_LEAF)]


def grads(y, xs):
    if not y.requires_grad:                                          # 入力に依らない値
        return torch.zeros(len(y), len(xs), dtype=y.dtype)
    g = torch.autograd.grad(y.sum(), xs, retain_graph=True, allow_unused=True)
    return torch.stack([torch.zeros_like(x) if t is None else t for t, x in zip(g, xs)], 1)


@pytest.mark.parametrize("seed", range(120))
def test_random_program(seed):
    rng, recipe, built = program(seed)
    xs = leaves(rng)
    ys = [x.detach().clone().requires_grad_() for x in xs]
    try:
        mine, failed, unsupported = chain.run_all(recipe, xs, pb.BITS)
        plain = chain.run(recipe, ys, pb.BITS, ops=plain_ops)
    except OverflowError as e:
        pytest.skip(str(e)[:40])
    if failed or unsupported:
        pytest.skip("答えを出さない手順か、箱の列で表せない手順")
    assert len(mine) == 1
    if mine[0][0] not in WIDTH:
        return                                                      # D から値が届かない型
    grid = np.stack([np.rint(x.detach().numpy() * 8).astype(np.int64) for x in xs], 1)
    try:
        want = run.run_lanes(built.text, grid, len(built.depths)).astype(np.float64) / np.array([2.0 ** d for d in built.depths])
    except RuntimeError as e:                                       # 実行台が止まる手順
        pytest.skip(str(e)[:40])
    wa, wb = words(mine[0]), words(plain[0])
    assert (torch.stack(wa, 1).detach().numpy() == want[:, :len(wa)]).all(), recipe
    for a, b in zip(wa, wb):
        assert torch.equal(grads(a, xs), grads(b, ys)), recipe       # 局所箱
    dx = [torch.tensor(rng.integers(-8, 9, len(xs[0])) / 8.0) for _ in xs]
    with fwAD.dual_level():
        dual = chain.run(recipe, [fwAD.make_dual(x.detach(), t) for x, t in zip(xs, dx)], pb.BITS)
        tangents = [fwAD.unpack_dual(w).tangent for w in words(dual[0])]
    for a, t in zip(wa, tangents):
        back = (grads(a, xs) * torch.stack(dx, 1)).sum(1)
        assert torch.equal(back, torch.zeros_like(back) if t is None else t), recipe        # 前後一致


@pytest.mark.parametrize("recipe,final", [
    ([("ho", 0), ("ho", 0), ("ho", 0), ("ma", 0), ("ma", 0), ("ri", 0)], "Q"),                                  # 名詞から 𝒬
    ([("ho", 0), ("ho", 0), ("ho", 0), ("ma", 0), ("ma", 0), ("ri", 0), ("go", 0), ("mo", 0)], "D"),
    ([("ho", 0), ("ho", 0), ("ho", 0), ("ma", 0), ("kukeke", 0), ("ma", 1), ("kukeke", 1), ("kukese", 0), ("mo", 0)], "D"),
])
def test_value_from_nouns(recipe, final):
    """D から値が届かない語が値を持つ型を出すとき、値は手順だけで決まる。commonc の出口と一致し、勾配は 0。"""
    n = 3
    built = assemble.value(recipe, n, pb.BITS)
    grid = np.array([[1, 2, 3], [-3, 0, 5]], dtype=np.int64)
    want = run.run_lanes(built.text, grid, len(built.depths)).astype(np.float64) / np.array([2.0 ** d for d in built.depths])
    xs = [torch.tensor(grid[:, i] / 8.0, requires_grad=True) for i in range(n)]
    slot = chain.run(recipe, xs, pb.BITS)[0]
    assert slot[0] == final
    got = torch.stack(words(slot), 1).detach().numpy()
    assert (got == want[:, :got.shape[1]]).all()
    assert all(not w.requires_grad for w in words(slot))


def const(k):
    """整数 k (> 0) を hu と no だけで作る手順。窓の左端に 1 本置く。"""
    return [("hu", 0)] + [s for _ in range(k - 1) for s in (("hu", 0), ("no", 0))]


MEMORY_PROGRAMS = {
    "入力の語 1 を読む（A の分子）": const(1) + [("mi", 0), ("ho", 1), ("ho", 1)],
    "語 3 へ A を書いて読み戻す": const(3) + [("mu", 0)] + const(3) + [("mi", 0), ("ho", 1), ("ho", 1)],
    "語 3 へ B の分子を書き、語 3 を読んで足す": const(3) + [("ho", 1), ("mu", 0)] + const(3) + [("mi", 0), ("no", 0)],
    "語 2 と語 4 を読んで足す（B と c の分子）": const(2) + [("mi", 0)] + const(4) + [("mi", 0), ("no", 0)] + [("ho", 1)] * 3,
    "語 5 へ書いて読み戻す": const(5) + [("mu", 0)] + const(5) + [("mi", 0), ("ho", 1), ("ho", 1)],
    "du は値を捨てる": [("du", 0), ("ho", 0), ("ho", 0)] + const(1),
}


@pytest.mark.parametrize("name", sorted(MEMORY_PROGRAMS))
def test_memory_words(name):
    """mi と mu。作業領域の語 1、2、4 に入力の分子が置かれ、mu が書いた値を mi が読み戻す。commonc の出口と一致し、
    勾配は普通の torch の勾配と一致する。"""
    recipe = MEMORY_PROGRAMS[name]
    rng = np.random.default_rng(0)
    grid = rng.integers(-24, 25, size=(64, 3))
    built = assemble.value(recipe, 3, pb.BITS)
    want = run.run_lanes(built.text, grid, len(built.depths)).astype(np.float64) / np.array([2.0 ** d for d in built.depths])
    xs = [torch.tensor(grid[:, i] / 8.0, requires_grad=True) for i in range(3)]
    ys = [x.detach().clone().requires_grad_() for x in xs]
    win, failed, unsupported = chain.run_all(recipe, xs, pb.BITS)
    assert not failed and not unsupported
    got = win[0][1].detach().numpy()
    assert (got == want[:, 0]).all()
    plain = chain.run(recipe, ys, pb.BITS, ops=plain_ops)[0][1]
    ga = grads(win[0][1], xs)
    assert torch.equal(ga, grads(plain, ys))
    assert ga.abs().sum() > 0 or name.startswith("du")


def test_loop_and_reports_use_commonc():
    """閉包（ya yi）は箱の列で表さず、commonc の値を使う。me と di は答えを出さない。"""
    from gradcmn4torch import torch_fn

    x = torch.tensor([[1.0, 2.0, 3.0], [0.0, 1.0, -1.0]], dtype=torch.float64, requires_grad=True)
    loop = [("ho", 0), ("ho", 0), ("ya", 0), ("hu", 0), ("so", 0), ("yi", 0)]                 # B を 1 本立てて閉じる
    win, failed, unsupported = chain.run_all(loop, [x[:, i] for i in range(3)], pb.BITS)
    assert unsupported and not failed
    y = torch_fn.evaluate([loop], [x], pb.BITS)[0]
    assert y is not None and not y.requires_grad and y[:, 0].tolist() == x[:, 2].tolist()
    for word in ("me", "di"):
        assert torch_fn.evaluate([[("ho", 0), ("ho", 0), (word, 0)]], [x], pb.BITS)[0] is None
