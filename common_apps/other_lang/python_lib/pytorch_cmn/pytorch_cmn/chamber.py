# -*- coding: utf-8 -*-
"""fx.Graph をコモン公用語の平文へ落とす。要素ごとの演算だけを扱う。

1 レーンが 1 要素を持つ。だから内積のように他のレーンの値が要る演算はここでは扱わず、
`walk.py` のステージの表へ回す。

## 固定小数

値 = 分子 · 2^-F で持つ。積は分子が掛け合わさるので F が 2F になる。**放っておくと
積のたびに F が増え、64 bit を越えて値が 0 になる**（F=12 なら 5 回で 2^72 mod 2^64 = 0）。
そこで二つの手当てをする。

1. まず graph 全体で「F が何倍になるか」を数え、収まるなら F を小さく選ぶ
2. それでも越えるなら、積のあとに右シフトを挿んで F を戻す

右シフトの命令は無いので、比較で桁を立てて作る。

$$b_k=\\bigl[\\,2^k\\le r_k\\,\\bigr],\\qquad r_{k+1}=r_k-b_k2^k,
\\qquad \\Bigl\\lfloor\\frac{x}{2^m}\\Bigr\\rfloor=\\sum_{k\\ge m}b_k2^{k-m}$$

## 番地

生きている値ごとに 1 語を配る。同時に生きている値には別の語が当たる（Common Assembler
式 13.2）。どの割り当てを選んでも意味が変わらないことは定理 13.1 が与える。
"""
import itertools


# ---- aten の名前 → intent の語 -------------------------------------------

WORD = {
    "mul":      ["ext"],            # ⋆  経路を保つ
    "add":      ["acc"],            # ⊕  実軸を渡る
    "sub":      ["flip", "acc"],
    "neg":      ["flip"],
    "le":       ["under"],          # ≤  Dyad → Bit → Dyad
    "halve":    ["halve"],          # β
    "read":     ["read"],
    "keep":     ["keep"],
    "unit":     ["unit"],
    "zero":     ["zero"],
    # 値を動かさない移り。番地を 1 つ配って写すだけ
    "to": [], "to_copy": [], "clone": [], "detach": [], "contiguous": [],
    "view": [], "reshape": [], "expand": [], "alias": [], "lift_fresh_copy": [],
}

# 平文は「後に言った方が第一引数」なので、aten と向きが逆になる語がある。
# `hi` は `X ka, Y ka, hi ka` = [Y ≤ X]（2026-09-27 に実測）。
REV = {"le"}

# 1 レーンが 1 要素を持つ形では書けない演算。ステージの表へ回す。
#
# レーンをまたぐ値が要るもの（内積と縮約）と、桁ごとに立てる形で出すもの（逆数・平方根・
# 指数）の両方が入る。後者はレーンをまたがないが、要素ごとの道に語が無い。
NEEDS_TABLE = {"mm", "bmm", "addmm", "linear", "matmul", "dot", "mv",
               "sum", "mean", "var", "amax", "amin", "max", "min", "argmax",
               "softmax", "_softmax", "layer_norm", "rms_norm",
               "native_layer_norm", "cumsum",
               "div", "truediv", "floordiv", "reciprocal",
               "exp", "sqrt", "rsqrt", "sigmoid", "silu",
               # これが無いと、Dynamo が graph を切った位置によって SDPA 単独の graph が
               # Walk へ回り「Unknown」で落ちる。Linear と同じ graph に居るかどうかで
               # 動いたり壊れたりする
               "scaled_dot_product_attention", "sdpa", "embedding"}


def _spec_types():
    """値ではなく「型や置き場の指定」として渡ってくるもの。引数から飛ばす。

    torch が無い環境でもこのモジュールを import できるようにしておく。
    """
    try:
        import torch
    except ImportError:
        return ()
    return tuple(t for t in (getattr(torch, n, None)
                             for n in ("dtype", "device", "layout", "memory_format"))
                 if isinstance(t, type))


SPEC = _spec_types()


class Unknown(Exception):
    """対応表に無い演算。名前を持って上がる。"""


class NeedsTable(Exception):
    """他のレーンの値が要る演算。`walk.py` のステージの表で書く。"""


# ---- 値 ------------------------------------------------------------------

class Val(object):
    """分子の置き場と、いまの F。F は host が持つ割り当ての属性で、語には入らない。"""

    __slots__ = ("addr", "depth")

    def __init__(self, addr, depth=0):
        self.addr = addr
        self.depth = depth

    def __repr__(self):
        return "Val(@%d, F=%d)" % (self.addr, self.depth)


def _name_of(node):
    """fx のノードから aten の短い名前を取る。"""
    t = getattr(node.target, "_overloadpacket", node.target)
    return getattr(t, "__name__", str(t)).lstrip("_").split(".")[-1]


def multiplier(graph):
    """graph を通ったあと F が何倍になるかを数える。F を選ぶために先に測る。"""
    m = {}
    worst = 1
    for n in graph.nodes:
        if n.op == "placeholder":
            m[n] = 1
        elif n.op == "output":
            continue
        else:
            got = [m.get(u, 1) for u in n.all_input_nodes]
            name = _name_of(n)
            if name == "mul":
                m[n] = sum(got[:2]) if len(got) >= 2 else (got[0] if got else 1)
            elif name == "le":
                m[n] = 0
            else:
                m[n] = max(got) if got else 1
        worst = max(worst, m[n])
    return worst


# ---- チェンバー ----------------------------------------------------------

class Chamber(object):
    """1 つの fx.Graph に対応する 1 つのチェンバー。

    `text()` が平文を返す。文の並びは因果深度の昇順で、同じ深度の中は frontier の
    左端の昇順になる（Common Assembler 定理 4.1 の正準形）。
    """

    BASE = 1 << 16          # 本文の作業領域はワイヤ（語 64 + w）の上に置く（19 §3.3）
    CAP = 48                # 分子の桁の上限。これを越えないよう右シフトを挿む
    WIDTH = 62              # 右シフトで見る桁数の上限（64 bit の符号の分を残す）
    HEAD = 10               # 分子は 2^F より大きくなりうるので、その分の余裕

    def __init__(self, graph, depth=None):
        self.graph = graph
        self.rung = itertools.count(1)
        self.val = {}                  # fx.Node → Val
        self.lines = []
        self.consts = {}               # 番地 → 分子（host が置く）
        self.last = self.BASE
        mult = multiplier(graph)
        # 積の回数から F を決める。収まるなら右シフトを挿まずに済む
        self.mult = mult
        self.depth = depth if depth is not None else max(6, min(12, self.CAP // max(1, mult)))
        self.shifted = 0               # 挿んだ右シフトの回数

    # -- 番地 --
    def landmark(self):
        self.last = self.BASE + next(self.rung)
        return self.last

    def top(self):
        """配った番地の一番上。作業領域の上端はここで決まる。"""
        return self.last

    def const(self, numer):
        """分子を 1 語に置く。同じ分子は 1 つの語を使い回す（host がシードとして入れる）。"""
        numer = int(numer)
        for a, v in self.consts.items():
            if v == numer:
                return Val(a, 0)
        a = self.landmark()
        self.consts[a] = numer
        return Val(a, 0)

    # -- 層 --
    def layers(self):
        """因果深度で層へ割る。$h(v)=1+\\max_{u\\in\\mathrm{Pred}(v)}h(u)$（16 式 2.2）。"""
        h, out = {}, {}
        for n in self.graph.nodes:
            pred = [h[u] for u in n.all_input_nodes if u in h]
            h[n] = 1 + max(pred) if pred else 0
        for n, r in h.items():
            out.setdefault(r, []).append(n)
        return [out[r] for r in sorted(out)]

    # -- 平文 --
    def say(self, *words):
        if words:
            self.lines.append(" ".join(w + " ka," for w in words).rstrip(","))

    def addr_of(self, a):
        """番地を 2 の冪の和で綴る。`unit` を `rung` で倍にして足す。

        数の桁を綴るのではなく、番地を作図で指している。commonc は定数を足し合わせるので、
        走るときの費用には乗らない。
        """
        out = []
        for n in sorted((k for k in range(a.bit_length()) if a >> k & 1), reverse=True):
            out += ["unit"] + ["rung"] * n + (["acc"] if out else [])
        return out

    def load(self, v):
        self.say(*(self.addr_of(v.addr) + ["read"]))

    def store(self, v):
        self.say(*(self.addr_of(v.addr) + ["keep"]))

    def fresh(self, depth):
        return Val(self.landmark(), depth)

    # -- 組み立ての部品 --
    def emit1(self, words, args, depth):
        """引数を積んで語を当て、新しい番地へ置く。"""
        out = self.fresh(depth)
        for a in args:
            self.load(a)
        for w in words:
            self.say(w)
        self.store(out)
        return out

    def scale_up(self, v, m):
        """F を m 段上げる（分子を 2^m 倍する）。`rung` を m 回。"""
        if m <= 0:
            return v
        out = self.fresh(v.depth + m)
        self.load(v)
        for _ in range(m):
            self.say("rung")
        self.store(out)
        return out

    def align(self, args):
        """⊕ や ≤ の前に F を揃える。浅い側を新しい番地へ写してから上げる。"""
        top = max(a.depth for a in args)
        return top, [a if a.depth == top else self.scale_up(a, top - a.depth) for a in args]

    def two_pow(self, k):
        """定数 2^k を 1 つの値として置く。"""
        return self.const(1 << k)

    def rshift(self, v, m, width=None):
        """$\\lfloor v/2^m\\rfloor$。符号を分けてから、比較で桁を立てて組む。

        右シフトの命令が無いので、上の桁から「立てても越えないか」を比べる。
        1 桁につき比較と引き算の 2 文で、最後に残す桁だけを足し合わせる。
        """
        if m <= 0:
            return v
        width = width or self.WIDTH
        # ここから下は分子そのものを整数として扱う。F は最後に付け直す
        raw = Val(v.addr, 0)
        zero = self.const(0)
        sgn = self.emit1(["under"], [raw, zero], 0)        # [0 ≤ v]
        neg = self.emit1(["flip"], [raw], 0)
        mag = self.select(sgn, raw, neg)
        bits, r = [], mag
        for k in range(width - 1, -1, -1):
            b = self.emit1(["under"], [r, self.two_pow(k)], 0)     # [2^k ≤ r]
            bits.append((k, b))
            if k:
                cut = self.emit1(["ext"], [b, self.two_pow(k)], 0)
                r = self.emit1(["flip", "acc"], [r, cut], 0)
        acc = None
        for k, b in bits:
            if k < m:
                continue
            term = self.emit1(["ext"], [b, self.two_pow(k - m)], 0)
            acc = term if acc is None else self.emit1(["acc"], [acc, term], 0)
        if acc is None:
            acc = self.const(0)
        back = self.emit1(["flip"], [acc], 0)
        got = self.select(sgn, acc, back)
        got.depth = v.depth - m
        return got

    def select(self, flag, a, b):
        """フラグが 1 なら a、0 なら b。$b+\\text{flag}\\cdot(a-b)$。"""
        d, (a, b) = self.align([a, b])
        diff = self.emit1(["flip", "acc"], [a, b], d)
        pick = self.emit1(["ext"], [flag, diff], d)
        return self.emit1(["acc"], [b, pick], d)

    def fit(self, v):
        """分子の桁が上限を越えたときだけ右シフトで戻す。

        積のあとに毎回戻すと、比較で桁を立てる文が積 1 つにつき千を越えて入り、ワイヤが
        作業領域に届いてしまう。**F は増えたままでよい**。困るのは 64 bit を越えるときだけ
        なので、そのときに限って戻す。出力の F は host が持っているので、実数へ戻す割り算は
        合う。
        """
        if v.depth <= self.CAP:
            return v
        self.shifted += 1
        # 桁数は**分子の大きさ**で決まる。値が 1 を越えると分子は 2^F より大きいので、
        # F だけを見て幅を決めると上の桁を取りこぼす。
        return self.rshift(v, v.depth - self.depth,
                           width=min(self.WIDTH, v.depth + self.HEAD))

    # -- ノード --
    def emit(self):
        for layer in self.layers():
            for n in layer:
                self.node(n)
        return self

    def arg_vals(self, n):
        """ノードの引数を Val の並びにする。数の引数は定数の語にする。

        `all_input_nodes` は Node しか返さないので、`x * 2` の `2` が落ちる。
        `args` と `kwargs` の両方を見る。
        """
        out = []
        for a in list(n.args) + [v for k, v in sorted(n.kwargs.items()) if k not in ("out", "alpha", "dtype", "device", "layout", "memory_format", "pin_memory")]:
            if hasattr(a, "op"):                        # fx.Node
                out.append(self.val[a])
            elif isinstance(a, bool):
                out.append(Val(self.const(int(a) << self.depth).addr, self.depth))
            elif isinstance(a, (int, float)):
                out.append(Val(self.const(round(a * (1 << self.depth))).addr, self.depth))
            elif a is None or isinstance(a, (list, tuple, str, SPEC)):
                continue            # shape・dtype・device などの指定。値ではないので飛ばす
            else:
                raise Unknown("引数の型 %s" % type(a).__name__)
        return out

    def node(self, n):
        if n.op == "placeholder":
            self.val[n] = self.fresh(self.depth)
            return
        if n.op == "output":
            return
        if n.op not in ("call_function", "call_method"):
            raise Unknown(n.op)
        name = _name_of(n)
        if name in NEEDS_TABLE:
            raise NeedsTable(name)
        if name not in WORD:
            raise Unknown(name)
        args = self.arg_vals(n)
        alpha = n.kwargs.get("alpha")
        if alpha is not None and alpha != 1 and name in ("add", "sub") and len(args) >= 2:
            k = Val(self.const(round(float(alpha) * (1 << self.depth))).addr, self.depth)
            args = [args[0], self.fit(self.emit1(["ext"], [args[1], k],
                                                args[1].depth + self.depth))]
        if not WORD[name]:                              # 値を動かさない移り
            src = args[0]
            out = self.fresh(src.depth)
            self.load(src)
            self.store(out)
            self.val[n] = out
            return
        if name in ("add", "sub", "le"):
            d, args = self.align(args[:2])
            if name == "le":
                d = self.depth                          # 比較の出力は 0 か 1
        elif name == "mul":
            d = sum(a.depth for a in args[:2])
            args = args[:2]
        elif name == "halve":
            d = args[0].depth + 1
        else:
            d = args[0].depth if args else self.depth
        out = self.emit1(WORD[name], (list(reversed(args)) if name in REV else args), d)
        if name == "le":
            # 0/1 の Bit を、F を持つ値として使えるようにする
            out = self.scale_up(out, self.depth)
            out.depth = self.depth
        self.val[n] = self.fit(out)

    # -- 出力 --
    def text(self, note=True):
        head = ["ma ma ka, kukeke kukeke ka, kukese ka, mo ka, ho ka"] if note else []
        return "\n".join(head + self.lines + ["said"]) + "\n"

    def outputs(self):
        """出力ノードの並び。tuple でも 1 つでも同じ形で返す。"""
        node = [n for n in self.graph.nodes if n.op == "output"][0]
        got = node.args[0]
        if isinstance(got, (tuple, list)):
            return list(got)
        return [got]
