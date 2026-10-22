# -*- coding: utf-8 -*-
"""表に並べた平文を一度に読む。probe.py と同じ道で、行ごとに答えを出す。"""
import os
import sys
import tempfile

from common_vcpu import toolchain

U = "ma ma ka, ri ka, ne ka, mo ka"


def addr(k):
    """語 2^n を単位の倍加で作り、その番地を読む。入口は 1 2 4 8 16 の五つ。"""
    n = {1: 0, 2: 1, 4: 2, 8: 3, 16: 4}[k]
    return U + ", he ka, no ka" * n + ", mi ka"


def run(name, body, seed, watch=(1,)):
    src = os.path.join(tempfile.gettempdir(), "b_%s.cmn" % name)
    open(src, "w", encoding="utf-8").write(body.strip() + "\nra ka, mo ka\n" + U + ", mu ka\nme ka\n")
    out = os.path.join(HERE, "build", "b_%s.bin" % name)
    image, need = toolchain.compile([src], None, out)
    lane = vcpu.Lane(1 << 17)
    for k, v in seed.items():
        lane.M[k] = v
    rep = vcpu.run_lane(toolchain.load(image, need), lane)
    return rep, lane.blocks, [lane.M[i] for i in watch]
