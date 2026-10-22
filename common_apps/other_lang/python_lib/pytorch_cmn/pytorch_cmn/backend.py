# -*- coding: utf-8 -*-
"""`torch.compile(fn, backend="common")` の登録。

Dynamo が渡す fx.Graph 1 枚を、1 つのチェンバーへ写して 1 つの image にする。演算ごとに
呼び戻さないので、閉包が途中で切れない。

    fn ──dynamo──▶ fx.Graph ──chamber──▶ 平文 ──lane.build──▶ image ──gvcpu──▶ 値

## 何を守るか

| 決め | 中身 |
|---|---|
| レーン | 出力の要素 1 つが 1 レーン。だから内積はここでは扱わない |
| broadcast | PyTorch と同じ形を出し、入力をその形へ広げてから 1 次元にする |
| 出力の shape と dtype | graph を 1 度だけ素の torch で走らせて取る（決め打ちしない） |
| 複数出力 | 全部返す。1 つ目に潰さない |
| 定数 | `x * 2` の `2` も語として置く。全レーンに同じ値を入れる |
"""
import collections

import numpy as np
import torch
from torch._dynamo import register_backend

from . import chamber
from . import fold
from . import graph
from . import lane


def quantize(t, depth):
    """実数を分子へ。値 = 分子 · 2^-depth で、刻みは 2 の冪に限る。"""
    return np.rint(np.asarray(t, dtype=np.float64) * (1 << depth)).astype(np.int64)


def dequantize(w, depth):
    return np.asarray(w, dtype=np.float64) / float(1 << depth)


def _reference(gm, example_inputs):
    """graph を素の torch で 1 度だけ走らせ、出力の形と dtype を取る。

    `example_inputs[0]` から決め打ちすると、`reshape` や `nn.Linear`（先頭が weight）で
    外れる。比較の出力が bool であることもここで分かる。
    """
    with torch.no_grad():
        got = gm(*[t.detach().clone() for t in example_inputs])
    if not isinstance(got, (tuple, list)):
        got = (got,)
    return [(tuple(t.shape), t.dtype) for t in got]


class Walk(object):
    """image 1 枚と、その入口・出口の番地。レーンは出力の要素数だけ並べる。"""

    def __init__(self, image, need, ins, outs, meta, top, consts, depth, check):
        self.image, self.need = image, need
        self.ins = ins                  # placeholder ごとの Val
        self.outs = outs                # 出力ごとの Val
        self.meta = meta                # 出力ごとの (shape, dtype)
        self.top = top
        self.consts = consts            # 番地 → 分子
        self.depth = depth
        self.check = check
        self._lanes = None
        self.shape = meta[0][0]         # 入力を広げる先

    def _board(self, n):
        """レーンを n 本並べる。作業領域は BASE から配った番地の 1 つ上まで。

        直線の平文なのでレーンの pc は割れない。`sync` は要らないので切る。レーンの数は
        同時に載る thread 数を越えてよい（越えた分は波になって、スループットは伸びる）。
        """
        from common_vcpu import gvcpu
        from common_vcpu import vcpu
        if self._lanes is None or self._lanes.n != n:
            prog = lane.best(vcpu.decode(self.image), self.need, self.check)
            hi = self.top + 1
            self._lanes = gvcpu.Lanes(prog, self.need, chamber.Chamber.BASE, hi, 0, n,
                                      sync=False)
        return self._lanes

    def __call__(self, *args):
        n = int(np.prod(self.shape)) if len(self.shape) else 1
        flat = []
        for a, v in zip(args, self.ins):
            arr = np.asarray(a.detach().cpu(), dtype=np.float64)
            if arr.size == n:
                # 要素の数が同じなら並べ替えだけ。`reshape` と `view` がここに来る
                arr = arr.reshape(-1)
            else:
                try:
                    arr = np.broadcast_to(arr, self.shape).reshape(-1)
                except ValueError:
                    raise RuntimeError(
                        "入力の形 %s を出力の形 %s へ広げられません。"
                        "要素ごとの道は 1 レーン 1 要素なので、この形はステージの表で扱います"
                        % (tuple(arr.shape), tuple(self.shape)))
            flat.append(arr)
        L = self._board(n)
        for v, f in zip(self.ins, flat):
            L.put_block(v.addr, quantize(f, v.depth).astype(np.uint64).reshape(1, n))
        for addr, numer in self.consts.items():
            L.put_block(addr, np.full((1, n), int(numer), dtype=np.uint64))
        rep, W = L.run(watch=tuple(v.addr for v in self.outs))
        bad = rep[(rep != 0) & (rep != 10)]
        if len(bad):
            raise RuntimeError("lane64 の報告 %s" % sorted(set(int(x) for x in bad)))
        raw = W.get().astype(np.int64)
        got = []
        for k, (v, (shape, dtype)) in enumerate(zip(self.outs, self.meta)):
            val = dequantize(raw[:, k], v.depth)
            t = torch.as_tensor(val.reshape(shape))
            got.append(t.to(torch.bool) if dtype == torch.bool else t.to(dtype))
        return tuple(got)


def _matmul_node(graph):
    """graph の中の行列の積を 1 つ返す。無ければ None。"""
    got = [n for n in graph.nodes
           if n.op in ("call_function", "call_method")
           and chamber._name_of(n) in MATMUL]
    return got[0] if len(got) == 1 else None


@register_backend
def common(gm, example_inputs):
    """Dynamo の backend。graph 1 枚 = チェンバー 1 つ = image 1 枚。

    行列の積が入っていれば内積の道（レーン = 出力の要素）、それ以外は要素ごとの道
    （レーン = 1 要素）へ振り分ける。
    """
    meta = _reference(gm, example_inputs)
    if _needs_table(gm.graph):
        return Table(gm, example_inputs, meta)
    numels = set(int(np.prod(s)) if len(s) else 1 for s, _ in meta)
    if len(numels) != 1:
        raise RuntimeError(
            "出力の要素数が揃いません %s。要素ごとの道は 1 レーン 1 要素なので、"
            "形の違う出力はステージの表の道で扱います" % [s for s, _ in meta])
    ch = chamber.Chamber(gm.graph).emit()
    ins = [ch.val[n] for n in gm.graph.nodes if n.op == "placeholder"]
    outs = [ch.val[n] for n in ch.outputs()]
    image, need, _ = lane.build(ch.text(), "g%d" % (abs(hash(str(gm.graph))) % 10 ** 8))
    walk = Walk(image, need, ins, outs, meta, ch.top(), ch.consts, ch.depth,
                _gate(ch, ins, outs, image, need))
    return walk


def _gate(ch, ins, outs, image, need):
    """最適化 pass を突き合わせるシードと、見る語を返す。

    シードの値が小さいと答えが右シフトで 0 になり、「最適化する前も後も 0」でゲートが空回りする
    （2026-09-28 にこれで壊れた pass を見逃した）。だから**出口が 0 でなくなる種**を
    探してから返す。値は 2 の冪の分数だけなので、正しければ差は厳密に 0 になる。
    """
    from common_vcpu import gvcpu, vcpu
    prog = gvcpu.fold(vcpu.decode(image), wires=(64, need))
    watch = tuple(v.addr for v in outs)
    last = None
    for trial in ([1.0], [1.0, 0.75], [1.5, 1.25], [3.0, 2.0], [1.0, -1.0], [5.0, 3.0]):
        seed = dict(ch.consts)
        for k, v in enumerate(ins):
            seed[v.addr] = int(quantize(trial[k % len(trial)], v.depth))
        last = (seed, watch)
        rep, got = lane._walked(prog, need, last)
        if rep == 0 and any(x != 0 for x in got):
            return last
    return last


# ---- 内積の道 -------------------------------------------------------------
#
# 1 レーン 1 要素の道では行列の積が書けない。他のレーンの値が要るからになる。そこで
# レーンを**出力の要素**に取り、係数と入力の行を共有メモリから読む。
#
#     lane (i, j) が  y[i,j] = Σ_k x[i,k] · W[j,k]
#
# バイアスは項を 1 本足して吸わせる。こうすると足し算も Common の側に残る。
#
#     x'[i,K] = 1,   W'[j,K] = b[j]
#
# `fold.twin_ptr(K+1)` が「2 つの先頭アドレスから K+1 項を掛けて足す」ソースで、
# 先頭アドレスはレーンごとに host が置く。

MATMUL = {"mm", "addmm", "linear", "matmul"}


def _tensor_of(gm, node, example_inputs, order):
    """fx のノードが指す実際の tensor を返す。placeholder と get_attr と t を辿る。"""
    if node.op == "placeholder":
        return example_inputs[order.index(node)], False
    if node.op == "get_attr":
        return getattr(gm, node.target), False
    name = chamber._name_of(node)
    if name == "t":
        t, flip = _tensor_of(gm, node.args[0], example_inputs, order)
        return t, not flip
    if name in ("to", "_to_copy", "clone", "detach", "contiguous", "view", "reshape"):
        return _tensor_of(gm, node.args[0], example_inputs, order)
    raise chamber.NeedsTable("内積の入力が %s から来ている" % name)


def _rows(gm, node, example_inputs, order):
    """行列の積を (入力 x, 出力ごとの係数の行 W, バイアス) に直す。

    どの形でも「行 j が出力 j の係数」になるよう並べ替える。並べ替えは host の転記。
    """
    name = chamber._name_of(node)
    if name == "addmm":
        # addmm(bias, x, Wt) は x @ Wt。Wt は (K, N) なので行を出力に合わせて直す
        bias, a, b, already = node.args[0], node.args[1], node.args[2], False
    elif name in ("mm", "matmul"):
        bias, a, b, already = None, node.args[0], node.args[1], False
    elif name == "linear":
        # linear(x, W, b) の W は (N, K)。行 j がそのまま出力 j の係数になる
        bias = node.args[2] if len(node.args) > 2 else node.kwargs.get("bias")
        a, b, already = node.args[0], node.args[1], True
    else:
        raise chamber.NeedsTable(name)
    x, xt = _tensor_of(gm, a, example_inputs, order)
    w, wt = _tensor_of(gm, b, example_inputs, order)
    if xt:
        x = x.t()
    if not already:
        w = w if wt else w.t()
    elif wt:
        w = w.t()
    bs = None
    if bias is not None and hasattr(bias, "op"):
        bs, _ = _tensor_of(gm, bias, example_inputs, order)
    return x.contiguous(), w.contiguous(), bs


class Product(object):
    """行列の積を 1 枚の image で走らせる。レーンは出力の要素。"""

    def __init__(self, x, w, bias, shape, dtype, depth=None):
        self.shape, self.dtype = shape, dtype
        self.m, self.k = int(x.shape[0]), int(x.shape[1])
        # 桁は項の数から決める。K 個の積を足すので、分子は K·2^(2F)·|xw| まで大きくなる。
        # 64 bit の符号を残して 2^62 に収めたい。値の大きさに 2^8 の余裕を見る。
        import math
        self.depth = depth if depth is not None else max(
            6, min(20, (54 - int(math.ceil(math.log2(max(2, self.k + 1))))) // 2))
        depth = self.depth
        self.n = int(w.shape[0])
        self.terms = self.k + 1
        self.xq = quantize(x.detach().cpu().numpy(), depth)
        self.wq = quantize(w.detach().cpu().numpy(), depth)
        self.bq = (quantize(bias.detach().cpu().numpy(), 2 * depth)
                   if bias is not None else np.zeros((self.n,), dtype=np.int64))
        self._lanes = None

    def _board(self):
        from common_vcpu import gvcpu, vcpu
        if self._lanes is not None:
            return self._lanes
        text = fold.twin_ptr(self.terms)
        image, need, _ = lane.build(text, "prod%d" % self.terms)
        seed = {fold.ROW: fold.ROW + 512, fold.XPT: fold.ROW + 1024}
        for j in range(self.terms):
            seed[fold.ROW + 512 + j] = j + 2
            seed[fold.ROW + 1024 + j] = j * 3 + 1
        prog = lane.best(vcpu.decode(image), need, (seed, (fold.OUT,)))
        lanes = self.m * self.n
        romlo = fold.OUT + 1
        romn = (self.m + self.n) * self.terms
        L = gvcpu.Lanes(prog, need, fold.ROW, romlo, romn, lanes, sync=False)
        # 共有メモリ: 入力の行（M 本）→ 係数の行（N 本）。どちらも K+1 語ずつ
        xrow = np.concatenate([self.xq, np.ones((self.m, 1), dtype=np.int64)], axis=1)
        wrow = np.concatenate([self.wq, self.bq.reshape(self.n, 1)], axis=1)
        L.rom_put(0, xrow.reshape(-1).astype(np.uint64))
        L.rom_put(self.m * self.terms, wrow.reshape(-1).astype(np.uint64))
        idx = np.arange(lanes, dtype=np.int64)
        L.put_block(fold.ROW, (romlo + (idx // self.n) * self.terms)
                    .astype(np.uint64).reshape(1, lanes))
        L.put_block(fold.XPT, (romlo + self.m * self.terms + (idx % self.n) * self.terms)
                    .astype(np.uint64).reshape(1, lanes))
        self._lanes = L
        return L

    def __call__(self):
        L = self._board()
        rep, W = L.run(watch=(fold.OUT,))
        bad = rep[(rep != 0) & (rep != 10)]
        if len(bad):
            raise RuntimeError("lane64 の報告 %s" % sorted(set(int(x) for x in bad)))
        raw = W[:, 0].get().astype(np.int64)
        val = dequantize(raw, 2 * self.depth).reshape(self.m, self.n)
        return (torch.as_tensor(val.reshape(self.shape)).to(self.dtype),)


def _needs_table(g):
    """レーンをまたぐ値が要る演算が入っているか。"""
    for n in g.nodes:
        if n.op in ("call_function", "call_method") and chamber._name_of(n) in chamber.NEEDS_TABLE:
            return True
    return False


# 生きている表。呼ばれた順に並べ、`KEEP` を越えた古いものから板の VRAM を放す。
# モデル全体を一つの表にすると共有帯に全部の重みが入るので、層ごとに表を持つ。
BOARDS = collections.OrderedDict()
KEEP = [2]


def keep_boards(n=None):
    """VRAM に残す表の数を決める。越えた分は板を捨てる（次の呼びで組み直す）。"""
    if n is not None:
        KEEP[0] = max(1, int(n))
    while len(BOARDS) > KEEP[0]:
        _, t = BOARDS.popitem(last=False)
        try:
            t.low.close()
        except Exception:
            pass


class Table(object):
    """グラフ全部をステージの表へ落として 1 回で走らせる道。

    行列の積も、要素ごとの演算も、縮約も、同じ表の 1 ステージになる。レーンは
    出力の 1 要素で、ステージのあいだの受け渡しは共有メモリへの書き込み（接合点）で
    足並みが揃う。
    """

    def __init__(self, gm, example_inputs, meta, depth=None):
        # 桁は graph の一番長い内積から決める（`Lower._depth`）
        self.gm, self.depth = gm, depth
        self.low = graph.Lower(gm, example_inputs, depth=depth).emit()
        self.meta = meta

    def _go(self, args):
        """実引数と weight を上げて走らせる。"""
        self.low.refresh(args)              # 実引数と weight がカットを渡る
        return self.low.B.run()

    def __call__(self, *args):
        BOARDS[id(self)] = self
        BOARDS.move_to_end(id(self))
        keep_boards()
        if self.low.outgrown(args):
            # 分子の上限は組んだときの値から測る。実引数か weight がそれを越えたら、
            # いまの値で組み直す。放って走らせると乗算が報告 43 で止まる。
            # 前の板の VRAM は先に放す（組み直すたびに積み上がる）
            self.low.close()
            self.low = graph.Lower(self.gm, list(args), depth=self.depth).emit()
        J, rep, steps = self._go(args)
        bad = rep[(rep != 0) & (rep != 10)]
        if len(bad):
            got = sorted(set(int(x) for x in bad))
            if 43 in got:
                # 分子が 64 bit を越えた。上限は組んだときの値から測るので、実行時の値が
                # それより大きいと足りない。**いまの値で組み直して一度だけやり直す。**
                # エンジンが必ず捕まえるので、黙って壊れることはない
                self.low.close()
                self.low = graph.Lower(self.gm, list(args), depth=self.depth).emit()
                J, rep, steps = self._go(args)
                bad = rep[(rep != 0) & (rep != 10)]
                got = sorted(set(int(x) for x in bad))
            if len(bad):
                raise RuntimeError("lane64 の報告 %s" % got)
        got = []
        for (head, rows, cols, d), (shape, dtype) in zip(self.low.outputs(), self.meta):
            v = self.low.B.read(J, head, rows, cols) / float(1 << d)
            t = torch.as_tensor(np.asarray(v).reshape(shape))
            got.append(t.to(torch.bool) if dtype == torch.bool else t.to(dtype))
        return tuple(got)
