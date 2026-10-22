# -*- coding: utf-8 -*-
"""cmn/hash.cmn（Common）の出力が、式どおりの純 Python の参照と一致する。参照は検査だけが持つ。"""
import pytest

from common_qbit.cmn import hash as H


def reference(m):
    """cmn/hash.py の docstring にある H の式。"""
    s = [0] * 8
    for j in range(3):
        for b in range(4):
            s[b] ^= (m >> (4 * j + b)) & 1
        for r in range(4):
            for p in range(6):
                s[p + 2] ^= s[p] & s[p + 1]
            for p in range(5):
                s[p + 3] ^= s[p]
            s[r] ^= 1
    return sum(b << i for i, b in enumerate(s))


@pytest.mark.parametrize("m", [0, 1, 2, 0x123, 0x7FF, 0x800, 0xA5A, 0xFFF, 0x0F0, 0x3C3])
def test_hash_cmn_matches_the_formula(m):
    assert H.digest(m) == reference(m)


def test_hash_cmn_is_a_good_mixer():
    ds = [H.digest(m) for m in range(256)]
    assert len(set(ds)) > 100                                   # 12 ビットを 8 ビットへ。偏りすぎない
    for bit in range(8):
        ones = sum((d >> bit) & 1 for d in ds)
        assert 60 < ones < 196                                  # どの出力ビットも片寄らない


def test_out_of_range_message_is_refused():
    with pytest.raises(ValueError):
        H.digest(1 << 12)
