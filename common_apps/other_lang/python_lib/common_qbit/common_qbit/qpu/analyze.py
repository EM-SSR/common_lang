# -*- coding: utf-8 -*-
"""観測された shot ごとの結果の列から、候補ごとに u0 の領域を出す（論文 3.16、5.16）。

候補（リセットの作用と、語ごとのメビウス作用の倍率 f）ごとに仮説の回路を作図し、image の境界の表で
観測列に沿って u0 の領域を削る。リセットの内側の結果は実機が返さないので、両方の側をたどる（vqpu.regions）。
領域が空の shot は、その候補と合わない。

    桁数 = −log2(領域の幅)          観測が u0 を何桁決めたか
"""
import math
from fractions import Fraction
from typing import Dict, List, Sequence

from common_vcpu import vqpu

from ..circuit.image import compile_cmn
from ..circuit.transcribe import circuit_to_cmn
from .experiment import Experiment, build


def _image(circuit, reset):
    text, _clbits, angles, _saves = circuit_to_cmn(circuit)
    return compile_cmn(text, circuit.num_qubits, reset, angles, {})[0]


def execution_order(image) -> List[object]:
    """測定とリセットの実行順。測定は書いた古典ビットの番号、リセットは None。"""
    _rep, _out, h, _cl = vqpu.run(image, [Fraction(0)])[0]
    order = []
    for k, rec in enumerate(h):
        if rec[0] == "M":
            order.append(next(r[1] for r in h[k + 1:] if r[0] == "C"))
        elif rec[0] == "R":
            order.append(None)
    return order


def observations(order: Sequence[object], bitstring: str) -> List[object]:
    """Qiskit の bitstring（古典ビット 0 が右端）を、実行順の結果の列にする。"""
    bits = bitstring.replace(" ", "")[::-1]
    return [None if c is None else int(bits[c]) for c in order]


def digits(intervals) -> float:
    width = sum(hi - lo for lo, hi in intervals)
    return math.inf if width == 0 else vqpu.DEPTH - math.log2(width)


def analyze(exp: Experiment, candidates: Dict[str, Dict[str, Fraction]], bitstrings: Sequence[str],
            reset: str = "consume") -> Dict[str, List[list]]:
    """候補の名前 → shot ごとの u0 の領域（区間の並び。空なら合わない）。"""
    out = {}
    for name, actions in candidates.items():
        image = _image(build(exp, actions), reset)
        order = execution_order(image)
        out[name] = [vqpu.regions(image, observations(order, b)) for b in bitstrings]
    return out


def report(regions: Dict[str, List[list]]) -> str:
    """候補ごとの、合う shot の数と、観測が決めた u0 の桁数（合う shot の中央値）。"""
    rows = ["| 候補 | 合う shot | 合わない shot | u0 の桁数（中央値） |", "|---|--:|--:|--:|"]
    for name, per_shot in regions.items():
        fit = [digits(r) for r in per_shot if r]
        med = sorted(fit)[len(fit) // 2] if fit else float("nan")
        rows.append("| %s | %d | %d | %.1f |" % (name, len(fit), len(per_shot) - len(fit), med))
    return "\n".join(rows)
