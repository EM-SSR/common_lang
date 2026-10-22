# -*- coding: utf-8 -*-
"""backend としての境界を固定するテスト。

演算 1 つが正しいことは `ops.py` が見る。ここが見るのは**合成の層**で、次の 5 つが
静かに値を壊しうる所になる。

| 見るもの | 壊れ方 |
|---|---|
| 定数の引数 | `x * 2 + 1` の `2` と `1` が落ちる（`all_input_nodes` は Node だけ） |
| 積を重ねたときの桁 | F が積のたびに倍になり、64 bit を越えて 0 になる |
| broadcast | `(2,3)+(3,)` や `(2,1)+(1,3)` が通らない |
| 出力の shape と dtype | 入力から決め打ちすると `reshape` と bool で外れる |
| 複数出力 | 1 つ目に潰れる |

同じ形の tensor どうしだけを試しても、この 5 つは 1 つも見つからない。
"""
import torch

CASES = [
    # 名前, 関数, 入力
    ("scalar",       lambda x: x * 2 + 1,
     [torch.tensor([0.5, -0.25, 1.0, 0.125])]),
    ("mul_depth",    lambda x, y: (((((x * y) * y) * y) * y) * y),
     [torch.tensor([1.0, 0.5, -1.0, 0.25]), torch.tensor([0.5, 1.0, 0.5, 1.0])]),
    ("broadcast_1",  lambda x, y: x + y,
     [torch.tensor([[0.5, -0.25, 1.0], [0.125, 0.75, -0.5]]),
      torch.tensor([0.25, 0.5, -1.0])]),
    ("broadcast_2",  lambda x, y: x + y,
     [torch.tensor([[0.5], [-0.25]]), torch.tensor([[0.25, 0.5, -1.0]])]),
    ("reshape",      lambda x: x.reshape(2, 2),
     [torch.tensor([0.5, -0.25, 1.0, 0.125])]),
    ("bool_output",  lambda x, y: x <= y,
     [torch.tensor([0.5, -0.25, 1.0, 0.125]), torch.tensor([0.25, 0.5, 1.0, -0.5])]),
    ("multi_output", lambda x, y: (x + y, x - y),
     [torch.tensor([0.5, -0.25, 1.0, 0.125]), torch.tensor([0.25, 0.5, -1.0, 0.75])]),
]


def _same(a, b):
    """形・dtype・値がそろって一致するか。"""
    if isinstance(a, (tuple, list)) != isinstance(b, (tuple, list)):
        return False, "片方だけ tuple"
    if isinstance(a, (tuple, list)):
        if len(a) != len(b):
            return False, "出力の数が %d と %d" % (len(a), len(b))
        for x, y in zip(a, b):
            ok, why = _same(x, y)
            if not ok:
                return ok, why
        return True, ""
    if tuple(a.shape) != tuple(b.shape):
        return False, "形が %s と %s" % (tuple(a.shape), tuple(b.shape))
    if a.dtype != b.dtype:
        return False, "dtype が %s と %s" % (a.dtype, b.dtype)
    if a.dtype == torch.bool:
        return bool((a == b).all()), "値が違う"
    d = float((a.double() - b.double()).abs().max())
    return d == 0.0, "差の最大 %.3e" % d


def run(verbose=True):
    """全部の境界を見る。返りは (通った数, 落ちた名前の並び)。"""
    from .. import backend  # noqa: F401  登録のために import する
    ok, bad = 0, []
    for name, fn, args in CASES:
        want = fn(*args)
        try:
            got = torch.compile(fn, backend="common", fullgraph=True, dynamic=False)(*args)
        except Exception as e:
            bad.append(name)
            if verbose:
                print("%-14s 落ちた  %s: %s" % (name, type(e).__name__, str(e).splitlines()[0][:70]))
            continue
        same, why = _same(want, got)
        if same:
            ok += 1
            if verbose:
                print("%-14s 通る" % name)
        else:
            bad.append(name)
            if verbose:
                print("%-14s 違う  %s" % (name, why))
    # nn.Linear は内積が要るので、レーンを出力の要素に取る道を通る。
    # 固定小数なので差は 0 にならない。刻みの分だけ許す。
    import torch.nn as nn
    torch.manual_seed(7)
    for K, N, M in ((8, 5, 6), (64, 32, 16)):
        lin = nn.Linear(K, N)
        xs = torch.randn(M, K)
        want = lin(xs)
        try:
            got = torch.compile(lin, backend="common", fullgraph=True, dynamic=False)(xs)
            got = got[0] if isinstance(got, (tuple, list)) else got
            d = float((got.double() - want.double()).abs().max())
            rel = d / max(1e-9, float(want.double().abs().max()))
            if tuple(got.shape) == tuple(want.shape) and rel < 1e-4:
                ok += 1
                if verbose:
                    print("%-14s 通る  相対の差 %.1e" % ("nn.Linear %dx%d" % (K, N), rel))
            else:
                bad.append("nn.Linear %dx%d" % (K, N))
                if verbose:
                    print("%-14s 違う  形 %s 相対の差 %.1e"
                          % ("nn.Linear %dx%d" % (K, N), tuple(got.shape), rel))
        except Exception as e:
            bad.append("nn.Linear %dx%d" % (K, N))
            if verbose:
                print("%-14s 落ちた  %s" % ("nn.Linear", str(e).splitlines()[0][:70]))
    # 行列の積と要素ごとの演算が混ざる形。ステージの表の道を通る。
    net = nn.Sequential(nn.Linear(8, 6), nn.ReLU(), nn.Linear(6, 4))
    xs = torch.randn(3, 8)
    want = net(xs)
    try:
        got = torch.compile(net, backend="common", fullgraph=True, dynamic=False)(xs)
        got = got[0] if isinstance(got, (tuple, list)) else got
        d = float((got.double() - want.double()).abs().max())
        if tuple(got.shape) == tuple(want.shape) and d < 1e-3:
            ok += 1
            if verbose:
                print("%-14s 通る  差の最大 %.1e" % ("MLP+ReLU", d))
        else:
            bad.append("MLP+ReLU")
            if verbose:
                print("%-14s 違う  形 %s 差 %.1e" % ("MLP+ReLU", tuple(got.shape), d))
    except Exception as e:
        bad.append("MLP+ReLU")
        if verbose:
            print("%-14s 落ちた  %s" % ("MLP+ReLU", str(e).splitlines()[0][:70]))

    return ok, bad


if __name__ == "__main__":
    import sys
    ok, bad = run()
    print()
    print("通った %d / 落ちた %s" % (ok, bad or "なし"))
    sys.exit(1 if bad else 0)
