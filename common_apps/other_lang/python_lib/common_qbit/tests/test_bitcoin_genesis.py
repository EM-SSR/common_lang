# -*- coding: utf-8 -*-
"""Bitcoin のジェネシスブロックのヘッダ（80 byte）の SHA-256d を、cmn が計算する。公表されているブロックのハッシュに一致し、
難しさの目標を満たす。ヘッダは 2 ブロック、二度目の入力は 32 byte で 1 ブロック。圧縮は合計 3 回。"""
import hashlib

import verify_btc as V
from common_qbit.cmn import sha256d


def test_the_header_is_80_bytes_and_makes_three_compressions():
    h = V.header()
    assert len(h) == 80 and len(sha256d.blocks(h)) == 2 and len(sha256d.blocks(bytes(32))) == 1


def test_cmn_reproduces_the_published_genesis_hash():
    h = V.header()
    d = sha256d.digest(h)
    assert d == hashlib.sha256(hashlib.sha256(h).digest()).digest()
    assert d[::-1].hex() == V.GENESIS_HASH                      # 表示は byte を逆順にする


def test_the_hash_satisfies_the_difficulty_target():
    d = sha256d.digest(V.header())
    assert V.target(0x1D00FFFF) == 0xFFFF << (8 * (0x1D - 3))
    assert int.from_bytes(d, "little") <= V.target(V.GENESIS["bits"])
    assert int.from_bytes(sha256d.digest(V.header()[:-1] + b"\x00"), "little") > V.target(V.GENESIS["bits"])     # nonce を変えると満たさない


def test_every_intermediate_state_of_the_genesis_header_matches_the_reference():
    import sha256_reference as ref
    d, trace = sha256d.trace(V.header())
    d_ref, want = ref.sha256d_states(V.header())
    assert len(trace) == 3 and V.compare(trace, want) == 0 and d == d_ref
