# -*- coding: utf-8 -*-
"""箱（boxes.py）を torch.autograd.Function にする。逆伝播は backward、前向きの微分は jvp が箱を実行して出す。

テンソルの値は二進有理数（float64 で厳密）。箱へは、入力を共通の 2^b の格子の整数にして渡し、
出口の整数を 2^(b') で割って戻す。上流から来る勾配は 2^-GRID の格子に丸めてから箱へ渡す。

文書との対応
    局所微分箱 D_i f             ti.rev  no.rev  hi.rev  so.rev …（cmn/box/*.cmn）
    合流 ⊕                       Dup の backward（no）。共有した値が複数の後続へ渡る箇所では autograd が足す
    微分持ち上げ f̂ (式 2.2)      jvp（ti.fwd  hi.fwd …）
"""
import numpy as np
import torch

from . import boxes

GRID = 24            # 上流の勾配を 2^-GRID の格子へ丸める
LIMIT = 62           # 整数が 2^LIMIT を越えると 64 bit の語に入らない


def _bits(v):
    """v のすべての要素が整数になる最小の b（v = 整数 / 2^b）。"""
    v = v[v != 0]
    if v.size == 0:
        return 0, 0
    m, e = np.frexp(v)
    mant = (m * (1 << 53)).astype(np.int64)
    low = np.where(mant == 0, 53, np.log2((mant & -mant).astype(np.float64)).astype(np.int64))
    b = np.max(53 - e - low)
    return max(int(b), 0), int(np.max(e))


def common(*ts):
    """入力の共通の b と、整数にした入力。"""
    arrays = [t.detach().cpu().numpy().astype(np.float64) for t in ts]
    b = max(_bits(a)[0] for a in arrays)
    top = max(_bits(a)[1] for a in arrays)
    if b + top > LIMIT:
        raise OverflowError("整数が 64 bit の語に入らない（b=%d、桁 %d）" % (b, top))
    return b, [np.rint(a * 2.0 ** b).astype(np.int64) for a in arrays]


def call(name, ts, extra=()):
    """箱 name を実行する。ts は Tensor の並び、extra は単位 U = 2^b を入力に加えるときの指定。返りは Tensor の並び。"""
    ref = ts[0]
    shape = ref.shape
    ts = [t.reshape(-1) for t in ts]
    b, ints = common(*ts)
    if extra:
        ints = ints + [np.full_like(ints[0], 1 << b)]
    out = boxes.run(name, ints)
    nb = boxes.OUT_SCALE[name](b)
    return [torch.as_tensor(o.astype(np.float64) / 2.0 ** nb, dtype=ref.dtype, device=ref.device).reshape(shape) for o in out]


def snap(g):
    """上流の勾配を 2^-GRID の格子に丸める。"""
    return torch.round(g * (1 << GRID)) / (1 << GRID)


class Ti(torch.autograd.Function):
    @staticmethod
    def forward(ctx, a, b):
        ctx.save_for_backward(a, b)
        ctx.save_for_forward(a, b)
        return call("ti.value", [a, b])[0]

    @staticmethod
    def backward(ctx, g):
        a, b = ctx.saved_tensors
        da, db = call("ti.rev", [a, b, snap(g)])
        return da, db

    @staticmethod
    def jvp(ctx, ta, tb):
        a, b = ctx.saved_tensors
        return call("ti.fwd", [a, b, snap(ta), snap(tb)])[0]


class No(torch.autograd.Function):
    @staticmethod
    def forward(ctx, a, b):
        return call("no.value", [a, b])[0]

    @staticmethod
    def backward(ctx, g):
        return tuple(call("no.rev", [snap(g)]))

    @staticmethod
    def jvp(ctx, ta, tb):
        return call("no.value", [snap(ta), snap(tb)])[0]


class Dup(torch.autograd.Function):
    """複製 Δ。双対は足し算 ⊕。"""

    @staticmethod
    def forward(ctx, a):
        return a.clone(), a.clone()

    @staticmethod
    def backward(ctx, g1, g2):
        return call("no.value", [snap(g1), snap(g2)])[0]

    @staticmethod
    def jvp(ctx, t):
        return t.clone(), t.clone()


class Ha(torch.autograd.Function):
    @staticmethod
    def forward(ctx, a):
        return call("ha.value", [a])[0]

    @staticmethod
    def backward(ctx, g):
        return call("ha.value", [snap(g)])[0]

    @staticmethod
    def jvp(ctx, t):
        return call("ha.value", [snap(t)])[0]


class Za(torch.autograd.Function):
    @staticmethod
    def forward(ctx, a, b):
        return call("za.value", [a, b])[0]

    @staticmethod
    def backward(ctx, g):
        d1, d2 = call("no.rev", [snap(g)])
        return d1 / 2, d2 / 2

    @staticmethod
    def jvp(ctx, ta, tb):
        return call("za.value", [snap(ta), snap(tb)])[0]


class Gu(torch.autograd.Function):
    @staticmethod
    def forward(ctx, a):
        return call("gu.value", [a], extra=True)[0]

    @staticmethod
    def backward(ctx, g):
        return call("gu.rev", [snap(g)])[0]

    @staticmethod
    def jvp(ctx, t):
        return call("gu.rev", [snap(t)])[0]


class Ge(torch.autograd.Function):
    @staticmethod
    def forward(ctx, a):
        return call("ge.value", [torch.ones_like(a)])[0]

    @staticmethod
    def backward(ctx, g):
        return call("ge.rev", [snap(g)])[0]

    @staticmethod
    def jvp(ctx, t):
        return call("ge.rev", [snap(t)])[0]


class So(torch.autograd.Function):
    """観測 [0 < x]。境界の規則 ∂/∂x = s(x) = (1/2)[x² ≤ 1]（文書 §9.3）。"""

    @staticmethod
    def forward(ctx, a):
        ctx.save_for_backward(a)
        ctx.save_for_forward(a)
        return call("so.value", [a])[0]

    @staticmethod
    def backward(ctx, g):
        a, = ctx.saved_tensors
        return call("so.rev", [a, snap(g)], extra=True)[0]

    @staticmethod
    def jvp(ctx, t):
        a, = ctx.saved_tensors
        return call("so.rev", [a, snap(t)], extra=True)[0]


class Hi(torch.autograd.Function):
    """大小 [x ≤ y]。境界の規則 ∂/∂y = s(y−x) = −∂/∂x。"""

    @staticmethod
    def forward(ctx, a, b):
        ctx.save_for_backward(a, b)
        ctx.save_for_forward(a, b)
        return call("hi.value", [a, b])[0]

    @staticmethod
    def backward(ctx, g):
        a, b = ctx.saved_tensors
        da, db = call("hi.rev", [a, b, snap(g)], extra=True)
        return da, db

    @staticmethod
    def jvp(ctx, ta, tb):
        a, b = ctx.saved_tensors
        return call("hi.fwd", [a, b, snap(ta), snap(tb)], extra=True)[0]


class Sub(torch.autograd.Function):
    """引き算 a ⊖ b。双対は (ȳ, ⊖ȳ)。"""

    @staticmethod
    def forward(ctx, a, b):
        return call("sub.value", [a, b])[0]

    @staticmethod
    def backward(ctx, g):
        return tuple(call("sub.rev", [snap(g)]))

    @staticmethod
    def jvp(ctx, ta, tb):
        return call("sub.value", [snap(ta), snap(tb)])[0]


class Eqz(torch.autograd.Function):
    """零との一致 1 ⊖ [0<x] ⊖ [0<⊖x]。境界の規則が左右で打ち消し合うので、微分は 0。"""

    @staticmethod
    def forward(ctx, a):
        return call("eqz.value", [a])[0]

    @staticmethod
    def backward(ctx, g):
        return call("ge.rev", [snap(g)])[0]

    @staticmethod
    def jvp(ctx, t):
        return call("ge.rev", [snap(t)])[0]


class Sign(torch.autograd.Function):
    """符号 [0<x] ⊖ [0<⊖x]。境界の規則から微分は 2 s(x) = [x² ≤ 1]。"""

    @staticmethod
    def forward(ctx, a):
        ctx.save_for_backward(a)
        ctx.save_for_forward(a)
        return call("sign.value", [a])[0]

    @staticmethod
    def backward(ctx, g):
        a, = ctx.saved_tensors
        return call("sign.rev", [a, snap(g)], extra=True)[0]

    @staticmethod
    def jvp(ctx, t):
        a, = ctx.saved_tensors
        return call("sign.fwd", [a, snap(t)], extra=True)[0]


class Lin(torch.autograd.Function):
    """線形補間 1 ⊕ h ⋆ (x ⊖ 1)。∂/∂h = x ⊖ 1、∂/∂x = h。"""

    @staticmethod
    def forward(ctx, h, x):
        ctx.save_for_backward(h, x)
        ctx.save_for_forward(h, x)
        return call("lin.value", [h, x], extra=True)[0]

    @staticmethod
    def backward(ctx, g):
        h, x = ctx.saved_tensors
        dh, dx = call("lin.rev", [h, x, snap(g)], extra=True)
        return dh, dx

    @staticmethod
    def jvp(ctx, th, tx):
        h, x = ctx.saved_tensors
        return call("lin.fwd", [h, x, snap(th), snap(tx)], extra=True)[0]
