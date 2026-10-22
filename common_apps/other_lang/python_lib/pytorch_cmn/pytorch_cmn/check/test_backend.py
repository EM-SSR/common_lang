# -*- coding: utf-8 -*-
"""backend の突き合わせ。intent の平文を compile して、PyTorch と同じ値が出るか見る。

    python check/test_backend.py

三つ見る。
  1. intent の語が音節へ開いて compile できる
  2. 要素ごとの演算が eager と一致する
  3. 列の内積が整数として厳密に一致する（cupy がある時だけ）
"""
import os
import sys


import numpy as np       # noqa: E402
from .. import lane
from .. import fold

FAIL = []


def say(name, ok, note=""):
    print("%-34s %s %s" % (name, "通り" if ok else "違い", note))
    if not ok:
        FAIL.append(name)


def intent_opens():
    """語が一つずつ音節へ開くか。定数は畳まれて消えるはず。"""
    lex = lane.lexicon()
    for need in ("unit", "zero", "read", "keep", "ext", "acc", "close", "rung"):
        if need not in lex:
            say("intent に %s が無い" % need, False)
            return
    img, need, plain = lane.build("unit\nrung\nrung\nread\nclose\nunit\nkeep\nsaid\n", "chk_open")
    rep, steps, w = lane.walk(img, need, seed={4: 7}, watch=(1,))
    say("intent が開く", rep == 0 and w[0] == 1, "ge(7) = ω = 1、%d 歩" % steps)


def elementwise():
    """fx.Graph 一枚を通して eager と突き合わせる。"""
    try:
        import torch

        from .. import backend  # noqa: F401  登録のために import する
    except Exception as e:
        say("要素ごとの演算", False, "torch が無い: %s" % e)
        return
    x = torch.tensor([0.5, 0.25, 1.0, -0.5])
    y = torch.tensor([2.0, 4.0, 0.5, 2.0])
    cases = [("x*y+x", lambda a, b: a * b + a),
             ("x-y", lambda a, b: a - b),
             ("-(x*y)", lambda a, b: -(a * b)),
             ("x<=y", lambda a, b: (a <= b).to(torch.float32)),
             ("(x*y-x)*(x<=y)", lambda a, b: (a * b - a) * (a <= b).to(torch.float32))]
    worst = 0.0
    for name, f in cases:
        try:
            g = torch.compile(f, backend="common", fullgraph=True)
            d = float((f(x, y).double() - g(x, y).double()).abs().max())
        except Exception as e:
            say("要素ごと %s" % name, False, "%s" % type(e).__name__)
            return
        worst = max(worst, d)
    say("要素ごとの演算 5 種", worst == 0.0, "差の最大 %.1e" % worst)


def column_fold():
    """一語に出力を詰めた内積。整数なので厳密に一致する。"""
    try:
        import cupy as cp
        from common_vcpu import gvcpu
        from common_vcpu import vcpu
    except Exception as e:
        say("列の内積", True, "cupy が無いので飛ばす（%s）" % type(e).__name__)
        return
    K, d, LANES = 8, 1, 1 << 16
    C = 1 << d
    B = 1 + int(np.ceil(np.log2(K * (1 << (d + 1)) * (1 << d))))
    n = 63 // B
    img, need, _ = lane.build(fold.text(K, fold.OUT + 1), "chk_fold")
    prog = lane.tighten(gvcpu.fold(vcpu.decode(img), wires=(64, need)), need)
    rng = np.random.default_rng(7)
    W = rng.integers(-C, C, size=(LANES * n, K), dtype=np.int64)
    x = rng.integers(0, 1 << d, size=(K,), dtype=np.int64)
    packed = np.zeros((LANES, K), dtype=np.int64)
    for j in range(n):
        packed |= (W[j::n][:LANES] + C) << (j * B)
    xb = fold.OUT + 1
    L = gvcpu.Lanes(prog, need, fold.ROW, xb, K + LANES * K, LANES, sync=False)
    L.rom_put(0, x.astype(np.uint64))
    L.rom_put(K, packed.reshape(-1).astype(np.uint64))
    L.put_block(fold.ROW, (xb + K + np.arange(LANES, dtype=np.int64) * K)
                .astype(np.uint64).reshape(1, LANES))
    L.run()
    got = L.get_block(fold.OUT, 1).reshape(-1).get().astype(np.int64)
    shift = C * int(x.sum())
    dig = np.stack([((got >> (j * B)) & ((1 << B) - 1)) - shift for j in range(n)], axis=1)
    want = np.stack([W[j::n][:LANES] @ x for j in range(n)], axis=1)
    bad = int(np.count_nonzero(dig != want))
    say("列の内積 %d lane × %d 項" % (LANES, K), bad == 0,
        "一語に %d 本、食い違い %d" % (n, bad))


def run():
    """全部見て、落ちた名前の並びを返す。"""
    del FAIL[:]
    intent_opens()
    elementwise()
    column_fold()
    return list(FAIL)


if __name__ == "__main__":
    bad = run()
    print()
    if bad:
        print("違いが出た: %s" % ", ".join(bad))
        sys.exit(1)
    print("全部通りました")
