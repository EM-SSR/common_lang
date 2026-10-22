# -*- coding: utf-8 -*-
"""Qiskit バックエンド `CommonQbitBackend`。

回路を .cmn へ写し、lane-qbit 版の commonc で image にする。量子状態の作図は compile 時に済み、
shot ごとの実行は測定座標 u0 と境界の表の比較だけになる。
"""
import os


def data_path(name):
    """同梱した data（commonc の lane-qbit 版の image など）の置き場。"""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", name)


from .backend import CommonQbitBackend  # noqa: E402
from .circuit.gates import CounterBeta, CounterMobius, CounterTransport  # noqa: E402
from .provider import CommonQbitProvider  # noqa: E402

__all__ = ["CommonQbitBackend", "CommonQbitProvider", "CounterTransport", "CounterMobius", "CounterBeta", "data_path"]
