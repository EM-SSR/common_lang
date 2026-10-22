# -*- coding: utf-8 -*-
"""PyTorch から使う検査。backward と前向きの微分が、普通の torch の計算（plain_ops）と一致する。"""
import numpy as np
import pytest
import torch

from gradcmn4torch import chain, torch_fn
from gradcmn4torch.check import plain_ops
from gradcmn4torch.check.test_chain import program
from gradcmn4torch.synth import problem as pb

BITS = pb.BITS


def inputs(rng, count=32):
    return torch.tensor(rng.integers(-3 * 8, 3 * 8 + 1, (count, pb.N_LEAF)) / 8.0, requires_grad=True)


def plain_jacobian(recipe, x):
    ys = [x.detach()[:, i].clone().requires_grad_() for i in range(x.shape[1])]
    slot = chain.run(recipe, ys, BITS, ops=plain_ops)[0]
    out = []
    for y in chain_words(slot):
        if not y.requires_grad:
            out.append(torch.zeros_like(x))
            continue
        g = torch.autograd.grad(y.sum(), ys, retain_graph=True, allow_unused=True)
        out.append(torch.stack([torch.zeros_like(ys[0]) if t is None else t for t in g], 1))
    return out


def chain_words(slot):
    t, v, _ = slot
    return [v] if t in ("D", "B") else list(v)


@pytest.mark.parametrize("seed", range(40))
def test_backward_and_jvp(seed):
    rng, recipe, _ = program(seed)
    x = inputs(rng)
    c = torch_fn.Construction(recipe, pb.N_LEAF, BITS)
    try:
        y = c(x)
    except (OverflowError, RuntimeError) as e:
        if not isinstance(e, OverflowError) and "実行できない" not in str(e):
            raise                                                   # 実行台が止まる手順だけを飛ばす
        pytest.skip(str(e)[:40])
    if c.final not in torch_fn.ACTIVE_WORDS:
        return
    if not y.requires_grad:
        pytest.skip("箱の列で表せない手順（閉包、作業領域の外）は微分を伝えない")
    want = plain_jacobian(recipe, x)
    for j, w in enumerate(want):
        x.grad = None
        y[:, j].sum().backward(retain_graph=True)
        got = torch.zeros_like(x) if x.grad is None else x.grad
        assert torch.equal(got, w), (recipe, j)
    dx = torch.tensor(rng.integers(-8, 9, tuple(x.shape)) / 8.0)
    t = c.jvp(x, dx)
    for j, w in enumerate(want):
        assert torch.equal(t[:, j], (w * dx).sum(1)), (recipe, j)


def test_forward_ad_through_evaluate():
    """torch.autograd.forward_ad で、Construction の出力の接ベクトルが前向きの箱の列（jvp）と一致する。"""
    import torch.autograd.forward_ad as fwAD

    rng = np.random.default_rng(3)
    recipe = [("he", 0), ("ti", 0), ("he", 1), ("hi", 1), ("mo", 1), ("no", 0)]
    c = torch_fn.Construction(recipe, 2, BITS)
    x = torch.tensor(rng.integers(-24, 25, (32, 2)) / 8.0)
    dx = torch.tensor(rng.integers(-8, 9, (32, 2)) / 8.0)
    with fwAD.dual_level():
        y = c(fwAD.make_dual(x.requires_grad_(), dx))
        t = fwAD.unpack_dual(y).tangent
    assert torch.equal(t, c.jvp(x.detach(), dx))


@pytest.mark.parametrize("seed", range(60))
def test_values_same_as_commonc(seed):
    """evaluate が返す答えの語は、主作図を commonc で実行した出口の語と厳密に一致する（実行できない手順も同じ）。"""
    from gradcmn4torch import assemble, run

    rng, recipe, built = program(seed)
    if any(w in ("me", "di") for w, _ in recipe):
        pytest.skip("me と di は答えを出さない")
    x = inputs(rng)
    y = torch_fn.evaluate([recipe], [x], BITS)[0]
    grid = np.rint(x.detach().numpy() * 8).astype(np.int64)
    try:
        want = run.run_lanes(built.text, grid, len(built.depths)).astype(np.float64) / np.array([2.0 ** d for d in built.depths])
    except RuntimeError:
        assert y is None, recipe                                    # commonc が止まる手順は、こちらも None
        return
    if y is None:
        pytest.skip("整数が 64 bit に入らない")
    assert np.array_equal(y.detach().numpy(), want), recipe


def test_division_by_zero_is_a_failure():
    """ba は零で割ると commonc が失敗を報告する。evaluate も None を返す。"""
    recipe = [("ho", 0), ("ba", 0)]
    x = torch.tensor([[1.0, 2.0, 3.0], [1.0, 2.0, 0.0]], dtype=torch.float64)
    assert torch_fn.evaluate([recipe], [x], BITS)[0] is None
    assert torch_fn.evaluate([recipe], [x[:1]], BITS)[0] is not None


def test_backward_overflow_fails_only_that_program(monkeypatch):
    """逆向きの箱が語の幅を越えて止まった手順だけが None になり、ほかの手順の値と微分は残る。"""
    from gradcmn4torch import boxes
    run = boxes.run

    def overflowing(name, ints):
        if name == "hi.rev":
            raise RuntimeError("箱が報告 [43] で止まった")
        return run(name, ints)

    monkeypatch.setattr(boxes, "run", overflowing)
    x = inputs(np.random.default_rng(0), 8)
    with_hi = [("hi", 0), ("ha", 1), ("mo", 0), ("ho", 1)]
    without_hi = [("ti", 0), ("ha", 1), ("za", 0)]
    ys = torch_fn.evaluate([with_hi, without_hi], [x, x], BITS)
    assert ys[0] is None and ys[1] is not None
    ys[1].sum().backward()
    assert x.grad is not None
