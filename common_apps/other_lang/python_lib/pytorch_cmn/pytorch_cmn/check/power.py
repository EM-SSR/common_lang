# -*- coding: utf-8 -*-
"""板を埋めたときの速度・VRAM・電力を測る。

lane が少ないと GPU の利得が出ない。thread 一本は CPU より遅いので、**待ち時間を
隠せるだけの warp が要る**。同じ graph のまま行（token）を増やしてレーンを伸ばし、
壁時間・積和/秒・VRAM・電力を並べる。

    python -m pytorch_cmn.check.power
    python -m pytorch_cmn.check.power 512 1408        # d と h を変える
"""
import subprocess
import sys
import time

import numpy as np
import torch

try:
    from .. import backend                      # noqa: F401
    from .. import graph
except ImportError:
    import pytorch_cmn.backend                  # noqa: F401
    from pytorch_cmn import graph


class FFN(torch.nn.Module):
    """Transformer の一段の FFN。正規化 → 門つき射影 → 戻す。"""

    def __init__(self, d, h):
        super(FFN, self).__init__()
        self.norm = torch.nn.RMSNorm(d)
        self.gate = torch.nn.Linear(d, h, bias=False)
        self.up = torch.nn.Linear(d, h, bias=False)
        self.down = torch.nn.Linear(h, d, bias=False)

    def forward(self, x):
        y = self.norm(x)
        return x + self.down(torch.nn.functional.silu(self.gate(y)) * self.up(y))


def watt():
    """いまの消費電力（W）。取れなければ None。"""
    try:
        got = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=power.draw", "--format=csv,noheader,nounits"],
            stderr=subprocess.DEVNULL)
        return float(got.decode().split("\n")[0])
    except Exception:
        return None


def _lower(net, x):
    """graph を組むところまで。走らせない。"""
    seen = {}

    def peek(gm, ex):
        seen["gm"], seen["ex"] = gm, ex
        return gm.forward

    torch.compile(net, backend=peek, dynamic=False)(x)
    return graph.Lower(seen["gm"], seen["ex"]).emit(), tuple(seen["ex"])


def full(d, h, width=None):
    """GPU が同時に載せられる lane 数から、埋まる token 数を逆算する。

    grid 全体の barrier を使うので、全 block が同時に載っていないと止まる。だから
    lane 数 = token 数 × width × 組数 が `lane.resident()` を越えられない。
    """
    from .. import lane as L
    cap = L.resident()
    w = width or h
    return max(1, cap // w), cap


def run(d=64, h=176, ts=None, reps=3, verbose=True):
    import cupy as cp
    mp = cp.get_default_memory_pool()
    torch.manual_seed(11)
    net = FFN(d, h)
    macs = float(d * h * 3)                      # gate・up・down の積和（1 token 分）
    tmax, cap = full(d, h)
    if ts is None:
        ts = [t for t in (1, tmax // 8, tmax // 2, tmax) if t >= 1]
        ts = sorted(set(ts))
    if verbose:
        print("FFN d=%d h=%d  1 token = %.3f M 積和  lane の上限 %d"
              % (d, h, macs / 1e6, cap))
        print("%-6s %-9s %-6s %-7s %-6s %-9s %-11s %-9s %-7s"
              % ("token", "lane", "占有", "block", "段", "壁 ms", "G 積和/秒",
                 "VRAM MB", "W"))
    out = []
    for T in ts:
        x = torch.randn(T, d) / 8.0
        try:
            low, args = _lower(net, x)
            J = low.B.board()
            low.refresh(args)
            low.B.run()                          # 温める
            cp.cuda.Stream.null.synchronize()
            t0 = time.perf_counter()
            for _ in range(reps):
                low.B.run()
            cp.cuda.Stream.null.synchronize()
            ms = (time.perf_counter() - t0) * 1e3 / reps
            g = macs * T / (ms * 1e-3) / 1e9
            row = (T, low.B.lanes, 100.0 * low.B.lanes / cap, J.nblocks,
                   len(low.B.rows), ms, g, mp.total_bytes() / 1e6, watt())
            out.append(row)
            if verbose:
                print("%-6d %-9d %-6.0f %-7d %-6d %-9.1f %-11.2f %-9.0f %-7s"
                      % (row[0], row[1], row[2], row[3], row[4], row[5], row[6],
                         row[7], "%.0f" % row[8] if row[8] else "-"))
            low.close()
            mp.free_all_blocks()
        except Exception as e:
            if verbose:
                print("%-6d 落ちた %s: %s" % (T, type(e).__name__,
                                            str(e).split("\n")[0][:60]))
    return out


if __name__ == "__main__":
    a = [int(v) for v in sys.argv[1:]]
    run(a[0] if a else 64, a[1] if len(a) > 1 else 176)
