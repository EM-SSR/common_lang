# -*- coding: utf-8 -*-
"""生の重みを積まずにモデルを開く。`device_map="common"` を受ける。

27B を bf16 で持つと 54 GB になり、VRAM にも RAM にも一度には載らない。載せる必要も
無い。要るのは二つ。

- **重みは safetensors の mmap のまま CPU に置く。** `low_cpu_mem_usage` で torch 側の
  確保を避ける。ページは触った分だけ入る。
- **層ごとに compile する。** モデル全体を一つの表にすると、その表の共有帯に全部の重みが
  入って 54 GB になる。層ごとなら一度に一層ぶん（Qwen 27B で約 0.8 GB）で足りる。
  表は層ごとに持ち、VRAM に残す数を `keep` で抑える。

    from pytorch_cmn import host
    tok, model = host.load("Qwen/Qwen3-27B", device_map="common")

`device_map` は `"common"` `"cpu"` `None` を受ける。`"common"` は「重みは host、計算は
Common」の意味で、torch から見ると CPU の tensor になる。
"""
import collections

_LIVE = collections.OrderedDict()      # 層 → compile 済みの呼び先。VRAM を抑えるため


def _pin(tag, obj, keep):
    """VRAM に残す表の数を抑える。古いものから板を捨てる。"""
    _LIVE[tag] = obj
    _LIVE.move_to_end(tag)
    while len(_LIVE) > keep:
        _, old = _LIVE.popitem(last=False)
        low = getattr(getattr(old, "_cmn", None), "low", None)
        if low is not None:
            low.close()


def wrap(model, keep=2, verbose=True):
    """decoder の層ごとに backend を差す。

    モデル全体を一つの graph にすると、共有帯に全部の重みが入る。層ごとなら一度に
    一層ぶんで足りる。`keep` は VRAM に残す層の数。
    """
    import torch
    from . import backend  # noqa: F401  登録のために import する

    layers = None
    for path in ("model.layers", "transformer.h", "model.decoder.layers"):
        got = model
        for part in path.split("."):
            got = getattr(got, part, None)
            if got is None:
                break
        if got is not None:
            layers = got
            break
    if layers is None:
        if verbose:
            print("層が見つからないので、モデル全体を一つの表にします")
        return torch.compile(model, backend="common")
    backend.keep_boards(keep)
    for i in range(len(layers)):
        layers[i] = torch.compile(layers[i], backend="common")
    if verbose:
        print("%d 層をそれぞれ表にしました（VRAM に残すのは %d 層）" % (len(layers), keep))
    return model


def load(model_dir, device_map="common", keep=2, compile_layers=True, verbose=True):
    """重みを mmap のまま開き、層ごとに backend を差す。"""
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    if device_map not in ("common", "cpu", None):
        raise ValueError("device_map は common か cpu か None。%r は受けません" % device_map)
    tok = AutoTokenizer.from_pretrained(model_dir)
    # **bf16 のまま開く。** float32 へ上げると倍になる。`low_cpu_mem_usage` で
    # torch 側の確保を避け、safetensors の mmap をそのまま使う
    model = AutoModelForCausalLM.from_pretrained(
        model_dir, dtype=torch.bfloat16, low_cpu_mem_usage=True, device_map=None)
    model.eval()
    if verbose:
        n = sum(p.numel() for p in model.parameters())
        print("重み %.2f G 個 = bf16 で %.1f GB（mmap のまま、VRAM は使わない）"
              % (n / 1e9, n * 2 / 1e9))
    if compile_layers:
        model = wrap(model, keep=keep, verbose=verbose)
    return tok, model
