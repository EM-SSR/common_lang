# -*- coding: utf-8 -*-
"""256 量子ビットを並列に使い、SHA-256d の出力 256 ビットを、lane-qbit の全 shot で得る。出力は sha256d.cmn が計算する。

hashlib は照合だけに使う。移送 B_x を下位の量子ビットから当てる（qpu/steer.py）。
"""
import hashlib
from fractions import Fraction

import pytest

from common_qbit import CommonQbitBackend
from common_qbit.cmn import sha256d
from common_qbit.qpu import steer

FN = steer.function("sha256d")


@pytest.mark.parametrize("m", [b"Common", b"abc", b""])
def test_all_256_bits_are_returned_in_every_shot(m):
    d = FN["digest"](m)
    assert d.to_bytes(32, "big") == hashlib.sha256(hashlib.sha256(m).digest()).digest()
    qc = steer.transport_circuit(d, bits=256)
    assert qc.num_qubits == 256 and qc.depth() == 3
    u0 = [Fraction(0), Fraction(1, 3), Fraction(1023, 1024), Fraction(1, 1 << 40)]
    counts = CommonQbitBackend().run(qc, shots=len(u0), initial_u0=u0).result().get_counts()
    assert counts == {format(d, "0256b"): len(u0)}


@pytest.mark.parametrize("noise", [False, True])
@pytest.mark.parametrize("counter", [False, True])
def test_all_256_bits_under_the_noise_and_the_counter_initial_state(noise, counter):
    """標準理論の雑音（緩和、過回転、z のずれ）と、Counter の初期状態（z_j、メビウス結合）を、それぞれ、または重ねて入れる。
    移送 B_x は ρ の重みに合わせて u を結果の領域へ移すので、256 ビットの出力は変わらない。"""
    from common_qbit.noise import world
    d = FN["digest"](b"Counter")
    u0 = [Fraction(1, 7), Fraction(1, 2), Fraction(5, 6), Fraction(1, 1 << 30)]
    counts = CommonQbitBackend().run(steer.transport_circuit(d, bits=256), shots=len(u0), initial_u0=u0,
                                     world=world(noise, counter), method="density_matrix").result().get_counts()
    assert counts == {format(d, "0256b"): len(u0)}
