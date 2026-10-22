# -*- coding: utf-8 -*-
"""Counter 量子情報論に固有の命令。

標準の量子状態には恒等で、測定座標など Counter の成分にだけ作用する（式 6.10）。
中身の空のゲートとして定義するので、OpenQASM 3 の gate として書き出せる。
"""
from qiskit.circuit import Gate, QuantumCircuit


class CounterTransport(Gate):
    """移送 B_x（式 6.2）。量子ビットの測定座標を、結果 x の領域へ移す。"""

    def __init__(self, x, eps=1):
        """eps = 1 が B_x。0 < eps < 1 は部分移送 A_{x,ε}（式 15.11）。eps は有理数（Fraction か整数の比）。"""
        super().__init__("counter_transport", 1, [x, float(eps)])    # Qiskit の引数は float。transcribe が有理数へ戻す

    def _define(self):
        self.definition = QuantumCircuit(1)


class CounterMobius(Gate):
    """メビウス作用（式 16.5）。測定座標の比 u/(1 − u) を f 倍する。f は正の有理数。量子ビットの指定は形だけ。"""

    def __init__(self, f):
        super().__init__("counter_mobius", 1, [float(f)])    # Qiskit の引数は float。transcribe が有理数へ戻す

    def _define(self):
        self.definition = QuantumCircuit(1)


class CounterBeta(Gate):
    """β（式 13.1）。作図深度 d を一つ進める。標準の量子状態には作用しない。量子ビットの指定は形だけ。"""

    def __init__(self):
        super().__init__("counter_beta", 1, [])

    def _define(self):
        self.definition = QuantumCircuit(1)
