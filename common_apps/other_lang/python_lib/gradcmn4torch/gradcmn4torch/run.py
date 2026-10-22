# -*- coding: utf-8 -*-
"""作図の平文を commonc で機械語(image)にして、vcpu で実行する。

    平文 ──commonc──▶ image ──vcpu──▶ 作業領域の語 0, 1, … （結果のワイヤ）

入力は作業領域の語 2^i に置く。結果の値は 語 / 2^δ で、δ(深度)は assemble が返す。
"""
import atexit
import hashlib
import os
from fractions import Fraction

from common_vcpu import toolchain


BUILD = os.environ.get("GRADCMN4TORCH_BUILD") or os.path.join(
    os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.cache"), "gradcmn4torch", "build")

_IMAGE = {}
_POOL = []


def _compile_text(text):
    try:
        return text, build_file(text)
    except Exception:                       # 平文を commonc が受け付けない。None として覚える
        return text, None


def build_file(text):
    key = hashlib.sha1(text.encode("utf-8")).hexdigest()[:20]
    os.makedirs(BUILD, exist_ok=True)
    src = os.path.join(BUILD, key + ".cmn")
    with open(src, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return toolchain.compile([src], None, os.path.join(BUILD, key + ".bin"))


def prepare(texts, procs=6):
    """まだ compile していない平文を、複数の process でまとめて compile する。"""
    todo = sorted({t for t in texts if hashlib.sha1(t.encode("utf-8")).hexdigest()[:20] not in _IMAGE})
    if not todo:
        return
    if not _POOL:
        import multiprocessing
        _POOL.append(multiprocessing.get_context("spawn").Pool(procs))
        atexit.register(_POOL[0].terminate)
    for text, built in _POOL[0].map(_compile_text, todo, chunksize=max(1, len(todo) // (4 * procs))):
        _IMAGE[hashlib.sha1(text.encode("utf-8")).hexdigest()[:20]] = built


def build(text):
    """平文を compile する。同じ平文は一度しか compile しない。返りは (image, n_need)。"""
    key = hashlib.sha1(text.encode("utf-8")).hexdigest()[:20]
    if key not in _IMAGE:
        _IMAGE[key] = build_file(text)
    if _IMAGE[key] is None:
        raise toolchain.CompileError("commonc が受け付けない平文")
    return _IMAGE[key]


def signed(v):
    v = int(v)
    return v - (1 << 64) if v >= (1 << 63) else v


BUDGET = 1 << 18                # 1 回の実行の命令数の上限。閉包（ya yi）が終わらない手順を止める。
                                # GPU の 1 回の起動が 2 秒を越えると Windows が GPU を再起動するので、約 0.1 秒で止まる値にする

CPU_BLOCKS = 1 << 16            # CPU の vcpu で 1 本を実行するときの block の歩数の上限


def run_one(text, leaves, n_out):
    """入力の値（整数）を置いて 1 本実行し、結果の分子を返す。報告が 0 でない、または予算を越えたら例外を投げる。"""
    from common_vcpu import vcpu

    image, need = build(text)
    tab = toolchain.load(image, need)
    lane = vcpu.Lane(toolchain.WORK + 64)
    for i, v in enumerate(leaves):
        lane.M[1 << i] = int(v)
    if vcpu.run_lane(tab, lane, CPU_BLOCKS) != 0:
        raise RuntimeError("報告 %s" % lane.report)
    return [signed(lane.M[i]) for i in range(n_out)]


def decode(words, depths):
    return [Fraction(w, 1 << d) for w, d in zip(words, depths)]


_LANES = {}


def run_lanes(text, leaves, n_out):
    """同じ image を GPU の lane に並べて実行する（gvcpu）。lane ごとに入力の値が違う。

    leaves は形 (L, 入力の数) の整数の並び、返りは形 (L, n_out) の numpy int64（結果の分子）。
    報告が 0 でない lane があれば例外を投げる。
    """
    import numpy as np
    from common_vcpu import gvcpu, vcpu

    leaves = np.ascontiguousarray(leaves, dtype=np.int64)
    L, nl = leaves.shape
    key = (hashlib.sha1(text.encode("utf-8")).hexdigest(), L, nl)
    if len(_LANES) > 2000:
        _LANES.clear()
    if key not in _LANES:
        image, need = build(text)
        _LANES[key] = gvcpu.Lanes(vcpu.decode(image), need, toolchain.WORK, toolchain.WORK + 64, 0, L)
    lanes = _LANES[key]
    lanes.reset()
    lanes.put(np.repeat(np.arange(L), nl), np.tile(1 << np.arange(nl), L), leaves.reshape(-1).view(np.uint64))
    rep, W = lanes.run(watch=list(range(n_out)), budget=BUDGET)
    if rep.any():
        raise RuntimeError("報告 %s の lane がある" % sorted(set(int(r) for r in rep if r)))
    return W.get()
