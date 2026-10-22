# -*- coding: utf-8 -*-
"""層ごとに compile したとき、VRAM が一層ぶんで済むかを測る。

モデル全体を一つの表にすると、その表の共有帯に全部の重みが入る。27B bf16 なら 54 GB。
層ごとなら一度に一層ぶんで足りる。層数を増やして VRAM が増えないことを見る。

    python -m pytorch_cmn.check.vram
"""
import torch

try:
    from .. import host
    from . import ops
except ImportError:
    from pytorch_cmn import host
    from pytorch_cmn.check import ops


def run(verbose=True):
    import cupy as cp
    mp = cp.get_default_memory_pool()
    ids = torch.tensor([[1, 5, 9, 2]])
    if verbose:
        print("%-6s %-10s %-12s %-12s %-12s"
              % ("層", "重み MB", "全体を一表", "層ごと", "層あたり"))
    for layers in (1, 2, 4):
        m = ops.tiny(layers=layers, hidden=128, heads=4, kv=2, inter=256)
        m = m.to(torch.bfloat16)
        wmb = sum(p.numel() for p in m.parameters()) * 2 / 1e6
        # 層ごと
        mp.free_all_blocks()
        got = host.wrap(m, keep=1, verbose=False)
        with torch.no_grad():
            got(ids)
        per = mp.total_bytes() / 1e6
        # 全体を一つの表に
        mp.free_all_blocks()
        m2 = ops.tiny(layers=layers, hidden=128, heads=4, kv=2, inter=256)
        m2 = m2.to(torch.bfloat16)
        whole = None
        try:
            c = torch.compile(m2, backend="common")
            with torch.no_grad():
                c(ids)
            whole = mp.total_bytes() / 1e6
        except Exception as e:
            whole = str(e)[:20]
        if verbose:
            print("%-6d %-10.2f %-12s %-12.1f %-12.1f"
                  % (layers, wmb,
                     ("%.1f" % whole) if isinstance(whole, float) else whole,
                     per, per / layers))
        mp.free_all_blocks()


if __name__ == "__main__":
    run()
