# -*- coding: utf-8 -*-
"""列の内積を測る。検算と速さを分け、VRAM を溢れさせない。

    python check/bench.py

VRAM は 16 GB しかない。溢れると RAM へ漏れて遅くなるので、lane の数は
「作業領域 + 共有メモリ <= 上限」から決める。検算は別の小さい走りでやる。
"""
import os
import subprocess
import sys
import threading
import time

import numpy as np

from .. import fold
from .. import lane

CAP = int(float(os.environ.get("CMN_CAP", "10")) * 1e9)   # 16 GB に対して余裕を残す。
# 溢れると RAM へ漏れて遅くなるので、上限は環境変数で下げられるようにしてある。


def smi(stop, out):
    while not stop.is_set():
        try:
            r = subprocess.run(["nvidia-smi", "--query-gpu=power.draw,memory.used",
                                "--format=csv,noheader,nounits"],
                               capture_output=True, text=True, timeout=3)
            out.append([float(v) for v in r.stdout.strip().split(",")])
        except Exception:
            pass
        time.sleep(0.02)


_IMG = {}


def image(k):
    """平文を image にして、命令を最適化して返す。検算ゲートを通す。"""
    from common_vcpu import gvcpu
    from common_vcpu import vcpu
    if k in _IMG:
        return _IMG[k]
    img, need, _ = lane.build(fold.text(k, fold.OUT + 1), "bn%d" % k)
    raw = gvcpu.fold(vcpu.decode(img), wires=(64, need))
    seed = {fold.ROW: fold.OUT + 1 + k}
    for t in range(k):
        seed[fold.OUT + 1 + t] = t + 3
        seed[fold.OUT + 1 + k + t] = t * 2 + 1
    ck = (seed, (fold.OUT,))
    want = lane._walked(raw, need, ck)
    best = raw
    for c in (lane.tighten(raw, need), lane.press(raw, need)):
        if lane._walked(c, need, ck) == want and len(c) < len(best):
            best = c
    _IMG[k] = (best, need)
    return _IMG[k]


def board(k, lanes):
    from common_vcpu import gvcpu
    prog, need = image(k)
    return gvcpu.Lanes(prog, need, fold.ROW, fold.OUT + 1, k + lanes * k, lanes, sync=False)


def lanes_for(k, need_words):
    """VRAM の上限から lane の数を出す。作業領域 8·語·lane と共有メモリ 8·k·lane。"""
    return int(CAP / (8.0 * (need_words + k)))


def verify(k, d):
    """小さい走りで、詰めた語が numpy と一致するかを見る。"""
    import cupy as cp
    L = board(k, 1 << 16)
    n_lanes = L.n
    b, n = fold.width(k, d)
    C = 1 << d
    rng = np.random.default_rng(7)
    W = rng.integers(-C, C + 1, size=(n_lanes * n, k), dtype=np.int64)
    x = rng.integers(0, C + 1, size=(k,), dtype=np.int64)
    packed, b2, n2 = fold.squeeze(W, d, k)
    xb = fold.OUT + 1
    L.rom_put(0, x.astype(np.uint64))
    L.rom_put(k, packed.reshape(-1).astype(np.uint64))
    L.put_block(fold.ROW, (xb + k + np.arange(n_lanes, dtype=np.int64) * k)
                .astype(np.uint64).reshape(1, n_lanes))
    L.run()
    got = L.get_block(fold.OUT, 1).reshape(-1).get().astype(np.int64)
    dig = fold.loosen(got, x, d, k)
    want = np.stack([W[j::n][:n_lanes] @ x for j in range(n)], axis=1)
    bad = int(np.count_nonzero(dig != want))
    del L
    cp.get_default_memory_pool().free_all_blocks()
    return bad


def speed(k, d, lanes):
    """速さだけ測る。検算の並びは確保しない。"""
    import cupy as cp
    from common_vcpu import gvcpu
    prog, need = image(k)
    b, n = fold.width(k, d)
    L = gvcpu.Lanes(prog, need, fold.ROW, fold.OUT + 1, k + lanes * k, lanes, sync=False)
    xb = fold.OUT + 1
    L.d_rom[:] = cp.arange(L.romn, dtype=cp.uint64) % (1 << (b - 1))
    L.put_block(fold.ROW, (xb + k + np.arange(lanes, dtype=np.int64) * k)
                .astype(np.uint64).reshape(1, lanes))
    rep = cp.zeros((lanes,), dtype=cp.int32)
    st = cp.zeros((lanes,), dtype=cp.int64)
    th_ = 256
    grid = (lanes + th_ - 1) // th_
    args = (L.d_prog, np.int32(L.nprog), L.M, np.int32(L.words), np.int32(lanes),
            np.int64(1 << 36), np.int32(L.need), np.int32(L.work), rep, st,
            L.d_rom, np.int64(L.romlo), np.int64(L.romn))
    go = lambda: L.k_run((grid,), (th_,), args, shared_mem=th_ * gvcpu.NREG_BYTES)
    go()
    cp.cuda.Stream.null.synchronize()
    stop = threading.Event()
    s = []
    t = threading.Thread(target=smi, args=(stop, s))
    t.start()
    reps = 30
    t0 = time.perf_counter()
    for _ in range(reps):
        go()
    cp.cuda.Stream.null.synchronize()
    el = (time.perf_counter() - t0) / reps
    stop.set()
    t.join()
    pw = max((v[0] for v in s), default=0)
    mu = max((v[1] for v in s), default=0)
    words = L.words
    del L, rep, st
    cp.get_default_memory_pool().free_all_blocks()
    return lanes * k * n / el / 1e9, pw, mu, words, n


def main():
    print("%-4s %-3s %-4s %-10s %-5s %-11s %-6s %-9s %-9s %-6s"
          % ("K", "d", "n", "lane", "語", "G 積和/秒", "W", "VRAM MB", "bit/係数", "食違"))
    ks = [int(v) for v in os.environ.get("CMN_K", "4,8,16").split(",")]
    ds = [int(v) for v in os.environ.get("CMN_D", "0,1,2").split(",")]
    for k in ks:
        for d in ds:
            bad = verify(k, d)
            words = image(k)[1]
            ln = lanes_for(k, _words(k))
            ln = (ln // 256) * 256
            g, pw, mu, w, n = speed(k, d, ln)
            print("%-4d %-3d %-4d %-10d %-5d %-11.2f %-6.0f %-9.0f %-9.1f %-6d"
                  % (k, d, n, ln, w, g, pw, mu, 64.0 / n, bad))


def _words(k):
    """lane あたりの語数。compact の後の値を一度だけ測る。"""
    from common_vcpu import gvcpu
    prog, need = image(k)
    _, n2 = gvcpu.compact(prog, (64, need), work=fold.ROW)
    return n2 + 2


if __name__ == "__main__":
    main()
