# -*- coding: utf-8 -*-
"""intent の平文を一つずつ lane64 で読み、命令数・ステップ数・出口の語を出す。

    python check/probe.py intent/unit.cmn [intent/chain.cmn ...]

語 1 に答えを置く約束で書く。seed は `path:4=7` の形で作業領域へ入れる。
"""
import os
import sys
import time

from common_vcpu import toolchain, vcpu  # noqa: E402



def one(srcs, watch=(1, 2, 3), words=1 << 17, seed=None):
    out = os.path.join(HERE, "build", os.path.basename(srcs[-1])[:-4] + ".bin")
    image, need = toolchain.compile(srcs, None, out)
    tab = toolchain.load(image, need)
    lane = vcpu.Lane(words)
    for k, v in (seed or {}).items():
        lane.M[k] = v
    t = time.perf_counter()
    rep = vcpu.run_lane(tab, lane)
    return len(image) // 16, lane.blocks, rep, time.perf_counter() - t, [lane.M[i] for i in watch]


def main(argv):
    for a in argv:
        head, _, sp = a.partition("#")
        srcs = [os.path.join(HERE, p) if not os.path.isabs(p) else p for p in head.split("+")]
        seed = {int(k): int(v) for k, v in (kv.split("=") for kv in sp.split(",") if kv)}
        try:
            n, b, rep, el, w = one(srcs, seed=seed)
            print("%-28s 命令 %-5d ステップ数 %-7d 報告 %-4s %7.2f ms  語 %s"
                  % (a, n, b, rep, el * 1e3, w))
        except Exception as e:
            print("%-28s %s: %s" % (a, type(e).__name__, e))


main(sys.argv[1:])
