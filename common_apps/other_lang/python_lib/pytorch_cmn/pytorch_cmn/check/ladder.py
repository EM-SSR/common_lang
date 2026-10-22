# -*- coding: utf-8 -*-
"""桁ごとに立てる三つ（`rshift` `recip` `isqrt` `rsqrt`）を単体で検算する。

エンジンの閉包一つで三つを回すので、係数 $(A, B, L)$ の取り方を間違えると静かに外れる。
組み合わせの中で推測せず、ここで数値を突き合わせる。GPU は使わない。

    python -m pytorch_cmn.check.ladder
"""
import numpy as np

try:
    from .. import graph
except ImportError:
    from pytorch_cmn import graph


def _run(make, vals, f=14, width=None, lanes=128):
    """1 行の表を組んで numpy で回し、入れた値に対する出た値を返す。"""
    B = graph.Build(len(vals), lanes, depth=f)
    src = B.data(np.asarray(vals, dtype=np.int64))
    out = make(B, src)
    mem, _ = B.simulate()
    return np.asarray(mem[out:out + len(vals)], dtype=np.float64)


def check(verbose=True):
    bad = []
    f = 14
    one = 1 << f

    # rshift: ⌊x / 2^m⌋（符号は絶対値を取ってから戻す）
    xs = [0, 1, 5, 1000, 123456, -7, -1000, -123456]
    for m in (1, 4, 14):
        got = _run(lambda B, s: B.rshift(s, None, m, 40), xs)
        want = np.array([int(abs(v) // (1 << m)) * (1 if v >= 0 else -1) for v in xs],
                        dtype=np.float64)
        err = float(np.max(np.abs(got - want)))
        if verbose:
            print("rshift m=%-3d 差 %.0f   入 %s → 出 %s"
                  % (m, err, xs[:4], [int(v) for v in got[:4]]))
        if err:
            bad.append("rshift m=%d" % m)

    # isqrt: ⌊√x⌋
    xs = [0, 1, 2, 3, 4, 100, 107374, 16777216]
    got = _run(lambda B, s: B.isqrt(s, 48), xs)
    want = np.floor(np.sqrt(np.asarray(xs, dtype=np.float64)))
    err = float(np.max(np.abs(got - want)))
    if verbose:
        print("isqrt       差 %.0f   入 %s → 出 %s"
              % (err, xs[4:8], [int(v) for v in got[4:8]]))
    if err:
        bad.append("isqrt")

    # recip: ⌊2^{2f} / b⌋ を桁 f の値として（つまり 1/b）
    bs = [1, 2, 3, 327, one, 5 * one]
    got = _run(lambda B, s: B.recip(s, f, 2 * f), bs)
    want = np.array([(1 << (2 * f)) // b for b in bs], dtype=np.float64)
    err = float(np.max(np.abs(got - want) / np.maximum(1.0, want)))
    if verbose:
        print("recip       相対の差 %.3g   入 %s → 出 %s（欲しい %s）"
              % (err, bs[2:5], [int(v) for v in got[2:5]],
                 [int(v) for v in want[2:5]]))
    if err > 1e-6:
        bad.append("recip")

    # rsqrt: 1/√v（v も返りも桁 f）
    vs = [round(x * one) for x in (0.0004, 0.01, 0.25, 1.0, 4.0, 100.0)]
    got = _run(lambda B, s: B.rsqrt(s, f, 2 * f), vs)
    want = np.array([one / np.sqrt(v / float(one)) for v in vs])
    err = float(np.max(np.abs(got - want) / np.maximum(1.0, want)))
    if verbose:
        print("rsqrt       相対の差 %.3g   入 %s → 出 %s（欲しい %s）"
              % (err, [round(v / float(one), 4) for v in vs[:3]],
                 [round(v / float(one), 3) for v in got[:3]],
                 [round(v / float(one), 3) for v in want[:3]]))
    if err > 5e-3:
        bad.append("rsqrt")

    # clamp: [lo, hi] へ収める
    xs = [-5000, -1, 0, 1, 7, 100000, 1 << 20]
    got = _run(lambda B, s: B.clamp(s, 0, 999), xs)
    want = np.clip(np.asarray(xs, dtype=np.float64), 0, 999)
    err = float(np.max(np.abs(got - want)))
    if verbose:
        print("clamp       差 %.0f   入 %s → 出 %s" % (err, xs, [int(v) for v in got]))
    if err:
        bad.append("clamp")

    # exp_pull: e^x（x ≤ 0、桁 f）
    xs = [0, -one // 2, -one, -2 * one, -10 * one, -40 * one]
    got = _run(lambda B, s: B.exp_pull(s, f), xs)
    want = np.array([np.exp(v / float(one)) * one for v in xs])
    err = float(np.max(np.abs(got - want)) / one)
    if verbose:
        print("exp_pull    相対の差 %.3g   入 %s → 出 %s（欲しい %s）"
              % (err, [round(v / float(one), 2) for v in xs[:4]],
                 [round(v / float(one), 4) for v in got[:4]],
                 [round(v / float(one), 4) for v in want[:4]]))
    if err > 2e-3:
        bad.append("exp_pull")

    if verbose:
        print("\n%s" % ("全部合う" if not bad else "落ちた: " + ", ".join(bad)))
    return bad


if __name__ == "__main__":
    import sys
    sys.exit(1 if check() else 0)
