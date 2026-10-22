# -*- coding: utf-8 -*-
"""手で書いた局所微分箱（cmn/box/*.cmn）を GPU の lane で実行する。

箱は整数を受け取る。入力 i は作業領域の語 2^i に置き、箱の先頭の層が hu と se で番地 2^i を作って mi で読む。
同じ番地を何度でも読めるので、係数を好きな順に並べられて、ワイヤの入れ替えは要らない。出口は語 0, 1, … の整数。

ワイヤの値は 整数 / 2^b。1 回の呼び出しの入力は共通の b にそろえる（U = 2^b は単位の入力で、定数 1 の代わりになる）。
出口の b は箱ごとに決まる。1/2 を掛けることは分子を動かさず b を 1 増やすことなので、箱には現れない。

    箱           入力の並び                       出口                        b'
    ti.value     x1 x2                           x1 x2                       2b
    no.value     x1 x2                           x1 + x2                     b
    za.value     x1 x2                           (x1 + x2) / 2               b + 1        se(x) = za(x, 1)
    ha.value     x                               −x                          b
    gu.value     x U                             2x − U                      b
    ge.value     U                               U                           b
    so.value     x                               [0 < x]                     0
    hi.value     x y                             [x ≤ y]                     0
    ti.rev       x1 x2 ȳ                         ȳ x2, ȳ x1                  2b
    no.rev       ȳ                               ȳ, ȳ                        b            ⊕ の双対は Δ
    gu.rev       ȳ                               2ȳ                          b
    ge.rev       ȳ                               0                           b
    so.rev       x ȳ U                           ȳ [x² ≤ U²] / 2              b + 1        前向きも同じ箱
    hi.rev       x y ȳ U                         −ȳ g, ȳ g (g = [(y−x)² ≤ U²]) / 2   b + 1
    ti.fwd       x1 x2 ẋ1 ẋ2                    x1 ẋ2 + x2 ẋ1              2b
    hi.fwd       x y ẋ ẏ U                       (ẏ − ẋ) g / 2               b + 1
"""
import hashlib
import os

import numpy as np

from common_vcpu import gvcpu, toolchain, vcpu

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.environ.get("GRADCMN4TORCH_BUILD") or os.path.join(
    os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.cache"), "gradcmn4torch", "build")

OUT_SCALE = {          # 箱 → (入力の共通の b から出口の b を求める関数)
    "ti.value": lambda b: 2 * b, "no.value": lambda b: b, "za.value": lambda b: b + 1,
    "ha.value": lambda b: b, "gu.value": lambda b: b, "ge.value": lambda b: b,
    "so.value": lambda b: 0, "hi.value": lambda b: 0,
    "ti.rev": lambda b: 2 * b, "no.rev": lambda b: b, "gu.rev": lambda b: b, "ge.rev": lambda b: b,
    "so.rev": lambda b: b + 1, "hi.rev": lambda b: b + 1,
    "ti.fwd": lambda b: 2 * b, "hi.fwd": lambda b: b + 1,
    "sub.value": lambda b: b, "sub.rev": lambda b: b, "eqz.value": lambda b: 0, "sign.value": lambda b: 0,
    "sign.rev": lambda b: b, "sign.fwd": lambda b: b,                  # 符号の微分は 2 s(x) = [x² ≤ 1]
    "lin.value": lambda b: 2 * b, "lin.rev": lambda b: 2 * b, "lin.fwd": lambda b: 2 * b,
}
FILE = {"sign.rev": "so.rev", "sign.fwd": "so.rev"}            # 箱の置き場。無ければ名前そのまま
N_OUT = {"ti.rev": 2, "no.rev": 2, "hi.rev": 2, "sub.rev": 2, "lin.rev": 2}

_IMAGE = {}
_LANES = {}


def _image(name):
    if name not in _IMAGE:
        src = os.path.join(HERE, "cmn", "box", FILE.get(name, name) + ".cmn")
        os.makedirs(BUILD, exist_ok=True)
        out = os.path.join(BUILD, "box_" + name + "_" + hashlib.sha1(open(src, "rb").read()).hexdigest()[:10] + ".bin")
        _IMAGE[name] = toolchain.compile([src], None, out)
    return _IMAGE[name]


CHUNK = 1 << 18                # 1 回に並べる lane の数の上限
MIN_LANES = 4096


class _Runner(object):
    """箱 1 つぶんの lane の領域。lane の数が増えたときだけ作り直し、呼び出しごとに使い回す。"""

    def __init__(self, name, capacity):
        import cupy as cp
        self.cp, self.capacity = cp, capacity
        image, need = _image(name)
        lanes = gvcpu.Lanes(vcpu.decode(image), need, toolchain.WORK, toolchain.WORK + 64, 0, capacity)
        self.lanes, self.M2 = lanes, lanes.M2
        self.in_rows = cp.asarray([lanes.pos(1 << i) for i in range(6)], dtype=cp.int64)
        self.out_rows = cp.asarray([lanes.pos(j) for j in range(N_OUT.get(name, 1))], dtype=cp.int64)
        self.report = cp.zeros((capacity,), dtype=cp.int32)
        self.steps = cp.zeros((capacity,), dtype=cp.int64)

    def __call__(self, ints):
        cp, l = self.cp, self.lanes
        L, n = len(ints[0]), len(ints)
        self.M2[self.in_rows[:n], :L] = cp.asarray(np.stack(ints).astype(np.int64).view(np.uint64))
        grid = ((L + 127) // 128,)
        l.k_run(grid, (128,), (l.d_prog, np.int32(l.nprog), l.M, np.int32(l.words), np.int32(L), np.int64(1 << 16),
                               np.int32(l.need), np.int32(l.work), self.report, self.steps, l.d_rom, np.int64(l.romlo),
                               np.int64(l.romn), np.int32(l.n)), shared_mem=128 * gvcpu.NREG_BYTES)
        out = cp.concatenate([self.M2[self.out_rows, :L].reshape(-1).view(cp.int64), self.report[:L].astype(cp.int64)]).get()
        k = len(self.out_rows)
        if out[k * L:].any():
            raise RuntimeError("箱が報告 %s で止まった" % sorted(set(int(r) for r in out[k * L:] if r)))
        return [out[j * L:(j + 1) * L] for j in range(k)]


def run(name, ints):
    """箱 name を、入力 ints（形 (L,) の int64 の並び）で実行する。返りは出口の int64 の並び。"""
    if len(ints[0]) > CHUNK:
        parts = [run(name, [x[i:i + CHUNK] for x in ints]) for i in range(0, len(ints[0]), CHUNK)]
        return [np.concatenate([p[j] for p in parts]) for j in range(len(parts[0]))]
    runner = _LANES.get(name)
    if runner is None or runner.capacity < len(ints[0]):
        runner = _LANES[name] = _Runner(name, max(MIN_LANES, 1 << (len(ints[0]) - 1).bit_length()))
    return runner(ints)
