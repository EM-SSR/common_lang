# -*- coding: utf-8 -*-
"""箱ごとの検査。値の保存（式 9.1）、局所の微分（式 2.1、2.4、2.7、2.8）、局所双対性（式 5.1）。
手で書いた箱（cmn/box）を torch の演算（plain_ops）と比べる。so と hi は境界の規則 s(t) = (1/2)[t² ≤ 1] を含む。"""
import pytest
import torch
import torch.autograd.forward_ad as fwAD

from gradcmn4torch import ops
from gradcmn4torch.check import plain_ops

ARITY = {"Ti": 2, "No": 2, "Za": 2, "Ha": 1, "Gu": 1, "So": 1, "Hi": 2, "Sub": 2, "Eqz": 1, "Sign": 1, "Lin": 2}


def sample(count=2000):
    g = torch.Generator().manual_seed(0)
    return [(torch.randint(-24, 25, (count,), generator=g).double() / 8) for _ in range(2)]


@pytest.mark.parametrize("name", sorted(ARITY))
def test_value_gradient_and_forward(name):
    mine, plain, n = getattr(ops, name), getattr(plain_ops, name), ARITY[name]
    x = sample()[:n]
    a = [t.clone().requires_grad_() for t in x]
    b = [t.clone().requires_grad_() for t in x]
    ya, yb = mine.apply(*a), plain.apply(*b)
    assert torch.equal(ya, yb)
    ya.sum().backward()
    yb.sum().backward()
    assert all(torch.equal(p.grad, q.grad) for p, q in zip(a, b))
    dx = [(t * 0 + torch.randint(-8, 9, t.shape).double() / 8) for t in x]
    with fwAD.dual_level():
        ta = mine.apply(*[fwAD.make_dual(t, d) for t, d in zip(x, dx)])
        tangent = fwAD.unpack_dual(ta).tangent
    assert torch.equal(tangent, sum(p.grad * d for p, d in zip(a, dx)))          # 前向きと逆向きが同じ（式 5.1）
