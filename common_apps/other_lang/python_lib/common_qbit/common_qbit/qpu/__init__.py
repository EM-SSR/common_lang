# -*- coding: utf-8 -*-
"""実機の実験。推定 → 操作語 → 本計算 → 再推定を一つの回路にし、一つの job で走らせる。

    experiment   回路と、候補ごとの仮説の回路
    run          IBM の装置か手元の装置で走らせ、shot ごとの bitstring を返す
    analyze      候補ごとに、観測列と合う u0 の領域を出す。空なら、その候補は合わない

    python -m common_qbit.qpu run <置き場> --backend ibm:<名前>|fake|lane-qbit --shots N
    python -m common_qbit.qpu analyze <置き場>
"""
from .analyze import analyze, report
from .experiment import Experiment, Word, build

__all__ = ["Experiment", "Word", "build", "analyze", "report"]
