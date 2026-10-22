# -*- coding: utf-8 -*-
"""qiskit-aer 標準のテストを CommonQbitBackend で走らせる。

    python run_aer_suite.py [テストファイル名 …]

tools/qiskit-aer の SimulatorTestCase は BACKEND に AerSimulator を使う。ここで BACKEND を
CommonQbitBackend の薄い殻へ差し替える。差し替えるのは実行時の属性だけで、qiskit-aer の
ソースも venv の中身も書き換えない。

lane-qbit が持つ語彙（標準ゲート、任意のユニタリ、測定、リセット、移送、delay、条件つき命令、繰り返し、store）の範囲だけが対象になる。
語彙の外のゲートと保存命令（save_statevector 以外の save_*）は NotImplementedError で落ちる。
"""
import os
import sys
from pathlib import Path

import pytest


def aer_root():
    for root in Path(__file__).resolve().parents:
        if (root / "tools" / "qiskit-aer" / "test").exists():
            return root / "tools" / "qiskit-aer"
    raise FileNotFoundError("tools/qiskit-aer が見つかりません")


DEFAULT_MODULES = ["test_measure.py", "test_reset.py", "test_standard_gates.py", "test_cliffords.py",
                   "test_non_cliffords.py", "test_circuit.py", "test_control_flow.py", "test_initialize.py",
                   "test_unitary_gate.py", "test_multiplexer.py", "test_pauli_gate.py", "test_rotation.py"]
_KNOWN = {"shots", "seed_simulator", "memory", "initial_u0", "method", "reset", "actions"}
# リセットが測定座標にする作用は論文に形が無い。Aer のテストでは候補をここで明示する
RESET = os.environ.get("AER_RESET", "consume")


def main(argv):
    root = aer_root()
    import qiskit_aer  # noqa: F401  ソースの qiskit_aer（未ビルド）より先に、導入済みのものを読む
    sys.path.insert(0, str(root))
    from common_qbit import CommonQbitBackend
    from test.terra.backends import simulator_test_case as stc

    class Adapter(CommonQbitBackend):
        """Aer の method・device などのオプションを受け流す殻。"""

        @classmethod
        def _default_options(cls):
            opts = super()._default_options()
            opts.update_options(method="statevector")     # Aer のテストが backend.options.method を読む
            return opts

        def __init__(self, **options):
            super().__init__()
            self.set_options(**{k: v for k, v in options.items() if k in _KNOWN})      # backend(method=…) の method を保つ

        def run(self, run_input, **options):
            options.setdefault("reset", RESET)
            options.setdefault("actions", {})          # 結合を零に置く（論文 14.1）。標準との一致を見る
            return super().run(run_input, **{k: v for k, v in options.items() if k in _KNOWN})

    stc.SimulatorTestCase.BACKEND = Adapter
    names = argv or DEFAULT_MODULES
    files = [str(root / "test" / "terra" / "backends" / "aer_simulator" / n) for n in names]
    extra = [a for a in os.environ.get("PYTEST_ARGS", "").split() if a]
    # 安定化状態の専用テスト（65〜433 量子ビットの GHZ を 1000 shot 走らせる）は、時間がかかるので外す。
    # GHZ 自体は tests/test_counter_state.py が疎な表現で検査する
    skip = os.environ.get("AER_SKIP", "not large_ghz")
    return pytest.main(["-q", "-p", "no:cacheprovider", "--rootdir", str(root), "-k", skip, *extra, *files])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
