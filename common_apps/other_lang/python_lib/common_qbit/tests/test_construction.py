# -*- coding: utf-8 -*-
"""compile 時の作図（commonc/src/qstate.cam）の検査。どれも等号で書く。

u0 = U0 / 2^62。測定の結果は [θ ≤ U0] で決まる（論文 3.6、境界は右の領域 5.4）。
"""
from fractions import Fraction as F
from math import isqrt

import pytest
from qiskit import QuantumCircuit

from common_qbit import CommonQbitBackend, CounterTransport
from common_qbit.circuit.image import compile_cmn
from common_qbit.circuit.transcribe import circuit_to_cmn
from common_vcpu import vcpu, vqpu

P = 1 << vqpu.DEPTH
HALF = F(1, 2)
EPS = F(1, P)


def run_u0(qc, u0s, reset=None, actions=None):
    actions = {} if actions is None else actions
    r = CommonQbitBackend().run(qc, shots=len(u0s), initial_u0=u0s, memory=True, reset=reset, actions=actions).result()
    return r.get_memory()


def thresholds(qc):
    """image が表へ置く境界 θ（Cst の分子のうち、表の番地より大きいもの）。"""
    text, _cl, angles, _s = circuit_to_cmn(qc)
    prog = vcpu.decode(compile_cmn(text, qc.num_qubits, None, angles)[0])
    return [im for (op, _a, _b, _c, _sb, _sc, im) in prog if op == 1 and im > (1 << 20)]


def ceil_two_plus_root2_over_4():
    x = 1 << 60
    r = isqrt(2 * x * x)
    return (1 << 61) + r + (1 if r * r < 2 * x * x else 0)


def bell():
    qc = QuantumCircuit(2, 2)
    qc.h(0)
    qc.cx(0, 1)
    return qc


def test_bell_boundary_is_right_region():
    qc = bell()
    qc.measure([0, 1], [0, 1])
    assert run_u0(qc, [F(0), HALF - EPS, HALF, 1 - EPS]) == ["00", "00", "11", "11"]


def test_hh_interferes_to_zero():
    qc = QuantumCircuit(1, 1)
    qc.h(0)
    qc.h(0)
    qc.measure(0, 0)
    assert run_u0(qc, [F(0), HALF, 1 - EPS]) == ["0", "0", "0"]


def test_hth_boundary_is_exact():
    qc = QuantumCircuit(1, 1)
    qc.h(0)
    qc.t(0)
    qc.h(0)
    qc.measure(0, 0)
    assert thresholds(qc) == [ceil_two_plus_root2_over_4()]


def test_reset_consume_reads_second_digit():
    """リセットが u を測定と同じく使う候補では、次の |+> の測定が u0 の二桁目を読む（論文 4.12）。"""
    qc = QuantumCircuit(1, 1)
    qc.h(0)
    qc.reset(0)
    qc.h(0)
    qc.measure(0, 0)
    u0s = [F(0), F(1, 4), HALF - EPS, HALF, F(3, 4), 1 - EPS]
    assert run_u0(qc, u0s, reset="consume") == ["0", "1", "1", "0", "1", "1"]


def test_reset_needs_explicit_candidate():
    qc = QuantumCircuit(1, 1)
    qc.reset(0)
    qc.measure(0, 0)
    with pytest.raises(Exception):
        run_u0(qc, [F(0)])


@pytest.mark.parametrize("x", [0, 1])
def test_transport_fixes_result(x):
    qc = QuantumCircuit(1, 1)
    qc.h(0)
    qc.append(CounterTransport(x), [0])
    qc.measure(0, 0)
    assert run_u0(qc, [F(0), HALF, 1 - EPS]) == [str(x)] * 3


def test_transport_on_one_side_fixes_partner():
    """共有する u へ量子ビット 0 の側から B_1 を当てると、量子ビット 1 の結果も 1 に決まる。"""
    qc = bell()
    qc.append(CounterTransport(1), [0])
    qc.measure([0, 1], [0, 1])
    assert run_u0(qc, [F(0), HALF, 1 - EPS]) == ["11", "11", "11"]


def test_lebesgue_grid_gives_born_counts():
    """u0 を 2^-6 の格子で全部走らせると、四つの結果の頻度が重み 1/4 に厳密に一致する（論文 14.2）。"""
    qc = QuantumCircuit(2, 2)
    qc.h(0)
    qc.h(1)
    qc.measure([0, 1], [0, 1])
    mem = run_u0(qc, [F(k, 64) for k in range(64)])
    assert sorted(mem.count(k) for k in ("00", "01", "10", "11")) == [16, 16, 16, 16]


# ---- 回転：角の閉包（qstate.cam の QSROT）。照合の値は検査の側だけで mpmath から出す ----

ANGLES = [0.3, 1.0, 1.5707963267948966, 2.5, -0.7, 1e-9, 100.0]


def _exact_ceil(T):
    import mpmath
    return int(mpmath.ceil(T * 2 ** 62))


@pytest.mark.parametrize("theta", ANGLES)
@pytest.mark.parametrize("gate", ["rx", "ry", "hrzh"])
def test_rotation_boundary_is_exact(theta, gate):
    import mpmath
    mpmath.mp.prec = 300
    qc = QuantumCircuit(1, 1)
    if gate == "hrzh":
        qc.h(0)
        qc.rz(theta, 0)
        qc.h(0)
    else:
        getattr(qc, gate)(theta, 0)
    qc.measure(0, 0)
    f = F(theta)
    x = mpmath.mpf(f.numerator) / f.denominator
    assert thresholds(qc) == [_exact_ceil(mpmath.cos(x / 2) ** 2)]


# ---- 論文が式で与える Counter の作用。どれも標準理論と違う境界になる ----

def _ceil62(frac):
    return -((-frac.numerator * P) // frac.denominator)


def test_mobius_after_gate_moves_boundary():
    """x の後に f = 3 のメビウス作用（論文 16.5）を候補として当てる。H X X の後、比 u/(1 − u) は 9 倍になり、
    境界は u0 の側で 1/10（標準なら 1/2）。"""
    qc = QuantumCircuit(1, 1)
    qc.h(0)
    qc.x(0)
    qc.x(0)
    qc.measure(0, 0)
    text, _cl, angles, _s = circuit_to_cmn(qc)
    prog = vcpu.decode(compile_cmn(text, 1, None, angles, {vqpu.GATE_ID["x"]: (1, 3, 1)})[0])
    assert [im for (op, _a, _b, _c, _sb, _sc, im) in prog if op == 1 and im > (1 << 20)] == [_ceil62(F(1, 10))]
    th = _ceil62(F(1, 10))
    assert run_u0(qc, [F(th - 1, P), F(th, P)], actions={"x": ("mobius", 3)}) == ["0", "1"]


def test_mobius_word_composes_additively():
    """メビウスの語を f = 2 と f = 3/2 で続けて当てると f = 3 と同じ（論文 16.6）。境界は 1/4。"""
    from common_qbit import CounterMobius
    qc = QuantumCircuit(1, 1)
    qc.h(0)
    qc.append(CounterMobius(2), [0])
    qc.append(CounterMobius(F(3, 2)), [0])
    qc.measure(0, 0)
    assert thresholds(qc) == [_ceil62(F(1, 4))]


def test_partial_transport_boundary():
    """部分移送 A_{1,1/2}（論文 15.11）。|+> では u' = 3u/4 + 1/4、境界は 1/3。"""
    qc = QuantumCircuit(1, 1)
    qc.h(0)
    qc.append(CounterTransport(1, F(1, 2)), [0])
    qc.measure(0, 0)
    assert thresholds(qc) == [_ceil62(F(1, 3))]


# ---- 観測された結果の列と合う u0 の領域（論文 3.16、5.16）----

def test_observed_region_is_intersection_of_chambers():
    """Bell で両方 1 を観測すると u0 ∈ [1/2, 1)。片方だけ 1 は、どの u0 とも合わない（候補が外れる）。"""
    qc = bell()
    qc.measure([0, 1], [0, 1])
    text, _cl, angles, _s = circuit_to_cmn(qc)
    image = compile_cmn(text, 2, None, angles)[0]
    assert vqpu.region(image, [1, 1]) == (P // 2, P)
    assert vqpu.region(image, [0, 0]) == (0, P // 2)
    assert vqpu.region(image, [1, 0]) is None


def test_observed_plus_sequence_reads_tape_digits():
    """|+> の測定とリセットを 3 回くり返して 1、0、1 を観測すると、u0 は [5/8, 6/8) に決まる（論文 5.16）。
    リセットの内側の判定は、直前の測定の結果と同じに決まる（|1> の p0 = 0）ので、列は 1、1、0、0、1。"""
    qc = QuantumCircuit(1, 3)
    for k in range(3):
        qc.h(0)
        qc.measure(0, k)
        if k < 2:
            qc.reset(0)
    text, _cl, angles, _s = circuit_to_cmn(qc)
    image = compile_cmn(text, 1, "consume", angles)[0]
    lo, hi = vqpu.region(image, [1, 1, 0, 0, 1])
    assert (F(lo, P), F(hi, P)) == (F(5, 8), F(6, 8))
