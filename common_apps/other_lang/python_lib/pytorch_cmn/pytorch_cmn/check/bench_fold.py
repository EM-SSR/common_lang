# -*- coding: utf-8 -*-
"""列の内積を板いっぱいの lane で測り、同じ仕事を PyTorch と突き合わせる。

    python check/bench_fold.py [列の本数] [行の本数]

lane は板に載る限り全部並べる。行が lane より多いときは行を分けるのではなく、
GPU の上限までを一度に載せる。
"""
import os
import sys
import time

import numpy as np


from .. import fold
from .. import lane

F = 12                       # 固定小数の深度。値 = 分子 · 2^-F


def main(k=64, rows=None):
    import cupy as cp
    from common_vcpu import gvcpu
    from common_vcpu import vcpu

    cap = lane.resident()
    rows = cap if rows is None else min(rows, cap)
    xbase = fold.OUT + 1                      # 共有メモリの頭。入力 x がここから k 語
    wbase = xbase + k                         # W は行ごとに k 語ずつ続く

    text = fold.text(k, xbase)
    t0 = time.perf_counter()
    image, need, plain = lane.build(text, "fold%d" % k)
    t_build = time.perf_counter() - t0

    rng = np.random.default_rng(7)
    W = rng.integers(-(1 << 8), 1 << 8, size=(rows, k), dtype=np.int64)
    x = rng.integers(-(1 << 8), 1 << 8, size=(k,), dtype=np.int64)

    romn = k + rows * k
    prog = gvcpu.fold(vcpu.decode(image), wires=(64, need))
    prog = gvcpu.fold(lane.forward(prog), wires=(64, need))
    L = gvcpu.Lanes(prog, need, fold.ROW, xbase, romn, rows, sync=True)
    L.rom_put(0, x.astype(np.uint64))
    L.rom_put(k, W.reshape(-1).astype(np.uint64))
    # 各 lane に自分の行の先頭番地を置く。host は散らすだけで計算をしない
    base = xbase + k + np.arange(rows, dtype=np.int64) * k
    L.put_block(fold.ROW, base.astype(np.uint64).reshape(1, rows))

    L.run()                                   # 一度目は module の作りが入る
    cp.cuda.Stream.null.synchronize()
    t0 = time.perf_counter()
    rep, _ = L.run(watch=())
    cp.cuda.Stream.null.synchronize()
    el = time.perf_counter() - t0
    got = L.get_block(fold.OUT, 1).reshape(-1).get().astype(np.int64)

    want = W @ x
    bad = int(np.count_nonzero(got != want))
    mac = rows * k
    print("列 %-6d 行 %-7d 積和 %.3f G   食い違い %d" % (k, rows, mac / 1e9, bad))
    print("  compile %7.2f ms   命令 %-7d ステップ数の上限 %d" % (t_build * 1e3, len(prog), L.words))
    print("  common  %7.2f ms   %.3f G 積和/秒   報告 %s"
          % (el * 1e3, mac / el / 1e9, sorted(set(int(r) for r in rep))))

    import torch
    A = torch.from_numpy(W.astype(np.float32))
    b = torch.from_numpy(x.astype(np.float32))
    torch.mv(A, b)
    t0 = time.perf_counter()
    for _ in range(3):
        torch.mv(A, b)
    tel = (time.perf_counter() - t0) / 3
    print("  torch   %7.2f ms   %.3f G 積和/秒" % (tel * 1e3, mac / tel / 1e9))
    print("  速さの比 %.2f 倍" % (tel / el))
    return bad


if __name__ == "__main__":
    k = int(sys.argv[1]) if len(sys.argv) > 1 else 64
    r = int(sys.argv[2]) if len(sys.argv) > 2 else None
    sys.exit(1 if main(k, r) else 0)
