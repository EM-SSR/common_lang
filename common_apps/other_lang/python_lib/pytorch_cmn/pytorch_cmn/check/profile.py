# -*- coding: utf-8 -*-
"""演算ごとに、時間の内訳を別々に測る。

    ステージ数        表の行数
    命令数            カーネルが 1 レーンで歩いた命令の数（`steps`）
    バリア回数        共有領域への書き込みの数。1 回ごとにグリッド全体が待つ
    リセット          ワーク領域を 0 にする時間
    種置き            表の先頭とレーン番号を置く時間
    カーネル          `k_run` の時間
    rep 取り出し      報告とステップ数を CPU へ戻す時間
    出力取り出し      結果の語を CPU へ戻す時間

    python -m pytorch_cmn.check.profile
"""
import time

import numpy as np
import torch

try:
    from .. import backend                      # noqa: F401
    from .. import graph, walk
except ImportError:
    import pytorch_cmn.backend                  # noqa: F401
    from pytorch_cmn import graph, walk


def _lower(fn, x):
    seen = {}

    def peek(gm, ex):
        seen["gm"], seen["ex"] = gm, ex
        return gm.forward

    torch.compile(fn, backend=peek, dynamic=False)(x)
    low = graph.Lower(seen["gm"], seen["ex"]).emit()
    return low, tuple(seen["ex"])


def _sync(cp):
    cp.cuda.Stream.null.synchronize()


def _shared_stores(prog):
    """エンジンの命令のうち、共有領域へ書くものを数える。

    共有領域は番地が `ROMLO` 以上。`op == 9`（ST）で番地がそこへ入ると、カーネルは
    `gbar` を呼んでグリッド全体を待たせる。番地が即値で決まらない ST は、表から
    読んだ出力先なので共有領域と見なす。
    """
    imm, shared, unknown = {}, 0, 0
    for p in prog:
        op, a, b = int(p[0]), int(p[1]), int(p[2])
        if op == 1:
            imm[a] = int(p[6])
            continue
        if op == 9:
            v = imm.get(b)
            if v is None:
                unknown += 1
            elif v >= graph.ROMLO:
                shared += 1
        if op in (1, 2, 3, 4, 8):
            imm.pop(a, None)
    return shared, unknown


def one(tag, fn, x, reps=5, verbose=True):
    import cupy as cp
    low, args = _lower(fn, x)
    B = low.B
    prog, need = graph._engine(B.unroll)
    J = B.board()
    low.refresh(args)

    def phase(f):
        f()
        _sync(cp)
        t0 = time.perf_counter()
        for _ in range(reps):
            f()
        _sync(cp)
        return (time.perf_counter() - t0) * 1e3 / reps

    t_reset = phase(J.reset)

    def seed():
        for addr, v in B._seed.items():
            J.M2[J.pos(addr), :] = v

    t_seed = phase(seed)

    # カーネルだけ。種を置き直してから呼ぶ
    def kernel():
        J.reset()
        seed()
        rep, steps, cnt, gen = J._scratch()
        J.k_run((J.nblocks,), (J.threads,),
                (J.d_prog, np.int32(J.nprog), J.M, np.int32(J.words),
                 np.int32(J.n), np.int64(1 << 36), np.int32(J.need),
                 np.int32(J.work), rep, steps, J.d_rom, np.int64(J.romlo),
                 np.int64(J.romn), cnt, gen, np.int32(J.nblocks)),
                shared_mem=J.threads * J.g.NREG_BYTES)

    t_all = phase(kernel)
    t_kernel = t_all - t_reset - t_seed

    # **リセットと種置きを通してから測る。** そのまま `J.run()` を呼ぶと前の走りの
    # 残りから始まって即停止し、命令数が 6 になる
    _, rep, steps = B.run()
    t_get = phase(lambda: (J._rep.get(), J._steps.get()))
    outs = low.outputs()
    t_out = phase(lambda: [B.read(J, h, r, c) for (h, r, c, d) in outs])

    ins = int(np.max(steps))
    per_stage = len(prog)
    # 共有領域へ書くのは 1 ステージに 2 回（出力の語とフラグの語）。番地は表から読むので
    # 即値では決まらず、静的には数えられない。エンジンの平文から 2 と分かっている
    bar = 2 * len(B.rows)
    if verbose:
        print("%-12s %-6d %-6d %-9d %-9d %-8.2f %-8.2f %-9.2f %-8.2f %-8.2f"
              % (tag, B.lanes, len(B.rows), ins, bar, t_reset, t_seed,
                 t_kernel, t_get, t_out))
    return dict(tag=tag, lanes=B.lanes, rows=len(B.rows), ins=ins, bar=bar,
                reset=t_reset, seed=t_seed, kernel=t_kernel, get=t_get,
                out=t_out, per_stage=per_stage)


def _cases(d=32, k=32):
    torch.manual_seed(11)
    lin = torch.nn.Linear(k, d, bias=False)
    w = torch.randn(d, k) / 8.0
    rn = torch.nn.RMSNorm(k)
    ln = torch.nn.LayerNorm(k)
    x = torch.randn(2, k) / 8.0
    return [
        ("Linear", lambda t: lin(t), x),
        ("SiLU", lambda t: torch.nn.functional.silu(t.matmul(w.t())), x),
        ("RMSNorm", lambda t: rn(t).matmul(w.t()), x),
        ("LayerNorm", lambda t: ln(t).matmul(w.t()), x),
        ("Softmax", lambda t: torch.softmax(t.matmul(w.t()), -1), x),
    ]


def sweep(verbose=True):
    """同じ演算のまま、レーンを増やして 1 命令あたりの時間を見る。

    レーンが少ないと、SM の中のワープが足りず、グローバルメモリの待ち時間が隠れない。
    増やせば 1 命令あたりが下がるはずである。下がらなければ別の原因がある。
    """
    from .. import lane as L
    cap = L.resident()
    torch.manual_seed(11)
    if verbose:
        print("同時に載るレーンの上限 %d\n" % cap)
        print("%-8s %-8s %-7s %-7s %-9s %-11s %-11s"
              % ("列", "レーン", "ブロック", "ステージ", "カーネル ms",
                 "us/ステージ", "ns/命令"))
    got = []
    for k in (32, 128, 512, 2048):
        w = torch.randn(k, k) / float(max(8, k))
        x = torch.randn(1, k) / 8.0
        try:
            g = one("k=%d" % k, lambda t: torch.nn.functional.silu(t.matmul(w.t())),
                    x, reps=3, verbose=False)
            got.append(g)
            if verbose:
                print("%-8d %-8d %-7d %-7d %-9.2f %-11.2f %-11.1f"
                      % (k, g["lanes"], (g["lanes"] + 127) // 128, g["rows"],
                         g["kernel"], g["kernel"] * 1e3 / max(1, g["rows"]),
                         g["kernel"] * 1e6 / max(1, g["ins"])))
        except Exception as e:
            if verbose:
                print("%-8d 落ちた %s: %s" % (k, type(e).__name__, str(e)[:50]))
    return got


def run(verbose=True):
    prog, _ = graph._engine(1)
    if verbose:
        print("エンジン 1 ステージ = %d 命令。共有領域への書き込みは 2（出力とフラグ）"
              % len(prog))
        print("バリアは共有領域へ書くたびに 1 回。時間はミリ秒。\n")
        print("%-12s %-6s %-6s %-9s %-9s %-8s %-8s %-9s %-8s %-8s"
              % ("演算", "レーン", "ステージ", "命令", "バリア", "リセット",
                 "種置き", "カーネル", "rep", "出力"))
    got = []
    for tag, fn, x in _cases():
        try:
            got.append(one(tag, fn, x, verbose=verbose))
        except Exception as e:
            if verbose:
                print("%-12s 落ちた %s: %s"
                      % (tag, type(e).__name__, str(e).split("\n")[0][:50]))
    if verbose and got:
        print("\n1 ステージあたり")
        print("%-12s %-12s %-12s %-12s" % ("演算", "命令/ステージ",
                                           "カーネル us/ステージ", "命令あたり ns"))
        for g in got:
            if g["rows"]:
                print("%-12s %-12.1f %-12.2f %-12.1f"
                      % (g["tag"], float(g["ins"]) / g["rows"],
                         g["kernel"] * 1e3 / g["rows"],
                         g["kernel"] * 1e6 / max(1, g["ins"])))
    return got


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "sweep":
        sweep()
    else:
        run()
