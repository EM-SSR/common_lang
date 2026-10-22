# -*- coding: utf-8 -*-
"""compile 時に作図した状態（ζ = e^{iπ/4} の整数係数）を、Qiskit の状態の型へ写す。

振幅 a + bζ + cζ² + dζ³ の複素数は (a + (b − d)/√2) + i(c + (b + d)/√2)。係数は規格化していないので、
最後に √𝒩 で割る（論文 7.4d）。係数は数百 bit の整数になるので、float へ写す前に共通の 2 の冪で縮める。
"""
import math

import numpy as np
from qiskit.quantum_info import DensityMatrix, Statevector

R2 = math.sqrt(0.5)


def _vector(coeffs):
    widest = max([abs(c).bit_length() for c in coeffs] + [1])
    shift = max(0, widest - 400)         # 二乗が float の上限（約 2^1024）を越えない幅
    a, b, c, d = (np.array([x >> shift for x in coeffs[j::4]], dtype=float) for j in range(4))
    v = (a + (b - d) * R2) + 1j * (c + (b + d) * R2)
    return v / np.linalg.norm(v)


def saved_state(kind, nq_saved, coeffs, n):
    """保存の種類（0 状態ベクトル、1 密度行列）の Qiskit の型。n は回路の量子ビットの数。作図に現れなかった
    上の量子ビットは |0>。"""
    v = np.zeros(1 << n, dtype=complex)
    v[:1 << nq_saved] = _vector(coeffs)
    if kind == 0:
        return Statevector(v)
    if kind == 1:
        return DensityMatrix(np.outer(v, v.conj()))
    raise NotImplementedError("保存の種類 %d は作図から写せない" % kind)
