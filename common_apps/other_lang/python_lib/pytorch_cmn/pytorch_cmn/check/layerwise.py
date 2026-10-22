# -*- coding: utf-8 -*-
"""層ごとに compile した形で、実機を通して素の torch と突き合わせる。

モデル全体を一つの表にすると共有帯に全部の重みが入る。層ごとなら一度に一層ぶんで
足りる。その形で値が合うかを見る。重みは bf16 のまま。

    python -m pytorch_cmn.check.layerwise
"""
import numpy as np
import torch

try:
    from .. import host
    from . import ops
except ImportError:
    from pytorch_cmn import host
    from pytorch_cmn.check import ops


def run(layers=2, hidden=64, heads=4, kv=2, inter=128, verbose=True):
    ids = torch.tensor([[1, 5, 9, 2]])
    m = ops.tiny(layers=layers, hidden=hidden, heads=heads, kv=kv, inter=inter)
    m = m.to(torch.bfloat16)
    with torch.no_grad():
        want = m(ids).logits.to(torch.float32)
    got = host.wrap(m, keep=2, verbose=verbose)
    with torch.no_grad():
        out = got(ids).logits.to(torch.float32)
    wa = np.asarray(want.reshape(-1))
    gf = np.asarray(out.detach().reshape(-1))
    err = float(np.max(np.abs(gf - wa))) / max(1.0, float(np.max(np.abs(wa))))
    if verbose:
        print("層ごとに compile  logits の相対の差 %.4g" % err)
        print("torch  %s" % np.round(wa[:6], 4))
        print("cmn    %s" % np.round(gf[:6], 4))
    return err


if __name__ == "__main__":
    import sys
    sys.exit(0 if (run() or 0) < 5e-2 else 1)
