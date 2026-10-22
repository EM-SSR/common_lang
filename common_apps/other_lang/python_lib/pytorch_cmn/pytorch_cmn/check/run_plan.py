# -*- coding: utf-8 -*-
"""段の表を走らせる。一枚なら vcpu、たくさんなら gvcpu の Joint。"""
import os
import sys

from .. import fold
from .. import lane
from .. import walk

SLOT = fold.ROW + 1 << 12         # 枠の置き場（一枚で走らせるとき）
TBL = fold.ROW + 64               # 表の置き場


def once(plan, watch, words=1 << 22, base=None):
    """一枚の lane で走らせる。返りは (報告, ステップ数, 見た枠の値, 段の数, 項の数)。

    置き場は表の長さから決める。表と枠が重なると語を取り違える。
    """
    tab, slots, k = plan.table()
    base = base or (TBL + len(tab) + 64)
    img, need, _ = lane.build(walk.board(k), "plan%d" % k)
    seed = {walk.TAB: TBL, walk.LEFT: len(plan.rows)}
    for i, v in enumerate(slots):
        seed[base + i] = v
    # 「零の在る番地」の枠には、零の枠の番地そのものを入れる
    if plan.zero_at is not None:
        seed[base + plan.zero_at] = base
    for i, v in enumerate(tab):
        seed[TBL + i] = base + v
    rep, steps, got = lane.walk(img, need, seed=seed, words=words,
                                watch=tuple(base + w for w in watch))
    return rep, steps, got, k, len(plan.rows)
