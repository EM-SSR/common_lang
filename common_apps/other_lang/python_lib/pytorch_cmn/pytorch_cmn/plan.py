# -*- coding: utf-8 -*-
"""計算を段の表へ落とす。三つの原始だけで組む。

`walk.board` の一段が出すのは二つ。

$$\\text{値}=\\sum_{j<K} M[w_j]\\cdot M[x_j]\\;+\\;M\\bigl[\\,M[\\text{先頭}]+M[\\text{添字}]\\,\\bigr],
\\qquad \\text{フラグ}=\\bigl[\\,M[b]\\le M[a]\\,\\bigr]$$

使わない側は零の枠へ向ける。だから段の組み方は三通りになる。

| 組み方 | 使うもの |
|---|---|
| `fold` | 内積だけ |
| `look` | 引きだけ |
| `less` | フラグだけ |

## 右シフトが無いことへの答え

分子を右へ寄せる命令が無い（`se` は $(\\text{分子},F)\\mapsto(\\text{分子}+2^F,F+1)$、
`za` は分子を変えず、`ba` は対を返すだけ）。そこで**比較のラダー**で桁を取り出す。

$$b_k=[\\,2^k\\le r_k\\,],\\qquad r_{k+1}=r_k-b_k2^k,
\\qquad \\Bigl\\lfloor\\frac{x}{2^m}\\Bigr\\rfloor=\\sum_{k\\ge m}b_k2^{k-m}$$

一桁につきフラグの段と残りの段で二段。幅 $W$ の値なら $2W+1$ 段で右シフトが出る。
全部の lane が同じ段を歩くので、足並みを揃える道がそのまま使える。
"""


class Plan(object):
    """枠を配り、段を並べる。枠 0 は零で、これが「使わない」印になる。"""

    def __init__(self):
        self.slots = [0]                 # 枠 0 = 零
        self.rows = []                   # (出す枠, フラグの枠, 引きの先頭, 引きの添字, 比べる二つ, 項)
        self.const = {}
        self.zero_at = None              # 「零の在る番地」の枠。引きを使わない段が指す

    # -- 枠 --
    def put(self, value=0):
        self.slots.append(int(value))
        return len(self.slots) - 1

    def imm(self, value):
        """定数の枠。同じ値は使い回す。"""
        v = int(value)
        if v not in self.const:
            self.const[v] = self.put(v)
        return self.const[v]

    # -- 段 --
    def _row(self, terms=(), look=None, less=None):
        """一段。使わない所は零の枠へ向ける。引きの先頭は「零の在る番地」を指す。"""
        if self.zero_at is None:
            self.zero_at = self.put(0)   # 走らせる前に host が零の枠の番地を入れる
        out = self.put()
        flag = self.put()
        lb, li = (look if look else (self.zero_at, 0))
        ca, cb = (less if less else (0, 0))
        self.rows.append((out, flag, lb, li, ca, cb, list(terms)))
        return out, flag

    def fold(self, terms):
        """$\\sum M[w]\\cdot M[x]$。"""
        return self._row(terms=terms)[0]

    def look(self, base, index):
        """$M[\\,M[\\text{base}]+M[\\text{index}]\\,]$。base の枠には表の先頭番地が入る。"""
        return self._row(look=(base, index))[0]

    def less(self, a, b):
        """$[\\,M[b]\\le M[a]\\,]$ をフラグとして返す。"""
        return self._row(less=(a, b))[1]

    # -- 組み立て --
    def mul(self, a, b):
        return self.fold([(a, b)])

    def add(self, *xs):
        one = self.imm(1)
        return self.fold([(one, x) for x in xs])

    def neg(self, a):
        return self.fold([(self.imm(-1), a)])

    def sub(self, a, b):
        return self.fold([(self.imm(1), a), (self.imm(-1), b)])

    def scale(self, a, m):
        """$2^m$ 倍。左は掛けるだけで済む。"""
        return self.fold([(self.imm(1 << m), a)])

    def pick(self, flag, a, b):
        """フラグが 1 なら a、0 なら b。$b+\\text{flag}\\cdot(a-b)$。"""
        return self.fold([(self.imm(1), b), (flag, self.sub(a, b))])

    # -- 比較のラダー --
    def bits(self, x, width):
        """$x\\ge0$ の桁を上から取り出す。返りは $[b_{W-1},\\ldots,b_0]$ の枠。"""
        out = [None] * width
        r = x
        for k in range(width - 1, -1, -1):
            p = self.imm(1 << k)
            b = self.less(r, p)                       # [2^k ≤ r]
            out[k] = b
            if k:
                r = self.fold([(self.imm(1), r), (self.imm(-(1 << k)), b)])
        return out

    def rshift(self, x, m, width):
        """$\\lfloor x/2^m\\rfloor$。ラダーで桁にしてから、残す桁だけを足し合わせる。"""
        b = self.bits(x, width)
        return self.fold([(self.imm(1 << (k - m)), b[k]) for k in range(m, width)])

    def sign_split(self, x, width):
        """符号と大きさに割る。フラグは $[0\\le x]$、大きさは $|x|$。"""
        s = self.less(x, self.imm(0))                 # [0 ≤ x]
        mag = self.pick(s, x, self.neg(x))
        return s, mag

    def rshift_signed(self, x, m, width):
        """符号つきの右シフト。零へ寄せる丸めになる。"""
        s, mag = self.sign_split(x, width)
        q = self.rshift(mag, m, width)
        return self.pick(s, q, self.neg(q))

    # -- 表 --
    def table(self, k=None):
        """段の表と、枠の初期値を返す。k は一段の項の数。"""
        k = k or max((len(t) for *_h, t in self.rows), default=1)
        tab = []
        for out, flag, lb, li, ca, cb, terms in self.rows:
            pad = list(terms) + [(0, 0)] * (k - len(terms))
            tab += [out, lb, li, flag, ca, cb]
            for w, x in pad:
                tab += [w, x]
        return tab, list(self.slots), k

    # -- 固定小数 --------------------------------------------------------
    #
    # 値 = 分子 · 2^-F。積は分子が掛け合わさって桁が 2F になるので、ラダーで F 段戻す。
    # 幅は積が収まる桁数を取る。`width` を小さくすると段が減るが、溢れると答えが崩れる。

    def fmul(self, a, b, f, width):
        """固定小数の積。桁 F の値二つから桁 F の値を出す。"""
        return self.rshift_signed(self.mul(a, b), f, width)

    def fix(self, value, f):
        """実数を桁 F の枠へ。"""
        return self.imm(int(round(value * (1 << f))))

    def recip(self, b, f, width, rounds=5, guess=0.5):
        """$1/b$ を Newton で。$y\leftarrow y(2-by)$。b は正で桁 F。"""
        y = self.fix(guess, f)
        two = self.fix(2.0, f)
        for _ in range(rounds):
            d = self.sub(two, self.fmul(b, y, f, width))
            y = self.fmul(y, d, f, width)
        return y

    def rsqrt(self, x, f, width, rounds=6, guess=1.0):
        """$1/\sqrt x$ を Newton で。$y\leftarrow y(3-xy^2)/2$。"""
        y = self.fix(guess, f)
        three = self.fix(3.0, f)
        half = self.fix(0.5, f)
        for _ in range(rounds):
            yy = self.fmul(y, y, f, width)
            d = self.sub(three, self.fmul(x, yy, f, width))
            y = self.fmul(self.fmul(y, d, f, width), half, f, width)
        return y

    def exp2m(self, x, f, width, m=6):
        """$e^x$ を $(1+x/2^m)^{2^m}$ で。倍加を m 回、どれも固定小数の積になる。"""
        one = self.fix(1.0, f)
        t = self.fold([(self.imm(1), one), (self.imm(1), self.rshift_signed(x, m, width))])
        for _ in range(m):
            t = self.fmul(t, t, f, width)
        return t

    def isqrt(self, x, width):
        """$\lfloor\sqrt x\rfloor$ を桁ごとに立てる。Newton と違って始めの値に依らない。

        $$y_k=y_{k+1}+2^k\cdot\bigl[(y_{k+1}+2^k)^2\le x\bigr]$$

        上の桁から順に、立てても $x$ を越えないかを比べる。一桁につき三段。
        """
        y = self.imm(0)
        for k in range(width // 2 - 1, -1, -1):
            t = self.fold([(self.imm(1), y), (self.imm(1 << k), self.imm(1))])
            b = self.less(x, self.mul(t, t))          # [t² ≤ x]
            y = self.fold([(self.imm(1), y), (self.imm(1 << k), b)])
        return y

    def fsqrt(self, x, f, width):
        """桁 F の $\sqrt x$。先に F 段左へ寄せると、平方根がそのまま桁 F になる。

        $\sqrt{n\cdot2^F\cdot2^{-F}}\cdot2^{F}=\sqrt{n\cdot2^{F}}$ なので、
        分子を $2^F$ 倍してから整数の平方根を取る。
        """
        return self.isqrt(self.scale(x, f), width)

    def frsqrt(self, x, f, width, rounds=5):
        """桁 F の $1/\sqrt x$。平方根を桁で立ててから逆数を Newton で取る。"""
        return self.recip(self.fsqrt(x, f, width), f, width, rounds=rounds)

    # -- 層 --------------------------------------------------------------

    def dot(self, xs, ys):
        """$\sum x_iy_i$ を桁 F のまま出す（呼ぶ側が戻す）。"""
        return self.fold(list(zip(xs, ys)))

    def mean(self, xs, f, width):
        """並びの平均。$1/n$ を定数として掛ける。"""
        one = self.imm(1)
        s = self.fold([(one, x) for x in xs])
        return self.fmul(s, self.fix(1.0 / len(xs), f), f, width)

    def layernorm(self, xs, gamma, beta, f, width, eps=1e-5):
        """$\hat x_i=\gamma_i\dfrac{x_i-\mu}{\sqrt{\sigma^2+\varepsilon}}+\beta_i$。

        平均と分散は内積、逆平方根は桁ごとの平方根と Newton の逆数で出す。
        """
        mu = self.mean(xs, f, width)
        d = [self.sub(x, mu) for x in xs]
        var = self.mean([self.fmul(t, t, f, width) for t in d], f, width)
        inv = self.frsqrt(self.add(var, self.fix(eps, f)), f, width)
        out = []
        for t, g, b in zip(d, gamma, beta):
            out.append(self.add(self.fmul(self.fmul(t, inv, f, width), g, f, width), b))
        return out

    def top(self, xs):
        """並びの最大と、その添字。比較のフラグで選ぶ。argmax がこれで出る。"""
        best, arg = xs[0], self.imm(0)
        for i, x in enumerate(xs[1:], 1):
            b = self.less(x, best)                 # [best ≤ x]
            best = self.pick(b, x, best)
            arg = self.pick(b, self.imm(i), arg)
        return best, arg

    def softmax(self, xs, f, width, m=6):
        """$\dfrac{e^{x_i-\max x}}{\sum_j e^{x_j-\max x}}$。"""
        hi, _ = self.top(xs)
        e = [self.exp2m(self.sub(x, hi), f, width, m=m) for x in xs]
        z = self.fold([(self.imm(1), t) for t in e])
        inv = self.recip(z, f, width)
        return [self.fmul(t, inv, f, width) for t in e]
