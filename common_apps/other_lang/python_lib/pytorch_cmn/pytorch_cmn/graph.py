# -*- coding: utf-8 -*-
"""fx.Graph をステージの表へ落とす。

`walk.engine3` の 1 ステージが出すのは

$$\\text{値}=\\sum_{j<K}M\\bigl[w+j\\bigr]\\cdot M\\bigl[x+j\\bigr]
\\;+\\;M\\bigl[\\,M[\\text{参照元}]+M[\\text{添字}]\\,\\bigr],
\\qquad \\text{フラグ}=\\bigl[\\,M[b]\\le M[a]\\,\\bigr]$$

で、アドレスはどれも

$$\\text{先頭}+s_1i_1+s_2i_2+s_3i_3+j$$

になる。$(i_1,i_2,i_3)$ はレーンごとに host が置く番号で、$s$ はステージごとの歩幅。

## レーンの割り当て

1 回の起動で全ノードを流すため、レーンの番号は**固定**する。

$$i_1=\\Bigl\\lfloor\\frac{\\mathrm{id}}{N}\\Bigr\\rfloor,\\qquad i_2=\\mathrm{id}\\bmod N$$

$N$ はグラフ全体で一番幅の広いテンソルの列数になる。どのテンソルも行を $N$ 語に
揃えて置くので、幅の狭いテンソルを扱うステージでも、はみ出したレーンは同じブロックの
余りへ書くだけで済む。

## 歩幅の決め方

| ノード | 出力 | 係数 | 入力 | 項 |
|---|---|---|---|---|
| 要素ごと $a\\odot b$ | $(N,1)$ | $a$ が $(N,1)$ | $b$ が $(N,1)$ | 1 |
| 行列の積 $xW^{\\top}$ | $(N,1)$ | $W$ が $(0,K)$ | $x$ が $(N_x,0)$ | $K$ |
| 行の総和 | $(N,0)$ | 1 の並び $(0,0)$ | $x$ が $(N_x,0)$ | $K$ |

足し算は「係数を 1 にした内積」、掛け算は「項が 1 本の内積」になる。
"""
import numpy as np

from . import chamber
from . import fold
from . import lane
from . import walk

ROMLO = fold.ROW + 40          # 作業領域はここまで。上は共有メモリ


class Build(object):
    """共有メモリの割り当てと、ステージの表を組む。"""

    def __init__(self, width, lanes, depth=12, unroll=1, threads=128, groups=1):
        """レーンは三軸 $(a,b,c)$ で並ぶ。id $= a\cdot BC + b\cdot C + c$。

        $a$ は行、$b$ は列、$c$ は**内積の組**になる。1 lane が $K$ 項を全部持つと
        GPU の利得が出ない（実測 512 項/lane・4096 lane = 0.391 G 積和/秒、
        16〜32 項/lane・65536 lane = 2.5 G）。$c$ を使って $K$ をレーンへ割る。

        要素ごとの段は $c$ の歩幅を 0 にする。$C$ 本のレーンが同じ番地へ同じ値を書くので、
        足並みを揃える道の「全 lane が段ごとにちょうど一度書く」を崩さない。
        """
        self.width = int(width)        # 置き場を確保するときの最大の詰め幅
        # いま組んでいる置き場の行の詰め。**置き場ごとに違う。**
        #
        # 一つの幅で揃えると、レーンの番号が id = i₁·(C·width) + i₂·C + i₃ なので
        # レーン数が「行の最大 × 列の最大」になる。Qwen 1 層 T=1 では 64 × 17408 =
        # 111 万本で、同時に載る上限 55296 の 20 倍。実際はどの置き場も 17408 語以下
        # （FFN の中間が 1 行 17408 列、attention の中間が 40 行 128 列）なので、詰めを
        # 置き場ごとに持てば収まる。
        self.W = int(width)
        self.groups = max(1, int(groups))
        self.threads = int(threads)
        # Joint はレーン数を thread 数の倍数へ丸める。余ったレーンも書き込むので、
        # テンソルはレーン全部が収まる大きさで取る。はみ出すと隣のテンソルを壊す。
        # **物理の lane は GPU に同時に載る数で頭打ち。仕事はそれより多い。**
        #
        # grid 全体の待ちは全 block が同時に載っていることを求めるので、この数を越やせ
        # ない。越えたぶんは一本の lane が順に持つ（波）。一波で $A$ 行ずつ進む。
        #
        #     span = C·W,   行 = ⌈仕事 / span⌉,   A = 物理 lane / span,   波 = ⌈行 / A⌉
        span = self.groups * self.width
        want = ((int(lanes) + threads - 1) // threads) * threads
        try:
            cap = (lane.resident() // threads) * threads
        except Exception:
            cap = want
        self.lanes = max(threads, min(want, cap))
        # $A$ は物理 lane が覆う行数。**切り上げる。** 切り捨てると、lane 数が span の
        # 倍数でないとき最後の何本かが波の外に出て、置き場の外を読む
        self.A = max(1, -(-self.lanes // span))         # 一波ぶんのずらし幅
        self.waves = max(1, -(-(-(-int(lanes) // span)) // self.A))
        self.depth = depth
        self.unroll = unroll
        self.blocks = []               # (先頭, numpy の並び) 置く中身
        # 割り当ての記録。(先頭, 語数)。一本の長い配列を使わない道が、これで置き場ごとに
        # 分けられる。gvcpu は整数の位置でしか読み書きできないので一本にするが、配列の
        # 演算として出す側にはその制約が無い
        self.spans = []
        self.n = 0
        self.rows = []
        self.const = {}
        self.pool = []                 # 返ってきたスロットの置き場（`unit` の大きさだけ）
        self.size = {}                 # スロットの先頭 → 語数
        self._J = None                 # 組んだ板。二度目からは中身だけ上げ直す
        self._scratch = None           # 誰も読まない書き込み先。全ステージで共用する
        # 波が覆う行まで取る。最後の波が置き場の外へ出ないようにする
        self.unit = self.waves * self.A * self.width

    # -- 置き場 --
    def room(self, n):
        h = self.n
        self.n += int(n)
        self.spans.append((h, int(n)))
        return h

    def data(self, arr):
        a = np.asarray(arr, dtype=np.int64).reshape(-1)
        h = self.room(a.size)
        self.blocks.append((h, a))
        return h

    def _nopw(self):
        """閉包を使わない行のための 1 語の表。回るが結果は混ぜないので中身は何でもよい。"""
        if ("nopw",) not in self.const:
            self.const[("nopw",)] = self.data([1])
        return self.const[("nopw",)]

    def _pow2(self, n):
        """$2^k$（$k<n$）の表。桁ごとに立てる閉包が引く。"""
        return self.table(("pow2", n), lambda: np.array(
            [1 << k for k in range(n)], dtype=np.int64))

    def imm(self, v):
        """定数を一つ置く。

        内側を `unroll` 項展開すると、項の数が 1 の stage でも `unroll` 語ぶん読む。
        後ろを 0 で埋めておけば、余った項は 0 を掛けるので値に効かない。埋めないと
        隣の定数を係数として拾う。
        """
        v = int(v)
        if v not in self.const:
            self.const[v] = self.data([v] + [0] * (self.unroll - 1))
        return self.const[v]

    def ones(self, n):
        """係数を全部 1 にするための並び。総和と足し算に使う。

        `unroll` の倍数まで 0 で埋める。余った項は 0 を掛ける。
        """
        key = ("ones", n)
        if key not in self.const:
            m = -(-int(n) // self.unroll) * self.unroll
            a = np.zeros((m,), dtype=np.int64)
            a[:n] = 1
            self.const[key] = self.data(a)
        return self.const[key]

    def tensor(self, rows=None):
        """行を `width` 語に揃えてテンソルを 1 つ置く。返りは先頭。

        大きさは**レーン全部が収まる**ようにする。余ったレーンの書き込みも自分の
        テンソルの中へ落ちる。

        使い終わったものは `free` で返す。返さないと、層を重ねたときに共有メモリが
        足りなくなる（26 層で数十万スロットになる）。
        """
        # いまの詰め幅ぶんは必ず取る。列が詰め幅を越える置き場を組むとき、`unit` だけでは
        # 1 行に足りない
        need = max(self.unit, self.W)
        if rows is not None:
            need = max(need, int(rows) * self.W)
        # **大きさごとに分けて使い回す。** 大きさを覚えずに返すと、小さいスロットが大きい
        # 確保へ渡り、後続の置き場と重なる。指数の表が係数の範囲に入り込んで $2^{34}$ を
        # 読んでいた（2026-09-29 に段 112 で踏んだ）
        if need == self.unit and self.pool:
            return self.pool.pop()
        h = self.room(need)
        if need == self.unit:
            self.size[h] = need          # 使い回すのはこの大きさだけ
        return h

    def part(self):
        """組ごとの途中の値を置く。$(a,b,c)$ の全部が要るので `unit` の $C$ 倍。"""
        need = self.unit * self.groups
        key = ("part", need)
        pool = self.const.setdefault(key, [])
        if pool:
            return pool.pop()
        return self.room(need)

    def free_part(self, head):
        self.const.setdefault(("part", self.unit * self.groups), []).append(head)

    def scratch(self):
        """誰も読まない書き込み先。ステージごとに取ると共有メモリが尽きるので共用する。"""
        if self._scratch is None:
            self._scratch = self.room(self.unit)
        return self._scratch

    def free(self, *heads):
        """テンソルのスロットを返す。**大きさごとに分けて返す。**

        大きさを覚えずに返すと、小さいスロットが大きい確保へ渡り、後続の置き場と重なる。
        """
        # **`unit` と同じ大きさのスロットだけ使い回す。** 大きさを覚えずに返すと、小さい
        # スロットが大きい確保へ渡り、後続の置き場と重なる（指数の表が係数の範囲に
        # 入り込んで $2^{34}$ を読んでいた。2026-09-29 に段 112 で踏んだ）
        for h in heads:
            if h is None or self.size.get(h) != self.unit:
                continue
            if h not in self.pool:
                self.pool.append(h)

    def keep(self, *heads):
        """返してほしくないスロットを守る（出力など）。"""
        for h in heads:
            while h in self.pool:
                self.pool.remove(h)

    def row(self, out, out_s, k, w, w_s, x, x_s, add=None, add_s=(0, 0, 0),
            flag=None, thresh=0, pull=None, pull_s=(0, 0, 0), lad=None,
            mx=None):
        """1 ステージ。先頭は「共有メモリの番号」で渡す。ここでアドレスへ直す。

        出る値は

            Σ_{j<K} M[w+j]·M[x+j] + M[add] + M[ g + M[t] ]

        フラグは [ thresh ≤ 出た値 ]。`pull` は (表の先頭 g, 添字の先頭 t) で、添字の
        番地は `pull_s` の歩幅を取る。渡さなければ 0 の語を指すので、引きの項は 0 になる。
        """
        z = self.imm(0)
        g, t = pull if pull is not None else (z, z)
        # 解放済みのスロットを読んでいないか見る。これを外すと、値が静かに壊れる
        for nm, h in (("係数", w), ("入力", x), ("足す項", add)):
            if h is not None and h in self.pool:
                raise AssertionError(
                    "ステージ %d の%sが解放済みのスロット %d を読んでいる" % (len(self.rows), nm, h))
        groups = max(1, -(-int(k) // self.unroll))
        # **表の語は値そのもの。** 番地を持つ語を指す形にすると engine が LOAD を
        # 二回する（1 stage 374 命令のうち 228 がアドレス取得だった）
        self.rows.append([
            ROMLO + out, out_s[0], out_s[1], out_s[2],
            groups,
            ROMLO + w, w_s[0], w_s[1], w_s[2],
            ROMLO + x, x_s[0], x_s[1], x_s[2],
            ROMLO + (add if add is not None else z),
            add_s[0] if add is not None else 0,
            add_s[1] if add is not None else 0,
            add_s[2] if add is not None else 0,
            # フラグを誰も読まないなら、ワーク領域の捨て先へ向ける。門を 0 にすると
            # エンジンが歩幅を掛けないので、共有領域へ書かず**バリアが起きない**
            (ROMLO + flag) if flag is not None else walk.FLAGSINK,
            thresh,
            ROMLO + g, ROMLO + t,
            pull_s[0], pull_s[1], pull_s[2],
            1 if flag is not None else 0,
            # 桁を下ろす閉包。`lad` は (回数, 2^{k+m} の表, 2^k の表, 使うか)。
            # 下ろさない行も閉包は 1 回回るので、比べる値を 2^62 にして立たないようにし、
            # 最後に「使うか」0 で混ぜないようにする
            # 桁ごとに立てる閉包。`lad` は (回数 n, 2^k の表, A, Lc, Lk, Bc, Bk, 使うか)。
            #
            #     t = q + 2^k,  c = t·(A·t + B),  b = [c ≤ L],  q ← q + b·2^k
            #     L = Lc + Lk·|x|,  B = Bc + Bk·|x|
            #
            # `rshift` `recip` `isqrt` が全部この形になる。使わない行も閉包は 1 回回るが、
            # 最後に「使うか」0 で混ぜないので値は変わらない。
        ] + list(lad if lad else (1, self._nopw(), 0, 0, 0, 0, 0, 0))
            # 行に沿った最大。`mx` は (回数, 使うか)。使わない行は 1 回回して捨てる
            + list(mx if mx else (1, 0))
            # 35 番。この段の波の数。いまは全段で同じ
            + [self.waves])
        self.rows[-1][26] = ROMLO + self.rows[-1][26]
        assert len(self.rows[-1]) == walk.ROW36, (
            "1 ステージの語数が %d。エンジンは %d 語ずつ進めるので合わせる"
            % (len(self.rows[-1]), walk.ROW36))

    # -- 走らせる --
    # ---- 固定小数の桁を戻す ---------------------------------------------------
    #
    # 積のたびに分子の桁 F が足し合わさる。レイヤーを重ねると 64 bit を越えるので、
    # 途中で戻す。右シフトの命令が無いので、比較で桁を立てて組む。
    #
    #     b_k = [ 2^k ≤ r_k ],   r_{k+1} = r_k − b_k·2^k,   ⌊x/2^m⌋ = Σ_{k≥m} b_k·2^{k−m}
    #
    # 1 桁につき「フラグを出すステージ」と「残りを引くステージ」の 2 つ。上の桁から
    # m まで下ろせば足りるので、桁数は width − m になる。

    def rshift(self, src, rows, m, width, signed=True):
        """`src` を $2^m$ で割る。**1 行で済む。**

        桁ごとに立てるのはエンジンの閉包が回す。$c=t\cdot2^m$、$L=|x|$ の形なので、
        $t\cdot2^m\le|x|$ を満たす一番大きい $t$ が $\lfloor|x|/2^m
floor$ になる。
        符号は閉包が戻す。

        前は 1 bit につき 2 行を表へ並べていたので 30 bit で 60 行になり、1 行ごとに
        333 命令のアドレス計算を払っていた。桁を下ろす間アドレスは変わらない。
        """
        if width <= m:
            return self._const_like(0)
        n = int(width) - int(m)
        out = self.tensor()
        E = (self.W, 1, 0)
        self.row(out, E, 1, self.imm(1), (0, 0, 0), src, E,
                 lad=(n, self._pow2(n), 0, 0, 1, 1 << int(m), 0, 1))
        return out

    def _add(self, a, b):
        """a + b。1 項の内積に、足す項として b を当てる。1 ステージで済む。"""
        out = self.tensor()
        E = (self.W, 1, 0)
        self.row(out, E, 1, a, E, self.imm(1), (0, 0, 0), add=b, add_s=E)
        return out

    def _scale(self, a, c):
        """a · c（c は定数）。"""
        out = self.tensor()
        E = (self.W, 1, 0)
        self.row(out, E, 1, a, E, self.imm(int(c)), (0, 0, 0))
        return out

    def _pick(self, flag, a, b):
        """フラグが 1 なら a、0 なら b。$b+\text{flag}\cdot(a-b)$。"""
        E = (self.W, 1, 0)
        nb = self._scale(b, -1)
        diff = self._add(a, nb)
        sel = self.tensor()
        self.row(sel, E, 1, flag, E, diff, E)
        got = self._add(b, sel)
        self.free(nb, diff, sel)
        return got

    # -- 縮約と非多項式 --
    # ---- 引きで関数を出す -------------------------------------------------
    #
    # 桁ごとに立てる形は一つにつき千段を越える。エンジンが $M[g+M[t]]$ を持つので、
    # 値の範囲が決まっている関数は**表を引いて一段**で出せる。挟み込みが十段付く。

    def table(self, key, make):
        """引きの表を置く。回収しない場所から取る。同じ表は使い回す。"""
        if key not in self.const:
            self.const[key] = self.data(make())
        return self.const[key]

    def lookup(self, idx, tab):
        """$M[	ext{表}+M[	ext{添字}]]$ を一段で出す。内積の項は 0 にする。"""
        E = (self.W, 1, 0)
        out = self.tensor()
        z = self.imm(0)
        self.row(out, E, 1, z, (0, 0, 0), z, (0, 0, 0), pull=(tab, idx), pull_s=E)
        return out

    def clamp(self, src, lo, hi):
        """`src` を $[lo, hi]$ へ収める。表の外を引くと番地が並びを越える。"""
        E = (self.W, 1, 0)
        one = self.imm(1)
        f = self.tensor()
        self.row(self.scratch(), E, 1, src, E, one, (0, 0, 0), flag=f, thresh=lo)
        got = self._pick(f, src, self._const_like(lo))      # [lo ≤ src] ? src : lo
        g = self.tensor()
        self.row(self.scratch(), E, 1, got, E, one, (0, 0, 0), flag=g, thresh=hi)
        return self._pick(g, self._const_like(hi), got)     # [hi ≤ got] ? hi : got

    def exp_pull(self, src, f):
        """$e^{x}$（$x\le0$）を引きで出す。

        $$T[i]=\operatorname{round}igl(e^{-i/2^{f}}\cdot2^{f}igr),\qquad
        i=\minigl(\max(-	ext{分子},0),\,I-1igr)$$

        $e^{-u}<2^{-f}$ になる $u$ から先は 0 なので、表は $I=\lceil f\ln2\cdot2^f
ceil+2$
        で足りる（$f=14$ で 15.9 万語）。
        """
        import math
        import numpy as np
        n = int(f * math.log(2.0) * (1 << f)) + 2
        tab = self.table(("exp", f, n), lambda: np.rint(
            np.exp(-np.arange(n, dtype=np.float64) / float(1 << f))
            * (1 << f)).astype(np.int64))
        return self.lookup(self.clamp(self._scale(src, -1), 0, n - 1), tab)

    def plane(self, rows, cols, off):
        """(行, 列) の値を、レーン全部が収まる大きさの面へ置く。"""
        need = max(self.unit, rows * self.W)
        tab = np.zeros((need // self.W, self.W), dtype=np.int64)
        tab[:rows, :cols] = off
        return self.data(tab.reshape(-1))

    def _spread_row(self, src, k, st, rows):
        """論理の行ごとに 1 語ある値を、行全体へ広げる。引きの項で 1 段。

        タイルにまたがる行では $r=\lfloor f/	ext{st}
floor$ が整数の割り算になり、
        線形な歩幅で書けない。compile 時の添字の表で写す。
        """
        tiles = st // self.W
        f = np.arange(rows * st).reshape(rows * tiles, self.W)
        off = (f // st)
        t = self.plane(rows * tiles, self.W, off)
        out = self.tensor(rows * tiles)
        z = self.imm(0)
        self.row(out, (self.W, 1, 0), 1, z, (0, 0, 0), z, (0, 0, 0),
                 pull=(src, t), pull_s=(self.W, 1, 0))
        return out

    def rowsum(self, src, k, st=None, rows=1):
        """行の総和。係数を 1 の並びにした内積。

        同じ行のレーンはどれも同じ和を出すので、**行の全列へ書く**。こうすると以降の
        ステージが要素ごとの歩幅のまま読める。列 0 だけに書くと、以降が 0 を読む。
        """
        st = self.W if st is None else int(st)
        if st > self.W:
            # 行がタイルにまたがる。タイルごとの部分和 → タイルをまとめる → 行へ広げる。
            # 行を $i_2$ に取ると、$i_2$ が詰め幅まで動くので読みが帯の外へ出る
            tiles = st // self.W
            part = self.tensor(tiles)          # 幅×tiles 語。$i_2<W$ が帯の中に収まる
            self.row(part, (1, 0, 0), self.W, self.ones(self.W), (0, 0, 0),
                     src, (self.W, 0, 0))
            one = self.tensor(rows)
            self.row(one, (0, 1, 0), tiles, self.ones(tiles), (0, 0, 0),
                     part, (0, tiles, 0))
            got = self._spread_row(one, k, st, rows)
            self.free(part, one)
            return got
        out = self.tensor()
        self.row(out, (self.W, 1, 0), k, self.ones(k), (0, 0, 0), src,
                 (self.W, 0, 0))
        return out

    def isqrt(self, src, width):
        """$\lfloor\sqrt{x}
floor$。**1 行で済む。**

        桁ごとに立てるのはエンジンの閉包が回す。$c=t^2$、$L=|x|$ の形。
        """
        n = max(1, int(width) // 2)
        out = self.tensor()
        E = (self.W, 1, 0)
        self.row(out, E, 1, self.imm(1), (0, 0, 0), src, E,
                 lad=(n, self._pow2(n), 1, 0, 1, 0, 0, 1))
        return out

    def _const_like(self, v):
        """全レーンに同じ定数を置いたテンソル。足す相手に使う。

        **回収済みのスロットを使ってはいけない。** 中身を入れるのは走る前の一度だけなので、
        そのスロットを前に使っていたステージが走ると上書きされる。同じ値は使い回す。
        """
        import numpy as np
        key = ("like", int(v))
        if key in self.const:
            return self.const[key]
        need = -(-self.lanes // self.width) * self.width
        head = self.room(need)                    # 回収しない場所から取る
        self.blocks.append((head, np.full((need,), int(v), dtype=np.int64)))
        self.const[key] = head
        return head

    def recip(self, src, f, width):
        """$1/b$ を桁ごとに立てる。$b>0$ で、返りの桁は f。**1 行で済む。**

        $c=t\cdot b$、$L=2^{2f}$ の形。Newton は始めの値の取り方で発散する
        （$b=4$ に $y_0=0.5$ だと $2-by=0$ で止まる）が、桁ごとに立てる形は大域的に正しい。

        $$q_k=q_{k+1}+2^kigl[(q_{k+1}+2^k)\cdot b\le 2^{2f}igr]$$
        """
        n = max(1, int(width))
        out = self.tensor()
        E = (self.W, 1, 0)
        self.row(out, E, 1, self.imm(1), (0, 0, 0), src, E,
                 lad=(n, self._pow2(n), 0, 1 << (2 * f), 0, 0, 1, 1))
        return out

    def rsqrt(self, src, f, width):
        """$1/\sqrt v$。先に $2^f$ 倍してから桁ごとの平方根を取ると、そのまま桁 f になる。

        幅は溢れないところで決める。桁ごとに立てる閉包は $t^2$ と $t\cdot y$ を作るので

            t² ≤ 2^62   →   2f + span ≤ 62
            t·y ≤ 2^62  →   n ≤ 62 − f − span/2

        を満たさなければならない。$f=23$ で `isqrt` の幅を $4f$ に取ると $t^2$ が
        $2^{92}$ になって壊れる（2026-09-29 に踏んだ）。
        """
        n1 = 2 * f + 8                      # isqrt の幅。桁数は n1/2 = f + 4
        n2 = max(4, min(f + 8, 62 - f - 6))  # recip の桁数
        return self.recip(self.isqrt(self._scale(src, 1 << f), n1), f, n2)

    def layernorm(self, src, k, f, width, gamma=None, beta=None, eps=1e-5,
                  mean=True, st=None, rows=1):
        """行ごとに中心を引いて散らばりで割る。$\gamma$ と $\beta$ は行に沿った並び。

        `mean` を下ろすと中心を引かない。$\sqrt{\overline{x^2}}$ で割る形（RMS）になる。
        """
        E = (self.W, 1, 0)
        kb = int(math.ceil(math.log(max(2, k), 2)))
        inv_k = self.imm(round((1 << f) / k))
        if not mean:
            d = src
        else:
            mu = self._mulc(self.rowsum(src, k, st, rows), inv_k)         # 深さ 2f
            mu = self.rshift(mu, None, f, min(62, 2 * f + 12 + kb))
            d = self._add(src, self._scale(mu, -1))             # 深さ f
        # 分散。二乗（2f）→ 行の和 → 1/k（3f）を一度にまとめて f へ落とす
        var = self._mulc(self.rowsum(self._mul(d, d), k, st, rows), inv_k)
        var = self.rshift(var, None, 2 * f, min(62, 3 * f + 12 + kb))
        var = self._add(var, self._const_like(max(1, round(eps * (1 << f)))))
        inv = self.rsqrt(var, f, width)                         # 深さ f
        out, od = self._mul(d, inv), 2 * f
        if gamma is not None:
            g = self.tensor()
            self.row(g, E, 1, out, E, gamma, (0, 1, 0))
            out, od = g, od + f
        # 出口で 1 回だけ戻す。深さ 3f のまま返すと下流の `fit` が分子を詰めすぎて、
        # 刻みが 0.1 台になる（2026-09-29 に ffn の `mul` で踏んだ）。
        if od > f:
            out = self.rshift(out, None, od - f, min(62, 2 * od + 12 - f))
            od = f
        if beta is not None:
            out = self._add_row(out, beta)
        return out, od

    def _mul(self, a, b):
        """要素ごとの積。桁は足し合わさる。"""
        out = self.tensor()
        E = (self.W, 1, 0)
        self.row(out, E, 1, a, E, b, E)
        return out

    def _mulc(self, a, cslot):
        """定数のスロットを掛ける。"""
        out = self.tensor()
        E = (self.W, 1, 0)
        self.row(out, E, 1, a, E, cslot, (0, 0, 0))
        return out

    def _add_row(self, a, row):
        """行に沿った並び（列ごとに 1 語）を足す。"""
        out = self.tensor()
        self.row(out, (self.W, 1, 0), 1, a, (self.W, 1, 0), self.imm(1), (0, 0, 0),
                 add=row, add_s=(0, 1, 0))
        return out

    def int_part(self, src, f, width):
        """$\lfloor x\rfloor$ を桁 f の値として返す（$x\ge0$）。下の f 桁を落とす。"""
        return self._scale(self.rshift(src, None, f, width), 1 << f)

    def exp_neg(self, src, f, width, nmax=24):
        """$e^{x}$（$x\le0$）。整数部を選び、小数部を多項式で出す。

        $$e^{x}=e^{-n}\cdot e^{-r},\qquad n=\lfloor-x\rfloor,\quad r=-x-n\in[0,1)$$

        $e^{-n}$ はフラグ $[\,k\le n\,]$ の差で選ぶ。望遠鏡の形なので足し合わせるだけで済む。
        $e^{-r}$ は $1-r+\frac{r^2}{2}-\frac{r^3}{6}+\frac{r^4}{24}$ で、$[0,1)$ では
        誤差が $10^{-3}$ 台に収まる。
        """
        import math
        E = (self.W, 1, 0)
        neg = self._scale(src, -1)                      # −x ≥ 0
        ip = self.int_part(neg, f, width)               # n（桁 f）
        r = self._add(neg, self._scale(ip, -1))         # r（桁 f）
        # e^{-n} を選ぶ
        got = self._const_like(1 << f)                  # e^0
        for k in range(1, nmax + 1):
            g = self.tensor()
            diff = self._add(ip, self._const_like(-(k << f)))
            self.row(self.tensor(), E, 1, diff, E, self.imm(1), (0, 0, 0),
                     flag=g, thresh=0)                  # [ k ≤ n ]
            step = round((math.exp(-k) - math.exp(-(k - 1))) * (1 << f))
            got = self._add(got, self._scale(g, step))
        # e^{-r} を多項式で。係数を掛けるたびに桁を f へ戻す
        poly = self._const_like(1 << f)
        term = self._const_like(1 << f)
        for c in (-1.0, 0.5, -1.0 / 6, 1.0 / 24):
            term = self.rshift(self._mul(term, r), None, f, width)
            poly = self._add(poly, self.rshift(self._scale(term, round(c * (1 << f))),
                                               None, f, width))
        return self.rshift(self._mul(got, poly), None, f, width)

    def board(self):
        """共有メモリを一度だけ組む。ステージの表と、置いた中身を上げる。

        表と定数は compile 時に決まるので一度で足りる。実引数と weight は呼ばれるたびに
        `send` で上げ直す。番地は動かないので、上げ直すのは中身だけになる。
        """
        if self._J is not None:
            return self._J
        import cupy as cp
        prog, need = _engine(self.unroll)
        tab_head = self.n
        flat = np.concatenate([np.asarray(r, dtype=np.int64) for r in self.rows])
        J = lane.Joint(prog, need, fold.ROW, ROMLO,
                       tab_head + flat.size + self.unroll, self.lanes,
                       threads=self.threads)
        for h, a in self.blocks:
            J.d_rom[h:h + a.size] = cp.asarray(a.astype(np.uint64))
        J.d_rom[tab_head:tab_head + flat.size] = cp.asarray(flat.astype(np.uint64))
        ids = cp.arange(J.n, dtype=cp.int64)
        C = self.groups
        self._seed = {walk.TAB: np.uint64(ROMLO + tab_head),
                      walk.LEFT: np.uint64(len(self.rows)),
                      walk.AWV: np.uint64(self.A),
                      walk.IDX1: (ids // (C * self.width)).astype(cp.uint64),
                      walk.IDX2: ((ids // C) % self.width).astype(cp.uint64),
                      walk.IDX3: (ids % C).astype(cp.uint64)}
        self._J = J
        return J

    def send(self, idx, arr):
        """置いた中身の `idx` 番を差し替える。板が出来ていれば共有メモリへも上げる。

        番地と語数は compile 時のまま。語数が変わる差し替えは形が変わったということなので、
        呼ぶ側で新しい graph を組む。
        """
        head, old = self.blocks[idx]
        a = np.asarray(arr, dtype=np.int64).reshape(-1)
        if a.size != old.size:
            raise RuntimeError("置き場 %d の語数が %d から %d へ変わりました"
                               % (head, old.size, a.size))
        self.blocks[idx] = (head, a)
        if self._J is not None:
            import cupy as cp
            self._J.d_rom[head:head + a.size] = cp.asarray(a.astype(np.uint64))

    def load(self):
        """共有帯を組んだ直後の中身へ戻す。0 で埋めてから、置いた中身を上げ直す。

        再現モデルは毎回 0 の帯から組む。エンジンは段の出力を同じ帯へ書くので、走った
        あとには前の回の中間値が残る。**0 に戻さないと、両者の始めの中身が違う。**

        土台が効くのは、余ったレーンが置き場の外を読む所になる。出力の列 $N$ が詰め幅
        より少ない行では、係数の歩幅 $(0,W,0)$ の $i_2$ が $N$ を越えて隣を読む。実の値は
        $i_2<N$ 側なので結果は正しいが、隣に前の回の大きい値が残っていると乗算が
        報告 43 で止まる（2026-09-29 に段 107 で踏んだ）。

        費用は帯の語数ぶんの 0 埋めが 1 回。狭めるなら、置き場の外を読む段を組むときに
        その区間を控えておく。
        """
        import cupy as cp
        J = self.board()
        J.d_rom[:self.n] = 0
        for h, a in self.blocks:
            J.d_rom[h:h + a.size] = cp.asarray(a.astype(np.uint64))
        return J

    def run(self, stop=None, fresh=True):
        """1 回の起動で全ステージを流す。返りは (Joint, 報告, ステップ数)。

        `Joint.run` は `M` をそのまま作業領域に使うので、走ったあとには前の値が残る。
        二度目を前の残りから始めると番地が壊れて報告 45 になる。だから毎回、作業領域を
        0 へ戻してから表の番地とレーンの番号を置き直す。

        `stop` を渡すとその段数で閉じる。表は動かさず、残りの段の数だけを置き換える。
        `fresh` を立てると共有帯も組んだ直後の中身へ戻す。
        """
        J = self.load() if fresh else self.board()
        J.reset()
        for addr, v in self._seed.items():
            J.M2[J.pos(addr), :] = v
        if stop is not None:
            J.M2[J.pos(walk.LEFT), :] = np.uint64(int(stop))
        rep, steps, _ = J.run()
        return J, rep, steps

    def rowmax(self, src, k, st=None, rows=1):
        """行の最大値。**1 行で済む。** 列を辿るのはエンジンの閉包が回す。

        $$m\leftarrow m+igl[\,m\le x_{j}\,igr]\cdot(x_{j}-m)$$

        前は列ごとに 4 行並べていたので、列 $k$ に対して $4k$ 行になった。語彙の大きさの
        softmax では $10^6$ 行になり、表が持てない。
        """
        E = (self.W, 1, 0)
        st = self.W if st is None else int(st)
        if st > self.W:
            tiles = st // self.W
            part = self.tensor(tiles)
            self.row(part, (1, 0, 0), 1, self.imm(1), (0, 0, 0), src,
                     (self.W, 0, 0), mx=(max(1, self.W - 1), 1))
            one = self.tensor(rows)
            self.row(one, (0, 1, 0), 1, self.imm(1), (0, 0, 0), part,
                     (0, tiles, 0), mx=(max(1, tiles - 1), 1))
            got = self._spread_row(one, k, st, rows)
            self.free(part, one)
            return got
        out = self.tensor()
        # 主たる値は使わないが、入力の先頭を渡すために 1 項の内積にしておく
        self.row(out, E, 1, self.imm(1), (0, 0, 0), src, (self.W, 0, 0),
                 mx=(max(1, int(k) - 1), 1))
        return out

    def softmax(self, src, k, f, width, nmax=24, st=None, rows=1):
        """行ごとの softmax。最大を引いてから指数を取り、和で割る。"""
        hi = self.rowmax(src, k, st, rows)
        sub = self._add(src, self._scale(hi, -1))
        e = self.exp_pull(sub, f)
        tot = self.rowsum(e, k, st, rows)
        inv = self.recip(tot, f, f + 6)
        return self.rshift(self._mul(e, inv), None, f, width)

    def simulate(self, watch=(), strict=False, stop=None, mem=None):
        """ステージの表を numpy で再現する。GPU と突き合わせるための土台。

        1 ステージの意味はエンジンと同じ。

            値 = Σ_{j<K·u} M[w + j] · M[x + j] + M[p]
            フラグ = [ しきい値 ≤ 値 ]

        アドレスはどれも 先頭 + s₁i₁ + s₂i₂ + s₃i₃ で、$(i_1,i_2)$ はレーンの番号。
        `watch` に (名前, 先頭) を渡すと、ステージごとの値を控えて返す。`strict` を立てると
        一つの積が 63 bit を越えた所で止まる。GPU の報告 43 と同じ条件になる。
        """
        import numpy as np
        # `mem` を渡すとその土台から始める。エンジンは段の出力を共有帯へ書くので、二度目の
        # 走りは前の回の中間値の上から始まる。同じ土台を渡せば両者を同じ条件で比べられる
        if mem is None:
            mem = np.zeros((self.n + 64,), dtype=np.int64)
        else:
            mem = np.concatenate([np.asarray(mem, dtype=np.int64),
                                  np.zeros((self.n + 64 - len(mem),), dtype=np.int64)])
        for h, a in self.blocks:
            mem[h:h + a.size] = a[:max(0, min(a.size, mem.size - h))]
        lanes = self.lanes
        C = self.groups
        ids = np.arange(lanes)
        i1 = ids // (C * self.width)
        i2 = (ids // C) % self.width
        i3 = ids % C
        trace = []
        rows = self.rows if stop is None else self.rows[:int(stop)]
        for si, r in enumerate(rows):
            # 表が持つのは ROMLO を足した絶対アドレス。mem は先頭からの番号で引く
            g = lambda k: int(r[k])
            head = lambda k: g(k) - ROMLO
            ob, os1, os2, os3 = head(0), g(1), g(2), g(3)
            groups = g(4)
            wb, ws = head(5), (g(6), g(7), g(8))
            xb, xs = head(9), (g(10), g(11), g(12))
            ab, as_ = head(13), (g(14), g(15), g(16))
            fb, th, gate = head(17), g(18), g(24)
            ln, pwb = g(25), head(26)
            mxn, mxu = g(33), g(34)
            lA, lLc, lLk, lBc, lBk, useq = (g(27), g(28), g(29), g(30), g(31), g(32))
            gb = head(19)                                  # 引きの表の先頭
            tb, ts = head(20), (g(21), g(22), g(23))       # 添字
            # 波。一本の lane が $A$ 行ずつずらしながら複数の仕事を順に持つ
            for kw in range(max(1, int(g(35)))):
                i1k = i1 + kw * self.A
                wp = wb + ws[0] * i1k + ws[1] * i2 + ws[2] * i3
                xp = xb + xs[0] * i1k + xs[1] * i2 + xs[2] * i3
                ap = ab + as_[0] * i1k + as_[1] * i2 + as_[2] * i3
                tp = tb + ts[0] * i1k + ts[1] * i2 + ts[2] * i3
                op = ob + os1 * i1k + os2 * i2 + os3 * i3
                fp = (fb + os1 * i1k + os2 * i2 + os3 * i3) if gate else 0
                def guard(u, v, what):
                    if not strict:
                        return
                    o = (np.abs(np.asarray(u).astype(object))
                         * np.abs(np.asarray(v).astype(object))) >= (1 << 62)
                    if np.any(o):
                        k2 = int(np.argmax(o))
                        raise OverflowError(
                            "ステージ %d の %s で積が 63 bit を越えます（%d × %d）"
                            % (si, what, int(np.ravel(u)[k2 % np.size(u)]),
                               int(np.ravel(v)[k2 % np.size(v)])))

                # 行に沿った最大を取る閉包。和より先に回す（エンジンと同じ順）
                mxv = mem[xp].copy()
                for _ in range(int(mxn)):
                    v = mem[xp + 1]
                    guard((mxv <= v).astype(np.int64), v - mxv, "最大の閉包")
                    mxv = mxv + (mxv <= v).astype(np.int64) * (v - mxv)
                    xp = xp + 1
                xp = xp - int(mxn)
                acc = np.zeros(lanes, dtype=np.int64)
                for j in range(groups * self.unroll):
                    if strict:
                        # int64 は黙って回る。エンジンは一つの積が 63 bit を越えると報告 43 で
                        # 止まるので、同じ所を Python の整数で見張る
                        w0 = np.abs(mem[wp + j].astype(object))
                        x0 = np.abs(mem[xp + j].astype(object))
                        over = (w0 * x0) >= (1 << 62)
                        if np.any(over):
                            k = int(np.argmax(over))
                            raise OverflowError(
                                "ステージ %d、項 %d、レーン %d で積が 63 bit を越えます"
                                "（%d × %d）" % (si, j, k, int(mem[wp + j][k]),
                                                 int(mem[xp + j][k])))
                    acc += mem[wp + j] * mem[xp + j]
                pa = gb + mem[tp]
                if strict or True:
                    if int(np.max(pa)) >= mem.size or int(np.min(pa)) < 0:
                        raise IndexError(
                            "ステージ %d の引きが帯の外（表の先頭 %d、添字 %d〜%d、帯 %d）"
                            % (si, gb, int(np.min(mem[tp])), int(np.max(mem[tp])),
                               mem.size))
                acc = acc + mem[ap] + mem[pa]
                guard(mxu, mxv - acc, "最大を混ぜる")
                acc = acc + mxu * (mxv - acc)
                # 桁ごとに立てる閉包。エンジンと同じ順で回す
                sg = 2 * (acc >= 0).astype(np.int64) - 1
                r = acc * sg
                lim, bco = lLc + lLk * r, lBc + lBk * r
                q = np.zeros_like(acc)
                for kk in range(int(ln) - 1, -1, -1):
                    pp = int(mem[pwb + kk])
                    t = q + pp
                    if strict:
                        # 桁を立てる閉包の中の積も見張る。ここを見ないと、内積だけ見ていて
                        # GPU が報告 43 を返すのに numpy は黙って回る
                        u = np.abs(t.astype(object))
                        w2 = np.abs((lA * t + bco).astype(object))
                        over = (u * w2) >= (1 << 62)
                        if np.any(over):
                            k2 = int(np.argmax(over))
                            raise OverflowError(
                                "ステージ %d、桁 %d、レーン %d で桁を立てる積が 63 bit を"
                                "越えます（%d × %d）"
                                % (si, kk, k2, int(t[k2]), int((lA * t + bco)[k2])))
                    c = t * (lA * t + bco)
                    guard((c <= lim).astype(np.int64), pp, "桁を足す")
                    q = q + (c <= lim).astype(np.int64) * pp
                guard(q, sg, "符号を戻す")
                guard(useq, q * sg - acc, "桁を混ぜる")
                acc = acc + useq * (q * sg - acc)
                mem[op] = acc
                if gate:                                       # 誰も読まないフラグは書かない
                    mem[fp] = (acc >= th).astype(np.int64)
            if watch:
                trace.append([(nm, mem[h:h + self.unit].copy()) for nm, h in watch])
        return mem, trace

    def read(self, J, head, rows, cols):
        """置いたテンソルを (rows, cols) で読み出す。行は `width` 語に揃っている。"""
        st = -(-max(1, int(cols)) // self.width) * self.width
        got = J.d_rom[head:head + rows * st].get().astype(np.int64)
        return got.reshape(rows, st)[:, :cols]


_ENGINE = {}


def _engine(u):
    """最適化した engine を返す。**unroll ごとに一度だけ組む。**

    `lane.best` は 15631 命令へ最適化の pass を不動点まで当てるので秒の単位で掛かる。
    engine は graph に依らないので、組み直すたびに走らせると graph の数だけ無駄になる
    （18 件の検査で 10 分を越えた）。
    """
    if u not in _ENGINE:
        from common_vcpu import vcpu
        img, need, _ = lane.build(walk.engine6(u), "eng7_%d" % u)
        _ENGINE[u] = (lane.best(vcpu.decode(img), need, _gate(u, need)), need)
    return _ENGINE[u]


def _gate(u, need):
    """最適化 pass の検算シード。1 ステージの内積を 1 レーンだけ走らせる。"""
    SL = fold.ROW + 2048
    sl = lambda i: SL + 512 + i
    k = u * 4
    wh, xh, oh, zer = SL, SL + k + 8, SL + 2 * k + 16, sl(91)
    seed = {walk.TAB: fold.ROW + 64, walk.LEFT: 1, walk.IDX1: 0, walk.IDX2: 0,
            walk.IDX3: 0, walk.AWV: 0, zer: 0}
    for j in range(k):
        seed[wh + j] = (j % 7) + 1
        seed[xh + j] = (j % 5) + 1
    # 引きの項は 0 の語を指す。M[zer + M[zer]] = M[zer + 0] = 0 が足されるだけになる
    pw = sl(92)
    seed[pw] = 1
    vals = [oh, 0, 0, 1, 4, wh, 0, 0, 0, xh, 0, 0, 0, zer, 0, 0, 0, SL + 400, 0,
            zer, zer, 0, 0, 0, 1, 1, pw, 0, 0, 0, 0, 0, 0, 1, 0, 1]
    # 表の語は値そのもの（`Build.row` と同じ形）
    for i, v in enumerate(vals):
        seed[fold.ROW + 64 + i] = v
    return (seed, (oh,))


# ---- fx.Graph を落とす ----------------------------------------------------

import math                                                      # noqa: E402

from . import chamber                                            # noqa: E402


class Lower(object):
    """fx.Graph をステージの表へ落とす。1 レーンが出力の 1 要素を持つ。

    固定小数は値 = 分子 · 2^-F。積のたびに F が倍になるので、その都度右シフトで戻す。
    戻さないと 26 層のモデルで分子が 64 bit を越える。
    """

    def __init__(self, gm, example_inputs, depth=None):
        self.gm = gm
        self.order = [n for n in gm.graph.nodes if n.op == "placeholder"]
        self.given = list(example_inputs)
        self.seen = {}                  # node → 素の走りで見た最大値
        self.scalar = {}                # node → compile 時に決まる数（`scale` など）
        self.dtype = {}                 # node → dtype（bool のマスクを見分ける）
        self.shape = self._shapes()
        # 上から押さえる伝播。**組み直すかの判定だけ**に使う。層を重ねると
        # $\sqrt K\max|W|$ を掛け続けるので指数的に緩み（2 層で $2^{121}$）、桁の決め方
        # には使えない
        self.bound = dict((n, v + self.MARGIN)
                          for n, v in self._spans(self.given).items())
        # 桁を決めるのは実測の最大値。越えたら乗算が報告 43 で止まるので黙って壊れない
        self.span = {}
        for n, v in self.seen.items():
            self.span[n] = (max(1, int(math.ceil(math.log(max(1.0, v), 2))) + 1)
                            + self.MARGIN)
        for n, v in self.bound.items():
            self.span.setdefault(n, v)
        self.depth = self._depth() if depth is None else depth
        # 桁を戻すときに拾う bit の幅。積の分子は $2^{2F}$ 桁になるので、$F+8$ では
        # 上の桁が落ちて値が小さい側へ潰れる（$F=20$ で $e^{-1}$ が $2^{-12}$ になった）
        self.bits = min(58, 2 * self.depth + 2 * self.HEAD)
        self.mag = {}                   # 置き場 → 分子の bit 数の上限
        self.shape_note = {}            # 置き場 → 本当の (行, 列)
        self.coef = self._coefficients()
        self.live = []                 # 呼ばれるたびに上げ直す置き場
        act = [s for n, s in self.shape.items() if n not in self.coef]
        # 幅は「列の最大」でなく**タイルの幅**に切る。
        #
        # レーンの番号は id = i₁·(C·width) + i₂·C + i₃ で $i_1$ の倍率が全体で一つなので、
        # 列の最大をそのまま幅にすると レーン数 = 行の最大 × 列の最大 になる。Qwen 1 層
        # T=1 で 64 × 17408 = 111 万本、上限 55296 の 20 倍（2026-09-29 に測った）。
        #
        # 置き場を $\lceil$要素数$/W\rceil$ 行 × $W$ 列に切れば
        #
        #     レーン数 = 行の最大 × W ≒ 置き場の要素数の最大
        #
        # になる。$W=512$ で Qwen 実寸が 20480 本に収まる。
        # 詰め幅は列の最大で取る。論理の 1 行が 1 タイルに収まるので、置き場の中の
        # 番地が行の先頭からの差だけで決まる。列がこれを越える置き場だけタイルに切る。
        # レーン数がこれで膨らんでも、越えたぶんは波が持つ（`Build.__init__`）。
        wide = max(int(s[-1]) if len(s) else 1 for s in act)
        self.width = wide if wide <= self.TILE else self.TILE
        # レーン数はタイル込みで数える
        rows = max(self._rows(t) * (-(-(int(t[-1]) if len(t) else 1) // self.width))
                   for t in act)
        C = self._groups(rows * self.width, self.UNROLL)
        self.B = Build(self.width, rows * self.width * C, unroll=self.UNROLL,
                       groups=C)
        self.val = {}
        self.host = self._hosts()       # host で先に済ませる node

    # 別名の箱。値も置き方も変えないので、役は元の node がそのまま持つ
    # 型を変えるだけの箱も値を動かさない。固定小数では型の区別が無い
    ALIAS = ("to", "_to_copy", "clone", "detach", "contiguous", "alias",
             "float", "double", "half", "bfloat16", "type", "type_as",
             "detach_", "requires_grad_")

    # 置き方が変わる箱。行ごとに width 語へ揃えているので、列の数が変わると詰めが合わない。
    # 引きの項 M[g + M[t]] に compile 時の添字表を渡して 1 ステージで写す。
    MOVE = ("view", "reshape", "t", "transpose", "permute",
            "unsqueeze", "squeeze", "flatten", "ravel")

    # `operator` から来る名前を aten の名前へ寄せる
    RENAME = {"truediv": "div", "floordiv": "div", "neg_": "neg",
              "mul_": "mul", "add_": "add", "sub_": "sub"}

    def _source(self, n):
        """別名と置き直しを辿って元の node を返す。

        **読む値を探すのに使ってはいけない。** `MOVE` は新しい置き場を作るので、辿ると
        置き直す前の値を読む。`x@Wᵀ.reshape(3,2).sum(-1)` が (1,1) になる食い違いが
        これだった（2026-09-29 に測った）。値は `self.val[n.args[0]]` で直に引く。
        使うのは「元の係数・placeholder はどれか」を決めるときだけ。
        """
        while (getattr(n, "op", None) in ("call_function", "call_method")
               and chamber._name_of(n) in self.ALIAS + self.MOVE):
            n = n.args[0]
        return n

    # ---- 値の大きさを上から押さえる -------------------------------------
    #
    # 分子が何 bit になるかは、値の大きさから決まる。実測（素の torch を一度走らせて
    # 最大値を見る）は**健全でない**。実行時の入力が compile 時より大きいと足りなくなり、
    # 乗算が報告 43 で止まる（2026-09-28 に block の段 3580 で踏んだ）。
    #
    # そこで掛け算の規則だけで上から押さえる。placeholder の最大値だけが入力なので、
    # 呼びごとに同じ規則で再評価できる。
    #
    #     |a ⋆ b|            ≤ |a|·|b|
    #     |Σ_{j<K} w_j x_j|  ≤ K·max|w|·max|x|
    #     |a ⊕ b|            ≤ |a| + |b|
    #     |σ(x)|, |softmax|  ≤ 1
    #     |silu(x)|, |relu(x)| ≤ |x|
    #     |rms(x)|           ≤ max|γ|·√k

    HUGE = float(1 << 40)        # 押さえられない所に置く値。ここは実測へ落とす

    def _shape_of(self, a):
        """node の形。置き直した node は自分の形を持つので、辿らず直に引く。"""
        return self.shape.get(a) or self.shape.get(self._source(a))

    def _cols(self, n):
        s = self._shape_of(n) if hasattr(n, "op") else None
        return int(s[-1]) if s else 1

    def _spans(self, args):
        """各 node の値の大きさを上から押さえ、bit 数として返す。"""
        POS = {"linear": (0, 1, 2), "mm": (0, 1, None), "matmul": (0, 1, None),
               "addmm": (1, 2, 0)}
        b = {}

        def at(v, default=1.0):
            if hasattr(v, "op"):
                return b.get(v, self.HUGE)
            try:
                return abs(float(v))
            except (TypeError, ValueError):
                return default

        for n in self.gm.graph.nodes:
            if n.op in ("placeholder", "get_attr"):
                try:
                    b[n] = max(1.0, float(self._t(n, args).detach().abs().max()))
                except (RuntimeError, TypeError, AttributeError):
                    b[n] = self.HUGE
                continue
            if n.op == "output":
                continue
            name = self.RENAME.get(chamber._name_of(n), chamber._name_of(n))
            if name in self.ALIAS + self.MOVE:
                b[n] = at(n.args[0])
                continue
            if name in POS:
                xi, wi, bi = POS[name]
                k = self._cols(n.args[xi])
                # $K$ 倍でなく $\sqrt K$ 倍で押さえる。$K$ 倍は全項が同符号で揃う最悪を
                # 仮定するので、$K=512$ で 9 bit 過大になり、下流の `fit` が桁を 0 まで
                # 削る（splitblk の `down` で踏んだ）。上界ではないが、越えれば乗算が
                # 報告 43 で止まるので黙って壊れることはない。
                got = math.sqrt(max(1.0, float(k))) * at(n.args[xi]) * at(n.args[wi])
                if bi is not None and len(n.args) > bi and hasattr(n.args[bi], "op"):
                    got += at(n.args[bi])
                b[n] = got
                continue
            if name in ("mul",):
                b[n] = at(n.args[0]) * at(n.args[1])
            elif name in ("add", "sub", "rsub"):
                b[n] = at(n.args[0]) + at(n.args[1])
            elif name in ("neg", "relu", "silu"):
                b[n] = at(n.args[0])
            elif name in ("div",):
                c = at(n.args[1], 0.0) if not hasattr(n.args[1], "op") else 0.0
                b[n] = at(n.args[0]) / c if c else self.HUGE
            elif name in ("sigmoid", "softmax", "_softmax", "exp"):
                b[n] = 1.0
            elif name in ("sum",):
                b[n] = at(n.args[0]) * math.sqrt(max(1.0, self._cols(n.args[0])))
            elif name in ("mean", "amax", "amin", "max", "min"):
                b[n] = at(n.args[0])
            elif name in ("sqrt",):
                b[n] = math.sqrt(max(1.0, at(n.args[0])))
            elif name == "embedding":
                b[n] = at(n.args[1])              # 表の最大。ids は番号
            elif name in ("getitem", "expand", "broadcast_to"):
                b[n] = at(n.args[0])
            elif name == "cat":
                b[n] = max([at(q) for q in list(n.args[0])] or [1.0])
            elif name == "pow":
                try:
                    b[n] = at(n.args[0]) ** max(1, int(n.args[1]))
                except (TypeError, ValueError):
                    b[n] = self.HUGE
            elif name in ("scaled_dot_product_attention", "sdpa"):
                # softmax の重みは凸結合なので、出る値は V の最大を越えない
                b[n] = at(n.args[2])
            elif name in ("rsqrt", "reciprocal"):
                # $arepsilon$ を足してから割るので $1/\sqrt{arepsilon}$ で抑える。
                # $arepsilon\ge10^{-6}$ なら 1000 に収まる
                b[n] = 1024.0
            elif name in ("cos", "sin", "tanh"):
                b[n] = 1.0
            elif name in ("layer_norm", "rms_norm"):
                g = at(n.args[2], 1.0) if len(n.args) > 2 else 1.0
                bb = at(n.args[3], 0.0) if len(n.args) > 3 and name != "rms_norm" else 0.0
                b[n] = g * math.sqrt(self._cols(n.args[0])) + bb
            else:
                b[n] = self.HUGE
        return dict((n, max(1, int(math.ceil(math.log2(max(1.0, v)))) + 1))
                    for n, v in b.items())

    # 内積を割る組の数の上限と、割る値打ちのある K の下限
    GROUP, MINK = 4096, 256
    # 内側を何項ずつ展開するか。
    #
    # **1 のままにする。** 展開は「係数が 0 で埋めた定数ブロック」のときだけ安全で、
    # 要素ごとの積（両辺が実データ、K=1）では端数の項が隣の列を掛ける。
    #
    #     sel = Σ_{j<u} flag[i+j]·diff[i+j]  ≠  flag[i]·diff[i]
    #
    # 内積だけ展開したいが、engine の展開幅は compile 時に一つなので stage ごとに
    # 変えられない。上げると `sigmoid` が報告 45 で止まる（2026-09-28 に踏んだ）。
    UNROLL = 1

    def _lengths(self):
        """graph の中の内積の項数を全部返す。"""
        POS = {"linear": (1, 1), "mm": (1, 0), "matmul": (1, 0), "addmm": (2, 0)}
        got = []
        for n in self.gm.graph.nodes:
            if n.op not in ("call_function", "call_method"):
                continue
            pos = POS.get(chamber._name_of(n))
            if pos is None or len(n.args) <= pos[0]:
                continue
            sh = self._shape_of(n.args[pos[0]])
            if sh and len(sh) >= 2:
                got.append(int(sh[pos[1]]))
        return got

    def _groups(self, flat, u=1):
        """内積を何組に割るか。`flat` は組を割らないときのレーン数。

        1 lane が $K$ 項を全部持つと GPU を使い切れない。組の数 $C$ を取って 1 lane を
        $U=\lceil K/C
ceil$ 項にする。条件は三つ。

        - **GPU に同時に載る数を越えない。** grid 全体の barrier を使うので、全 block が
          同時に載っていないと止まる。$A\cdot B\cdot C\le$ `lane.resident()`。
        - **$K$ を $C\cdot U$ まで 0 で埋める。** 割り切る必要は無くなる。埋めた項は
          係数が 0 なので値に効かない。$C\cdot U\le	ext{width}$ でなければならない
          （入力は行ごとに width 語なので、越えると次の行を読む）。
        - **1 組が展開の幅で割り切れる。** 割り切れないと組の端が隣の組の係数を拾う。
        """
        ks = [k for k in self._lengths() if k >= self.MINK]
        if not ks:
            return 1
        try:
            cap = lane.resident()
        except Exception:
            cap = 1 << 16
        c = min(self.GROUP, min(ks), max(1, int(cap) // max(1, int(flat))))
        while c > 1:
            need = [(-(-k // c)) for k in ks]                  # 一組の項数 U
            if (all(c * v <= self.width for k, v in zip(ks, need))
                    and all(v % u == 0 for v in need)):
                break
            c -= 1
        return max(1, c)

    def _terms(self):
        """graph の中で一番長い内積の項数。桁を選ぶために先に測る。"""
        POS = {"linear": (1, 1), "mm": (1, 0), "matmul": (1, 0), "addmm": (2, 0)}
        got = [1]
        for n in self.gm.graph.nodes:
            if n.op not in ("call_function", "call_method"):
                continue
            pos = POS.get(chamber._name_of(n))
            if pos is None or len(n.args) <= pos[0]:
                continue
            s = self._shape_of(n.args[pos[0]])
            if s and len(s) >= 2:
                got.append(int(s[pos[1]]))
        return max(got)

    # 桁ごとに立てる形で出す演算。1 つにつき $2(2F+8-F)$ 段の比較が付くので F を抑える
    LADDER = {"softmax", "_softmax", "layer_norm", "rms_norm", "exp", "sqrt",
              "rsqrt", "sigmoid", "silu", "reciprocal", "div"}

    def _depth(self):
        """固定小数の桁 F。$K$ 項の内積の分子が 64 bit の符号を越えないように取る。

        値と係数をどちらも $F$ で持つと分子は $K\\cdot2^{2F+2B}$ まで大きくなる。
        大きさに $2^8$ の余裕を見て $2^{54}$ に収めると

        $$F=\\Bigl\\lfloor\\frac{54-\\lceil\\log_2(K+1)\\rceil}{2}\\Bigr\\rfloor$$

        下は 6（これ以下では刻みが粗くて相対の差が $10^{-2}$ 台になる）、上は 20 で切る。
        ラダーを通る graph では 14 で止める。段の数が $F$ に比例して伸びるためになる。
        """
        k = self._terms()
        f = max(6, min(20, (54 - int(math.ceil(math.log2(max(2, k + 1))))) // 2))
        names = set(self.RENAME.get(chamber._name_of(n), chamber._name_of(n))
                    for n in self.gm.graph.nodes
                    if n.op in ("call_function", "call_method"))
        return min(f, 14) if names & self.LADDER else f

    def _coefficients(self):
        """行列の積の係数とバイアスにしか使われない placeholder と get_attr。

        これを活性と同じ置き方（行を width 語に揃える）で置くと、幅が weight の列数へ
        引っ張られる。`ffn_gate` の $(5120,17408)$ で幅 17408・行 5120、レーンが
        $8.9\\times10^7$ 本になる。係数は `raw` で行を揃えずに置くので、幅の勘定から外す。

        活性の位置に一度でも現れた node は候補から落とす。`matmul` の両側が活性である
        attention の形をここで取り違えない。
        """
        # `embedding` の表も係数。行の詰めを $d$ 語のままにしないと、引きの添字が
        # 出す番地と合わない
        POS = {"linear": (1, 2), "mm": (1, 2), "matmul": (1, 2), "addmm": (0, 2),
               "embedding": (1, 2)}
        coef, act = set(), set()
        for n in self.gm.graph.nodes:
            if n.op == "output":
                got = n.args[0]
                act.update(g for g in (got if isinstance(got, (tuple, list)) else [got])
                           if hasattr(g, "op"))
                continue
            if n.op not in ("call_function", "call_method"):
                continue
            name = chamber._name_of(n)
            if name in self.ALIAS + self.MOVE:
                continue
            pos = POS.get(name)
            if pos is None:
                act.update(self._source(u) for u in n.all_input_nodes)
                continue
            for k, a in enumerate(n.args):
                if hasattr(a, "op"):
                    (coef if k in pos else act).add(self._source(a))
            b = n.kwargs.get("bias")
            if hasattr(b, "op"):
                coef.add(self._source(b))
        return {n for n in coef - act if n.op in ("placeholder", "get_attr")}

    TILE = 512                   # 置き場の詰め幅。列がこれを越える置き場はタイルに切る

    def _stride(self, cols):
        """論理の 1 行が占める語数。列が詰め幅を越えるとタイルの倍数になる。"""
        w = self.width
        return -(-max(1, int(cols)) // w) * w

    def _alloc(self, rows, cols):
        """論理の (行, 列) ぶんの置き場。列が詰め幅を越えたらタイルぶん行を増やす。"""
        return self.B.tensor(int(rows) * (self._stride(cols) // self.width))

    def _rows(self, shape):
        """論理の行数。タイルに切るぶんは掛けない（確保と面の側で掛ける）。"""
        n = 1
        for v in shape[:-1]:
            n *= int(v)
        return max(1, n)

    def _shapes(self):
        """各ノードの形を、素の torch で 1 度走らせて取る。"""
        import torch
        out = {}
        env = {}
        with torch.no_grad():
            for n in self.gm.graph.nodes:
                if n.op == "placeholder":
                    env[n] = self.given[self.order.index(n)]
                elif n.op == "get_attr":
                    env[n] = getattr(self.gm, n.target)
                elif n.op == "output":
                    continue
                else:
                    a = torch.fx.node.map_arg(n.args, lambda k: env[k])
                    kw = torch.fx.node.map_arg(n.kwargs, lambda k: env[k])
                    if n.op == "call_method":
                        # `call_method` の target は文字列。tensor の側から引く
                        env[n] = getattr(a[0], n.target)(*a[1:], **kw)
                    else:
                        env[n] = n.target(*a, **kw)
                if isinstance(env[n], (int, float)) and not isinstance(env[n], bool):
                    # scalar の node。`scale` のように compile 時に決まる数がここへ来る
                    self.scalar[n] = float(env[n])
                if hasattr(env[n], "shape"):
                    out[n] = tuple(env[n].shape)
                    # 実測の最大値も控える。桁の決め方に使う
                    self.dtype[n] = env[n].dtype
                    try:
                        v = float(env[n].detach().abs().max())
                        # 切る値より上は数えない。マスクの $-\infty$ で桁が 4 まで落ちる
                        self.seen[n] = min(v, float(self.TAME))
                    except (RuntimeError, TypeError, ValueError):
                        pass
        return out

    # -- 置く --
    def _numer(self, tensor, d):
        """実数を分子へ。値 = 分子 · 2^-d。

        **ここで表せる範囲へ切る。** マスクは `finfo.min`（$-3.4	imes10^{38}$）を持つので
        $2^{d}$ を掛けると 64 bit を越え、整数へ落としたときに値が飛ぶ。softmax で 0 に
        なる十分小さい値へ収めれば意味は変わらない（2026-09-29 に `sdpainf` で踏んだ）。
        """
        import numpy as np
        import torch
        from . import device as _dev
        t = _dev.bare(tensor)           # device=common の tensor は中身を取る
        t = _dev.bare(t.detach()).cpu() if hasattr(t, "detach") else t
        if t.dtype not in (torch.float32, torch.float64):
            t = t.to(torch.float32)     # bf16 は numpy へ直に渡せない
        a = np.asarray(t, dtype=np.float64)
        a = np.nan_to_num(a, nan=0.0, posinf=float(self.TAME), neginf=-float(self.TAME))
        got = np.rint(a * (1 << d))
        lim = float(1 << 58)
        return np.clip(got, -lim, lim).astype(np.int64)

    def _pad(self, a):
        """行を width 語に揃える。"""
        import numpy as np
        a = a.reshape(self._rows(a.shape), -1) if a.ndim else a.reshape(1, 1)
        pad = np.zeros((a.shape[0], self._stride(a.shape[1])), dtype=np.int64)
        pad[:, :a.shape[1]] = a
        return a.shape, pad.reshape(-1)

    def put(self, node, tensor, depth=None, get=None):
        """テンソルを共有メモリへ。行は width 語に揃える。

        `get` を渡すと、呼ばれるたびに上げ直す置き場として覚える。`get(args)` が
        そのときの tensor を返す。
        """
        d = self.depth if depth is None else depth
        shape, flat = self._pad(self._numer(tensor, d))
        # **回収しない場所から取る。** `tensor()` は解放済みスロットを使い回すので、後の段が
        # 上書きする。因果マスクの置き場に添字の表が入っていた（2026-09-29 に踏んだ）
        head = self.B.room(max(self.B.unit, flat.size))
        self.B.blocks.append((head, flat))
        self.mag[head] = d + self.span.get(node, self.HEAD)
        if get is not None:
            self.live.append([len(self.B.blocks) - 1, d, get, True,
                              self._limit(tensor), get.node, get.then, None])
        self.val[node] = (head, shape[0], shape[1], d)
        return self.val[node]

    def embed(self, n):
        """`embedding(W, ids)`。引きの項で 2 段。host に計算はさせない。

        $$	ext{idx}[t,c]=	ext{ids}[t]\cdot d+c,\qquad
          	ext{out}[t,c]=Migl[W_{	ext{base}}+	ext{idx}[t,c]igr]$$

        $W$ は行の詰めを $d$ 語のままにする（`width` へ揃えない）。添字が $	ext{ids}\cdot d$
        で番地を出すので、詰めを変えると合わない。
        """
        import torch
        E, Z = (self.W, 1, 0), (0, 0, 0)
        # `F.embedding(input, weight)` なので ids が 0 番、表が 1 番
        idn, wn = n.args[0], n.args[1]
        if self._source(wn) not in self.coef:
            raise NotImplementedError("embedding の表が中間の値から来ている")
        get_w = self._getter(wn, lambda t: t.contiguous())
        wt = get_w(self.given)
        vocab, d = int(wt.shape[0]), int(wt.shape[1])
        wh, _ = self.raw(wt, self.depth, get=get_w)
        # token の番号は整数なので桁 0 で置く。**1 token 1 行**に並べ直す（列に並べると
        # 行ごとに違う番号を読めない）
        flat1 = lambda t: t.reshape(-1, 1).to(torch.float32)
        iv = self.put(("ids", idn), flat1(self._t(idn)), depth=0,
                      get=self._getter(idn, flat1))
        rows = iv[1]
        ramp = self.B.data(np.arange(d, dtype=np.int64))
        idx = self.B.tensor(rows)
        self.B.row(idx, E, 1, self.B.imm(d), Z, iv[0], (self.W, 0, 0),
                   add=ramp, add_s=(0, 1, 0))
        out = self.B.tensor(rows)
        z = self.B.imm(0)
        self.B.row(out, E, 1, z, Z, z, Z, pull=(wh, idx), pull_s=E)
        self.B.free(idx)
        return self.mark(out, rows, d, self.depth,
                         self.depth + self.span.get(n, self.HEAD))

    def raw(self, tensor, depth, get=None, rows=None, cols=None):
        """行を揃えずに置く（行列の係数はここ）。

        `rows` を渡すと先頭の軸をその行数まで 0 で埋める。**レーンは (行 × width) 本
        あるので、出力の列が width より少ない matmul では余ったレーンが係数の並びの外を
        読む。** 読んだ値が大きいと乗算が報告 43 で止まる（block の段 3580 で $2^{52}$ を
        読んだ）。0 で埋めておけば余ったレーンは 0 を出す。
        """
        head = self.B.data(
            self._fill(self._numer(tensor, depth), rows, cols).reshape(-1))
        if get is not None:
            self.live.append([len(self.B.blocks) - 1, depth, get, (rows or 0, cols or 0),
                              self._limit(tensor), get.node, get.then, None])
        return head, tuple(tensor.shape)

    def _fill(self, a, rows, cols=None):
        """先頭の軸を `rows` 行、最後の軸を `cols` 語まで 0 で埋める。"""
        import numpy as np
        if cols and a.ndim >= 2 and a.shape[-1] < cols:
            pad = np.zeros(a.shape[:-1] + (cols,), dtype=np.int64)
            pad[..., :a.shape[-1]] = a
            a = pad
        if not rows or a.ndim == 0 or a.shape[0] >= rows:
            return a
        pad = np.zeros((rows,) + a.shape[1:], dtype=np.int64)
        pad[:a.shape[0]] = a
        return pad

    def refresh(self, args):
        """実引数と weight を共有メモリへ上げ直す。**カットを渡る辺はここ一箇所になる。**

        番地も語数も compile 時のまま。差し替えるのは中身だけなので、ステージの表は
        触らない。ここを飛ばすと出力が compile 時の値に固まり、接合秩が 0 になる。

        **変わっていない置き場は送らない。** weight は呼びごとに同じなので、印
        （番地と書き換え回数）が同じなら転記も host→device も要らない。
        """
        for e in self.live:
            if e[5].op not in ("placeholder", "get_attr"):
                # host で出し直す置き場（位置から決まる値や因果マスク）。印は取らない
                a = self._numer(e[2](args), e[1])
                r, c = e[3] if isinstance(e[3], tuple) else (e[3] or 0, 0)
                self.B.send(e[0], self._pad(a)[1] if e[3] is True
                            else self._fill(a, r or None, c or None).reshape(-1))
                continue
            t = self._t(e[5], args)
            mark = (int(t.data_ptr()), int(getattr(t, "_version", 0)),
                    tuple(t.shape))
            if e[7] == mark:
                continue
            e[7] = mark
            a = self._numer(e[6](t) if e[6] is not None else t, e[1])
            if e[3] is True:
                flat = self._pad(a)[1]
            else:
                r, c = e[3] if isinstance(e[3], tuple) else (e[3] or 0, 0)
                flat = self._fill(a, r or None, c or None).reshape(-1)
            self.B.send(e[0], flat)

    def _limit(self, tensor):
        """この置き場に許す値の大きさ。組んだときの $2^{	ext{MARGIN}}$ 倍まで。"""
        try:
            v = float(tensor.detach().abs().max())
        except (RuntimeError, TypeError):
            return None
        return max(1.0, v) * (1 << self.MARGIN)

    def outgrown(self, args):
        """押さえが組んだときより伸びたか。伸びていれば表を組み直す。

        placeholder の最大値だけを見て同じ規則を回すので、素の torch を走らせ直す必要が
        無い。押さえが伸びたまま走らせると乗算が報告 43 で止まる。
        """
        got = self._spans(list(args))
        return any(v + self.MARGIN > self.bound.get(n, v + self.MARGIN)
                   for n, v in got.items())

    def close(self):
        """抱えている VRAM を放す。組み直す前に前の板を捨てる。"""
        if self.B._J is not None:
            self.B._J.close()
            self.B._J = None

    # -- 桁を戻す --
    #
    # $F$ は host の側の属性で、語に入るのは分子だけになる。だから $2^m$ で割るのは
    # 記帳であり、段は要らない。段が要るのは**分子が 64 bit の符号を溢れるとき**だけ。
    #
    # 積のたびに戻すと 1 回につき 5(幅 − F) 段の比較が付く。`softmax` の 1564 段のうち
    # 1298 段がこれだった（2026-09-28 に測った）。そこで分子の上限を持ち回る。
    #
    #     mag(a ⋆ b)           = mag(a) + mag(b)
    #     mag(Σ_{j<K} w_j x_j) = mag(w) + mag(x) + ⌈log₂ K⌉
    #
    # **溢れの検査は段の中の一つの積に当たる**（`gvcpu` が報告 43 を返す）。だから予算は
    # 積の結果ではなく**掛ける前の二つの因子**に効く。戻すのは積の前になる。
    #
    #     mag(w) + mag(x) + ⌈log₂ K⌉ ≤ 62

    @property
    def W(self):
        """いま組んでいる置き場の行の詰め。`Build` と同じものを見る。"""
        return self.B.W

    BUDGET = 62                  # 分子に許す bit。符号の 1 bit と余裕を残す
    TARGET = 54                  # 分子に使いたい bit。深さは押さえから決める

    def _want_depth(self, node):
        """その node の桁。**押さえから決める。**

        全体で一つの $F$ を使うと、小さい値では刻みが粗く（埋め込み出力 0.008 の二乗が
        $F=14$ で 0 になる）、大きい値では予算が尽きる。値ごとに

        $$	ext{depth}(n)=T-\operatorname{span}(n)$$

        と取れば、分子が常に約 $T$ bit を使うので刻みが最も細かくなる。
        """
        sp = self.span.get(node)
        if sp is None:
            return self.depth
        return max(4, min(self.TARGET, self.TARGET - int(sp)))
    HEAD = 8                     # 実測が無い置き場に見る余裕
    # 実測の上限へ足す余裕。上限は compile 時の入力から測るので、実行時の入力が
    # それより大きいと足りなくなる。16 倍まで見る。越えたら乗算が報告 43 で止まる
    # （静かに壊れることは無い）。
    MARGIN = 4

    def _mag(self, head, d):
        """分子の bit 数の上限。覚えていなければ「F ＋ 大きさ 8 bit」と見る。"""
        return self.mag.get(head, d + self.HEAD)

    def _settle(self, node, head, rows, cols, d, mag):
        """積の結果を、押さえから決めた桁へ落ち着かせる。1 行で済む。"""
        m = self._cap(node, d, mag)
        self.mark(head, rows, cols, d, m)
        want = self._want_depth(node)
        if d <= want:
            return self.fit((head, rows, cols, d), self.BUDGET)
        cut = d - want
        got = self.B.rshift(head, rows, cut, min(self.BUDGET, m))
        self.mag[got] = m - cut
        return got, rows, cols, want

    def _cap(self, node, d, mag):
        """溜まった見積りを、押さえから来る上限で切る。

        積を重ねると見積りが実際より大きくなる。桁を戻しても `m − cut` を持ち回るので
        差が残り、下流の `fit` が桁を削りすぎる（splitblk の `down` で深さが 0 になった）。
        node の押さえが分かるところで切る。
        """
        sp = self.span.get(node)
        return mag if sp is None else min(mag, d + sp)

    def mark(self, head, rows, cols, d, mag):
        """分子の上限を覚えるだけ。段は足さない。"""
        self.shape_note[head] = (int(rows), int(cols))
        self.mag[head] = mag
        return head, rows, cols, d

    def fit(self, v, room):
        """分子が `room` bit に収まるまで F を戻す。積へ渡す前に当てる。"""
        head, rows, cols, d = v
        m = self._mag(head, d)
        if m <= room:
            return v
        cut = min(d, m - room)
        if cut <= 0:
            raise RuntimeError(
                "分子が %d bit で、F が %d しかないので戻せません。graph の F を下げます"
                % (m, d))
        got = self.B.rshift(head, rows, cut, min(self.BUDGET, m))
        self.mag[got] = m - cut
        return got, rows, cols, d - cut

    def exact(self, v):
        """F を既定へちょうど戻す。桁ごとに立てる形（`exp` や `layernorm`）の入口で当てる。

        **`fit` を先に通してはいけない。** `fit` は分子を `room` bit へ縮めるので、上限が
        緩いと桁を 3 まで削ってから 14 へ持ち上げることになり、刻みが 0.125 になる。
        """
        head, rows, cols, d = v
        m = self._mag(head, d)
        if d == self.depth:
            return v
        if d < self.depth:                          # 足りない側は 2 の冪で持ち上げる
            up = self.B._scale(head, 1 << (self.depth - d))
            self.mag[up] = m + (self.depth - d)
            return up, rows, cols, self.depth
        cut = d - self.depth
        got = self.B.rshift(head, rows, cut, min(self.BUDGET, m))
        self.mag[got] = m - cut
        return got, rows, cols, self.depth

    def norm(self, head, rows, cols, d, mag=None):
        """後ろ向きの呼び名。上限を覚えて、溢れそうなときだけ戻す。"""
        m = self._mag(head, d) if mag is None else mag
        self.mark(head, rows, cols, d, m)
        return self.fit((head, rows, cols, d), self.BUDGET)

    # -- ノードごとの段 --
    # ---- host で先に済ませる node -----------------------------------------
    #
    # 位置から決まる値（`arange`、回転の `cos` `sin`、因果マスクの `le`）は **caller が
    # 渡す入力を祖先に持たない**。module の持ち物（weight と buffer）だけから決まる。
    # これを「呼びごとに host が入れ直す置き場」として置けば、weight と同じ扱いになり、
    # 表に段を足さずに済む。呼びごとに入れ直すので値が焼き付くこともない。

    def _module_side(self, n):
        """module の持ち物から来る node か。caller が渡す入力と分ける。"""
        # Dynamo は module の持ち物を `L_self_...` という名で placeholder にする。
        # caller が渡す引数は `L_args_...` や `L_input_ids_` になる
        t = str(getattr(n, "target", ""))
        return (n.op == "get_attr"
                or (n.op == "placeholder" and t.lower().startswith("l_self_")))

    def _hosts(self):
        """host で先に済ませられる node の集まり。"""
        got = set()
        for n in self.gm.graph.nodes:
            if n.op == "output":
                continue
            if self._module_side(n):
                got.add(n)
                continue
            if n.op == "placeholder":
                continue                       # caller が渡す入力
            ins = list(n.all_input_nodes)
            # 入力 node を持たない（Python の値から作る）node も定数。`arange` がこれ
            if all(a in got for a in ins):
                got.add(n)
        return got

    def _host_edge(self, n):
        """その host node を置く必要があるか。host でない利用者がいるときだけ。

        `arange` → `cos` の途中は置かなくてよい。置くと桁の扱いに困る（番号の tensor を
        固定小数として置くことになる）。
        """
        for u in n.users:
            if u.op == "output" or u not in self.host:
                return True
        return False

    def _host_eval(self, node, args):
        """`node` の値を host で出す。祖先だけを辿るので安い。"""
        import torch
        order = [n for n in self.gm.graph.nodes]
        pos = dict((n, k) for k, n in enumerate(order))
        want, seen = [], set()

        def walk(n):
            if n in seen:
                return
            seen.add(n)
            for a in n.all_input_nodes:
                walk(a)
            want.append(n)

        walk(node)
        need = set(want)
        vals, it = {}, iter(args)
        for n in order:
            if n.op == "placeholder":
                v = next(it)
                if n in need:
                    vals[n] = v
        for n in sorted(want, key=lambda q: pos[q]):
            if n.op == "placeholder":
                continue
            if n.op == "get_attr":
                v = self.gm
                for part in str(n.target).split("."):
                    v = getattr(v, part)
                vals[n] = v
                continue
            a = torch.fx.node.map_arg(n.args, lambda q: vals[q])
            kw = torch.fx.node.map_arg(n.kwargs, lambda q: vals[q])
            tgt = n.target
            if n.op == "call_method":
                tgt = getattr(a[0], n.target)
                a = a[1:]
            vals[n] = tgt(*a, **kw)
        return vals[node]

    def emit(self):
        """グラフを順に辿ってステージを並べる。返りは出力ノードごとの置き場。"""
        import torch
        E = (self.W, 1, 0)
        for n in self.gm.graph.nodes:
            if n.op in ("placeholder", "get_attr"):
                if n not in self.coef:
                    self.put(n, self._t(n), get=self._getter(n))
                continue                        # 係数は matmul が raw で置く
            if n.op == "output":
                continue
            name = self.RENAME.get(chamber._name_of(n), chamber._name_of(n))
            # **host の判定を先に見る。** `unsqueeze` のように MOVE にも入る名前があるので、
            # 後回しにすると置かなかった途中の値を読もうとする
            if n in self.host:
                if not self._host_edge(n):
                    continue               # 途中の値。置かなくてよい
                v = self._host_eval(n, self.given)
                if hasattr(v, "shape") and v.numel():
                    # 呼びごとに host が入れ直す。焼き付かない
                    self.put(n, self._tame(v), get=self._host_getter(n))
                continue
            if name in self.ALIAS:
                if self._source(n) not in self.coef:
                    self.val[n] = self.val[n.args[0]]  # 置き方を変えない移り
                continue
            if name in self.MOVE:
                if self._source(n) not in self.coef:
                    self.val[n] = self.move(n, name)
                continue
            if name in ("scaled_dot_product_attention", "sdpa"):
                self.val[n] = self.attend(n)
                continue
            if name == "cat":
                self.val[n] = self.concat(n)
                continue
            if name == "pow":
                # $x^k$。整数の冪は掛け算を重ねる
                k = int(n.args[1])
                if k < 1:
                    raise NotImplementedError("pow の冪が %s" % n.args[1])
                v = self.val[n.args[0]]
                for _ in range(k - 1):
                    a2 = self.fit(v, self.BUDGET // 2)
                    out = self.B.tensor(a2[1])
                    self.B.row(out, E, 1, a2[0], E, a2[0], E)
                    v = self._settle(n, out, a2[1], a2[2], a2[3] * 2,
                                     2 * self._mag(a2[0], a2[3]))
                self.val[n] = v
                continue
            if name == "getitem":
                self.val[n] = self.gather(n)
                continue
            if name in ("expand", "broadcast_to"):
                sz = tuple(n.args[1:]) if len(n.args) > 2 else tuple(n.args[1])
                self.val[n] = self.gather(n, how=lambda t: t.expand(sz))
                continue
            if name == "embedding":
                self.val[n] = self.embed(n)
                continue
            if name in ("linear", "addmm", "mm", "matmul"):
                self.val[n] = self.matmul(n)
                continue
            if name in ("mul", "add", "sub", "neg", "relu", "div", "rsub"):
                self.val[n] = self.point(n, name)
                continue
            if name in ("sum", "mean", "amax", "max", "amin", "min"):
                self.val[n] = self.reduce(n, name)
                continue
            if name in ("softmax", "_softmax"):
                self.val[n] = self.soft(n)
                continue
            if name in ("layer_norm", "rms_norm"):
                self.val[n] = self.normed(n, name)
                continue
            if name in ("exp", "rsqrt", "sqrt", "sigmoid", "silu", "reciprocal"):
                self.val[n] = self.curve(n, name)
                continue
            raise chamber.Unknown(name)
        # 押さえを表へ渡す。配列の演算として出す側が、係数と入力を何 bit に割るかを
        # ここから決める（int8 の行列積は int64 の 14 倍）
        self.B.mag = dict(self.mag)
        # 置き場ごとの本当の (行, 列)。行列積の段をレーン格子いっぱいでなく、実際に
        # 要る大きさで回すのに使う（attention の QKᵀ は 8x8 しか要らないのに
        # 108x512 を回していた）
        self.B.shape_at = dict(self.shape_note)
        for n, (h, rr, cc, _d) in self.val.items():
            self.B.shape_at[h] = (int(rr), int(cc))
        return self

    # ---- 行に沿った縮約 ---------------------------------------------------
    #
    # 縮約の値は**行の全列へ**入る。列 0 だけに書くと、以降のステージが要素ごとの歩幅で
    # 読んで 0 を拾う。論理の列数は 1 に落とすので、出力として読むときは 1 列だけ取る。
    def _last_dim(self, n):
        """縮約の軸が最後の軸か。行をまたぐ縮約はレーンの割り当てが変わるので断る。"""
        s = self._shape_of(n.args[0])
        dim = n.args[1] if len(n.args) > 1 else n.kwargs.get("dim")
        if isinstance(dim, (list, tuple)):
            if len(dim) != 1:
                return False
            dim = dim[0]
        return isinstance(dim, int) and s is not None and dim % len(s) == len(s) - 1

    def reduce(self, n, name):
        """$\\bigoplus_k$ と $\\bigvee_k$。係数を単位にした内積と、入れ替えの比較。"""
        if not self._last_dim(n):
            raise chamber.Unknown("%s の軸が最後の軸でない" % name)
        h, rows, cols, d = self.val[n.args[0]]
        if name in ("amax", "max"):
            return self.norm(self.B.rowmax(h, cols, self._stride(cols), rows),
                             rows, 1, d)
        if name in ("amin", "min"):
            got = self.B.rowmax(self.B._scale(h, -1), cols)
            return self.norm(self.B._scale(got, -1), rows, 1, d)
        kb = int(math.ceil(math.log2(max(2, cols))))
        # 平均は和のあとに $1/k$ を掛ける。その分の桁も**先に**空ける。空けないと
        # 分子が 68 bit になって乗算が溢れ、値が $2^{-5}$ で飽和する（2026-09-29 に
        # attention の RMSNorm で踏んだ）
        inv = round((1 << self.depth) / cols) if name == "mean" else 1
        room = self.BUDGET - kb - (max(1, int(inv).bit_length())
                                   if name == "mean" else 0)
        h, rows, cols2, d = self.fit((h, rows, cols, d), room)
        out = self.B.rowsum(h, cols, self._stride(cols), rows)
        mag = self._mag(h, d) + kb
        if name == "mean":
            out = self.B._mulc(out, self.B.imm(inv))
            d = d + self.depth
            mag = mag + max(1, int(inv).bit_length())
        return self.norm(out, rows, 1, d, mag=mag)

    def soft(self, n):
        """行ごとの softmax。最大を引いてから指数を取り、和で割る。"""
        h, rows, cols, d = self.exact(self.val[n.args[0]])
        f = self.depth
        got = self.B.softmax(h, cols, f, self.bits,
                             st=self._stride(cols), rows=rows)
        return (got, rows, cols, f)

    def normed(self, n, name):
        """層ごとの正規化。$\\gamma$ と $\\beta$ は行に沿った並びとして置く。"""
        h, rows, cols, d = self.exact(self.val[n.args[0]])
        f = self.depth
        w = n.args[2] if len(n.args) > 2 else n.kwargs.get("weight")
        b = n.args[3] if len(n.args) > 3 and name != "rms_norm" else n.kwargs.get("bias")
        eps = ([a for a in n.args if isinstance(a, float)] or
               [n.kwargs.get("eps") or 1e-5])[0]
        gh = bh = None
        if hasattr(w, "op"):
            get = self._getter(w, lambda t: t.contiguous())
            gh, _ = self.raw(get(self.given), f, get=get)
        if hasattr(b, "op"):
            get = self._getter(b, lambda t: t.contiguous())
            bh, _ = self.raw(get(self.given), f, get=get)
        mean = name != "rms_norm"
        out, od = self.B.layernorm(h, cols, f, self.bits, gamma=gh, beta=bh,
                                   eps=eps, mean=mean,
                                   st=self._stride(cols), rows=rows)
        # 深さは `layernorm` が返す。出口で戻していないので f のままではない
        # 分子の上限は押さえから取る。`od + 2·HEAD + log2 cols` と置くと 12 bit 過大で、
        # 下流の `fit` が桁を削りすぎる（2026-09-29 に ffn の `mul` で踏んだ）
        return self.mark(out, rows, cols, od, od + self.span.get(n, self.HEAD))

    def curve(self, n, name):
        """一変数の関数。縮小写像の閉包と、桁ごとに立てる形で出す。"""
        B = self.B
        # $1/\\sqrt v$・$\\sqrt v$・$1/v$ は**入力の桁をそのまま使う**。既定の 14 へ落とすと
        # 分散 $4\\times10^{-4}$ の分子が 6 しか残らず 9% 外れる
        if name in ("rsqrt", "sqrt", "reciprocal"):
            # 桁ごとに立てる閉包が $t^2$ を作るので $2f+	ext{span}\le62$。24 で止める
            h, rows, cols, d = self.fit(self.val[n.args[0]], self.BUDGET // 2)
            if d > 24:
                h, rows, cols, d = self.exact((h, rows, cols, d)) if self.depth > 24                     else self.fit((h, rows, cols, d), 24 + self.HEAD)
            d = max(4, min(24, d))
            if name == "rsqrt":
                return (B.rsqrt(h, d, 2 * d), rows, cols, d)
            if name == "sqrt":
                return (B.isqrt(B._scale(h, 1 << d), 4 * d), rows, cols, d)
            return (B.recip(h, d, 2 * d), rows, cols, d)
        h, rows, cols, d = self.exact(self.val[n.args[0]])
        f = self.depth
        if name == "exp":                              # $x\\le0$ の側だけ
            return (B.exp_pull(h, f), rows, cols, f)
        # sigmoid と silu。`exp_neg` は $x\\le0$ の側しか出ないので $e^{-|x|}$ から両側を組む
        #
        #     σ(x) = 1/(1+t)  (x ≥ 0),      t/(1+t)  (x < 0),      t = e^{-|x|}
        #
        E = (self.W, 1, 0)
        up = B.tensor()
        B.row(B.scratch(), E, 1, h, E, B.imm(1), (0, 0, 0), flag=up, thresh=0)  # [0 ≤ x]
        t = B.exp_pull(B._pick(up, B._scale(h, -1), h), f)          # e^{-|x|}
        inv = B.recip(B._add(t, B._const_like(1 << f)), f, f + 6)               # 1/(1+t)
        s = B._pick(up, inv, B.rshift(B._mul(t, inv), rows, f, self.bits))
        if name == "sigmoid":
            return (s, rows, cols, f)
        return (B.rshift(B._mul(h, s), rows, f, self.bits), rows, cols, f)

    def matmul(self, n):
        """$y=xW^{\top}+b$。レーン $(i,j)$ が 1 要素を受け持つ。"""
        name = chamber._name_of(n)
        if name == "linear":
            xn, wn = n.args[0], n.args[1]
            bn = n.args[2] if len(n.args) > 2 else n.kwargs.get("bias")
            wt = False
        elif name == "addmm":
            bn, xn, wn, wt = n.args[0], n.args[1], n.args[2], True
        else:
            bn, xn, wn, wt = None, n.args[0], n.args[1], True
        # 右側が中間の値なら、係数として置き直せない。転置して置き場から読む。
        #
        # 素の係数は K 語で詰めてあるが、中間の値は行ごとに width 語へ揃えてある。だから
        # 歩幅が (0, K, 0) ではなく (0, width, 0) になる。attention の QKᵀ がこの形。
        if self._source(wn) not in self.coef:
            bv = self.val[wn]
            if wt:                                   # matmul(x, B) は B が (K, N)
                bv = self._flip(bv)                  # → (N, K) で k 方向に連続
            N, K = bv[1], bv[2]
            # **両辺に予算を半分ずつ配る。** 片側だけ削ると桁が落ちる（QKᵀ は両辺とも
            # 積の出力なので F が 40 になり、片側を 12 bit へ詰めると差が 2×10⁻² 出た）
            half = (self.BUDGET - int(math.ceil(math.log2(max(2, K))))) // 2
            bv = self.fit(bv, half)
            wh, w_s, wd = bv[0], (0, self.W, 0), bv[3]
        else:
            # 行 j が出力 j の係数になる形へ。呼ばれるたびに同じ並べ替えをやり直す
            get_w = self._getter(wn, (lambda t: t.t().contiguous()) if wt
                                 else (lambda t: t.contiguous()))
            wshape = tuple(get_w(self.given).shape)
            N, K = int(wshape[0]), int(wshape[1])
            # 余ったレーン（i₂ ≥ N）が並びの外を読まないよう行を width まで、
            # 内側の展開の端数が隣を拾わないよう列を unroll の倍数まで、0 で埋める
            u = self.B.unroll
            # **係数の桁を先に決める。** 入力の分子が大きいとき、入力を削るのでなく係数の
            # 桁を下げる。係数は compile 時に置くので、桁を下げても段は増えない
            kb = int(math.ceil(math.log2(max(2, K))))
            spw = self.span.get(self._source(wn), self.HEAD)
            spx = self.span.get(xn, self.HEAD)
            # 予算を係数と入力へ**均等に**配る。片方へ寄せると、もう片方の桁が
            # 6 まで落ちて刻みが 10^-1 台になる
            share = (self.BUDGET - kb - spw - spx) // 2
            wdep = max(4, min(self.TARGET - spw, share))
            C0 = self.B.groups
            Kp = K
            if C0 > 1 and K >= self.MINK:
                Kp = C0 * (-(-K // C0))            # 組の端が並びの外を読まない大きさへ
            Kp = -(-Kp // u) * u
            # 行は N ぶん要る。詰め幅で切ると、列が詰め幅を越える行列積で半分が落ちる
            wh, _ = self.raw(get_w(self.given), wdep, get=get_w,
                             rows=max(N, self.width), cols=Kp)
            w_s, wd = (0, Kp, 0), wdep
            # 係数の分子も押さえから取る。`depth + HEAD` と決め打ちすると空ける bit が
            # 3 bit 多くなり、入力の桁が削られる
            self.mag[wh] = wdep + spw
        # 段の中の一つの積が 63 bit に収まるように、掛ける前に x を戻す
        room = (self.BUDGET - self._mag(wh, wd)
                - int(math.ceil(math.log2(max(2, K)))))
        xh, xr, xc, xd = self.fit(self.val[xn], room)
        bias = None
        if bn is not None and hasattr(bn, "op"):
            get_b = self._getter(bn, lambda t: t.contiguous())
            bias, _ = self.raw(get_b(self.given), wd + xd, get=get_b,
                               rows=self.width)
        E, Z = (self.W, 1, 0), (0, 0, 0)
        bias_s = (0, 1, 0) if bias is not None else Z
        C = self.B.groups
        out = self._alloc(xr, N)
        # 列が詰め幅を越える行列積は、レーンの $i_1$ をタイルに使う。内積の分割とは
        # 同じ軸を取り合うので、そのときは割らない
        if C > 1 and K >= self.MINK and w_s[1] != self.width and N <= self.width:
            # 組ごとの内積。1 lane は U 項だけ持つ
            #
            #     p[a,b,c] = Σ_{u<U} W[b, cU+u] · x[a, cU+u],   U = K/C
            #
            # 係数は (0, K, U)、入力は (width, 0, U)、出す先は (width·C, C, 1)。
            U = -(-K // C)
            p = self.B.part()
            self.B.row(p, (self.width * C, C, 1), U, wh, (0, w_s[1], U),
                       xh, (self.width, 0, U))
            # 組の総和。係数を単位の並びにして C 項の内積にする
            self.B.row(out, E, C, self.B.ones(C), Z, p, (self.width * C, C, 0),
                       add=bias, add_s=bias_s)
            self.B.free_part(p)
        else:
            # 出力の列が詰め幅を越えるときは、レーンの $i_1$ がタイル、$i_2$ が
            # タイル内の列になる。出す番号は $n=i_1W+i_2$ なので係数の歩幅は $(WK, K, 0)$
            if N > self.width and xr == 1:
                self.B.row(out, E, K, wh, (self.width * w_s[1], w_s[1], 0),
                           xh, (0, 0, 0), add=bias, add_s=bias_s)
            elif N > self.width:
                # 列が詰め幅を越え、行も複数ある形。番地は
                #
                #     h + r·T·W + t·W + c,    n = t·W + c,   T = ⌈N/W⌉
                #
                # で、レーンの三軸から $t=i_1mod T$ を作る剰余がエンジンに無い。
                # タイルごとに段を置くと $i_1=r$、$i_2=c$ になって剰余が消える。
                # 段は $T$ 本。Qwen の FFN（17408 列、詰め幅 512）で 34 本になる
                T = self._stride(N) // self.width
                for t in range(T):
                    self.B.row(out + t * self.width, (T * self.width, 1, 0), K,
                               wh + t * self.width * w_s[1], (0, w_s[1], 0),
                               xh, (self._stride(xc), 0, 0),
                               add=None if bias is None else bias + t * self.width,
                               add_s=bias_s)
            else:
                self.B.row(out, E, K, wh, w_s, xh, (self._stride(xc), 0, 0),
                           add=bias, add_s=bias_s)
        # 埋めた項は係数が 0 なので、値には効かない
        mag = (self._mag(xh, xd) + self._mag(wh, wd)
               + int(math.ceil(math.log2(max(2, K)))))
        return self._settle(n, out, xr, N, xd + wd, mag)

    def _spread(self, v, rows, cols):
        """大きさ 1 の軸を伸ばして (rows, cols) の形へ置き直す。

        PyTorch の broadcast は大きさ 1 の軸を伸ばす。読む歩幅 0 がそれに当たるので、
        1 ステージ書き写すだけで済む。

        **歩幅だけ変えて済ませてはいけない。** 後段の `fit`・`rshift`・`_align` は
        (width, 1, 0) で読むので、広げていない置き場を渡すと 2 行目以降が隣を読む。
        bias が 1 行目にしか足されない食い違いがこれだった（2026-09-29 に測った）。
        """
        head, r, c, d = v
        if (r, c) == (rows, cols):
            return v
        if r not in (1, rows) or c not in (1, cols):
            raise NotImplementedError(
                "broadcast できない形 %s → %s" % ((r, c), (rows, cols)))
        src = (self.width if r == rows else 0, 1 if c == cols else 0, 0)
        out = self.B.tensor(rows)
        self.B.row(out, (self.W, 1, 0), 1, head, src, self.B.imm(1), (0, 0, 0))
        self.mag[out] = self._mag(head, d)
        return out, rows, cols, d

    def move(self, n, name):
        """置き方を変える箱。`reshape` `view` `t` `transpose` `permute` `unsqueeze` 等。

        添字の表は `arange` に**同じ演算を当てて**作る。だから (行, 列) に潰した形で
        判定してはいけない。4 軸の `transpose(1,2)` は行と列の数が変わらないまま行の
        並びが変わるので、潰して比べると素通りしてしまう（2026-09-29 に踏んだ。
        `query_states` が 1.45 外れた）。
        """
        if name in ("t",):
            return self.gather(n, how=lambda t: t.t())
        if name == "transpose":
            d0, d1 = int(n.args[1]), int(n.args[2])
            return self.gather(n, how=lambda t: t.transpose(d0, d1))
        if name == "permute":
            dims = tuple(n.args[1:]) if len(n.args) > 2 else tuple(n.args[1])
            dims = tuple(int(v) for v in dims)
            return self.gather(n, how=lambda t: t.permute(dims))
        # reshape・view・unsqueeze・squeeze・flatten は並びを変えないので形だけ合わせる
        want = self.shape.get(n)
        return self.gather(n, how=lambda t: t.reshape(tuple(want)))

    def _plane(self, rows, cols, off):
        """(行, 列) の値を、**レーン全部が収まる大きさ**の面へ置く。

        レーンは最大行数まであるので、行数ぶんしか取らないと $i_1\\ge$ 行数 のレーンが
        面の外（次の置き場＝活性の値）を読む。引きの添字でそれをやると番地が飛ぶ。
        """
        st = self._stride(cols)
        one = np.zeros((rows, st), dtype=np.int64)
        one[:, :cols] = off
        need = max(self.B.unit, rows * st)
        tab = np.zeros((need // self.width, self.width), dtype=np.int64)
        tab[:rows * (st // self.width)] = one.reshape(-1, self.width)
        return self.B.data(tab.reshape(-1))

    def _recast(self, v, rows, cols, off):
        """添字表 `off` に従って 1 ステージで写す。引きの項 $M[g+M[t]]$ を使う。"""
        head, r, c, d = v
        t = self._plane(rows, cols, off)
        out = self._alloc(rows, cols)
        z = self.B.imm(0)
        self.B.row(out, (self.W, 1, 0), 1, z, (0, 0, 0), z, (0, 0, 0),
                   pull=(head, t), pull_s=(self.W, 1, 0))
        self.mag[out] = self._mag(head, d)
        return out, rows, cols, d

    def _flip(self, v, pad=False):
        """中間値を転置する。内積を $k$ 方向に連続にするために使う。

        `pad` を立てると行を詰め幅まで伸ばす。**係数として歩幅 $(0,W,0)$ で読む側は必ず
        立てる。** $i_2$ は詰め幅まで動くので、行が足りないと遠くを読む。
        """
        head, r, c, d = v
        base = (np.arange(c)[:, None] * 1 + np.arange(r)[None, :] * self.width)
        rows = self.width if pad else c
        off = np.zeros((rows, r), dtype=np.int64)
        off[:c] = base
        return self._recast(v, rows, r, off)

    def attend(self, n):
        """`scaled_dot_product_attention`。head ごとに段を並べる。

        $$A=rac{QK^{\mathsf T}}{\sqrt D}+	ext{mask},\qquad
          P=\operatorname{softmax}(A),\qquad O=PV$$

        いまは head ごとに切り出して並べるので、段の数が head の数に比例する。Qwen
        （65 層 × 40 head）では 2 万段を越えるため、$i_3$ 軸を head に割る形へ直す必要が
        ある。まず動く形を置く。
        """
        import torch
        E, Z = (self.W, 1, 0), (0, 0, 0)
        qn, kn, vn = n.args[0], n.args[1], n.args[2]
        # 引数は位置でも名前でも来る。`is_causal` と `enable_gqa` と `dropout_p` を
        # 落とすと、PyTorch は因果 attention、こちらは全結合 attention になる
        pos = list(n.args)

        def take(k, nm, dv, scalar=True):
            got = pos[k] if len(pos) > k else n.kwargs.get(nm, dv)
            # スカラーの欄に node が入っていたら、位置の数え方が違う。名前側を見る
            if scalar and hasattr(got, "op"):
                got = n.kwargs.get(nm, dv)
            return got

        mask = pos[3] if len(pos) > 3 else n.kwargs.get("attn_mask")
        if mask is not None and not hasattr(mask, "op"):
            mask = n.kwargs.get("attn_mask")
        drop = take(4, "dropout_p", 0.0)
        causal = bool(take(5, "is_causal", False))
        scale = take(6, "scale", None)
        gqa = bool(take(7, "enable_gqa", False))
        if drop:
            raise NotImplementedError("dropout_p が %s。推論では 0 のみ" % (drop,))
        qs, ks = self.shape[qn], self.shape[kn]
        if len(qs) != 4 or len(ks) != 4:
            raise NotImplementedError("attention の形が 4 軸でない %s" % (qs,))
        B, H, T, D = [int(v) for v in qs]
        S = int(ks[2])
        Hk = int(ks[1])
        if hasattr(scale, "op"):
            # `scale` が node で来る形。値は config から決まるので compile 時に取れる
            scale = self.scalar.get(scale)
        if scale is None:
            scale = 1.0 / math.sqrt(float(D))
        scale = float(scale)
        want = self.shape[n]
        rows, cols = self._rows(want), int(want[-1])
        f = self.depth
        out = None
        for bh in range(B * H):
            b0, h0 = bh // H, bh % H
            # **KV の head は `//` で対応する。** `%` だと 0 1 0 1 になり、PyTorch の
            # 0 0 1 1 と食い違う（H=4 Hk=2 で相対差 0.57）
            hk = h0 // max(1, H // max(1, Hk)) if Hk < H else h0
            hk = min(hk, Hk - 1)
            qv = self._slice_head(qn, b0, h0, T, D)
            kv = self._slice_head(kn, b0, hk, S, D, pad=True)
            vv = self._slice_head(vn, b0, hk, S, D, pad=True)
            # A = Q·Kᵁ。K は (S, D) なので k 方向に連続。係数の歩幅は (0, width, 0)
            half = (self.BUDGET - int(math.ceil(math.log2(max(2, D))))) // 2
            qf, kf = self.fit(qv, half), self.fit(kv, half)
            a2 = self.B.tensor(T)
            self.B.row(a2, E, D, kf[0], (0, self.W, 0), qf[0],
                       (self.W, 0, 0))
            av = self.exact(self.mark(a2, T, S, qf[3] + kf[3],
                                      self._mag(qf[0], qf[3]) + self._mag(kf[0], kf[3])
                                      + int(math.ceil(math.log2(max(2, D))))))
            # 1/√D を掛ける
            kk = int(round(scale * (1 << f)))
            av = self.exact((self.B._scale(av[0], kk), T, S, av[3] + f))
            if causal:
                # $s\le t+(S-T)$ の外を落とす。KV を溜めていると S > T になる
                av = self._add_plane(av, self._causal(T, S), T, S)
            if mask is not None and hasattr(mask, "op"):
                mv = self._mask_head(mask, b0, h0, T, S)
                mv = self._as_add(mask, mv)
                d2, ah, bh2 = self._align(av, mv)
                av = (self.B._add(ah, bh2), T, S, d2)
            pv = (self.B.softmax(self.exact(av)[0], S, f, self.bits), T, S, f)
            # O = P·V。V を転置して s 方向に連続にする
            vt = self._flip(vv, pad=True)
            half = (self.BUDGET - int(math.ceil(math.log2(max(2, S))))) // 2
            pf, vf = self.fit(pv, half), self.fit(vt, half)
            o2 = self.B.tensor(T)
            self.B.row(o2, E, S, vf[0], (0, self.W, 0), pf[0],
                       (self.W, 0, 0))
            ov = self.exact(self.mark(o2, T, D, pf[3] + vf[3],
                                      self._mag(pf[0], pf[3]) + self._mag(vf[0], vf[3])
                                      + int(math.ceil(math.log2(max(2, S))))))
            out = self._put_head(out, ov, bh, T, D, rows, cols)
        return self.mark(out[0], rows, cols, out[3],
                         self._cap(n, out[3], self._mag(out[0], out[3])))

    def _slice_head(self, node, b0, h0, T, D, pad=False):
        """(B,H,T,D) の 1 つの head を (T, D) として取り出す。1 段。

        `pad` を立てると行を詰め幅まで伸ばす。**係数として歩幅 $(0,W,0)$ で読む側は必ず
        立てる。** $i_2$ は詰め幅まで動くので、$S$ 行しか置かないと余ったレーンが 26 万語
        先を読み、拾った値の積が 64 bit を越える（2026-09-29 に段 112 で踏んだ）。
        """
        import torch
        v = self.val[node]
        sh = self.shape[node]
        lin = torch.arange(int(np.prod(sh))).reshape(sh)[b0, h0]
        c0 = int(sh[-1])
        flat = np.asarray(lin.contiguous().reshape(T, D))
        rows = self.width if pad else T
        full = np.zeros((rows, D), dtype=np.int64)
        full[:T] = flat                     # 余った行は先頭を指す（値は普通の大きさ）
        off = (full // c0) * self.width + (full % c0)
        return self._recast(v, rows, D, off)

    def _causal(self, T, S):
        """因果マスクの加算の形。$s>t+(S-T)$ を $-2^{18}$ にする。"""
        off = S - T
        t = np.arange(T)[:, None]
        s = np.arange(S)[None, :]
        return np.where(s <= t + off, 0, -(1 << 18)).astype(np.int64)

    def _add_plane(self, v, plane, rows, cols):
        """compile 時に決まる面を足す。1 段。"""
        h, r, c, d = v
        mh = self._plane(rows, cols, plane * (1 << d))
        out = self.B.tensor(rows)
        E = (self.W, 1, 0)
        self.B.row(out, E, 1, h, E, self.B.imm(1), (0, 0, 0), add=mh, add_s=E)
        self.mag[out] = max(self._mag(h, d), d + 19) + 1
        return out, rows, cols, d

    def _as_add(self, node, mv):
        """マスクを足し算の形へ。

        `torch.nn.functional.scaled_dot_product_attention` は **bool のマスクを「True の
        所を使う」** と読む。数として足すと $-\infty$ ではなく 1 を足してしまう
        （2026-09-29 に Qwen で踏んだ。$A$ 自体は厳密に合っていた）。

        $$A\leftarrow A+(M-1)\cdot	ext{TAME}$$
        """
        import torch
        if self.dtype.get(node) != torch.bool:
            return mv
        # **先に桁を既定へ揃える。** 深い桁のまま $2^{20}$ を掛けると分子が 69 bit になる
        h, rows, cols, d = self.exact(mv)
        big = 1 << 18                     # softmax の指数が 0 になれば十分
        low = self.B.tensor(rows)
        E = (self.W, 1, 0)
        self.B.row(low, E, 1, h, E, self.B.imm(1), (0, 0, 0),
                   add=self.B.imm(-(1 << d)), add_s=(0, 0, 0))
        got = self.B._scale(low, big)
        self.B.free(low)
        self.mag[got] = d + 1 + int(big).bit_length()
        return got, rows, cols, d

    def _mask_head(self, node, b0, h0, T, S):
        """マスクの 1 つの head を (T, S) として取り出す。

        軸は 2・3・4 のどれでも来る。`arange` を 4 軸へ揃えてから取るので、書き方を
        自分で解釈しなくてよい。大きさ 1 の軸は広げる。
        """
        import torch
        v = self.val[node]
        sh = tuple(self.shape[node])
        lin = torch.arange(int(np.prod(sh))).reshape(sh)
        while lin.dim() < 4:
            lin = lin.unsqueeze(0)
        got = lin[min(b0, lin.shape[0] - 1), min(h0, lin.shape[1] - 1)]
        if tuple(got.shape) != (T, S):
            got = got.expand(T, S)
        c0 = int(sh[-1])
        flat = np.asarray(got.contiguous().reshape(T, S))
        off = (flat // c0) * self.width + (flat % c0)
        return self._recast(v, T, S, off)

    def _put_head(self, out, piece, bh, T, D, rows, cols):
        """head の結果を出力の行 [bh·T, (bh+1)·T) へ入れる。0/1 の面で混ぜる。"""
        import torch
        E = (self.W, 1, 0)
        lin = torch.zeros((rows, cols), dtype=torch.int64)
        m = torch.zeros((rows, cols), dtype=torch.int64)
        idx = torch.arange(T * D).reshape(T, D)
        lin[bh * T:(bh + 1) * T, :D] = idx
        m[bh * T:(bh + 1) * T, :D] = 1
        flat = np.asarray(lin)
        off = (flat // D) * self.width + (flat % D)
        t = self._recast(piece, rows, cols, off)
        if out is None:
            mh = self._plane(rows, cols, np.asarray(m, dtype=np.int64))
            got = self.B.tensor(rows)
            self.B.row(got, E, 1, mh, E, t[0], E)
            return (got, rows, cols, t[3])
        d = self.B.tensor(rows)
        self.B.row(d, E, 1, self.B.imm(1), (0, 0, 0), t[0], E,
                   add=self.B._scale(out[0], -1), add_s=E)
        mh = self._plane(rows, cols, np.asarray(m, dtype=np.int64))
        got = self.B.tensor(rows)
        self.B.row(got, E, 1, mh, E, d, E, add=out[0], add_s=E)
        self.B.free(d)
        return (got, rows, cols, out[3])

    def concat(self, n):
        """`cat`。切れ目ごとに引きで写して、compile 時の 0/1 の面で混ぜる。

        引きの項は先頭が一つしか持てないので、piece ごとに 1 段で写す。どこへ来るかは
        `cat` を `arange` に当てて調べる。混ぜるのは

        $$	ext{out}=t_0+\sum_{i\ge1}m_i\,(t_i-t_0)$$

        で、$m_i$ は piece $i$ の場所が 1 の面。piece 1 つにつき 3 段（先頭だけ 1 段）。
        """
        import torch
        parts = list(n.args[0])
        dim = n.args[1] if len(n.args) > 1 else n.kwargs.get("dim", 0)
        want = self.shape.get(n)
        rows = self._rows(want)
        cols = int(want[-1]) if len(want) else 1
        E = (self.W, 1, 0)
        shs = [self.shape.get(p) for p in parts]
        if any(sh is None for sh in shs) or want is None:
            raise NotImplementedError("cat の形が分からない")
        # 中身が無い piece は飛ばす。KV の連結は初回、過去の長さが 0 になる
        keep = [k for k, sh in enumerate(shs) if int(np.prod(sh)) > 0]
        parts = [parts[k] for k in keep]
        shs = [shs[k] for k in keep]
        if not parts:
            raise NotImplementedError("cat の piece が全部空")
        got = None
        for i, p in enumerate(parts):
            # piece i の中の番号を out の場所へ並べる
            pick = [torch.zeros(sh, dtype=torch.int64) for sh in shs]
            pick[i] = torch.arange(int(np.prod(shs[i])) or 1).reshape(shs[i])
            idx = torch.cat(pick, dim=dim).reshape(rows, cols)
            mask = [torch.zeros(sh, dtype=torch.int64) for sh in shs]
            mask[i] = torch.ones(shs[i], dtype=torch.int64)
            m = torch.cat(mask, dim=dim).reshape(rows, cols)
            c0 = int(shs[i][-1]) if len(shs[i]) else 1
            flat = np.asarray(idx)
            off = (flat // c0) * self.width + (flat % c0)
            t = self._recast(self.val[p], rows, cols, off)
            if got is None:
                got = t
                continue
            # d = t − got
            d = self.B.tensor(rows)
            self.B.row(d, E, 1, self.B.imm(1), (0, 0, 0), t[0], E,
                       add=self.B._scale(got[0], -1), add_s=E)
            # out = got + m·d
            mh = self._plane(rows, cols, np.asarray(m, dtype=np.int64))
            out = self.B.tensor(rows)
            self.B.row(out, E, 1, mh, E, d, E, add=got[0], add_s=E)
            self.B.free(d)
            got = (out, rows, cols, got[3])
        return self.mark(got[0], rows, cols, got[3],
                         self._cap(n, got[3], self._mag(got[0], got[3])))

    def _bcast(self, src, v, want):
        """`src` の置き場を `want`（torch の形）へ広げる。`arange` を同じ形へ広げて添字にする。"""
        import torch
        sh = self.shape.get(src) if hasattr(src, "op") else None
        if sh is None or want is None or tuple(sh) == tuple(want):
            return v
        lin = torch.arange(int(np.prod(sh)) or 1).reshape(sh)
        try:
            lin = lin.expand(tuple(want))
        except RuntimeError:
            raise NotImplementedError("broadcast できない形 %s → %s"
                                      % (tuple(sh), tuple(want)))
        rows = self._rows(want)
        cols = int(want[-1]) if len(want) else 1
        flat = np.asarray(lin.reshape(rows, cols))
        c0 = int(sh[-1]) if len(sh) else 1
        off = (flat // c0) * self.width + (flat % c0)
        return self._recast(v, rows, cols, off)

    def gather(self, n, how=None):
        """切り出しと広げを、引きの項で 1 段。

        添字の表は `arange` に**同じ切り出しを当てて**作る。だから `getitem` の書き方
        （`slice` `Ellipsis` `None` の組み合わせ）を自分で解釈しなくてよい。

        $$	ext{lin}=\operatorname{arange}(|	ext{src}|)\ 	ext{を src の形へ},\qquad
          	ext{off}=\Bigl\lfloorrac{	ext{lin}[	ext{同じ切り出し}]}{c_0}\Bigr
floor
          \cdot	ext{width}+igl(	ext{lin}[\cdot]mod c_0igr)$$
        """
        import torch
        src = n.args[0]
        v = self.val[src]
        sh = self.shape.get(src)
        want = self.shape.get(n)
        if sh is None or want is None:
            raise NotImplementedError("形が分からない切り出し")
        if tuple(sh) == tuple(want) and how is not None:
            # 形も並びも変わらないなら段は足さない
            probe = how(torch.arange(int(np.prod(sh)) or 1).reshape(sh))
            if bool((np.asarray(probe.contiguous().reshape(-1))
                     == np.arange(int(np.prod(sh)) or 1)).all()):
                return v
        lin = torch.arange(int(np.prod(sh)) or 1).reshape(sh)
        got = how(lin) if how is not None else lin[n.args[1]]
        rows = self._rows(want)
        cols = int(want[-1]) if len(want) else 1
        if got.numel() != rows * cols:
            raise NotImplementedError("切り出しの要素数が合わない")
        flat = np.asarray(got.contiguous().reshape(rows, cols))
        c0 = int(sh[-1]) if len(sh) else 1
        off = (flat // c0) * self.width + (flat % c0)
        return self._recast(v, rows, cols, off)

    def point(self, n, name):
        """要素ごとの演算。"""
        E = (self.W, 1, 0)
        a = self.val[n.args[0]]
        if name == "neg":
            return (self.B._scale(a[0], -1), a[1], a[2], a[3])
        if name == "relu":
            f = self.B.tensor()
            self.B.row(self.B.tensor(), E, 1, a[0], E, self.B.imm(1), (0, 0, 0),
                       flag=f, thresh=0)
            out = self.B.tensor()
            self.B.row(out, E, 1, a[0], E, f, E)
            return (out, a[1], a[2], a[3])
        b = self.val[n.args[1]] if hasattr(n.args[1], "op") else None
        if b is not None:
            # 形の違う相手は先に広げる。**(行, 列) に潰した形でなく torch の形で見る。**
            # 潰すと (1,4,1) と (1,4,64) の関係が (4,1) と (4,64) になり、4 軸の tensor で
            # 取り違える
            want = self.shape.get(n)
            a = self._bcast(n.args[0], a, want)
            b = self._bcast(n.args[1], b, want)
        if name == "div":
            if b is None:                               # 定数で割るのは逆数を掛ける
                c = round((1 << self.depth) / float(n.args[1]))
                w = max(1, int(abs(c)).bit_length())
                a = self.fit(a, self.BUDGET - w)
                return self.mark(self.B._scale(a[0], c), a[1], a[2], a[3] + self.depth,
                                 self._mag(a[0], a[3]) + w)
            h, rows, cols, d = self.norm(*a)
            inv = self.B.recip(self.norm(*b)[0], self.depth, self.depth + 6)
            return self.norm(self.B._mul(h, inv), rows, cols, d + self.depth,
                             mag=self._mag(h, d) + self.depth + self.HEAD)
        if name == "rsub":                              # rsub(a, b) = b − a
            a = (self.B._scale(a[0], -1), a[1], a[2], a[3])
            name = "add"
        if b is None:                                   # 定数との演算
            c = float(n.args[1])
            if name == "mul":
                k = round(c * (1 << self.depth))
                w = max(1, int(abs(k)).bit_length())
                a = self.fit(a, self.BUDGET - w)
                return self.mark(self.B._scale(a[0], k), a[1], a[2], a[3] + self.depth,
                                 self._mag(a[0], a[3]) + w)
            k = self.B.imm(round(c * (1 << a[3])) * (1 if name == "add" else -1))
            out = self.B.tensor()
            self.B.row(out, E, 1, a[0], E, self.B.imm(1), (0, 0, 0), add=k, add_s=(0, 0, 0))
            return (out, a[1], a[2], a[3])
        if name == "mul":
            # 予算は等分にしない。**大きい側から削る。** 半分ずつと決めると、片側の桁が
            # 28 から 3 へ落ちて刻みが 0.1 台になる
            ma, mb = self._mag(a[0], a[3]), self._mag(b[0], b[3])
            over = ma + mb - self.BUDGET
            if over > 0:
                hi, lo = max(ma, mb), min(ma, mb)
                cut = min(over, hi - lo)
                rest = over - cut
                thi, tlo = hi - cut - (rest + 1) // 2, lo - rest // 2
                if ma >= mb:
                    a, b = self.fit(a, thi), self.fit(b, tlo)
                else:
                    a, b = self.fit(a, tlo), self.fit(b, thi)
            out = self._alloc(max(a[1], b[1]), max(a[2], b[2]))
            self.B.row(out, E, 1, a[0], E, b[0], E)
            return self._settle(n, out, max(a[1], b[1]), max(a[2], b[2]),
                                a[3] + b[3],
                                self._mag(a[0], a[3]) + self._mag(b[0], b[3]))
        if name == "sub":
            b = (self.B._scale(b[0], -1), b[1], b[2], b[3])
        d, ah, bh = self._align(a, b)
        return (self.B._add(ah, bh), max(a[1], b[1]), max(a[2], b[2]), d)

    def _align(self, a, b):
        """足す前に桁を揃える。**深い側を下げる。**

        浅い側を $2^k$ で持ち上げると分子が $k$ bit 伸びる。残差の足し算で深さが 45 と 14
        なら 31 bit 伸びて、次の二乗が予算を越える。桁を下げるのは 1 行で済むので、
        深い側を下げる方が安い。
        """
        if a[3] == b[3]:
            return a[3], a[0], b[0]
        lo, hi = (a, b) if a[3] < b[3] else (b, a)
        cut = hi[3] - lo[3]
        down = self.B.rshift(hi[0], hi[1], cut,
                             min(self.BUDGET, self._mag(hi[0], hi[3])))
        self.mag[down] = max(1, self._mag(hi[0], hi[3]) - cut)
        return lo[3], (a[0] if lo is a else down), (down if lo is a else b[0])

    def _t(self, node, args=None):
        """ノードが指す実際の tensor。placeholder と get_attr と別名を辿る。

        `args` を渡すと、その呼びの実引数から取る。compile 時は `self.given` を使う。
        """
        if node.op == "placeholder":
            got = self.given if args is None else args
            return got[self.order.index(node)]
        if node.op == "get_attr":
            return getattr(self.gm, node.target)
        name = chamber._name_of(node)
        if name == "t":
            return self._t(node.args[0], args).t()
        if name in ("view", "reshape"):
            return self._t(node.args[0], args).reshape(self.shape[node])
        if name in self.ALIAS:
            return self._t(node.args[0], args)
        raise chamber.Unknown("係数が %s から来ている" % name)

    TAME = 1 << 20          # 表せる範囲。マスクの $-\infty$ をここへ切る

    def _tame(self, v):
        """固定小数に載らない値を切る。

        マスクは $-\infty$（$-3.4	imes10^{38}$）を持つ。$2^{F}$ を掛けると 64 bit を
        越えるので、softmax で 0 になる十分小さい値へ切る。
        """
        import torch
        v = v.to(torch.float32) if v.dtype != torch.float32 else v
        return torch.clamp(torch.nan_to_num(v, nan=0.0, posinf=self.TAME,
                                            neginf=-self.TAME),
                           -float(self.TAME), float(self.TAME))

    def _host_getter(self, node):
        """呼びごとに host でその node を出し直す関数。"""
        def get(args):
            return self._tame(self._host_eval(node, list(args)))
        get.node, get.then = node, None
        return get

    def _getter(self, node, then=None):
        """呼ばれるたびに元の tensor を取り直す関数を返す。

        weight も実引数も Dynamo は placeholder で渡すので、同じ形で取れる。
        元の node と変形を関数に付けておく。`refresh` が「変わったか」を元の tensor で
        見るために要る（変形した後の tensor は毎回別物になる）。
        """
        if then is None:
            def get(args):
                return self._t(node, args)
        else:
            def get(args):
                return then(self._t(node, args))
        get.node, get.then = node, then
        return get

    def outputs(self):
        node = [n for n in self.gm.graph.nodes if n.op == "output"][0]
        got = node.args[0]
        got = list(got) if isinstance(got, (tuple, list)) else [got]
        return [self.val[g] for g in got]
