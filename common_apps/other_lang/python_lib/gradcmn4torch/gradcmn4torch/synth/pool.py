# -*- coding: utf-8 -*-
"""問題の集まりを並列に作ってディスクに置く。

手順を乱数で作る → 主作図の平文を commonc で compile する（複数 process）→ 答えを gvcpu の lane でまとめて求める。
手順の長さは 1 … MAX_LEN で一様に選ぶので、短い問題から長い問題まで混ざる。
答えの種類が偏らないように、答えの型ごとの上限と、同じ答えの問題の数の上限を置く。(A, B) によらず一定の答えをもつ
値の型（D、B、Q、X）の問題は使わない。

    python -m gradcmn4torch.synth.pool --count 50000 --out pool.pkl
"""
import argparse
import collections
import os
import pickle
import time

import numpy as np

from .. import assemble, run
from . import problem as pb
from . import syntax

CHUNK = 768


SHARE = {"D": 0.32, "Q": 0.22, "X": 0.08, "B": 0.12, "R": 0.10, "T": 0.08, "P": 0.05, "N": 0.03}      # 答えの型の割合の上限
ACTIVE = "DBQX"
PASSIVE_DROP = 0.8                                                                                      # 値を持たない型の手順を捨てる確率
PER_ANSWER = 3                                                                                          # 同じ答えの問題の数の上限


def candidates(rng, count, longest, final_type):
    """手順を乱数で count 個作る。final_type は (手順 → 答えの型)。"""
    out = []
    while len(out) < count:
        tokens = syntax.random_tokens(rng, int(rng.integers(1, longest + 1)))
        if tokens is None:
            continue
        recipe = syntax.to_recipe(tokens)
        try:
            text = assemble.layered(syntax.to_layers(tokens), recipe, pb.N_LEAF, pb.BITS).text
            final = final_type(recipe)
        except (ValueError, OverflowError):
            continue
        if final not in ACTIVE and rng.random() < PASSIVE_DROP:         # 値を持たない型は、compile の前にほとんど捨てる
            continue
        out.append((tokens, text, int(rng.integers(-12, 13)) / 8, final))
    return out


def _final(recipe):
    return assemble.check(recipe, pb.N_LEAF)[1][0]


def make(count, longest=syntax.MAX_WORDS, seed=0, out=None, log=print):
    """count 個の問題を作る。out があれば途中経過もそこへ書き、あれば続きから作る。
    型ごとの上限に達した型の手順は、実行せずに捨てる。新しい問題が出なくなったら、count に届かなくても止める。"""
    rng = np.random.default_rng(seed)
    problems = []
    if out and os.path.exists(out):
        problems = pickle.load(open(out, "rb"))
        rng = np.random.default_rng(seed + len(problems))
        log("続きから: %d 個" % len(problems))
    seen = {tuple(p["tokens"]) for p in problems}
    per_type = collections.Counter(p["type"] for p in problems)
    per_answer = collections.Counter(p["rows"][:, 2:].round(4).tobytes() for p in problems)
    t0, idle = time.time(), 0
    while len(problems) < count and idle < 40:
        batch = [c for c in candidates(rng, CHUNK, longest, _final)
                 if tuple(c[0]) not in seen and per_type[c[3]] < SHARE.get(c[3], 0) * count]
        run.prepare([c[1] for c in batch])
        before = len(problems)
        for tokens, _, c, final in batch:
            if per_type[final] >= SHARE[final] * count:
                continue
            p = pb.check_and_rows(tokens, c, rng, final)
            if p is None:
                continue
            key = p["rows"][:, 2:].round(4).tobytes()
            if per_answer[key] >= PER_ANSWER:
                continue
            p["tokens"] = tokens
            problems.append(p)
            seen.add(tuple(tokens))
            per_type[final] += 1
            per_answer[key] += 1
        idle = idle + 1 if len(problems) - before < 5 else 0
        log("%d / %d 個  %.0f 秒  %s" % (len(problems), count, time.time() - t0, dict(per_type)))
        if out:
            pickle.dump(problems, open(out + ".tmp", "wb"))
            os.replace(out + ".tmp", out)
    return problems[:count]


def load(path, count, longest=syntax.MAX_WORDS, seed=0):
    """path があれば読み、足りなければ作り足す。返りは (訓練, 保留)。"""
    problems = make(count, longest, seed, path)
    train = [p for p in problems if not pb.held_out(p)]
    test = [p for p in problems if pb.held_out(p)]
    return train, test


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=50000)
    ap.add_argument("--longest", type=int, default=syntax.MAX_WORDS)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    make(a.count, a.longest, a.seed, a.out)
