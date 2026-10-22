# -*- coding: utf-8 -*-
"""lane-qbit（cmn）の量子回路でハッシュの出力を測る。全 shot の全ビットが、hash.cmn の出力に一致する。

|+> を測ると、標準理論では各ビットが等確率で、8 ビットが一致する確率は 2^-8。Counter 量子情報論では結果が u0 で決まり、
移送 B_x（式 6.2）を当てれば、どの u0 でも結果が x になる（式 6.13）。確率の許容も統計の検定も使わない。
"""
from fractions import Fraction

import pytest

from common_qbit import CommonQbitBackend
from common_qbit.cmn import hash as H
from common_qbit.qpu import steer

MESSAGES = steer.pick_messages(8)


def key(d):
    return format(d, "0%db" % steer.K)


@pytest.mark.parametrize("m", MESSAGES)
def test_every_shot_returns_the_hash_output(m):
    d = H.digest(m)
    for seed in (1, 2, 3):
        counts = CommonQbitBackend().run(steer.transport_circuit(d), shots=256, seed_simulator=seed).result().get_counts()
        assert counts == {key(d): 256}


def test_the_result_does_not_depend_on_u0():
    d = H.digest(MESSAGES[0])
    u0 = [Fraction(0), Fraction(1, 3), Fraction(1, 2), Fraction(2047, 2048), Fraction(1, 1 << 40)] + [Fraction(i, 997) for i in range(250)]
    counts = CommonQbitBackend().run(steer.transport_circuit(d), shots=len(u0), initial_u0=u0).result().get_counts()
    assert counts == {key(d): len(u0)}


def test_the_same_circuit_and_the_same_u0_return_the_same_sequence():
    d = H.digest(MESSAGES[1])
    run = lambda: CommonQbitBackend().run(steer.transport_circuit(d), shots=64, seed_simulator=9, memory=True).result().get_memory()
    assert run() == run()


def test_without_the_transport_the_outputs_differ_between_shots():
    from qiskit import QuantumCircuit
    qc = QuantumCircuit(steer.K, steer.K)
    for q in range(steer.K):
        qc.h(q)
    qc.measure(range(steer.K), range(steer.K))
    counts = CommonQbitBackend().run(qc, shots=256, seed_simulator=1).result().get_counts()
    assert len(counts) > 100                                   # 移送が無ければ、u0 ごとに出力が違う


def test_the_circuit_uses_one_qubit_per_output_bit_and_measures_them_together():
    qc = steer.transport_circuit(H.digest(MESSAGES[0]))
    assert qc.num_qubits == steer.K and qc.depth() == 1 + 1 + 1       # H、移送、測定の三層


def test_the_order_of_the_transports_decides_the_output():
    """独立な量子ビットへの移送でも、構成順序は結果に残る（式 2.10）。上位から移送すると、出力はビットを逆順にした d になる。"""
    d = H.digest(MESSAGES[0])
    up = steer.transport_circuit(d, order=list(range(steer.K - 1, -1, -1)))
    counts = CommonQbitBackend().run(up, shots=64, seed_simulator=1).result().get_counts()
    assert counts == {format(int(format(d, "0%db" % steer.K)[::-1], 2), "0%db" % steer.K): 64}


def test_the_instructions_traced_from_the_cmn_match_the_circuit(tmp_path):
    """lane-qbit へ渡す平文が実行する量子の命令は、元の回路（リセット、H、移送、測定の繰り返し）に一致する。"""
    from common_qbit.circuit import trace, transcribe
    d = H.digest(MESSAGES[0])
    qc = steer.transport_circuit(d)
    path = tmp_path / "transport.cmn"
    path.write_text(transcribe.circuit_to_cmn(qc)[0], encoding="utf-8", newline="\n")
    assert steer.signature(trace.cmn_to_circuit(str(path))) == steer.signature(qc)
    assert [x for n, _q, x in steer.signature(qc) if n == "counter_transport"] == [(d >> t) & 1 for t in range(steer.K)]
