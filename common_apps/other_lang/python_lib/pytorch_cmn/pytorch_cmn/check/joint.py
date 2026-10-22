# -*- coding: utf-8 -*-
"""実機を基準に、段ごとに再現モデルと突き合わせる。

`check/shape` と `check/ladder` は `Build.simulate`（numpy）だけを見るので、表の組み方の
誤りは捕まえても、エンジンと再現モデルのずれは通してしまう。両者が分かれる場所は一つ
しかない。

    共有帯への Store が接合点になる（`lane64_runb`）。作業領域への Store は接合点に
    ならない。

だから段 $s$ の直後の共有帯

    V_s = { M[o_s + s₁i₁ + s₂i₂ + s₃i₃] : (i₁,i₂,i₃) }

を両方から取り、最初に食い違う $s$ を二分探索で探す。段の数は表を組み直さずに `LEFT` の
初期値だけで変えられる。

二度目の実行も見る。エンジンは段の出力を共有帯へ書くので、走ったあとの帯には前の回の
中間値が残る。再現モデルは毎回 0 から組む。**一度目だけを見ると、この差は出ない。**

    python -m pytorch_cmn.check.joint          # 28 通り
    python -m pytorch_cmn.check.joint ffn      # 名前の先頭で選ぶ
"""
import sys

import numpy as np

try:
    from .. import graph
    from . import shape as S
except ImportError:
    from pytorch_cmn import graph
    from pytorch_cmn.check import shape as S


def band(J, n):
    """共有帯の先頭 n 語を符号つきで読む。"""
    return J.d_rom[:n].get().astype(np.int64)


def support(low):
    """ノードの置き場が覆う語だけを立てた面を返す。

    置き場の外へ書くレーンがある。出力の列 $N$ が詰め幅より少ない行では、$i_2\ge N$ の
    レーンが置き場の外へ書く。番地が重なるので、どのレーンの値が残るかは決まらない。
    **その語はエンジンと再現モデルで一致しなくてよい。** 値に意味があるのは置き場の
    中だけになる。
    """
    keep = np.zeros((low.B.n,), dtype=bool)
    for h, rows, cols, _ in low.val.values():
        st = low._stride(cols)
        a = np.arange(rows)[:, None] * st + np.arange(cols)[None, :] + h
        a = a[a < low.B.n]
        keep[a] = True
    return keep


def _where(low, addrs):
    """食い違った番地が、どのノードの置き場に入るかを返す。"""
    got = []
    for n, (h, rows, cols, d) in low.val.items():
        st = low._stride(cols)
        lo, hi = h, h + rows * st
        hit = int(np.sum((addrs >= lo) & (addrs < hi)))
        if hit:
            got.append((hit, n.name))
    got.sort(reverse=True)
    return got[:3]


def _rows_at(B, s):
    """段 s の行から、見て分かる欄だけを抜く。"""
    r = B.rows[s]
    return dict(出す枠=int(r[0]), 歩幅=(int(r[1]), int(r[2]), int(r[3])),
                組=int(r[4]), 係数=int(r[5]), 入力=int(r[9]),
                足す項=int(r[13]), 桁数=int(r[25]), 最大=int(r[33]))


def split(B, lo, hi, model, engine):
    """[lo, hi) で最初に分かれる段を探す。lo は合う段、hi は分かれる段。"""
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if np.array_equal(model(mid), engine(mid)):
            lo = mid
        else:
            hi = mid
    return hi


def layer_low(hidden=128, heads=4, kv=2, inter=512, tokens=8):
    """decoder の層を一枚だけ切り出して lowering する。

    報告のあった食い違いは「層だけを切り出した graph に固有の形」なので、モデル全体から
    降りた graph では出ない。`host.wrap` と同じ切り方で層を一枚だけ捕まえる。
    """
    import torch
    from . import ops
    got = {}

    def peek(gm, ex):
        got.setdefault("gm", gm)
        got.setdefault("ex", list(ex))
        return gm.forward

    m = ops.tiny(layers=1, hidden=hidden, heads=heads, kv=kv, inter=inter)
    m = m.to(torch.bfloat16)
    m.model.layers[0] = torch.compile(m.model.layers[0], backend=peek, dynamic=False)
    with torch.no_grad():
        m(torch.arange(1, tokens + 1).reshape(1, tokens))
    return graph.Lower(got["gm"], got["ex"]).emit()


def one(name, low, verbose=True):
    """一つの case を実機と再現で突き合わせる。返りは分かれた段（合えば None）。"""
    B = low.B
    Sn = len(B.rows)

    keep = support(low)

    def model(s):
        mem, _ = B.simulate(stop=s)
        return mem[:B.n][keep]

    def engine(s):
        J, rep, steps = B.run(stop=s)
        bad = rep[(rep != 0) & (rep != 10)]
        if len(bad):
            raise RuntimeError("報告 %s" % sorted(set(int(v) for v in bad)))
        return band(J, B.n)[keep]

    want, got = model(Sn), engine(Sn)
    first = None
    if not np.array_equal(want, got):
        first = split(B, 0, Sn, model, engine)
    # 二度目。同じ板を使い回したときに、前の回の中間値が効かないことを見る
    same2 = np.array_equal(want, engine(Sn))

    if verbose:
        mark = "合う" if first is None else "**段 %d で分かれる**" % first
        print("%-30s %4d 段 %7d lane  %s%s"
              % (name, Sn, B.lanes, mark,
                 "" if same2 else "   二度目が違う"))
        idx = np.flatnonzero(keep)
        if first is not None:
            a = idx[np.flatnonzero(want != got)]
            print("     行: %s" % _rows_at(B, first))
            print("     食い違う番地 %d 語 / %d。置き場: %s"
                  % (a.size, B.n, _where(low, a)))
        if not same2:
            a = idx[np.flatnonzero(want != engine(Sn))]
            print("     二度目で食い違う番地 %d 語。置き場: %s"
                  % (a.size, _where(low, a)))
    return first, same2


def run(pick=None, verbose=True):
    bad = []
    for name, make in S.CASES:
        if pick and not name.strip().startswith(pick):
            continue
        try:
            fn, x = make()
            first, same2 = one(name, S._lower(fn, x), verbose=verbose)
            if first is not None or not same2:
                bad.append(name.strip())
        except Exception as e:
            if verbose:
                print("%-30s 落ちた %s: %s"
                      % (name, type(e).__name__, str(e).split("\n")[0][:50]))
            bad.append(name.strip())
    if verbose:
        n = len([c for c in S.CASES if not pick or c[0].strip().startswith(pick)])
        print("\n%d / %d 合う" % (n - len(bad), n))
        if bad:
            print("分かれた: %s" % ", ".join(bad))
    return bad


def layers(verbose=True):
    """層を一枚だけ切り出した graph。報告のあった条件（数百段・数千 lane）を含める。"""
    bad = []
    for kw in (dict(hidden=128, inter=512, tokens=8),
               dict(hidden=256, heads=8, kv=4, inter=1024, tokens=8),
               dict(hidden=512, heads=8, kv=4, inter=2048, tokens=16)):
        name = "layer d=%d h=%d T=%d" % (kw["hidden"], kw["inter"], kw["tokens"])
        try:
            first, same2 = one("%-30s" % name, layer_low(**kw), verbose=verbose)
            if first is not None or not same2:
                bad.append(name)
        except Exception as e:
            if verbose:
                print("%-30s 落ちた %s: %s"
                      % (name, type(e).__name__, str(e).split(chr(10))[0][:50]))
            bad.append(name)
    return bad


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    if arg == "layer":
        sys.exit(1 if layers() else 0)
    sys.exit(1 if run(arg) else 0)
