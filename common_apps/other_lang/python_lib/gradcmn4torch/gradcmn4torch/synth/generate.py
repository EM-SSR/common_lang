# -*- coding: utf-8 -*-
"""条件（固定の 16 組の (A, B) に対する答えの語）から、それを満たす .cmn を生成する。

学習した生成器が解法の手順と縮尺 c を出す。それを Common で実行して、条件と厳密に合うものだけを .cmn に書き出す。

    python -m gradcmn4torch.synth.generate --ckpt run1.pt --conditions cond.json --out out_dir

cond.json は {"answers": [[y1, …, y5] を 16 行]}。行の順は problem.PROMPT_AB の (A, B) の順になる。
出力は out_dir/solution_N.cmn と solution_N.json。.cmn は入力 A、B、c を作業領域の語 1、2、4 から読む（値の 8 倍の整数）。
"""
import argparse
import json
import os

import numpy as np
import torch

from .. import assemble
from . import problem as pb
from . import syntax
from .model import Generator, sample
from .train import AMP, execute


def load_model(path, device="cuda"):
    ck = torch.load(path, map_location=device)
    a = ck["args"]
    model = Generator(a["d"], a["heads"], a["layers"], 4 * a["d"], a["context"]).to(device)
    model.load_state_dict(ck["model"])
    return model.eval()


@torch.no_grad()
def generate(model, answers, tries=256):
    """条件に合う (字句の列, c) の並び。answers は形 (16, WIDTH)。"""
    dev = next(model.parameters()).device
    cond = np.concatenate([np.array(pb.PROMPT_AB, dtype=np.float32), np.asarray(answers, dtype=np.float32)], 1)
    rows = torch.from_numpy(cond)[None].repeat(tries, 1, 1)
    with torch.autocast(**AMP):
        tokens, _, _ = sample(model, rows.to(dev))
        _, mu = model(rows.to(dev), tokens.to(dev))
    c = (mu.float().clamp(-2, 2).cpu() * 8).round() / 8                       # c は 1/8 の格子
    ys = execute(rows, tokens, c)
    found = {}
    for t, cc, y in zip(tokens.tolist(), c.tolist(), ys):
        if y is not None and bool(((y - rows[0, :, 2:]).abs() < 1e-5).all()):
            found.setdefault((tuple(t[:t.index(syntax.END)]), cc), None)
    return [(list(t), c_) for (t, c_) in found]


def write(tokens, c, path):
    """生成器が書いた .cmn（入力を読む層を前置したもの）と、c と出口の深度を書く。"""
    layers = syntax.to_layers(tokens)
    built = assemble.layered(layers, syntax.to_recipe(tokens), pb.N_LEAF, pb.BITS)
    with open(path + ".cmn", "w", encoding="utf-8", newline="\n") as f:
        f.write(built.text)
    with open(path + ".json", "w", encoding="utf-8") as f:
        json.dump(dict(program=layers, c=c, inputs={"1": "8 A", "2": "8 B", "4": int(round(c * 8))},
                       exit_depths=built.depths), f, ensure_ascii=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--conditions", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tries", type=int, default=256)
    a = ap.parse_args()
    answers = json.load(open(a.conditions, encoding="utf-8"))["answers"]
    found = generate(load_model(a.ckpt), answers, a.tries)
    os.makedirs(a.out, exist_ok=True)
    for i, (tokens, c) in enumerate(found):
        write(tokens, c, os.path.join(a.out, "solution_%d" % i))
    print("条件に合う解法: %d 個" % len(found))


if __name__ == "__main__":
    main()
