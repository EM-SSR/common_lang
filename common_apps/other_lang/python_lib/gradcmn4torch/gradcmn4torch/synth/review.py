# -*- coding: utf-8 -*-
"""学習したモデルの出力を、問題の長さ別・訓練と保留別に評価する。

問題の行で手順と c を出させ、新しい行（48 行）で実行して、答えの語がすべて合ったら一致とする。

    貪欲        最も確からしい手順 1 つの一致率
    pass@N      N 個サンプルして、1 つでも一致した問題の割合
    一致率      サンプルのうち一致した割合
    行だけ      問題の行では一致し、新しい行では外れた割合（行に合わせただけの手順）
    手順の種類  サンプルの中の異なる手順（語と位置の並び）の数の平均
    実行できた  サンプルのうち、答えが出た割合

    python -m gradcmn4torch.synth.review --ckpt build_tools/data/v70.pt --pool-file build_tools/data/pool_v66_use.pkl --pool 3600
"""
import argparse
import collections

import numpy as np
import torch

from . import pool as pool_mod
from . import problem as pb
from . import syntax
from .generate import load_model
from .model import sample
from .train import AMP, REASONS, answer_type, execute, reason

CHUNK = 256


def solve(model, problems, rng, n, greedy, fresh_rows=48):
    """問題ごとに n 個の手順を出させて実行する。返りは問題ごとの (手順, c, 実行できた, 行で一致, 新しい行で一致, 理由) の並び。"""
    dev = next(model.parameters()).device
    out = []
    for lo in range(0, len(problems), max(1, CHUNK // n)):
        part = problems[lo:lo + max(1, CHUNK // n)]
        rows = torch.stack([torch.from_numpy(pb.make_rows(p)) for p in part]).repeat_interleave(n, 0)
        fresh = torch.stack([torch.from_numpy(pb.make_rows(p, rng, fresh_rows)) for p in part]).repeat_interleave(n, 0)
        with torch.no_grad(), torch.autocast(**AMP):
            tokens, _, _ = sample(model, rows.to(dev), greedy=greedy)
            _, mu = model(rows.to(dev), tokens.to(dev))
        c = mu.float().clamp(-2, 2).cpu()
        want = [answer_type(p) for p in part for _ in range(n)]
        on_rows = execute(rows, tokens, c, want)
        on_fresh = execute(fresh, tokens, c, want)
        for k, p in enumerate(part):
            one = []
            for j in range(k * n, (k + 1) * n):
                y, z = on_rows[j], on_fresh[j]
                recipe = syntax.to_recipe(tokens[j].tolist())
                hit_rows = y is not None and bool(((y - rows[j, :, 2:]).abs() < 1e-5).all())
                hit_fresh = z is not None and bool(((z - fresh[j, :, 2:]).abs() < 1e-5).all())
                one.append((tuple(recipe), float(c[j]), y is not None, hit_rows, hit_fresh, reason(recipe, want[j], y)))
            out.append(one)
    return out


def summarize(results, greedy_results):
    """問題の一群の結果を、評価の項目ごとの数にする。"""
    n = len(results)
    flat = [r for one in results for r in one]
    return dict(
        問題数=n,
        貪欲=np.mean([g[0][4] for g in greedy_results]) if n else float("nan"),
        passN=np.mean([any(r[4] for r in one) for one in results]) if n else float("nan"),
        一致率=np.mean([r[4] for r in flat]) if n else float("nan"),
        行だけ=np.mean([r[3] and not r[4] for r in flat]) if n else float("nan"),
        手順の種類=np.mean([len({r[0] for r in one}) for one in results]) if n else float("nan"),
        実行できた=np.mean([r[2] for r in flat]) if n else float("nan"),
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--pool-file", required=True)
    ap.add_argument("--pool", type=int, default=3600)
    ap.add_argument("--n", type=int, default=32, help="問題ごとにサンプルする手順の数")
    ap.add_argument("--max-problems", type=int, default=40, help="長さ・分割ごとに評価する問題の数の上限")
    ap.add_argument("--words", type=int, nargs="+", default=None, help="評価する手順の長さ（語の数）。省くと上限から 1 つ上までの 3 つ")
    ap.add_argument("--examples", type=int, default=8)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default=None, help="結果の置き場（Markdown）")
    a = ap.parse_args()

    train, test = pool_mod.load(a.pool_file, a.pool)
    ck = torch.load(a.ckpt, map_location="cpu", weights_only=False)
    cap, step = ck.get("cap", syntax.MAX_WORDS), ck["step"]
    del ck
    model = load_model(a.ckpt)
    words = a.words or [w for w in range(max(2, cap - 1), min(syntax.MAX_WORDS, cap + 1) + 1)]
    rng = np.random.default_rng(a.seed)
    lines = ["# %s の評価（ステップ %d、長さの上限 %d）" % (a.ckpt, step, cap), "",
             "| 分割 | 語の数 | 問題数 | 貪欲 | pass@%d | 一致率 | 行だけ | 手順の種類 | 実行できた |" % a.n,
             "|---|---|---|---|---|---|---|---|---|"]
    shown, reasons = [], collections.Counter()
    for name, pool in (("訓練", train), ("保留", test)):
        for w in words:
            group = [p for p in pool if len(p["recipe"]) == w]
            group = [group[i] for i in rng.permutation(len(group))[:a.max_problems]]
            if not group:
                lines.append("| %s | %d | 0 | - | - | - | - | - | - |" % (name, w))
                continue
            samples = solve(model, group, rng, a.n, greedy=False)
            greedy = solve(model, group, rng, 1, greedy=True)
            s = summarize(samples, greedy)
            lines.append("| %s | %d | %d | %.3f | %.3f | %.3f | %.3f | %.1f | %.2f |" % (
                name, w, s["問題数"], s["貪欲"], s["passN"], s["一致率"], s["行だけ"], s["手順の種類"], s["実行できた"]))
            if w == words[0]:
                reasons.update(r[5] for one in samples for r in one)
            if name == "訓練" and len(shown) < a.examples:
                for p, one, g in list(zip(group, samples, greedy))[:max(1, a.examples // len(words))]:
                    best = max(one, key=lambda r: (r[4], r[3]))
                    shown.append((name, w, p["recipe"], p["c"], g[0], best))
    lines += ["", "## 実行できなかった理由（語の数 %d のサンプル）" % words[0], ""]
    total = sum(reasons.values())
    lines += ["- %s: %.3f" % (r, reasons[r] / total) for r in REASONS if total]
    lines += ["", "## 例（訓練の問題）", ""]
    for name, w, ref, c, g, best in shown:
        lines += ["- 正解 %s  c=%.3f" % (list(ref), c),
                  "  - 貪欲 %s  c=%.2f  一致=%s" % (list(g[0]), g[1], g[4]),
                  "  - サンプルの最良 %s  c=%.2f  一致=%s  同じ手順=%s" % (list(best[0]), best[1], best[4], best[0] == tuple(ref))]
    text = "\n".join(lines)
    print(text)
    if a.out:
        with open(a.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
