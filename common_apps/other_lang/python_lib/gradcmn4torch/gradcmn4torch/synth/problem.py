# -*- coding: utf-8 -*-
"""点の作図の問題を作る。

直線上の 3 つの値 (A, B, c) が最初のワイヤにある。c は連続な量で、縮尺として使う。
解法は生成器が書く .cmn（syntax.py の字句の列）で、終わりに残る 1 本のワイヤが答えになる。
答えの型は D、B、R、P、T、N、Q、X のどれでもよく、出口の語（最大 WIDTH 語）が答えの値になる。

    問題 = 固定の 16 組の (A, B) に対する答えの語
    解法 = .cmn と、縮尺 c の値

答えは Common の実行で求める。
"""
import zlib

import numpy as np
from common_vcpu import toolchain

from .. import assemble, run
from .syntax import N_LEAF, to_layers, to_recipe

BITS = 3            # 入力は 1/8 の格子に丸める
WIDTH = 5           # 答えの語の数の上限
PROMPT_AB = [(-2, -1), (-1, 2), (0, 1), (1, -2), (2, 3), (3, 0), (-3, 2), (1, 1),
             (-3, -3), (0, 0), (2, -1), (-1, -2), (3, 3), (1, 0), (-2, 3), (2, 2)]        # 問題文の (A, B)
ROWS = len(PROMPT_AB)
PROBE = [(-2, 1), (1, 3), (2, -3), (3, 3), (0, 2)]                  # 保留の判定に使う行


def program(tokens):
    """字句の列から、(手順, 層の並び)。"""
    return to_recipe(tokens), to_layers(tokens)


def answers(problem, ab):
    """問題の解法を Common で実行して、(A, B) の各組に対する答えの語 (行, WIDTH) を返す。"""
    built = assemble.layered(to_layers(problem["tokens"]), problem["recipe"], N_LEAF, BITS)
    leaves = np.array([[a, b, problem["c"]] for a, b in ab]) * (1 << BITS)
    out = run.run_lanes(built.text, np.rint(leaves).astype(np.int64), len(built.depths))
    words = out.astype(np.float64) / np.array([2.0 ** x for x in built.depths])
    if words.shape[1] > WIDTH:
        raise ValueError("答えの語が多すぎる")
    return np.pad(words, ((0, 0), (0, WIDTH - words.shape[1])))


def check_and_rows(tokens, c, rng, final=None):
    """手順が使える問題か確かめ、問題文の行（答えの語つき）と保留の印を返す。使えなければ None。

    問題文の行、保留の判定に使う行、新しい行での実行確認を、1 回の実行にまとめる。"""
    problem = dict(c=c, tokens=tokens, recipe=to_recipe(tokens))
    if any(w in ("me", "di") for w, _ in problem["recipe"]):
        return None                                         # me は出口を書かずに閉じ、di は失敗する。答えを出さない
    extra = [(int(rng.integers(-3, 4)), int(rng.integers(-3, 4))) for _ in range(32)]      # 新しい行でも実行できる
    try:
        y_all = answers(problem, PROMPT_AB + PROBE + extra)
    except (ValueError, OverflowError, RuntimeError, toolchain.CompileError):
        return None
    y = y_all[:ROWS]
    if np.abs(y_all).max() > 300:
        return None                                         # 値が大きすぎる
    if final in ("D", "B", "Q", "X") and np.ptp(y, axis=0).max() == 0:
        return None                                         # 値を持つ型の答えが (A, B) によらず一定の問題は使わない
    probe = y_all[ROWS:ROWS + len(PROBE)]
    problem["rows"] = np.concatenate([np.array(PROMPT_AB, dtype=np.float64), y], 1).astype(np.float32)
    problem["type"] = final
    problem["held"] = zlib.crc32(repr(np.round(probe, 4).tolist()).encode()) % 8 == 0
    return problem


def make_rows(problem, rng=None, count=ROWS):
    """問題の行 (count, 2 + WIDTH) = (A, B, 答えの語)。rng がなければ問題文の固定の (A, B)（保存した行）。"""
    if rng is None and "rows" in problem:
        return problem["rows"]
    ab = PROMPT_AB if rng is None else [(int(rng.integers(-3, 4)), int(rng.integers(-3, 4))) for _ in range(count)]
    return np.concatenate([np.array(ab, dtype=np.float64), answers(problem, ab)], 1).astype(np.float32)




def held_out(problem):
    """解法が表す関数の特徴で、問題を訓練と保留に分ける（約 1/8 が保留）。"""
    if "held" in problem:
        return problem["held"]
    y = answers(problem, PROBE)
    return zlib.crc32(repr(np.round(y, 4).tolist()).encode()) % 8 == 0
