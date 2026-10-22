# -*- coding: utf-8 -*-
"""`device="common"` を作る。torch の PrivateUse1 を Python だけで塞ぐ。

重みを torch に確保させると、27B bf16 で 54 GB を torch 側が持つ。置き場を自分で持てば
同じ語を二度持たない。`device="common"` の tensor は中身を `Held.inner` で持ち、
backend はそこから直に読む。

    from pytorch_cmn import device
    device.setup()
    t = torch.empty(4, device="common")
    model = device.move(model)          # `.to("common")` の代わり

`.to("common")` は torch の C++ 側が「not linked」で止めるので使えない。`move()` は
`Module._apply` で同じことをする。
"""
import torch

DEV = None
_READY = [False]


class Held(torch.Tensor):
    """device が common の tensor。中身は `inner` で持つ。"""

    @staticmethod
    def __new__(cls, inner):
        return torch.Tensor._make_wrapper_subclass(
            cls, inner.shape, strides=inner.stride(),
            storage_offset=inner.storage_offset(), dtype=inner.dtype,
            layout=inner.layout, device=DEV, requires_grad=False)

    def __init__(self, inner):
        self.inner = inner

    def __repr__(self):
        return "common%s:%s" % (tuple(self.shape), self.dtype)

    @classmethod
    def __torch_dispatch__(cls, func, types, args=(), kwargs=None):
        """中身へ落として実行し、tensor の返りは包み直す。"""
        kwargs = kwargs or {}
        tree = torch.utils._pytree.tree_map

        def down(x):
            return x.inner if isinstance(x, Held) else x

        name = str(func)
        if name in ("aten.to.Device", "aten._to_copy.default"):
            dev = kwargs.get("device") or (args[1] if len(args) > 1 else None)
            rest = dict((k, v) for k, v in kwargs.items() if k != "device")
            got = func(*tree(down, args), **rest)
            if dev is not None and torch.device(dev).type == "common":
                return Held(down(got))
            return down(got)
        out = func(*tree(down, args), **tree(down, kwargs))
        if isinstance(out, torch.Tensor) and not isinstance(out, Held):
            return Held(out)
        return out


class _Mod(object):
    """torch が device を問い合わせる先。"""

    @staticmethod
    def device_count():
        return 1

    @staticmethod
    def is_available():
        return True

    @staticmethod
    def current_device():
        return 0

    @staticmethod
    def set_device(d):
        pass

    @staticmethod
    def is_initialized():
        return True

    @staticmethod
    def _is_in_bad_fork():
        return False

    @staticmethod
    def manual_seed_all(seed):
        pass


def setup():
    """`device="common"` を使えるようにする。二度呼んでも害は無い。"""
    global DEV
    if _READY[0]:
        return DEV
    torch.utils.rename_privateuse1_backend("common")
    torch._register_device_module("common", _Mod())
    DEV = torch.device("common", 0)
    lib = torch.library.Library("aten", "IMPL", "PrivateUse1")

    def empty(size, *, dtype=None, layout=None, device=None, pin_memory=None,
              memory_format=None):
        return Held(torch.empty(size, dtype=dtype, layout=layout, device="cpu"))

    def empty_strided(size, stride, *, dtype=None, layout=None, device=None,
                      pin_memory=None):
        return Held(torch.empty_strided(size, stride, dtype=dtype, device="cpu"))

    def copy_from(src, dst, non_blocking=False):
        d = dst.inner if isinstance(dst, Held) else dst
        s = src.inner if isinstance(src, Held) else src
        d.copy_(s.to(d.dtype) if s.dtype != d.dtype else s)
        return dst

    lib.impl("empty.memory_format", empty)
    lib.impl("empty_strided", empty_strided)
    lib.impl("_copy_from", copy_from)
    _READY[0] = True
    return DEV


def move(model):
    """モデルを common へ移す。

    `.to("common")` は torch の C++ 側が「not linked」で止めるので、`_apply` で同じ
    ことをする。重みは `Held.inner` が持つので、torch 側に二重に確保されない。
    """
    setup()
    return model._apply(lambda t: t if isinstance(t, Held) else Held(t))


def bare(t):
    """`Held` なら中身を返す。そうでなければそのまま。"""
    return t.inner if isinstance(t, Held) else t
