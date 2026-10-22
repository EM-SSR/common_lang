# -*- coding: utf-8 -*-
"""Eligibility Trace の作図（文書 §6）。箱は ops の No と Ha（cmn/box/no.value.cmn、ha.value.cmn）。

選んだ語 a_t のロジット q_t に対する log π の勾配は、softmax の局所微分（式 6.2）で

    S_{t,j} = [j = a_t] ⊖ p_{t,j}

となる。時刻 T までのトレースは E_t = ρ E_{t-1} ⊕ S_t（式 6.4）で、展開すると

    E_{T,k,j} = ρ^{T−k} S_{k,j}                                   （式 6.6）

ρ = 2^-r を掛けることは深度を r 増やすことで、箱は要らない。⊕ は、時刻ごとのロジットを並べた空間 Q = ⊕_k R^V の直和で、
スロット (k, j) は混ざらない。パラメータの勾配は、Q の E_T に Transformer の逆伝播 J_Q^T を当てて得る（式 6.9）。
確率 p は 2^-F の格子に丸めて箱へ渡す。
"""
import torch

from . import ops

F = 20                          # 確率を 2^-F の格子にする


def quantize(p):
    return torch.round(p * (1 << F)) / (1 << F)


def eligibility(onehot, p, halvings=0):
    """S = [j = a] ⊖ p（式 6.2）を、1/2 を halvings 回掛けて返す。onehot と p は同じ形の Tensor。"""
    return ops.No.apply(onehot, ops.Ha.apply(quantize(p))) / 2.0 ** halvings


def accumulate(steps, r=0):
    """E_t = ρ E_{t-1} ⊕ S_t（式 6.4）を時刻順に当てる。steps は S_t の並び、ρ = 2^-r。"""
    E = steps[0]
    for S in steps[1:]:
        E = ops.No.apply(E / 2.0 ** r, S)
    return E
