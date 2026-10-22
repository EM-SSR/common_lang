# -*- coding: utf-8 -*-
"""lane を上限まで並べたときの積和/秒・VRAM・電力を測る。

grid 全体の barrier を使うので、全 block が同時に載っていないと止まる。だから lane 数は
`lane.resident()`（36 SM × 1536 thread = 55296）が上限になる。その中で

    lane = token 数 × 出力の列数 × 組数

を上限いっぱいに取る。内積が主役になる形（列を少なく、K を大きく）を選ぶと、1 stage の
固定費（アドレス取得 347 命令）が内積の中に埋もれる。

    python -m pytorch_cmn.check.bench_lane
    python -m pytorch_cmn.check.bench_lane 4096 64      # K と 出力の列数
"""
import subprocess
import sys
import time

import torch

try:
    from .. import backend                      # noqa: F401
    from .. import graph
    from .. import lane as L
except ImportError:
    import pytorch_cmn.backend                  # noqa: F401
    from pytorch_cmn import graph
    from pytorch_cmn import lane as L


def watt():
    """いまの消費電力（W）。取れなければ None。"""
    try:
        got = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=power.draw,memory.used",
             "--format=csv,noheader,nounits"], stderr=subprocess.DEVNULL)
        a = got.decode().split("\n")[0].split(",")
        return float(a[0]), float(a[1])
    except Exception:
        return None, None


def _lower(net, x):
    seen = {}

    def peek(gm, ex):
        seen["gm"], seen["ex"] = gm, ex
        return gm.forward

    torch.compile(net, backend=peek, dynamic=False)(x)
    return graph.Lower(seen["gm"], seen["ex"]).emit(), tuple(seen["ex"])


def run(k=4096, n=64, reps=3, verbose=True):
    import cupy as cp
    mp = cp.get_default_memory_pool()
    cap = L.resident()
    torch.manual_seed(11)
    net = torch.nn.Linear(k, n, bias=False)
    if verbose:
        print("Linear K=%d → %d  lane の上限 %d" % (k, n, cap))
        print("%-6s %-9s %-5s %-6s %-5s %-6s %-9s %-11s %-9s %-6s"
              % ("token", "lane", "占有", "組", "段", "項/lane", "壁 ms",
                 "G 積和/秒", "VRAM MB", "W"))
    out = []
    # token 数は上限から逆算する。組数は Lower が上限内で最大を選ぶ
    for T in _tokens(cap, n):
        x = torch.randn(T, k) / 32.0
        try:
            low, args = _lower(net, x)
            if low.B.lanes > cap:
                continue
            J = low.B.board()
            low.refresh(args)
            low.B.run()
            cp.cuda.Stream.null.synchronize()
            t0 = time.perf_counter()
            for _ in range(reps):
                low.B.run()
            cp.cuda.Stream.null.synchronize()
            ms = (time.perf_counter() - t0) * 1e3 / reps
            C = low.B.groups
            g = float(T) * n * k / (ms * 1e-3) / 1e9
            w, vram = watt()
            row = (T, low.B.lanes, 100.0 * low.B.lanes / cap, C, len(low.B.rows),
                   k // C, ms, g, vram if vram else mp.total_bytes() / 1e6, w)
            out.append(row)
            if verbose:
                print("%-6d %-9d %-5.0f %-6d %-5d %-6d %-9.1f %-11.2f %-9.0f %-6s"
                      % (row[0], row[1], row[2], row[3], row[4], row[5], row[6],
                         row[7], row[8], "%.0f" % row[9] if row[9] else "-"))
            low.close()
            mp.free_all_blocks()
        except Exception as e:
            if verbose:
                print("%-6d 落ちた %s: %s"
                      % (T, type(e).__name__, str(e).split("\n")[0][:58]))
    return out


def _tokens(cap, n):
    """占有が 1 割・5 割・満杯になる token 数。組数 64 を当てにして逆算する。"""
    got = []
    for frac in (0.02, 0.25, 1.0):
        t = max(1, int(cap * frac) // (n * 64))
        if t not in got:
            got.append(t)
    return got


if __name__ == "__main__":
    a = [int(v) for v in sys.argv[1:]]
    run(a[0] if a else 4096, a[1] if len(a) > 1 else 64)
