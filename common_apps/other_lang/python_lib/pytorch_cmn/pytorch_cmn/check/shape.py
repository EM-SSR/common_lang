# -*- coding: utf-8 -*-
"""形と配置の検査。**演算を繋いだときだけ出る食い違いを見る。**

単体で通る演算を繋ぐと壊れる。理由は二つ。

- `Lower` の中間値は (先頭, 行, 列, F) しか持たない。PyTorch の tensor が持つ
  layout・view・broadcast の意味が落ちている。
- `matmul` が一つ入ると graph 全体が Table の経路へ切り替わる。すると単体では Walk の
  経路（host 側の `np.broadcast_to`）で通っていた `add` が、別実装の `Lower.point` に
  なる。

GPU は使わない。`Build.simulate`（numpy での再現）と素の torch を突き合わせる。

    python -m pytorch_cmn.check.shape
"""
import numpy as np
import torch

try:
    from .. import backend                      # noqa: F401
    from .. import graph
except ImportError:
    import pytorch_cmn.backend                  # noqa: F401
    from pytorch_cmn import graph


def _lower(fn, x):
    seen = {}

    def peek(gm, ex):
        seen["gm"], seen["ex"] = gm, ex
        return gm.forward

    torch.compile(fn, backend=peek, dynamic=False)(x)
    return graph.Lower(seen["gm"], seen["ex"]).emit()


def _read(low, mem, want=None):
    """出力ノードの置き場から値を取り出す。

    Table は (行, 列) で持つので、縮約の後は torch の (3,) が (3,1) になる。
    `backend.Table` は `meta` で torch の形へ戻すので、ここでも要素数が合えば戻す。
    """
    got = []
    for k, (h, rows, cols, d) in enumerate(low.outputs()):
        st = low._stride(cols)
        a = mem[h:h + rows * st].reshape(rows, st)[:, :cols]
        a = np.asarray(a) / float(1 << d)
        if want is not None and a.size == int(np.prod(want.shape or (1,))):
            a = a.reshape(want.shape)
        got.append(a)
    return got


def _rand(*shape):
    torch.manual_seed(3)
    return torch.randn(*shape) / 4.0


# ---- case。どれも matmul を含めて Table の経路へ入れる ----------------------

def _bias():
    """x @ Wᵀ + b。b は (C,) なので行方向の歩幅は 0 でなければならない。"""
    torch.manual_seed(5)
    w = torch.randn(2, 3) / 2.0
    b = torch.tensor([0.1, -0.2])
    return lambda x: x.matmul(w.t()) + b, _rand(2, 3)


def _bias_col():
    """x @ Wᵀ + r。r は (R,1) なので列方向の歩幅が 0。"""
    torch.manual_seed(5)
    w = torch.randn(2, 3) / 2.0
    r = torch.tensor([[0.25], [-0.5]])
    return lambda x: x.matmul(w.t()) + r, _rand(2, 3)


def _bias_mul():
    """列ごとの倍率を掛ける。積の側の broadcast。"""
    torch.manual_seed(5)
    w = torch.randn(2, 3) / 2.0
    s = torch.tensor([2.0, 0.5])
    return lambda x: x.matmul(w.t()) * s, _rand(2, 3)


def _reshape_sum():
    """reshape してから行に沿って足す。行と列が入れ替わる。"""
    torch.manual_seed(5)
    w = torch.randn(6, 6) / 4.0
    return lambda x: x.matmul(w.t()).reshape(3, 2).sum(-1), _rand(1, 6)


def _t_sum():
    """転置してから行に沿って足す。"""
    torch.manual_seed(5)
    w = torch.randn(3, 3) / 3.0
    return lambda x: x.matmul(w.t()).t().sum(-1), _rand(2, 3)


def _two_matmul():
    """中間の値どうしの matmul。attention の QKᵀ がこの形。"""
    torch.manual_seed(5)
    A = torch.randn(4, 3) / 3.0
    B = torch.randn(4, 3) / 3.0
    return lambda x: x.matmul(A.t()).matmul(x.matmul(B.t()).t()), _rand(2, 3)


def _linear_then_bias():
    """nn.Linear の後にもう一つ足す。"""
    torch.manual_seed(5)
    m = torch.nn.Linear(3, 4)
    b2 = torch.tensor([0.1, 0.2, -0.1, -0.2])
    return lambda x: m(x) + b2, _rand(2, 3)


def _rms():
    """RMSNorm のあとに射影。桁を戻す所が並ぶ。"""
    torch.manual_seed(5)
    m = torch.nn.RMSNorm(4)
    w = torch.randn(3, 4) / 2.0
    return lambda x: m(x).matmul(w.t()), _rand(2, 4)


def _ln():
    """LayerNorm のあとに射影。中心も引く。"""
    torch.manual_seed(5)
    m = torch.nn.LayerNorm(4)
    w = torch.randn(3, 4) / 2.0
    return lambda x: m(x).matmul(w.t()), _rand(2, 4)


def _soft():
    """softmax のあとに射影。"""
    torch.manual_seed(5)
    w = torch.randn(3, 4) / 2.0
    a = torch.randn(4, 4) / 2.0
    return (lambda x: torch.softmax(x.matmul(a.t()), -1).matmul(w.t()),
            _rand(2, 4))


def _silu_lin():
    """silu のあとに射影。"""
    torch.manual_seed(5)
    w = torch.randn(3, 4) / 2.0
    a = torch.randn(4, 4) / 2.0
    return (lambda x: torch.nn.functional.silu(x.matmul(a.t())).matmul(w.t()),
            _rand(2, 4))


def _ffn():
    """Transformer の一段。正規化・門・残差が全部入る。"""
    torch.manual_seed(7)

    class FFN(torch.nn.Module):
        def __init__(self):
            super(FFN, self).__init__()
            self.norm = torch.nn.RMSNorm(4)
            self.gate = torch.nn.Linear(4, 8, bias=False)
            self.up = torch.nn.Linear(4, 8, bias=False)
            self.down = torch.nn.Linear(8, 4, bias=False)

        def forward(self, x):
            y = self.norm(x)
            return x + self.down(torch.nn.functional.silu(self.gate(y)) * self.up(y))

    return FFN(), _rand(2, 4)


def _split():
    """K が大きく、内積をレーンへ割る形。"""
    torch.manual_seed(5)
    m = torch.nn.Linear(256, 128)
    return lambda t: m(t), _rand(2, 256)


def _splitblk():
    """割る形の一段まるごと。"""
    torch.manual_seed(7)

    class Blk(torch.nn.Module):
        def __init__(self, d=256, h=512):
            super(Blk, self).__init__()
            self.norm = torch.nn.RMSNorm(d)
            self.gate = torch.nn.Linear(d, h, bias=False)
            self.up = torch.nn.Linear(d, h, bias=False)
            self.down = torch.nn.Linear(h, d, bias=False)

        def forward(self, x):
            y = self.norm(x)
            return x + self.down(torch.nn.functional.silu(self.gate(y)) * self.up(y))

    return Blk(), _rand(1, 2, 256)


def _sdpa(heads=2, T=3, D=4, mask=False):
    """attention 単体。q k v は射影から作る（中間の値にする）。"""
    torch.manual_seed(5)
    wq = torch.randn(heads * D, D) / 4.0
    wk = torch.randn(heads * D, D) / 4.0
    wv = torch.randn(heads * D, D) / 4.0
    m = None
    if mask:
        m = torch.zeros(1, 1, T, T)
        m[..., 1:, 0] = -1e4 if mask == 1 else torch.finfo(torch.float32).min

    def fn(x):
        q = x.matmul(wq.t()).reshape(1, T, heads, D).transpose(1, 2)
        k = x.matmul(wk.t()).reshape(1, T, heads, D).transpose(1, 2)
        v = x.matmul(wv.t()).reshape(1, T, heads, D).transpose(1, 2)
        return torch.nn.functional.scaled_dot_product_attention(q, k, v, attn_mask=m)

    return fn, _rand(T, D)


def _gqa(H=4, Hk=2, T=3, D=4):
    """KV を少ない head で作り、Qwen と同じ広げ方で H head にしてから attention。"""
    torch.manual_seed(5)
    wq = torch.randn(H * D, D) / 4.0
    wk = torch.randn(Hk * D, D) / 4.0
    wv = torch.randn(Hk * D, D) / 4.0
    rep = H // Hk

    def fn(x):
        q = x.matmul(wq.t()).reshape(1, T, H, D).transpose(1, 2)
        k = x.matmul(wk.t()).reshape(1, T, Hk, D).transpose(1, 2)
        v = x.matmul(wv.t()).reshape(1, T, Hk, D).transpose(1, 2)
        k = k[:, :, None, :, :].expand(1, Hk, rep, T, D).reshape(1, H, T, D)
        v = v[:, :, None, :, :].expand(1, Hk, rep, T, D).reshape(1, H, T, D)
        return torch.nn.functional.scaled_dot_product_attention(q, k, v)

    return fn, _rand(T, D)


def _att(heads=2, kvh=None, T=3, D=4, mask=0, causal=False, gqa=False):
    """attention の契約をひととおり。`is_causal` `enable_gqa` 2/3/4 軸のマスク。"""
    torch.manual_seed(5)
    kvh = kvh or heads
    wq = torch.randn(heads * D, D) / 4.0
    wk = torch.randn(kvh * D, D) / 4.0
    wv = torch.randn(kvh * D, D) / 4.0
    m = None
    if mask == 1:                                  # 4 軸、数で足す
        m = torch.zeros(1, 1, T, T)
        m[..., 1:, 0] = -1e4
    elif mask == 2:                                # 4 軸、-inf 相当
        m = torch.zeros(1, 1, T, T)
        m[..., 1:, 0] = torch.finfo(torch.float32).min
    elif mask == 3:                                # 4 軸、bool
        m = torch.tril(torch.ones(T, T, dtype=torch.bool))[None, None]
    elif mask == 4:                                # 2 軸
        m = torch.tril(torch.ones(T, T, dtype=torch.bool))

    def fn(x):
        q = x.matmul(wq.t()).reshape(1, T, heads, D).transpose(1, 2)
        k = x.matmul(wk.t()).reshape(1, T, kvh, D).transpose(1, 2)
        v = x.matmul(wv.t()).reshape(1, T, kvh, D).transpose(1, 2)
        return torch.nn.functional.scaled_dot_product_attention(
            q, k, v, attn_mask=m, is_causal=causal, enable_gqa=gqa)

    return fn, _rand(T, D)


def _wide(n=1024, k=64):
    """列が詰め幅（512）を越える形。タイルに切られる。"""
    torch.manual_seed(5)
    m = torch.nn.Linear(k, n, bias=False)
    return lambda t: m(t), _rand(1, k)


def _wide_norm(n=1024, k=64):
    """タイルに切られた置き場を、行に沿って縮約する。"""
    torch.manual_seed(5)
    m = torch.nn.Linear(k, n, bias=False)
    rn = torch.nn.RMSNorm(n)
    return lambda t: rn(m(t)), _rand(1, k)


def _wide_ffn(d=64, h=1024):
    """タイルに切られた中間を通す FFN。"""
    torch.manual_seed(7)

    class W(torch.nn.Module):
        def __init__(self):
            super(W, self).__init__()
            self.up = torch.nn.Linear(d, h, bias=False)
            self.down = torch.nn.Linear(h, d, bias=False)

        def forward(self, x):
            return x + self.down(torch.nn.functional.silu(self.up(x)))

    return W(), _rand(1, d)


CASES = [
    ("bias      x@Wt + b (C,)     ", _bias),
    ("bias_col  x@Wt + r (R,1)    ", _bias_col),
    ("bias_mul  x@Wt * s (C,)     ", _bias_mul),
    ("linear2   Linear + b2       ", _linear_then_bias),
    ("reshape   x@Wt.reshape.sum  ", _reshape_sum),
    ("transpose x@Wt.t().sum      ", _t_sum),
    ("qk        (x@At)@(x@Bt)t    ", _two_matmul),
    # 桁を戻す所が並ぶ形。段の数がここで決まる
    ("rms       RMSNorm then @Wt   ", _rms),
    ("ln        LayerNorm then @Wt ", _ln),
    ("softmax   softmax then @Wt   ", _soft),
    ("silu      silu then @Wt      ", _silu_lin),
    ("ffn       RMSNorm+gate+down  ", _ffn),
    # attention 単体
    ("sdpa      2 head T=3 D=4     ", lambda: _sdpa()),
    ("sdpamask  マスクつき          ", lambda: _sdpa(mask=1)),
    ("sdpainf   マスクが -inf 相当     ", lambda: _sdpa(mask=2)),
    ("gqa       4 head / KV 2 head  ", lambda: _gqa()),
    # Qwen と同じ寸法
    ("sdpa16    1 head T=4 D=16     ", lambda: _sdpa(heads=1, T=4, D=16)),
    ("sdpa16m   同じ寸法 マスクつき      ", lambda: _sdpa(heads=1, T=4, D=16, mask=2)),
    # attention の契約。**前処理で問題を消してから測ってはいけない**
    ("att_causal is_causal=True    ", lambda: _att(causal=True)),
    ("att_bool  4 軸 bool マスク       ", lambda: _att(mask=3)),
    ("att_2d    2 軸 マスク           ", lambda: _att(mask=4)),
    ("att_gqa   enable_gqa 4/2      ", lambda: _att(heads=4, kvh=2, gqa=True)),
    ("att_both  causal + gqa        ", lambda: _att(heads=4, kvh=2, gqa=True,
                                                    causal=True)),
    # 列が詰め幅を越えてタイルに切られる形
    ("wide      Linear 64->1024    ", lambda: _wide()),
    ("widenorm  1024 を行で縮約      ", lambda: _wide_norm()),
    ("wideffn   d=64 h=1024        ", lambda: _wide_ffn()),
    # 内積をレーンへ割る形
    ("split     Linear 256->128    ", _split),
    ("splitblk  d=256 h=512        ", _splitblk),
]

LOOSE = 2e-3


def run(verbose=True):
    head = "%-30s %-14s %-14s %-9s %s"
    if verbose:
        print(head % ("graph", "torch の形", "cmn の形", "差", "結果"))
    bad = []
    for name, make in CASES:
        fn, x = make()
        want = fn(x)
        want = want[0] if isinstance(want, (tuple, list)) else want
        wa = np.asarray(want.detach())
        try:
            low = _lower(fn, x)
            mem, _ = low.B.simulate()
            got = _read(low, mem, wa)[0]
            shape_ok = got.shape == wa.shape
            if shape_ok:
                err = float(np.max(np.abs(got - wa))) / max(1.0, float(np.max(np.abs(wa))))
            else:
                err = float("inf")
            ok = shape_ok and err <= LOOSE
            if verbose:
                print(head % (name, str(tuple(wa.shape)), str(tuple(got.shape)),
                              "%.3g" % err,
                              ("合う" if ok else "**食い違う**")
                              + "  %d 段" % len(low.B.rows)))
            if not ok:
                bad.append(name.strip())
        except Exception as e:
            if verbose:
                print(head % (name, str(tuple(wa.shape)), "-", "-",
                              "落ちた %s: %s" % (type(e).__name__,
                                               str(e).split("\n")[0][:44])))
            bad.append(name.strip())
    if verbose:
        print("\n%d / %d 合う" % (len(CASES) - len(bad), len(CASES)))
        if bad:
            print("落ちた: %s" % ", ".join(bad))
    return bad


if __name__ == "__main__":
    import sys
    sys.exit(1 if run() else 0)
