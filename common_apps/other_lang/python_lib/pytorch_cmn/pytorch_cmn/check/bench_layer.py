# -*- coding: utf-8 -*-
"""レイヤー一枚を端から端まで測る。Qwen の FFN の形（5120 → 17408）で cupy と突き合わせる。

    python check/bench_layer.py [入力の幅] [出力の幅] [K] [d]

二段。
  1. 詰めた語で掛けて足す（コモン公用語）。lane = 出力の組 × 列の区間
  2. 詰めを解いて、列の区間をまたいで足す

lane の行は共有メモリに [W, x, W, x, ...] と交互に並ぶ。列の区間ごとに x が違うので、
固定の番地からは読まない。
"""
import os
import sys
import time

import numpy as np

from .. import fold
from .. import lane


def run(C=5120, R=17408, K=4, d=0, batch=1, byte=False, cap=float(os.environ.get("CMN_CAP", "11")) * 1e9):
    import cupy as cp
    from common_vcpu import gvcpu
    from common_vcpu import vcpu

    b, n = fold.width(K, d, byte=byte)
    G = R // n
    R2 = G * n                       # 一語に n 本ずつ入るので、ここまでを見る
    blocks = C // K
    lanes = G * blocks * batch
    print("入力 %d  出力 %d（%d まで見る）  K %d  d %d  一語に %d 本  桁 %d bit"
          % (C, R, R2, K, d, n, b))

    img, need, _ = lane.build(fold.twin_ptr(K), "ly%d" % K)
    seed = {fold.ROW: fold.ROW + 512, fold.XPT: fold.ROW + 1024}
    for j in range(K):
        seed[fold.ROW + 512 + j] = j + 2
        seed[fold.ROW + 1024 + j] = j * 3 + 1
    prog = lane.best(vcpu.decode(img), need, check=(seed, (fold.OUT,)))
    words = gvcpu.compact(prog, (64, need), work=fold.ROW)[1] + 2
    vram = words * 8.0 * lanes + 8.0 * (lanes * K + C)
    print("  lane %d = 組 %d × 区間 %d × 枚 %d   語/lane %d   命令 %d   VRAM %.2f GB"
          % (lanes, G, blocks, batch, words, len(prog), vram / 1e9))
    if vram > cap:
        print("  VRAM を越えるので止めます（上限 %.1f GB）" % (cap / 1e9))
        return 0

    L = gvcpu.Lanes(prog, need, fold.ROW, fold.OUT + 1, lanes * K + C, lanes, sync=False)
    rs = cp.random.RandomState(7)
    C0 = 1 << d
    x = rs.randint(0, C0 + 1, size=(C,), dtype=cp.int64)
    W = rs.randint(-C0, C0 + 1, size=(R2, C), dtype=cp.int64)
    packed = cp.zeros((G, C), dtype=cp.int64)
    for j in range(n):
        packed |= (W[j::n] + C0) << (j * b)
    # 行の並び: (組, 区間, K, 2) で [W, x] を交互に置く
    # 共有メモリ: 先に係数（lane ごとに K 語）、後に入力（列ぜんぶで一組だけ）
    L.d_rom[:lanes * K] = cp.broadcast_to(packed.reshape(1, -1), (batch, G * C)).reshape(-1).astype(cp.uint64)
    L.d_rom[lanes * K:] = x.astype(cp.uint64)
    romlo = fold.OUT + 1
    L.M2[L.pos(fold.ROW), :] = (romlo + cp.arange(lanes, dtype=cp.int64) * K).astype(cp.uint64)
    # 入力の先頭は列の区間で決まる。lane (枚, 組, 区間) の区間だけを見る
    blk = cp.tile(cp.repeat(cp.arange(blocks, dtype=cp.int64), 1), G * batch)
    L.M2[L.pos(fold.XPT), :] = (romlo + lanes * K + blk * K).astype(cp.uint64)
    del packed, blk
    cp.cuda.Stream.null.synchronize()

    L.run()
    cp.cuda.Stream.null.synchronize()
    t0 = time.perf_counter()
    L.run()
    cp.cuda.Stream.null.synchronize()
    t_mul = time.perf_counter() - t0
    part = L.get_block(fold.OUT, 1).reshape(-1).copy()
    del L
    cp.get_default_memory_pool().free_all_blocks()

    shift8 = (C0 * x.reshape(blocks, K).sum(axis=1)).astype(cp.int32)

    def open_add(pt):
        """詰めを解いて区間の軸を足し合わせる。桁が 8 bit なら byte の読み替えで済む。"""
        if b == 8:
            f = pt.view(cp.uint8).reshape(G, blocks, 8).astype(cp.int32)
        else:
            f = cp.stack([((pt >> (j * b)) & ((1 << b) - 1)) for j in range(n)],
                         axis=1).reshape(G, blocks, n)
        f = f - shift8.reshape(1, blocks, 1)
        return f.sum(axis=1).reshape(-1)

    one = part.reshape(batch, -1)[0]
    open_add(one)                                    # 一度目は cupy の作りが入る
    cp.cuda.Stream.null.synchronize()
    t0 = time.perf_counter()
    got = open_add(one)
    cp.cuda.Stream.null.synchronize()
    t_add = (time.perf_counter() - t0) * batch
    shift = C0 * x.reshape(blocks, K).sum(axis=1)          # 区間ごとの下駄
    del part

    want = (W * x.reshape(1, C)).sum(axis=1)
    got = got.astype(want.dtype)
    bad = int(cp.count_nonzero(got != want))
    mac = float(R2) * C * batch
    el = t_mul + t_add
    print("  掛けて足す %7.3f ms   解いて合わせる %7.3f ms   合計 %7.3f ms"
          % (t_mul * 1e3, t_add * 1e3, el * 1e3))
    print("  積和 %.1f M   食い違い %d   common %.2f G 積和/秒" % (mac / 1e6, bad, mac / el / 1e9))

    A = W.astype(cp.float32)
    xf = x.astype(cp.float32)
    A @ xf
    cp.cuda.Stream.null.synchronize()
    t0 = time.perf_counter()
    for _ in range(10):
        A @ xf
    cp.cuda.Stream.null.synchronize()
    tc = (time.perf_counter() - t0) / 10
    tc = tc * batch
    print("  cupy fp32 %7.3f ms   %.2f G 積和/秒   → common は %.2f 倍"
          % (tc * 1e3, mac / tc / 1e9, tc / el))
    print("  bit/係数  common %.2f   fp32 32 → %.1f 分の 1" % (64.0 / n, 32.0 / (64.0 / n)))
    del W, A
    cp.get_default_memory_pool().free_all_blocks()
    return bad


if __name__ == "__main__":
    a = sys.argv[1:]
    bad = run(int(a[0]) if a else 5120, int(a[1]) if len(a) > 1 else 17408,
              int(a[2]) if len(a) > 2 else 4, int(a[3]) if len(a) > 3 else 0,
              int(a[4]) if len(a) > 4 else 1, len(a) > 5 and a[5] == "byte")
    sys.exit(1 if bad else 0)
