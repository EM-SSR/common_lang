# -*- coding: utf-8 -*-
"""手で書いた全体の作図と、箱の列（chain）の勾配が一致する（経路一致、文書 §4.2、§4.3）。

cmn/example/diamond_rev.cmn は、共有ノードを持つ主作図

    u = x²,  y = u + 1,  z = u²,  L = y z                       （x = 2 のとき dL/dx = 224）

の逆向きの微分作図で、係数を ȳ の左右に挟む入れ子にしてあるので入れ替えが 1 回も要らない。
"""
import os

import torch
from common_vcpu import toolchain

from gradcmn4torch import torch_fn

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIAMOND = [("he", 0), ("ti", 0), ("he", 0), ("he", 0), ("he", 0), ("ti", 0), ("hu", 1), ("no", 1), ("ho", 2), ("ti", 0)]


def test_diamond_by_hand():
    image, need = toolchain.compile([os.path.join(HERE, "cmn", "example", "diamond_rev.cmn")], None,
                                    os.path.join(os.environ.get("TEMP", "/tmp"), "diamond_rev.bin"))
    by_hand = toolchain.run(toolchain.load(image, need), toolchain.WORK + 64, {})[0]
    x = torch.tensor([[2.0]], dtype=torch.float64, requires_grad=True)
    y = torch_fn.Construction(DIAMOND, 1)(x)
    y.sum().backward()
    assert y.item() == 80                         # u = 4, y = 5, z = 16
    assert x.grad.item() == by_hand == 224


XOR = [("he", 0), ("he", 2), ("ti", 1), ("he", 1), ("no", 1), ("ha", 1), ("sw", 1), ("no", 0), ("no", 0)]       # a + b − 2ab


def test_xor_by_hand():
    """式 (2.6)(2.7): XOR~(a, b) = a + b − 2ab、∂/∂a = 1 − 2b、∂/∂b = 1 − 2a。a = 1、b = 0 の手書きの作図と箱の列を比べる。"""
    image, need = toolchain.compile([os.path.join(HERE, "cmn", "example", "xor_rev.cmn")], None,
                                    os.path.join(os.environ.get("TEMP", "/tmp"), "xor_rev.bin"))
    M = toolchain.run(toolchain.load(image, need), toolchain.WORK + 64, {})
    by_hand = (M[0] - (1 << 64) if M[0] >= 1 << 63 else M[0], M[1])              # (∂/∂b, ∂/∂a)
    c = torch_fn.Construction(XOR, 2)
    for a, b in ((0, 0), (0, 1), (1, 0), (1, 1)):
        x = torch.tensor([[a, b]], dtype=torch.float64, requires_grad=True)
        y = c(x)
        y.sum().backward()
        assert y.item() == (a ^ b)                                  # 二値で元のゲートと一致する（式 9.1）
        assert x.grad.tolist() == [[1 - 2 * b, 1 - 2 * a]]
    assert by_hand == (-1, 1)


def test_trace_by_hand():
    """式 (6.4)(6.5): E_2 = ρ S_1 ⊕ S_2。ρ = 1/2、S_1 = (1/2, −1/2)、S_2 = (−1/2, 1/2)。
    時刻の対を入れ子に並べると、減衰の箱 ti と合流の箱 no が隣り合って、入れ替えが要らない。"""
    from gradcmn4torch import trace

    image, need = toolchain.compile([os.path.join(HERE, "cmn", "example", "trace.cmn")], None,
                                    os.path.join(os.environ.get("TEMP", "/tmp"), "trace.bin"))
    M = toolchain.run(toolchain.load(image, need), toolchain.WORK + 64, {})
    by_hand = [(m - (1 << 64) if m >= 1 << 63 else m) / 4.0 for m in (M[0], M[1])]          # 深度 2
    S1 = torch.tensor([0.5, -0.5], dtype=torch.float64)
    S2 = torch.tensor([-0.5, 0.5], dtype=torch.float64)
    assert by_hand == trace.accumulate([S1, S2], 1).tolist() == [-0.25, 0.25]
