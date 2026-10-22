# -*- coding: utf-8 -*-
"""主作図の値を、torch で同じ計算をした結果と厳密に比べる（値の保存、式 9.1）。"""
import random

import pytest

from gradcmn4torch import assemble, run
from gradcmn4torch.check import torch_calc


def case(seed, build):
    """深度が MAXDEPTH に収まる作図を、乱数で選ぶ。"""
    rng = random.Random(seed)
    while True:
        n = rng.randint(1, 4)
        recipe = torch_calc.random_recipe(rng, n, rng.randint(1, 14))
        try:
            built = build(recipe, n)
        except OverflowError:
            continue
        return n, recipe, [rng.randint(-4, 4) for _ in range(n)], built


@pytest.mark.parametrize("seed", range(80))
def test_value(seed):
    n, recipe, xs, built = case(seed, assemble.value)
    if torch_calc.mixed_depth_hi(recipe, n):
        pytest.skip("hi の入力の深度が 0 と 1 以上")
    got = run.decode(run.run_one(built.text, xs, len(built.depths)), built.depths)
    assert got == [torch_calc.value_and_grad(recipe, xs)[0]], (recipe, xs)
