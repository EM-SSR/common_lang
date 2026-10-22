# -*- coding: utf-8 -*-
"""実機へ送る一つの回路と、候補ごとの仮説の回路を組む。

推定 → 操作語 → 本計算 → 再推定を一つの回路で続ける（論文 9.1、18.5）。どの段も、量子ビット 0 を
リセット、H、（操作語、）測定の順に使う。|+> の測定は測定座標の桁を読む（論文 4.2）。

    推定      K 回の |+> の測定
    操作語    候補の語ごとに、|+> に語を当てて測る段を r 回
    本計算    与えられた回路（量子ビット 1 以降、古典ビットは段の後ろ）
    再推定    K 回の |+> の測定

仮説の回路は、同じ並びの語の後に、候補が決めるメビウス作用 u → f u/(1 − u + f u)（論文 16.5）を差す。
f = 1 が「語は測定座標を動かさない」という候補になる。
"""
from dataclasses import dataclass, field
from fractions import Fraction
from typing import Dict, Optional, Tuple

from qiskit import QuantumCircuit

from ..circuit.gates import CounterMobius


@dataclass(frozen=True)
class Word:
    """標準の量子状態を |+> へ戻す一量子ビットの操作語（論文 9.13、9.14）。"""
    name: str
    circuit: QuantumCircuit


@dataclass(frozen=True)
class Experiment:
    estimate: int
    words: Tuple[Word, ...]
    repeat: int
    reestimate: int
    main: Optional[QuantumCircuit] = field(default=None)

    @property
    def stage_bits(self) -> int:
        return self.estimate + len(self.words) * self.repeat + self.reestimate


def _plus_cycle(qc: QuantumCircuit, clbit: int, word: Optional[QuantumCircuit] = None,
                mobius: Optional[Fraction] = None) -> None:
    qc.reset(0)
    qc.h(0)
    if word is not None:
        qc.compose(word, [0], inplace=True)
        if mobius is not None and mobius != 1:
            qc.append(CounterMobius(mobius), [0])
    qc.measure(0, clbit)
    qc.barrier()


def build(exp: Experiment, actions: Optional[Dict[str, Fraction]] = None) -> QuantumCircuit:
    """実機の回路（actions = None）か、候補 actions（語の名前 → f）の仮説の回路。"""
    main_q = exp.main.num_qubits if exp.main is not None else 0
    main_c = exp.main.num_clbits if exp.main is not None else 0
    qc = QuantumCircuit(1 + main_q, exp.stage_bits + main_c, name="counter_experiment")
    bit = 0
    for _ in range(exp.estimate):
        _plus_cycle(qc, bit)
        bit += 1
    for word in exp.words:
        f = None if actions is None else Fraction(actions.get(word.name, 1))
        for _ in range(exp.repeat):
            _plus_cycle(qc, bit, word.circuit, f)
            bit += 1
    first_reestimate = bit
    if exp.main is not None:
        qc.compose(exp.main, list(range(1, 1 + main_q)), list(range(exp.stage_bits, exp.stage_bits + main_c)), inplace=True)
        qc.barrier()
    for k in range(exp.reestimate):
        _plus_cycle(qc, first_reestimate + k)
    return qc
