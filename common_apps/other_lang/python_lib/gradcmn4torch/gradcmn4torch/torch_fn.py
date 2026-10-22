# -*- coding: utf-8 -*-
"""作図を PyTorch の関数として使う。

    y = evaluate(手順の並び, 入力の並び, bits)      手順ごとの答えの語 (L, W)

D、B、𝒬、Rational を答えにする手順は、chain が局所微分箱の列として実行して値と ∂y/∂x を同時に出す。値は commonc の
実行と一致する（check/test_chain.py）。Point、Trace、Reflection、Noun、Region、Chain を答えにする手順は、D の値が届かず
手順だけで値が決まるので、commonc で 1 度だけ実行して覚える。
入力は 2^-bits の格子に丸めてから渡す（丸めの微分は 1 とする）。backward は、箱が出した ∂y_j/∂x に上流の勾配を掛ける。
前向きの微分は jvp_batch が、前向きの箱（ti.fwd など）の列で出す。
"""
from functools import lru_cache

import numpy as np
import torch
import torch.autograd.forward_ad as fwAD

from common_vcpu import toolchain

from . import assemble, chain, run
from .words import D, B, Q, X

ACTIVE_WORDS = {D: 1, B: 1, Q: 2, X: 2}           # 微分の対象になる出口の語の数（先頭から）
CONSTANT_TAIL = {Q: [0.0, 0.0, 1.0]}              # 𝒬 の出口の残り 3 語（構成語 m、ε と符号）は commonc が 0 0 1 に固定している
FAILURES = (OverflowError, ValueError, RuntimeError, toolchain.CompileError)


def final_type(recipe, n):
    types = assemble.check(recipe, n)[1]
    if len(types) != 1:
        raise ValueError("終わりに残るワイヤは 1 本でなければならない")
    return types[0]


def snap(x, bits):
    return torch.round(x * (1 << bits)) / (1 << bits)


@lru_cache(maxsize=None)
def plan(recipe, n, bits):
    """(答えの型, 答えの語の数, 主作図の平文, 出口の深度, 入力で実行の成否が変わるか)。作れない手順は None。
    作業領域の語（mi mu）と閉包（ya yi）は、入力の値で番地や繰り返しの回数が決まる。"""
    if any(w in ("me", "di") for w, _ in recipe):             # 答えを出さない
        return None
    try:
        built = assemble.value(list(recipe), n, bits)
        dynamic = any(w in ("mi", "mu", "ya", "yi") for w, _ in recipe)
        return final_type(list(recipe), n), len(built.depths), built.text, built.depths, dynamic
    except (ValueError, OverflowError):
        return None


_FIXED = {}


def fixed_words(recipe, n, bits):
    """答えが手順だけで決まる型の語。commonc で 1 度だけ実行して覚える。実行できない手順は None。"""
    key = (recipe, n, bits)
    if key not in _FIXED:
        _, width, text, depths, _ = plan(recipe, n, bits)
        try:
            out = run.run_one(text, [0] * n, width)
            _FIXED[key] = [float(v) / 2.0 ** d for v, d in zip(out, depths)]
        except FAILURES:
            _FIXED[key] = None
    return _FIXED[key]


def _vm_values(recipe, x, bits):
    """主作図を commonc で、lane ごとの入力で実行した答えの語。実行できない手順は None。"""
    n = x.shape[1]
    _, width, text, depths, _ = plan(tuple(map(tuple, recipe)), n, bits)
    grid = np.rint(x.detach().numpy() * (1 << bits)).astype(np.int64)
    try:
        words = run.run_lanes(text, grid, width).astype(np.float64) / np.array([2.0 ** d for d in depths])
    except FAILURES:
        return None
    return torch.as_tensor(words, dtype=x.dtype)


def _words(slot):
    t, v, _ = slot
    return [v] if t in (D, B) else list(v)


def _answer(slot, width):
    """スロットの値を答えの語 (L, W) にそろえる。𝒬 の残りの語は定数。"""
    ws = _words(slot)
    like = ws[0]
    ws = ws + [torch.full_like(like, c) for c in CONSTANT_TAIL.get(slot[0], [])]
    return torch.stack(ws, 1)


def _run_chain(recipes, leaves, bits):
    """束ねて実行する。返りは (窓の並び, 箱の列で表せない手順か)。ops の整数が溢れる手順があれば、1 本ずつ実行して
    溢れた手順の窓を None にする。実行時に失敗する手順の窓も None にする。"""
    try:
        wins, failed, uns = chain.run_batch(recipes, leaves, bits)
        return [None if f else w for w, f in zip(wins, failed)], uns
    except FAILURES:
        out, flags = [], []
        for r, ls in zip(recipes, leaves):
            try:
                wins, failed, uns = chain.run_batch([r], [ls], bits)
                out.append(None if failed[0] else wins[0])
                flags.append(uns[0])
            except FAILURES:
                out.append(None)
                flags.append(False)
        return out, flags


def _jacobian(wins, leaves, widths):
    """手順ごとの ∂y_j/∂x（形 (L, W, n)）と、逆向きの箱が溢れて出せなかった手順の印。値が入力に依らない語は 0。
    まとめた逆伝播が止まったら、1 本ずつやり直して、溢れた手順だけを出せなかったことにする。"""
    n = len(leaves[0])
    J = [torch.zeros(len(ls[0]), w, n, dtype=ls[0].dtype) for ls, w in zip(leaves, widths)]
    bad = [False] * len(wins)
    for j in range(2):
        picks = [(p, _words(win[0])[j]) for p, win in enumerate(wins)
                 if win is not None and not bad[p] and j < ACTIVE_WORDS[win[0][0]] and _words(win[0])[j].requires_grad]
        if not picks:
            continue
        try:
            groups = [(picks, [t for p, _ in picks for t in leaves[p]])]
            grads = [torch.autograd.grad(sum(y.sum() for _, y in picks), groups[0][1], retain_graph=True, allow_unused=True)]
        except FAILURES:
            groups, grads = [], []
            for p, y in picks:
                try:
                    grads.append(torch.autograd.grad(y.sum(), leaves[p], retain_graph=True, allow_unused=True))
                    groups.append(([(p, y)], leaves[p]))
                except FAILURES:
                    bad[p] = True
        for (ps, _), g in zip(groups, grads):
            for k, (p, _) in enumerate(ps):
                for i in range(n):
                    if g[k * n + i] is not None:
                        J[p][:, j, i] = g[k * n + i]
    return J, bad


class _Link(torch.autograd.Function):
    @staticmethod
    def forward(ctx, x, value, J):
        ctx.save_for_backward(J)
        ctx.save_for_forward(J)
        return value.clone()

    @staticmethod
    def jvp(ctx, tx, tvalue, tJ):
        J, = ctx.saved_tensors
        return torch.einsum("lwn,ln->lw", J, tx)

    @staticmethod
    def backward(ctx, g):
        J, = ctx.saved_tensors
        return torch.einsum("lw,lwn->ln", g, J), None, None


VM_LIMIT = 32            # 1 回の evaluate で commonc に実行させる、箱の列で表せない手順の数の上限。残りは実行できない手順とする


def evaluate(recipes, xs, bits=0, want=None):
    """手順の並びを入力の並び（形 (L, n)）に当てる。返りは手順ごとの答えの語 (L, W)。実行できない手順は None。
    入力に勾配が要るときだけ、∂y/∂x を出して backward に結ぶ。

    want は手順ごとの求める答えの型の並び。答えが手順だけで決まる型（Point など）の手順は、型が合うときだけ commonc で実行し、
    合わなければ実行しない（None を返す）。"""
    xs = [x + (snap(x, bits) - x).detach() if bits else x for x in xs]          # 丸めの微分は 1
    n = xs[0].shape[1]
    keys = [tuple(map(tuple, r)) for r in recipes]
    plans = [plan(k, n, bits) for k in keys]
    out = [None] * len(recipes)
    fixed = [p for p, pl in enumerate(plans) if pl and pl[0] not in ACTIVE_WORDS and not pl[4] and (want is None or want[p] == pl[0])]
    vm_used = 0
    for p, pl in enumerate(plans):                          # 答えが手順だけで決まる型でも、入力で成否が変わる手順は lane ごとに実行する
        if pl and pl[0] not in ACTIVE_WORDS and pl[4] and (want is None or want[p] == pl[0]) and vm_used < VM_LIMIT:
            out[p] = _vm_values(recipes[p], xs[p], bits)
            vm_used += 1
    todo = [p for p in fixed if (keys[p], n, bits) not in _FIXED]
    run.prepare([plans[p][2] for p in todo])
    for p in fixed:
        w = fixed_words(keys[p], n, bits)
        if w is not None:
            out[p] = torch.tensor(w, dtype=xs[p].dtype).expand(xs[p].shape[0], len(w)).clone()
    act = [p for p, pl in enumerate(plans) if pl and pl[0] in ACTIVE_WORDS]
    need = [bool(xs[p].requires_grad and torch.is_grad_enabled()) for p in act]
    leaves = [[xs[p].detach()[:, i].clone().requires_grad_(f) for i in range(n)] for p, f in zip(act, need)]
    wins, uns = _run_chain([recipes[p] for p in act], leaves, bits)
    J, bad = _jacobian(wins, leaves, [plans[p][1] for p in act]) if any(need) else ([None] * len(act), [False] * len(act))
    for p, win, f, j, u, b in zip(act, wins, need, J, uns, bad):
        if win is None or b:
            continue
        if u:                                               # 箱の列で表せない手順は、commonc で実行した値を使い、微分は伝えない
            if vm_used < VM_LIMIT:
                out[p] = _vm_values(recipes[p], xs[p], bits)
                vm_used += 1
            continue
        value = _answer(win[0], plans[p][1]).detach()
        out[p] = _Link.apply(xs[p], value, j) if f else value
    return out


def jvp_batch(recipes, xs, dxs, bits):
    """手順ごとの ẏ（形 (L, W)）。前向きの箱の列で出す。微分の対象でない語は 0。"""
    n = xs[0].shape[1]
    widths = [len(assemble.value(r, n, bits).depths) for r in recipes]
    with fwAD.dual_level():
        leaves = [[fwAD.make_dual(x.detach()[:, i], dx.detach()[:, i]) for i in range(n)] for x, dx in zip(xs, dxs)]
        wins, _, _ = chain.run_batch(recipes, leaves, bits)
        out = []
        for x, w, win in zip(xs, widths, wins):
            t = torch.zeros(x.shape[0], w, dtype=x.dtype, device=x.device)
            if win[0][0] in ACTIVE_WORDS:
                for j, y in enumerate(_words(win[0])):
                    tangent = fwAD.unpack_dual(y).tangent
                    if tangent is not None:
                        t[:, j] = tangent
            out.append(t)
    return out


class Construction(object):
    """一つの手順。c = Construction(手順, 入力の数, bits);  y = c(x)  x は (L, n)、y は (L, W)。"""

    def __init__(self, recipe, n, bits=0):
        self.recipe, self.n, self.bits = recipe, n, bits
        self.final = final_type(recipe, n)

    def __call__(self, x):
        y = evaluate([self.recipe], [x], self.bits)[0]
        if y is None:
            raise RuntimeError("この手順は実行できない")
        return y

    def jvp(self, x, dx):
        return jvp_batch([self.recipe], [x], [dx], self.bits)[0]


class _Choice(torch.autograd.Function):
    @staticmethod
    def forward(ctx, logits, trace, advantage):
        ctx.save_for_backward(trace, advantage)
        return -(advantage[:, None, None] * trace * logits.detach()).sum() / logits.shape[0]

    @staticmethod
    def backward(ctx, g):
        trace, advantage = ctx.saved_tensors
        return -g * advantage[:, None, None] * trace / trace.shape[0], None, None


def choice_loss(logits, trace, advantage):
    """選択の損失。ロジットの勾配は −(R − b) E_T / N（式 6.9）。trace は Common が出した E_T。"""
    return _Choice.apply(logits, trace, advantage)
