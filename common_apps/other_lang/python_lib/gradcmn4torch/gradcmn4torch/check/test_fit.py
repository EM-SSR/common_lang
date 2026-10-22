# -*- coding: utf-8 -*-
"""小規模な訓練。Common の逆向きの微分だけで、PyTorch のパラメータを当てはめる。

y = x (a + b x) を作図し、a、b を torch の Adam で動かして、y* = 1.5 x − 0.75 x² に合わせる。
勾配は作図が出した ∂y/∂a、∂y/∂b を、torch の逆伝播がそのまま受け取る。
"""
import numpy as np
import torch

from gradcmn4torch.torch_fn import Construction

BITS = 5


def test_fit():
    c = Construction([("ti", 0), ("no", 0), ("ti", 0)], 4, BITS)     # 入力は [b, x, a, x]
    rng = np.random.default_rng(0)
    x = torch.tensor(rng.integers(-2 * 2 ** BITS, 2 * 2 ** BITS + 1, size=4096) / 2.0 ** BITS)
    target = 1.5 * x - 0.75 * x * x
    theta = torch.tensor([0.0, 0.0], dtype=torch.float64, requires_grad=True)   # a, b
    opt = torch.optim.Adam([theta], lr=0.05)
    for _ in range(300):
        a, b = theta
        leaves = torch.stack([b.expand_as(x), x, a.expand_as(x), x], 1)
        loss = ((c(leaves)[:, 0] - target) ** 2).mean()
        opt.zero_grad()
        loss.backward()
        opt.step()
    assert loss.item() < 1e-3
    assert (theta.detach() - torch.tensor([1.5, -0.75])).abs().max() < 0.02


def test_replay_loss_raises_probability_of_found_programs():
    """誤差 0 の手順を貯めて学習すると、その手順の −log p が下がる。"""
    import os
    import pickle
    import numpy as np
    from gradcmn4torch.synth import problem as pb, train
    from gradcmn4torch.synth.model import Generator, sample
    if not os.path.exists("build_tools/data/pool_v66_use.pkl"):
        pytest.skip("問題集が無い")
    pool = pickle.load(open("build_tools/data/pool_v66_use.pkl", "rb"))[:4]
    model = Generator(64, 4, 2, 128, 128).cuda()
    rows = torch.stack([torch.from_numpy(pb.make_rows(p)) for p in pool]).cuda()
    tokens, _, _ = sample(model, rows)
    found = {(i, tuple(t.tolist())): 0.5 for i, t in enumerate(tokens.cpu())}
    opt = torch.optim.Adam(model.parameters(), lr=1e-2)
    rng = np.random.default_rng(0)
    first = float(train.replay_loss(model, found, pool, rng, 4, "cuda"))
    for _ in range(40):
        opt.zero_grad()
        train.replay_loss(model, found, pool, rng, 4, "cuda").backward()
        opt.step()
    assert float(train.replay_loss(model, found, pool, rng, 4, "cuda")) < 0.2 * first
