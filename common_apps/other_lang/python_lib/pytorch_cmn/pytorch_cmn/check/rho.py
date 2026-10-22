# -*- coding: utf-8 -*-
"""compile と run のカットを渡る影響を測る。

`torch.compile` が返す関数は、compile を起こした入力の一点で合っていても正しくない。
compile 時の入力を焼き付けた形でも、その一点だけは合うからになる。だから見るのは値では
なく**影響**にする。

$$P_{ij}=\bigl[\ x\ \text{の}\ i\ \text{要素を動かすと}\ y\ \text{の}\ j\ \text{要素が動く}\ \bigr]$$

$P$ が素の torch と一致すれば、カットを渡る辺が全部ある。接合秩 $\rho=\operatorname{rank}P$ は
その本数の下限を与える（`Common-Lang/1` R4）。

摂動は $2$ の冪の分数に限る。固定小数の刻みに乗るので、正しければ差は厳密に 0 になる。

    python -m pytorch_cmn.check.rho
"""
import numpy as np
import torch

try:
    from .. import backend                      # noqa: F401  register_backend が走る
except ImportError:
    import pytorch_cmn.backend                  # noqa: F401


def _flat(y):
    y = y[0] if isinstance(y, (tuple, list)) else y
    return np.asarray(y.detach(), dtype=np.float64).reshape(-1)


def influence(f, x, delta=0.5, limit=32):
    """入力を 1 要素ずつ動かしたときの出力の動きを、そのまま（絶対値で）返す。

    要素ごとに一度ずつ呼ぶので、大きい入力では `limit` 個までに絞る。絞った分だけ行が
    減るが、素の torch と同じ絞り方をするので突き合わせは成り立つ。
    """
    base = _flat(f(x))
    n = min(int(x.numel()), limit)
    D = np.zeros((n, base.size), dtype=np.float64)
    cell = x.detach().reshape(-1)
    for i in range(n):
        keep = float(cell[i])
        cell[i] = keep + delta
        D[i] = np.abs(_flat(f(x)) - base)
        cell[i] = keep
    return D, base


def covers(dw, dg, eps=1e-3):
    """torch で明確に動く所が、cmn でも動いているか。

    **辺を 1 つの閾値で数えて突き合わせてはいけない。** torch は float32 なのでどんな
    小さな動きも記録するが、固定小数は $2^{-F}$ より小さい動きが 0 になる。正規化を挟むと
    1 要素の摂動が遠い出力に与える影響が刻みを下回り、閾値の際で辺が入れ替わる
    （splitblk で 8192 辺のうち 11 辺）。

    見るのは片側の包含にする。刻みの十分上（`eps` × 出力の大きさ）で torch が動く所は
    cmn でも動かなければならない。刻み以下の所で cmn が動くのは欠陥ではない。焼き付け
    （どこも動かない）はこの判定でも 0 と区別できる。
    """
    if dw.shape != dg.shape:
        return False, 0, 0
    line = eps * max(1.0, float(np.max(dw)))
    must = dw > line
    got = dg > 0.0
    miss = int(np.count_nonzero(must & ~got))
    return miss == 0, int(np.count_nonzero(must)), miss


def rank_of(d, eps=0.0):
    p = (d > eps).astype(np.float64)
    return int(np.linalg.matrix_rank(p)) if p.size else 0


def rank(P):
    return int(np.linalg.matrix_rank(P.astype(np.float64))) if P.size else 0


# ---- 試す graph ----------------------------------------------------------
#
# 形は全部違えておく。**同じ形の tensor どうしだけを試すと、置き方の穴が 1 つも出ない。**

def _linear(k, n, seed=0.0):
    m = torch.nn.Linear(k, n)
    with torch.no_grad():
        m.weight.copy_((torch.arange(float(k * n)).reshape(n, k) - seed) / 16.0)
        m.bias.copy_(torch.arange(float(n)) / 8.0)
    return m


def _mod(m, x, wrap=None):
    """モジュールの case。三つ目が「動かす weight」になる。"""
    return (m if wrap is None else wrap(m)), x, list(m.parameters())


# (名前, 作る関数)。作る関数は (fn, x, 動かす weight) を返す。
CASES = [
    ("point    x*2+1        (2,2)", lambda: (lambda x: x * 2.0 + 1.0,
                                             torch.tensor([[1.0, .5], [.25, 1.5]]), [])),
    ("point    x*y+x        (2,3)", lambda: (lambda x: x * x + x,
                                             torch.arange(6.0).reshape(2, 3) / 4.0, [])),
    ("linear   (2,4)->(2,5)      ", lambda: _mod(
        _linear(4, 5), torch.arange(8.0).reshape(2, 4) / 4.0)),
    ("linear   (2,3,4)->(2,3,5)  ", lambda: _mod(
        _linear(4, 5), torch.arange(24.0).reshape(2, 3, 4) / 8.0)),
    ("linear   (1,7,4)->(1,7,5)  ", lambda: _mod(
        _linear(4, 5), torch.arange(28.0).reshape(1, 7, 4) / 16.0)),
    ("relu     relu(linear)      ", lambda: _mod(
        _linear(4, 5, 10.0), torch.arange(8.0).reshape(2, 4) / 4.0,
        wrap=lambda m: lambda x: torch.relu(m(x)))),
    ("reshape  view then mul     ", lambda: (lambda x: x.reshape(3, 2) * 2.0,
                                             torch.arange(6.0).reshape(2, 3) / 4.0, [])),
    ("sum      row sum           ", lambda: (lambda x: x.sum(-1),
                                             torch.arange(6.0).reshape(2, 3) / 4.0, [])),
    ("mean     row mean          ", lambda: (lambda x: x.mean(-1),
                                             torch.arange(8.0).reshape(2, 4) / 4.0, [])),
    # 先頭の要素が行の最大になるように置く。そうでないと、先頭を動かしても出力が動かず
    # 「焼き付けている」のと見分けが付かない
    ("amax     row max           ", lambda: (lambda x: x.amax(-1),
                                             torch.tensor([[3., 1., 2.], [-1., -3., -2.]]), [])),
    ("div      by constant       ", lambda: (lambda x: x / 4.0,
                                             torch.arange(6.0).reshape(2, 3), [])),
    ("softmax  row softmax       ", lambda: (lambda x: torch.softmax(x, -1),
                                             torch.tensor([[1., 0., -1.], [.5, .25, 0.]]), [])),
    ("sigmoid  both sides        ", lambda: (torch.sigmoid,
                                             torch.tensor([[1., -1.], [.5, -2.]]), [])),
    ("silu     x*sigmoid(x)      ", lambda: (torch.nn.functional.silu,
                                             torch.tensor([[1., -1.], [.5, -2.]]), [])),
    ("rms_norm row rms           ", lambda: _mod(
        torch.nn.RMSNorm(4), torch.arange(8.0).reshape(2, 4) / 4.0)),
    ("layernorm row layer norm   ", lambda: _mod(
        torch.nn.LayerNorm(4), torch.arange(8.0).reshape(2, 4) / 4.0)),
    # 積の連鎖。層を重ねると分子が伸びるので、桁を戻す所がここで出る
    ("deep     MLP 16x16 x4      ", lambda: _mod(_stack(4), _rand(3, 16))),
    # LLM の形。3 次元の活性 ＋ 正規化 ＋ 積
    ("block    norm+linear+silu  ", lambda: _mod(_block(), _rand(1, 3, 8))),
    # 内積をレーンへ割る形（K ≥ 256 かつ 64 の倍数）。1 lane が K 項を全部持たない
    ("split    (2,256)->(2,128)  ", lambda: _mod(
        torch.nn.Linear(256, 128), _rand(2, 256))),
    ("splitblk d=256 h=512       ", lambda: _mod(_block(256, 512), _rand(1, 2, 256))),
]


def _rand(*shape):
    torch.manual_seed(3)
    return torch.randn(*shape) / 4.0


def _stack(n, k=16):
    torch.manual_seed(5)
    return torch.nn.Sequential(*sum(([torch.nn.Linear(k, k), torch.nn.ReLU()]
                                     for _ in range(n)), []))


class _Block(torch.nn.Module):
    """Transformer の一段の骨。正規化 → 二つの射影 → 門 → 戻す。"""

    def __init__(self, d=8, h=16):
        super(_Block, self).__init__()
        self.norm = torch.nn.RMSNorm(d)
        self.up = torch.nn.Linear(d, h, bias=False)
        self.gate = torch.nn.Linear(d, h, bias=False)
        self.down = torch.nn.Linear(h, d, bias=False)

    def forward(self, x):
        y = self.norm(x)
        return x + self.down(torch.nn.functional.silu(self.gate(y)) * self.up(y))


def _block(d=8, h=16):
    torch.manual_seed(7)
    return _Block(d, h)

# 固定小数で作る関数は刻みの分だけ差が出る。許す幅を case ごとに置く
LOOSE = {"softmax": 2e-3, "sigmoid": 2e-3, "silu": 2e-3,
         "rms_norm": 2e-3, "layernorm": 2e-3, "div": 1e-4, "mean": 1e-4,
         "deep": 1e-3, "block": 2e-3, "split": 1e-3, "splitblk": 2e-3}


def _shift(f, cells, x, delta=0.5, single=False):
    """`cells` を動かす前と後で呼ぶ。焼き付けた形は後が前と同じになる。

    `single` を立てると先頭の一要素だけ動かす。**softmax と layer_norm は入力全体を
    同じだけ動かしても値が変わらない**ので、全体を動かす形では焼き付けを見つけられない。
    """
    def move(sign):
        with torch.no_grad():
            for c in cells:
                if single:
                    c.reshape(-1)[0] += sign * delta
                else:
                    c += sign * delta

    a = _flat(f(x))
    move(+1)
    b = _flat(f(x))
    move(-1)
    return a, b


def _gap(a, b):
    """相対の差。**絶対値で比べてはいけない。**

    weight を動かすと出力の大きさ自体が変わる（block は 0.53 → 144）。固定小数の刻みは
    値の大きさに比例するので、絶対値で線を引くと大きい側だけが落ちる。
    """
    if a.shape != b.shape:
        return float("inf")
    return float(np.max(np.abs(a - b))) / max(1.0, float(np.max(np.abs(b))))


def _tracks(f, ref, cells, x):
    """`cells` を動かしたあと、素の torch と同じだけ動くか。

    返りは (動いたか, 相対の差)。動く先が無い case（weight を持たない）は素通り。
    """
    if not cells:
        return True, 0.0
    a, b = _shift(f, cells, x)
    a0, b0 = _shift(ref, cells, x)
    return bool(not np.array_equal(a, b)), _gap(b, b0)


def run(verbose=True):
    head = "%-28s %-13s %-13s %-9s %-8s %-8s %s"
    if verbose:
        print(head % ("graph", "torch rho/辺", "common rho/辺", "P",
                      "二度目", "weight", "値"))
    bad = []
    for name, make in CASES:
        fn, x, cells = make()
        want, _ = influence(fn, x.clone())
        row = [name, "%d/%d" % (rank_of(want), int(np.count_nonzero(want > 0)))]
        try:
            got = torch.compile(fn, backend="common", dynamic=False)
            P, _ = influence(got, x.clone())
            ok_P, need, miss = covers(want, P)
            row.append("%d/%d" % (rank_of(P), int(np.count_nonzero(P > 0))))
            row.append("合う" if ok_P else "欠け %d/%d" % (miss, need))
            xc, xr = x.clone(), x.clone()
            xa, xb = _shift(got, [xc.detach()], xc, single=True)
            ra, rb = _shift(fn, [xr.detach()], xr, single=True)
            ok_x = not np.array_equal(xa, xb)
            row.append("動く" if ok_x else "**固定**")
            ok_w, dw = _tracks(got, fn, cells, x.clone())
            row.append(("動く" if ok_w else "**固定**") if cells else "-")
            err = max(_gap(xb, rb), dw)
            row.append("0" if err == 0.0 else "%.3g" % err)
            line = LOOSE.get(name.split()[0], 0.0)
            if not (ok_P and ok_x and ok_w and err <= line):
                bad.append(name.strip())
        except Exception as e:
            # 途中まで埋まっていることがあるので、欄の数を揃えて上書きする
            row = row[:2] + ["落ちた", "-", "-", "-",
                             "%s: %s" % (type(e).__name__,
                                         str(e).split("\n")[0][:40])]
            bad.append(name.strip())
        if verbose:
            print(head % tuple(row))
    if verbose:
        print("\n%d / %d 合う" % (len(CASES) - len(bad), len(CASES)))
        if bad:
            print("落ちた: %s" % ", ".join(bad))
    return bad


if __name__ == "__main__":
    import sys
    sys.exit(1 if run() else 0)
