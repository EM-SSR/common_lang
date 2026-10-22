# -*- coding: utf-8 -*-
"""段の表を GPU で走らせる。

共有メモリの並びは「枠 → 表」。枠の番号 i は共有メモリの i 番になるので、番地は romlo + i。
lane ごとに違うのは番号（語 IDX）だけで、あとは全部共有メモリに一枚。
"""
import os
import sys

import numpy as np

from .. import fold
from .. import lane
from .. import walk

ROMLO = fold.ROW + 16          # 作業領域はここまで。上は共有メモリ
_IMG = {}


def image(u=16):
    """エンジンの image。最適化 pass を当て、検算ゲートを通す。"""
    from common_vcpu import gvcpu
    from common_vcpu import vcpu
    if u not in _IMG:
        img, need, _ = lane.build(walk.engine_u(u), "engine%d" % u)
        raw = gvcpu.fold(vcpu.decode(img), wires=(64, need))
        _IMG[u] = (lane.best(raw, need, _check(u, need)), need, len(raw))
    return _IMG[u]


def _check(u, need):
    """一段の線形を一枚だけ走らせる種。最適化の前後を突き合わせる。"""
    SL = fold.ROW + 2048
    sl = lambda i: SL + 512 + i
    k = u * 4
    wh, xh, oh, zer = SL, SL + k + 8, SL + 2 * k + 16, sl(91)
    seed = {walk.TAB: fold.ROW + 64, walk.LEFT: 1, walk.IDX: 0, zer: 0}
    for j in range(k):
        seed[wh + j] = (j % 7) + 1
        seed[xh + j] = (j % 5) + 1
    vals = [oh, 1, 4, wh, 0, xh, 0, zer, 0, SL + 400, 0, 0]
    for i, v in enumerate(vals):
        seed[sl(i)] = v
        seed[fold.ROW + 64 + i] = sl(i)
    return (seed, (oh,))


def run(rows, share, lanes, u=16, threads=128, reps=1):
    """段を走らせる。返りは (Joint, 報告, ステップ数, 秒)。共有メモリは J.d_rom で読む。"""
    import cupy as cp
    import time
    prog, need, _raw = image(u)
    tab_head = len(share)
    flat = []
    for r in rows:
        flat += [ROMLO + int(v) for v in r]
    J = lane.Joint(prog, need, fold.ROW, ROMLO, tab_head + len(flat), lanes, threads=threads)
    J.rom_put(0, np.asarray(share, dtype=np.uint64))
    J.rom_put(tab_head, np.asarray(flat, dtype=np.uint64))
    J.M2[J.pos(walk.TAB), :] = np.uint64(ROMLO + tab_head)
    J.M2[J.pos(walk.LEFT), :] = np.uint64(len(rows))
    J.M2[J.pos(walk.IDX), :] = cp.arange(J.n, dtype=cp.uint64)
    rep, steps, _ = J.run()
    cp.cuda.Stream.null.synchronize()
    t0 = time.perf_counter()
    for _ in range(reps):
        J.M2[J.pos(walk.TAB), :] = np.uint64(ROMLO + tab_head)
        J.M2[J.pos(walk.LEFT), :] = np.uint64(len(rows))
        rep, steps, _ = J.run()
    cp.cuda.Stream.null.synchronize()
    return J, rep, steps, (time.perf_counter() - t0) / reps
