# -*- coding: utf-8 -*-
"""三軸のエンジンを GPU で走らせる。共有メモリは numpy の並びで渡す（Python の list を使わない）。"""
import os
import sys
import time

import numpy as np

from .. import fold
from .. import lane
from .. import walk

ROMLO = fold.ROW + 16
_IMG = {}


def image(u):
    from common_vcpu import gvcpu
    from common_vcpu import vcpu
    if u not in _IMG:
        img, need, _ = lane.build(walk.engine3(u), "e3_%d" % u)
        raw = gvcpu.fold(vcpu.decode(img), wires=(64, need))
        _IMG[u] = (lane.press(raw, need), need, len(raw))
    return _IMG[u]


class Run(object):
    """共有メモリを numpy で組み、段を並べて走らせる。"""

    def __init__(self, u, lanes, threads=128):
        self.u = u
        self.lanes = lanes
        self.threads = threads
        self.share = []          # (先頭, 並び) の予約
        self.n = 0
        self.rows = []

    def room(self, n):
        h = self.n
        self.n += int(n)
        return h

    def data(self, arr):
        a = np.asarray(arr, dtype=np.int64).reshape(-1)
        h = self.room(a.size)
        self.share.append((h, a))
        return h

    def imm(self, v):
        return self.data([int(v)])

    def row(self, out, out_s, k_groups, w, w_s, x, x_s,
            look=None, flag=None, less=None):
        """十八語の段。先頭は番地（ROMLO + 枠番号）を持つ枠、歩幅と数は値の枠。"""
        z = self.imm(0)
        zat = self.data([ROMLO + z])
        self.rows.append([
            self.data([ROMLO + out]), self.imm(out_s[0]), self.imm(out_s[1]), self.imm(out_s[2]),
            self.imm(k_groups),
            self.data([ROMLO + w]), self.imm(w_s[0]), self.imm(w_s[1]), self.imm(w_s[2]),
            self.data([ROMLO + x]), self.imm(x_s[0]), self.imm(x_s[1]), self.imm(x_s[2]),
            (self.data([ROMLO + look[0]]) if look else zat),
            (self.imm(look[1]) if look else z),
            self.data([ROMLO + (flag if flag is not None else self.room(1))]),
            (self.imm(less[0]) if less else z), (self.imm(less[1]) if less else z),
        ])

    def go(self, idx, reps=1):
        """idx は (lane 数, 3) の並びで、三軸の番号。"""
        import cupy as cp
        prog, need, raw = image(self.u)
        tab_head = self.n
        flat = np.concatenate([np.asarray(r, dtype=np.int64) + ROMLO for r in self.rows])
        romn = tab_head + flat.size
        J = lane.Joint(prog, need, fold.ROW, ROMLO, romn, self.lanes, threads=self.threads)
        for h, a in self.share:
            J.d_rom[h:h + a.size] = cp.asarray(a.astype(np.uint64))
        J.d_rom[tab_head:romn] = cp.asarray(flat.astype(np.uint64))
        J.M2[J.pos(walk.TAB), :] = np.uint64(ROMLO + tab_head)
        J.M2[J.pos(walk.LEFT), :] = np.uint64(len(self.rows))
        # Joint はレーン数を thread 数の倍数へ丸める。余ったレーンにも番号を入れる
        pad = np.zeros((J.n, 3), dtype=np.int64)
        pad[:len(idx)] = idx
        for w, col in ((walk.IDX1, 0), (walk.IDX2, 1), (walk.IDX3, 2)):
            J.M2[J.pos(w), :] = cp.asarray(pad[:, col].astype(np.uint64))
        rep, steps, _ = J.run()
        cp.cuda.Stream.null.synchronize()
        t0 = time.perf_counter()
        for _ in range(reps):
            J.M2[J.pos(walk.TAB), :] = np.uint64(ROMLO + tab_head)
            J.M2[J.pos(walk.LEFT), :] = np.uint64(len(self.rows))
            rep, steps, _ = J.run()
        cp.cuda.Stream.null.synchronize()
        el = (time.perf_counter() - t0) / reps
        return J, rep, steps, el, len(prog)
