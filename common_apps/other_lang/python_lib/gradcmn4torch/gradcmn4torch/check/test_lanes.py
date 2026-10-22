# -*- coding: utf-8 -*-
"""gvcpu（GPU）で同じ作図を大量の lane に割り当てる。lane ごとの入力に対して、結果が torch の計算と一致する。"""
import random

import numpy as np
import pytest

from gradcmn4torch import assemble, run
from gradcmn4torch.check import torch_calc

LANES = 65536


def make(seed, build):
    rng = random.Random(seed)
    while True:
        n = rng.randint(1, 4)
        recipe = torch_calc.random_recipe(rng, n, rng.randint(1, 12))
        try:
            return n, recipe, build(recipe, n)
        except OverflowError:
            continue


@pytest.mark.parametrize("seed", range(6))
def test_value_lanes(seed):
    n, recipe, built = make(seed, assemble.value)
    if torch_calc.mixed_depth_hi(recipe, n):
        pytest.skip("hi の入力の深度が 0 と 1 以上")
    rng = np.random.default_rng(seed)
    leaves = rng.integers(-4, 5, size=(LANES, n))
    out = run.run_lanes(built.text, leaves, len(built.depths))
    for l in rng.integers(0, LANES, size=40):
        got = run.decode([int(v) for v in out[l]], built.depths)
        assert got == [torch_calc.value_and_grad(recipe, leaves[l].tolist())[0]], (recipe, leaves[l])


@pytest.mark.parametrize("depth", range(4))
@pytest.mark.parametrize("tail", [[("so", 0)], [("hu", 1), ("hi", 0)], [("hu", 1), ("hi", 0), ("mo", 0)]])
def test_compare_with_depth(depth, tail):
    """so と hi は、深度が 1 以上のワイヤでも CPU（vcpu）と GPU（gvcpu）で同じ答えを出す。"""
    built = assemble.value([("se", 0)] * depth + tail, 1)
    xs = np.arange(-9, 10, dtype=np.int64)[:, None]
    got = run.run_lanes(built.text, xs, len(built.depths))
    want = np.array([run.run_one(built.text, [int(x)], len(built.depths)) for x in xs[:, 0]])
    assert (got == want).all(), xs[(got != want).any(1), 0]
