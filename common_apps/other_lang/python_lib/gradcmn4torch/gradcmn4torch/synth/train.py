# -*- coding: utf-8 -*-
"""生成器の学習。教師の解法は使わない。学習の信号は Common の作図が出す二つだけ。

    J_sem    縮尺 c への勾配。解法を GPU で実行した結果 y と ∂y/∂c を、手書きの局所微分箱の列が出す（式 7.1）
    J_choice 字句の選択への勾配。(R − b) E_T を Eligibility Trace の作図が出す（式 6.9）

    J_total = J_sem + β J_choice

問題は pool.py が並列に作ってディスクに置く。モデルの大きさ、バッチ、問題の長さは引数で決める。

使い方:  build_tools/venv/Scripts/python.exe -u -m gradcmn4torch.synth.train --pool-file build_tools/data/pool_v66_use.pkl --pool 3600 --d 1024 --heads 16 --layers 16 --problems 24 --samples 16 --recompute --vram 0.8 --context 1024 --steps 10800 --advance 0.25 --eval-every 100 --save-every 500 --save build_tools/data/v70.pt --logdir build_tools/runs/v70 2>&1 | tee build_tools/logs/v70.log
"""

import argparse
import collections
import math
import os
import time

import numpy as np
import torch
from torch.utils.tensorboard import SummaryWriter

from .. import torch_fn, trace
from ..torch_fn import choice_loss
from . import pool as pool_mod
from . import problem as pb
from . import syntax
from .model import Generator, T, sample

AMP = dict(device_type="cuda", dtype=torch.bfloat16)


def execute(rows, tokens, c, want=None):
    """各サンプルの手順を束ねて実行する。返りは答えの語 (L, WIDTH) のリスト。実行できない手順は None。
    want は問題ごとの正解の型。答えが手順だけで決まる型は、型が正解と同じ手順だけを実行する。"""
    recipes = [syntax.to_recipe(t.tolist()) for t in tokens]
    xs = [torch.cat([rows[i, :, :2].double(), c[i].double().expand(rows.shape[1])[:, None]], 1) for i in range(len(recipes))]
    return [None if y is None else torch.nn.functional.pad(y, (0, pb.WIDTH - y.shape[1])).float()
            for y in torch_fn.evaluate(recipes, xs, pb.BITS, want)]


REASONS = ["実行できた", "me/di を含む", "手順を作れない", "答えの型が正解と違い値を持たない", "実行失敗（番地・予算・割り算・上限）"]


def reason(recipe, want, y):
    """サンプルが実行できなかった理由。実行できたなら先頭の語。"""
    if y is not None:
        return REASONS[0]
    if any(w in ("me", "di") for w, _ in recipe):
        return REASONS[1]
    plan = torch_fn.plan(tuple(map(tuple, recipe)), pb.N_LEAF, pb.BITS)
    if plan is None:
        return REASONS[2]
    if plan[0] not in torch_fn.ACTIVE_WORDS and plan[0] != want:
        return REASONS[3]
    return REASONS[4]


def evaluate(model, problems, rng, count=48):
    """最も確からしい解法で、新しい行に対して解けた割合。新しい行で正解が実行できない問題は数えない。"""
    fresh, kept = [], []
    for p in problems:
        try:
            fresh.append(torch.from_numpy(pb.make_rows(p, rng, count)))
            kept.append(p)
        except RuntimeError:
            pass
    model.eval()
    dev = next(model.parameters()).device
    rows = torch.stack([torch.from_numpy(pb.make_rows(p)) for p in kept]).to(dev)
    with torch.no_grad(), torch.autocast(**AMP):
        tokens, masks, valid = sample(model, rows, greedy=True)
        _, mu = model(rows, tokens.to(dev))
    fresh = torch.stack(fresh)
    ys = execute(fresh, tokens, mu.float().clamp(-2, 2).cpu(), [answer_type(p) for p in kept])
    ok = [y is not None and bool(((y.detach() - fresh[i, :, 2:]).abs() < 1e-5).all()) for i, y in enumerate(ys)]
    model.train()
    return float(np.mean(ok)) if ok else float("nan")


def answer_type(problem):
    """問題の正解の型。"""
    return torch_fn.final_type(problem["recipe"], pb.N_LEAF)


def explained(y, target):
    """語ごとの相関の二乗の平均（行の方向に取る）。正解が行によらず一定の語は数えない。定数を出す手順は 0 になる。"""
    t = target - target.mean(0)
    u = y - y.mean(0)
    var_t, var_u = (t * t).sum(0), (u * u).sum(0)
    live = var_t > 1e-9
    if not live.any():
        return torch.zeros(())
    r2 = (t * u).sum(0) ** 2 / (var_t * var_u).clamp_min(1e-12)
    return (r2 * (var_u > 1e-9))[live].mean()


def replay_loss(model, found, train, rng, count, dev):
    """誤差 0 だった手順を、そのまま選ぶ確率を上げる損失。found は (問題の番号, 字句の列) → c。
    字句ごとの −log p（文法が許した字句の中での確率）と、c への二乗誤差の和。"""
    keys = [list(found)[i] for i in rng.integers(0, len(found), min(count, len(found)))]
    rows = torch.stack([torch.from_numpy(pb.make_rows(train[i])) for i, _ in keys]).to(dev)
    tokens = torch.tensor([t for _, t in keys], device=dev)
    allowed = torch.from_numpy(syntax.masks_of(tokens.cpu().numpy())).to(dev)
    with torch.autocast(**AMP):
        logits, mu = model(rows, tokens)
    logp = torch.log_softmax(logits.float().masked_fill(~allowed, -1e9), -1).gather(-1, tokens[..., None]).squeeze(-1)
    live = (tokens != syntax.PAD).float()
    c = torch.tensor([found[k] for k in keys], device=dev)
    return -(logp * live).sum() / live.sum() + ((mu.float() - c) ** 2).mean()


def learning_rate(step, a):
    warm = min(1.0, step / a.warmup)
    cos = 0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * min(1.0, step / a.steps)))
    return a.lr * warm * cos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=3000)
    ap.add_argument("--problems", type=int, default=128, help="1 ステップで使う問題の数")
    ap.add_argument("--samples", type=int, default=8, help="問題ごとに生成する解法の数")
    ap.add_argument("--beta", type=float, default=1.0)
    ap.add_argument("--lr", type=float, default=1e-5)
    ap.add_argument("--warmup", type=int, default=200)
    ap.add_argument("--d", type=int, default=1024)
    ap.add_argument("--heads", type=int, default=16)
    ap.add_argument("--layers", type=int, default=12)
    ap.add_argument("--recompute", action="store_true", help="層ごとの途中結果を持たず、逆伝播で計算し直す")
    ap.add_argument("--vram", type=float, default=0.85, help="torch が使える GPU メモリの割合。超えると溢れずに止まる")
    ap.add_argument("--context", type=int, default=128, help="復号器が読める字句の最大数")
    ap.add_argument("--sigma", type=float, default=0.0)
    ap.add_argument("--pool-file", required=True, help="問題の置き場。無ければ作る")
    ap.add_argument("--pool", type=int, default=60000, help="作る問題の数")
    ap.add_argument("--longest", type=int, default=syntax.MAX_WORDS, help="問題の語の数の上限")
    ap.add_argument("--sharp", type=float, default=4.0, help="報酬 exp(−sharp · 誤差) の鋭さ。大きいほど一致に近いものだけが報われる")
    ap.add_argument("--replay", type=float, default=0.5,
                    help="方策が自分で見つけた、誤差 0 の手順を繰り返し学習する損失の重み。0 なら使わない")
    ap.add_argument("--replay-batch", type=int, default=64)
    ap.add_argument("--entropy", type=float, default=0.1, help="選択の分布のエントロピーに掛ける係数")
    ap.add_argument("--advance", type=float, default=0.0,
                    help="0 でなければ、手順の長さの上限を 2 から始めて、直近の完全一致率がこの値を越えるたびに 1 ずつ上げる")
    ap.add_argument("--save", default=None, help="チェックポイントの置き場。あれば続きから学習する")
    ap.add_argument("--save-every", type=int, default=100)
    ap.add_argument("--report", type=int, default=0, help="終わりに、先頭の問題 N 個の正解と生成した解法を表示する")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--logdir", default=None, help="TensorBoard の記録の置き場")
    ap.add_argument("--log-file", default=None, help="文字のログの置き場（UTF-8、続きから学習するときは追記する）")
    ap.add_argument("--eval-every", type=int, default=100)
    ap.add_argument("--eval-size", type=int, default=256)
    a = ap.parse_args()

    name = os.path.splitext(os.path.basename(a.save or "run"))[0]
    logfile = open(a.log_file or "build_tools/logs/%s.log" % name, "a", encoding="utf-8", newline="\n")

    def say(text):
        print(text, flush=True)
        logfile.write(text + "\n")
        logfile.flush()

    rng = np.random.default_rng(a.seed)
    torch.manual_seed(a.seed)
    train, test = pool_mod.load(a.pool_file, a.pool, a.longest, a.seed)
    say("問題 訓練 %d 保留 %d" % (len(train), len(test)))
    dev = torch.device("cuda")
    torch.cuda.set_per_process_memory_fraction(a.vram)               # 共有メモリへ溢れさせない
    import cupy
    cupy.get_default_memory_pool().set_limit(size=3 << 29)            # 箱の lane の領域は 1.5 GB まで
    model = Generator(a.d, a.heads, a.layers, 4 * a.d, a.context, a.recompute).to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=0.01)
    say("パラメータ %.0f M" % (sum(p.numel() for p in model.parameters()) / 1e6))
    first = 1
    cap, recent = (2 if a.advance else syntax.MAX_WORDS), []
    found = {}                                                 # (問題の番号, 字句の列) → 誤差 0 だったときの c
    if a.save and os.path.exists(a.save):
        ck = torch.load(a.save, map_location=dev, weights_only=False)
        model.load_state_dict(ck["model"])
        opt.load_state_dict(ck["opt"])
        first, cap, recent = ck["step"] + 1, ck.get("cap", cap), ck.get("recent", [])
        found = {(i, tuple(t)): c for i, t, c in ck.get("found", [])}              # 古い形式のチェックポイントには無い
        if "rng" in ck:
            rng.bit_generator.state = ck["rng"]
            torch.set_rng_state(ck["torch_rng"].cpu())
            torch.cuda.set_rng_state(ck["cuda_rng"].cpu())
        say("続きから: ステップ %d  長さの上限 %d  誤差 0 の手順 %d 個" % (first, cap, len(found)))
    K = a.samples
    log = SummaryWriter(a.logdir or "build_tools/runs/" + name)
    log.add_text("引数", str(vars(a)))
    length = np.array([len(p["recipe"]) for p in train])
    for step in range(first, a.steps + 1):
        t0 = time.time()
        for g in opt.param_groups:
            g["lr"] = learning_rate(step, a)
        usable = np.flatnonzero(length <= cap)
        idx = usable[rng.integers(0, len(usable), size=a.problems)]
        rows = torch.stack([torch.from_numpy(pb.make_rows(train[i])) for i in idx]).repeat_interleave(K, 0)
        with torch.autocast(**AMP):
            tokens, masks, valid = sample(model, rows.to(dev))
        t1 = time.time()
        with torch.autocast(**AMP):
            logits, mu = model(rows.to(dev), tokens.to(dev))
        logits, mu = logits.float(), mu.float()
        c = mu.clamp(-2, 2) + a.sigma * torch.randn_like(mu)
        ys = execute(rows, tokens, c.cpu(), [answer_type(train[i]) for i in idx for _ in range(K)])
        t2 = time.time()
        wants = [answer_type(train[i]) for i in idx for _ in range(K)]
        why = collections.Counter(reason(syntax.to_recipe(t.tolist()), w, y) for t, w, y in zip(tokens, wants, ys))
        loss_i = torch.stack([((y - rows[i, :, 2:]) ** 2).mean() if y is not None else torch.tensor(25.0)
                              for i, y in enumerate(ys)])
        has = torch.tensor([y is not None for y in ys])
        hit = torch.stack([((y - rows[i, :, 2:]).abs() < 1e-5).all(-1).float().mean() if y is not None else torch.zeros(())
                           for i, y in enumerate(ys)])                                         # 5 語すべてが合った行の割合
        r2 = torch.stack([explained(y.detach(), rows[i, :, 2:]) if y is not None else torch.zeros(()) for i, y in enumerate(ys)])
        reward = torch.where(has, 0.5 * r2 + torch.exp(-a.sharp * loss_i.detach()) + 0.5 * hit + (loss_i.detach() < 1e-9).float(), torch.zeros(()))
        total = torch.zeros((), device=dev)
        sem = torch.log1p(loss_i)[has].mean() if has.any() else torch.zeros(())
        total = total + sem.to(dev)
        R = reward.view(-1, K)
        adv = (R - (R.sum(1, keepdim=True) - R) / (K - 1))
        adv = (adv / (R.std(1, keepdim=True) + 0.1)).reshape(-1)
        p = torch.softmax(logits.detach().double().masked_fill(~masks.to(dev), -1e9), -1).cpu()
        onehot = torch.zeros_like(p)
        n_i, t_i = np.nonzero(valid.numpy())
        onehot[n_i, t_i, tokens.numpy()[n_i, t_i]] = 1
        E = (trace.eligibility(onehot, p).float() * valid[:, :, None]).to(dev)
        total = total + a.beta * choice_loss(logits, E, adv.to(dev))
        logp = torch.log_softmax(logits.masked_fill(~masks.to(dev), -1e9), -1)
        ent = -(logp.exp() * logp).sum(-1)[valid.to(dev)].mean()
        total = total - a.entropy * ent
        for k in np.flatnonzero((loss_i < 1e-9).numpy() & has.numpy()):
            found.setdefault((int(idx[k // K]), tuple(tokens[k].tolist())), float(torch.round(c[k] * 8) / 8))
        replay = torch.zeros(())
        if a.replay and found:
            replay = replay_loss(model, found, train, rng, a.replay_batch, dev)
            total = total + a.replay * replay
        opt.zero_grad()
        total.backward()
        norm = torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        exact = float((loss_i < 1e-9).float().mean())
        recent = (recent + [exact])[-20:]
        if a.advance and len(recent) == 20 and np.mean(recent) >= a.advance and cap < syntax.MAX_WORDS:
            cap, recent = cap + 1, []
        log.add_scalar("長さの上限", cap, step)
        log.add_scalar("自分で見つけた誤差 0 の手順/数", len(found), step)
        log.add_scalar("自分で見つけた誤差 0 の手順/損失", float(replay), step)
        log.add_scalar("報酬/完全一致の割合", exact, step)
        line = "step %5d  長さ ≤ %2d  報酬 %.3f  実行できた %.2f  エントロピー %.2f  勾配の大きさ %.2f  %.1f 秒（生成 %.1f 実行 %.1f 更新 %.1f）  VRAM %.1f GB" % (
            step, cap, reward.mean(), has.float().mean(), float(ent), norm, time.time() - t0, t1 - t0, t2 - t1, time.time() - t2,
            torch.cuda.max_memory_allocated() / 2 ** 30)
        line += "  誤差 0 の手順 %d 個" % len(found)
        line += "  理由 " + " ".join("%s %.2f" % (r[:6], why[r] / len(ys)) for r in REASONS)
        log.add_scalar("報酬/平均", float(reward.mean()), step)
        log.add_scalar("報酬/実行できた割合", float(has.float().mean()), step)
        log.add_scalar("報酬/説明した割合 R2", float(r2.mean()), step)
        log.add_scalar("報酬/一致した割合", float((loss_i < 1e-9).float().mean()), step)
        log.add_scalar("方策/エントロピー", float(ent), step)
        log.add_scalar("方策/勾配の大きさ", float(norm), step)
        log.add_scalar("方策/学習率", opt.param_groups[0]["lr"], step)
        log.add_scalar("損失/J_sem", float(sem), step)
        log.add_scalar("時間/1 ステップ", time.time() - t0, step)
        log.add_scalar("時間/生成", t1 - t0, step)
        log.add_scalar("時間/実行", t2 - t1, step)
        log.add_scalar("VRAM/最大 GB", torch.cuda.max_memory_allocated() / 2 ** 30, step)
        for r in REASONS:
            log.add_scalar("実行できなかった理由/" + r, why[r] / len(ys), step)
        if step % a.eval_every == 0 or step == a.steps:
            tr = evaluate(model, [train[i] for i in usable[rng.integers(0, len(usable), a.eval_size)]], rng)
            te = evaluate(model, [p for p in test if len(p["recipe"]) <= cap][:a.eval_size], rng)
            line += "  解けた割合 訓練 %.3f 保留 %.3f" % (tr, te)
            log.add_scalar("解けた割合/訓練", tr, step)
            log.add_scalar("解けた割合/保留", te, step)
        log.flush()
        say(line)
        if a.save and (step % a.save_every == 0 or step == a.steps):
            torch.save(dict(model=model.state_dict(), opt=opt.state_dict(), step=step, cap=cap, recent=recent,
                            found=[(i, list(t), c) for (i, t), c in found.items()], rng=rng.bit_generator.state,
                            torch_rng=torch.get_rng_state(), cuda_rng=torch.cuda.get_rng_state(), args=vars(a)), a.save + ".tmp")
            os.replace(a.save + ".tmp", a.save)

    for p in train[:a.report]:
        rows = torch.from_numpy(pb.make_rows(p))[None].to(dev)
        with torch.no_grad(), torch.autocast(**AMP):
            tokens, _, _ = sample(model, rows.repeat(8, 1, 1))
            _, mu = model(rows.repeat(8, 1, 1), tokens.to(dev))
        print("正解", p["recipe"], "c =", p["c"])
        for t_, m_ in list(zip(tokens.tolist(), mu.float().tolist()))[:4]:
            print("   生成", syntax.to_recipe(t_), "c = %.2f" % m_)


if __name__ == "__main__":
    main()
