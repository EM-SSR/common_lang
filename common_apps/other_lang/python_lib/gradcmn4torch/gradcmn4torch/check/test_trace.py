# -*- coding: utf-8 -*-
"""Eligibility Trace の検査。文書 §6 の式 6.2、6.6、6.9（定理 6.1）。"""
import itertools

import numpy as np
import pytest
import torch

from gradcmn4torch import trace

F = trace.F


@pytest.mark.parametrize("halvings", [0, 1, 3])
def test_softmax_box(halvings):
    """式 (6.2)・(6.6): E_j = ρ^m ([j=a] − p_j)。torch の autograd で出した log p_a の勾配と比べる。"""
    rng = np.random.default_rng(halvings)
    L, V = 4096, 12
    logits = torch.tensor(rng.normal(size=(L, V)), dtype=torch.float64, requires_grad=True)
    a = torch.tensor(rng.integers(0, V, size=L))
    logp = torch.log_softmax(logits, -1).gather(1, a[:, None]).sum()
    want, = torch.autograd.grad(logp, logits)
    p = torch.softmax(logits, -1).detach()
    onehot = torch.zeros(L, V, dtype=torch.float64)
    onehot[torch.arange(L), a] = 1
    got = trace.eligibility(onehot, p, halvings)
    assert (got - want / 2 ** halvings).abs().max() < 2.0 ** -F


def test_policy_gradient():
    """定理 6.1（式 6.9）: ρ=1 のとき ∇J = E_τ[R(τ) Σ_t S_t]。全軌跡を数え上げて厳密に比べる。

    状態 3 つ、行動 3 つの表形式方策。2 時刻で、次の状態は (状態 + 行動) mod 3。
    """
    S, A, T = 3, 3, 2
    torch.manual_seed(0)
    theta = torch.randn(S, A, dtype=torch.float64, requires_grad=True)
    reward = torch.randn(A ** T, dtype=torch.float64)

    paths = list(itertools.product(range(A), repeat=T))
    prob = []
    for acts in paths:
        s, pr = 0, 1.0
        for a in acts:
            pr = pr * torch.softmax(theta[s], -1)[a]
            s = (s + a) % S
        prob.append(pr)
    J = sum(pr * r for pr, r in zip(prob, reward))
    want, = torch.autograd.grad(J, theta)

    est = torch.zeros(S, A, dtype=torch.float64)
    for pr, acts, r in zip(prob, paths, reward):
        s = 0
        for a in acts:
            p = torch.softmax(theta[s], -1).detach()
            onehot = torch.zeros(1, A, dtype=torch.float64)
            onehot[0, a] = 1
            E = trace.eligibility(onehot, p[None])[0]
            est[s] += float(pr) * float(r) * E
            s = (s + a) % S
    assert (est - want).abs().max() < 1e-5


def test_accumulate():
    """式 (6.6): E_T = Σ_k ρ^{T−k} S_k。"""
    torch.manual_seed(1)
    S = [torch.round(torch.randn(8, 5, dtype=torch.float64) * 64) / 64 for _ in range(4)]
    r = 2
    want = sum(s / 2.0 ** (r * (3 - k)) for k, s in enumerate(S))
    assert torch.equal(trace.accumulate(S, r), want)
