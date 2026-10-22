# -*- coding: utf-8 -*-
"""グラフの node ごとに、素の torch と表の再現を突き合わせる。

どの演算で値が分かれるかを一目で出す。GPU は使わない（`Build.simulate`）。

    python -m pytorch_cmn.check.trace            # 既定は shape の ffn
    python -m pytorch_cmn.check.trace ln         # shape の case 名の先頭で選ぶ
"""
import sys

import numpy as np
import torch

try:
    from .. import backend                      # noqa: F401
    from .. import chamber, graph
    from . import shape as S
except ImportError:
    import pytorch_cmn.backend                  # noqa: F401
    from pytorch_cmn import chamber, graph
    from pytorch_cmn.check import shape as S


def trace(fn, x, verbose=True):
    """node ごとの値を比べて、最初に分かれた node を返す。"""
    seen = {}

    def peek(gm, ex):
        seen["gm"], seen["ex"] = gm, ex
        return gm.forward

    torch.compile(fn, backend=peek, dynamic=False)(x)
    gm, ex = seen["gm"], seen["ex"]
    low = graph.Lower(gm, ex).emit()
    mem, _ = low.B.simulate()
    W = low.B.width

    # 素の torch を一段ずつ走らせて、node ごとの値を控える
    env = {}
    it = iter(ex)
    for n in gm.graph.nodes:
        if n.op == "placeholder":
            env[n] = next(it)
        elif n.op == "get_attr":
            env[n] = getattr(gm, n.target)
        elif n.op == "output":
            continue
        else:
            args = torch.fx.node.map_arg(n.args, lambda a: env[a])
            kw = torch.fx.node.map_arg(n.kwargs, lambda a: env[a])
            tgt = n.target
            if n.op == "call_method":
                tgt = getattr(args[0], n.target)
                args = args[1:]
            env[n] = tgt(*args, **kw)

    if verbose:
        print("%-22s %-12s %-14s %-8s %-8s %-9s"
              % ("node", "演算", "形(torch)", "行×列", "F", "相対の差"))
    first = None
    for n in gm.graph.nodes:
        if n not in low.val or n.op == "output":
            continue
        h, rows, cols, d = low.val[n]
        st = low._stride(cols)
        a = mem[h:h + rows * st].reshape(rows, st)[:, :cols]
        got = np.asarray(a) / float(1 << d)
        want = env.get(n)
        if not hasattr(want, "shape"):
            continue
        wa = np.asarray(want.detach()).reshape(-1)
        gf = got.reshape(-1)
        if gf.size != wa.size:
            err = float("inf")
        else:
            big = max(1.0, float(np.max(np.abs(wa))))
            err = float(np.max(np.abs(gf - wa))) / big
        name = (chamber._name_of(n) if n.op in ("call_function", "call_method")
                else n.op)
        if verbose:
            print("%-22s %-12s %-14s %-8s %-8d %-9s"
                  % (n.name[:22], name[:12], str(tuple(want.shape)),
                     "%dx%d" % (rows, cols), d,
                     "%.3g" % err if err == err else "nan"))
        if first is None and err > 2e-3:
            first = (n.name, name, err)
    if verbose:
        if first:
            print("\n最初に分かれた node: %s（%s）相対の差 %.3g" % first)
        else:
            print("\nどの node も合う")
    return first


def run(pick=None, verbose=True):
    for name, make in S.CASES:
        if pick and not name.strip().startswith(pick):
            continue
        fn, x = make()
        if verbose:
            print("== %s" % name.strip())
        trace(fn, x, verbose=verbose)
        if pick:
            return


if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "ffn")
