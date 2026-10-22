# -*- coding: utf-8 -*-
"""任意の .cmn が QPU で実行する量子の命令列を、Qiskit の回路として取り出す。

doc: casm.lane64.host casm.lane64.sem

    python -m common_qbit.circuit.trace program.cmn circuit.png [--qubits N] [--u0 0.3]

流れ:  .cmn ─ commonc（lane-qbit 版）─▶ image ─ 実行台 ─▶ 実行された量子の命令 ─▶ QuantumCircuit ─▶ 画像

古典の命令（ADD、LD、分岐など）は実行台が走らせて解決する。残るのは、実際に QPU へ送られる
量子の命令だけになる。ループで繰り返したゲートは、繰り返した回数だけ並ぶ。
測定は、結果を入れる古典ビットを一つずつ足す。分岐が測定の結果に依る .cmn は、u0 によって
別の回路になる（式 3.6）。

量子ビット数は、一度、状態を持たずに走らせて（測定の結果は 0、1、0、1、…とする）使った最大の番号から決める。
--qubits で決め直せる。
"""
import argparse
import os
import tempfile
from fractions import Fraction

import numpy as np
from qiskit import ClassicalRegister, QuantumCircuit

from common_vcpu import toolchain, vcpu, vqpu

from ..backend import COMMONC
from .gates import CounterTransport


class _Dry(vqpu.Qlane):
    """状態を持たない。使われた量子ビットの最大の番号だけを控える。"""

    def __init__(self, nq, u0):
        self.nq, self.h, self.sel, self.saves, self.probes, self.rec = nq, [], None, [], [], []
        self.u0, self.a, self.s = vqpu.Coord(u0), Fraction(0), Fraction(1)
        self.top = 0
        self.cl, self.guard, self.pend = {}, True, []

    def _see(self, *qs):
        self.top = max([self.top] + [q for q in qs if q is not None])

    def gate(self, g, q1, q2):
        self._see(q1, q2 if vqpu.GATES[g] in ("cx", "cz", "swap") else None)

    def apply_table(self, U, qs):
        self._see(*qs)

    def measure(self, q):
        self._see(q)
        self.count = getattr(self, "count", 0) + 1
        self.rec.append((self.count - 1) % 2)
        return (self.count - 1) % 2          # 0, 1, 0, 1, ... ループが終わりやすい並び

    def reset(self, q):
        self._see(q)

    def transport(self, q, x):
        self._see(q)

    def probe(self, k):
        pass

    def beta(self):
        pass

    def delay(self, q, code):
        self._see(q)

    def set_state(self, vec):
        self._see(self.nq - 1)


class _Trace(vqpu.Qlane):
    """走らせながら、実行された量子の命令を回路へ積む。"""

    def __init__(self, nq, u0, tables):
        super().__init__(nq, u0)
        self.circ = QuantumCircuit(nq, name="common_qbit")
        self.tables = tables
        self.nmeas = 0

    def gate(self, g, q1, q2):
        name = vqpu.GATES[g]
        getattr(self.circ, name)(*([q1, q2] if name in ("cx", "cz", "swap") else [q1]))
        super().gate(g, q1, q2)

    def apply_table(self, U, qs):
        self.circ.unitary(U, list(qs), label="U%s" % self.sel)
        super().apply_table(U, qs)

    def measure(self, q, record=True):
        x = super().measure(q, record)
        if record:                               # リセットの中の測定は、回路に測定として残さない
            reg = ClassicalRegister(1, "m%d" % self.nmeas)
            self.nmeas += 1
            self.circ.add_register(reg)
            self.circ.measure(q, reg[0])
        return x

    def reset(self, q):
        self.circ.reset(q)
        # リセットは測定を含む。回路には reset だけを残し、状態は測定の規則で更新する
        super().reset(q)

    def transport(self, q, x):
        self.circ.append(CounterTransport(x), [q])
        super().transport(q, x)

    def delay(self, q, code):
        self.circ.delay(code >> 3, q, unit=vqpu.DELAY_UNITS[code & 7])
        super().delay(q, code)

    def set_state(self, vec):
        self.circ.initialize(list(vec), list(range(self.nq)))
        super().set_state(vec)


def _run(prog, nq, u0, tables, qlane, budget=1 << 28):
    st = vqpu.State(nq, u0, words=1 << 20, tables=tables)           # ワイヤの帯（語 64 〜）が大きい平文でも足りる
    st.Q = qlane
    return vqpu.step(prog, st, budget=budget)


def compile_cmn(path, workdir=None):
    """lane-qbit 版 commonc で .cmn を image にする。返りは image。"""
    d = workdir or tempfile.mkdtemp()
    image, _ = toolchain.compile([path], None, os.path.join(d, "program.bin"), commonc=COMMONC)
    return image


def cmn_to_circuit(path, qubits=None, u0=Fraction(3, 10), tables=()):
    """.cmn が実行する量子の命令列を QuantumCircuit にして返す。"""
    prog = vcpu.decode(compile_cmn(path))
    if qubits is None:
        dry = _Dry(1, u0)
        try:
            _run(prog, 1, u0, tables, dry, budget=1 << 20)
        except RuntimeError:
            pass                                 # 止まらない場合は、そこまでに使った番号で決める
        qubits = dry.top + 1
    st = _run(prog, qubits, u0, tables, _Trace(qubits, u0, tables))
    return st.Q.circ


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmn")
    ap.add_argument("png")
    ap.add_argument("--qubits", type=int, default=None)
    ap.add_argument("--u0", type=Fraction, default=Fraction(3, 10))
    a = ap.parse_args(argv)
    circ = cmn_to_circuit(a.cmn, a.qubits, a.u0)
    circ.draw("mpl", filename=a.png)
    print(circ.draw("text"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
