# -*- coding: utf-8 -*-
"""条件から .cmn を書き出す部分の検査。手順と c から書いた .cmn を commonc で実行すると、条件の答えが再現する。"""
import json
import os

import numpy as np

from gradcmn4torch import run
from gradcmn4torch.synth import generate, problem as pb, syntax


def test_written_cmn_reproduces_the_answers(tmp_path):
    tokens = [syntax.INDEX[t] for t in ("ti", "ka", "no", "ka")] + [syntax.END]            # y = A B + c
    c = 0.375
    problem = {"tokens": tokens, "recipe": syntax.to_recipe(tokens), "c": c}
    answers = pb.answers(problem, pb.PROMPT_AB)
    generate.write(tokens, c, str(tmp_path / "s"))
    text = open(str(tmp_path / "s.cmn"), encoding="utf-8").read()
    meta = json.load(open(str(tmp_path / "s.json"), encoding="utf-8"))
    leaves = np.array([[round(a * 8), round(b * 8), meta["inputs"]["4"]] for a, b in pb.PROMPT_AB], dtype=np.int64)
    out = run.run_lanes(text, leaves, len(meta["exit_depths"])).astype(np.float64) / np.array([2.0 ** d for d in meta["exit_depths"]])
    assert (out == answers[:, :out.shape[1]]).all()
