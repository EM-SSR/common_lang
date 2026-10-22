# -*- coding: utf-8 -*-
"""cmn/sha256d.cmn（Common）の出力が、hashlib の SHA-256d に一致する。メッセージの長さに制限はない。"""
import hashlib

import pytest

from common_qbit.cmn import gen_sha256d, sha256d


def reference(m):
    return hashlib.sha256(hashlib.sha256(m).digest()).digest()


@pytest.mark.parametrize("n", [0, 3, 55, 56, 63, 64, 80, 119, 120, 128, 300, 1000])
def test_sha256d_matches_hashlib_for_any_length(n):
    m = bytes((7 * i + 3) % 256 for i in range(n))
    assert sha256d.digest(m) == reference(m)


def test_blocks_follow_the_padding_rule():
    assert len(sha256d.blocks(b"x" * 55)) == 1 and len(sha256d.blocks(b"x" * 56)) == 2
    assert len(sha256d.blocks(b"x" * 80)) == 2 and len(sha256d.blocks(b"x" * 120)) == 3


def test_the_committed_cmn_is_what_the_typesetter_writes():
    with open(sha256d.SOURCE, encoding="utf-8") as f:
        assert f.read() == gen_sha256d.text()


def test_every_intermediate_state_matches_the_reference():
    """スケジュール W の 64 語と、ラウンドごとの状態 (a … h)。一度目のブロックと二度目のブロックのすべて。"""
    import sha256_reference as ref
    for m in (b"abc", bytes(range(80))):
        d, got = sha256d.trace(m)
        d_ref, want = ref.sha256d_states(m)
        assert d == d_ref == reference(m)
        assert len(got) == len(want)
        for (w, s), (w2, s2) in zip(got, want):
            assert w == w2 and s == s2


def test_the_committed_trace_cmn_is_what_the_typesetter_writes():
    with open(sha256d.SOURCE_TRACE, encoding="utf-8") as f:
        assert f.read() == gen_sha256d.text(True)
