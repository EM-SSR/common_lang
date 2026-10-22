# 意図の判定条件

[← Index](../Index.md)

## 1. 何をもって意図と呼ぶか

チェンバー $C$ について、値を得るのに要り、かつ本文に現れない量の集まりを $H(C)$ と置く。

$$
H(C)=\bigl\{\ \text{$\llbracket C\rrbracket$ を得るのに要り、かつ $C$ の本文に現れない量}\ \bigr\}
$$

$$
\boxed{\ C\ \text{は意図}\iff H(C)=\varnothing\ }
\tag{1.1}
$$

命令列は $H$ が空でない。`ke 1 0; ke 1 0; ko` は $2$ を返すが、なぜ足すか、
いくつで止めるか、どれが答えかは本文の外に残る。

04 §17 は答えの型を明示したチェンバーを「計算すべき問い」と呼ぶ。

$$
P:X\to\{0,1\},
\qquad
P:X\to[0,1],
\qquad
P:X\otimes Y\to\mathcal Q,
\qquad
P:X\to C
$$

出口型を持つ式だけを問いとして扱うと、「何を答えれば計算完了なのか」が構文の外に残らない。

## 2. 手続きを書く場所が構文に無い生成元

| 音節 | 生成元 | 書かずに済むもの |
|---|---|---|
| `yu` | $\bigvee$ | 探索順、打ち切り |
| `zi` | $\Omega_a[\beta_a;x_0]$ | 反復回数、収束判定 |
| `ye` `yo` | $\searrow$、$\swarrow$ | 逆算の手続き |
| `na` `ni` `to` | $q\Leftrightarrow p$ | 分類器、特徴選択 |
| `ne` | $\varphi_\partial\circ\pi$ | 閾値 |
| `kukese` … `kuketi` | 領域の関係 | 走査、隣接リスト、経路探索 |

どれも随伴・上限・不動点・幾何の関係になる。定義から一意に決まるので、
手続きを書く席が構文の側に無い。

## 3. 例：候補のうちいちばん良いもの

`examples/intent/01_sup.cmn`

$$
P:X\otimes Y\to\mathcal Q,
\qquad
\bigvee_{y\in Y}P(x,y)
$$

候補 $Y=\{\tfrac12,\tfrac14,\tfrac34\}$、原型 $1$。評価は整合対 `na`（$q\Leftrightarrow1$）になる。

$$
\bigvee\Bigl\{\tfrac12,\ \tfrac14,\ \tfrac34\Bigr\}=\tfrac34
$$

$\bigvee$ は完備束の上限なので結合的かつ可換になる（定理 3.3）。畳む順序は値を変えないから、
探索順が本文に現れない。

## 4. 例：半分ずつ寄っていく先

`examples/intent/02_omega.cmn`

$$
x=\frac{x+a}{2}
\ \Longrightarrow\
x=a,
\qquad
\Omega_a[\beta_a;x_0]=a
\tag{構成語 5.2}
$$

書くのは方程式と集積点だけになる。反復を回す箱は生成元レジストリに無い。

## 5. 例：届かせるのに何が要るか

`examples/intent/03_residual.cmn`

$$
a\star b\le c
\iff
b\le a\searrow c
\iff
a\le c\swarrow b
\tag{定理 3.3}
$$

$$
q\searrow c=\max\bigl\{\,r\ \bigm|\ q\star r\le c\,\bigr\}
$$

残差は随伴なので、$\max$ の中身を探す手続きが要らない。

## 6. 例：幾何の問い

領域の層は、走査を書かずに済む問いをまとめて与える（[generators/region](../generators/region.md)）。

### 6.1 二つの場所は隣り合うか

`examples/region/07_adjacent.cmn`

```
ma ma ka
ki zu ka
kukeke kukeke ka
kuketa ka
```

$$
A\ \text{と}\ B\ \text{は隣接}
\iff
A\cap B=\varnothing
\ \wedge\
\bigl((2A\cap B)\cup(A\cap 2B)\bigr)\neq\varnothing
$$

本文にあるのは「原点のノード」「$i$ で一歩進んだノード」「それぞれの単位領域」「隣接か」の四つになる。
隣接リストも探索も現れない。

### 6.2 この場所の集まりは一続きの道か

`examples/region/09_path.cmn`（値 $1$）と `examples/region/10_gap.cmn`（値 $0$）

道は Level 0 の原始概念であり、一次元の連結した領域になる（幾何 Index）。
本文は領域を合わせて「道か」と問うだけで閉じる。幅優先探索も訪問済みの印も出てこない。

### 6.3 閉じた曲面に境界は無い

`examples/region/12_nilpotent.cmn`（値 $0$）

$$
\partial(\partial G)=\varnothing
\tag{影響関数 証明3.2}
$$

$\mathbb R^3$ の閉じた曲面は内側と外側を分ける面であり、その面には境界が無い。
冪零性は代数の要請ではなく、この幾何的事実の係数表現になる。

## 7. 判定表

| 例 | $H(C)$ に落ちそうな量 | 本文での扱い |
|---|---|---|
| 01_sup | 探索順、打ち切り | $\bigvee$ が可換かつ結合的 |
| 02_omega | 反復回数、収束判定 | 集積点が方程式で決まる |
| 03_residual | 逆算の手続き | 随伴が一意に決める |
| 04_member | 閾値 | $\varphi_\partial$ が境界を持つ |
| 07_adjacent | 隣接リスト、走査 | 幾何の関係が定義そのもの |
| 09_path | 経路探索、訪問済みの印 | 道が Level 0 の原始概念 |
| 12_nilpotent | 符号の相殺の手順 | $\partial^2=0$ が幾何的事実 |

七本とも $H(C)=\varnothing$ になる。

## 参照

- [generators/judge](../generators/judge.md) 上限・残差・整合対
- [generators/region](../generators/region.md) 領域と鎖
- `continuous_republic/examples/intent/Index.md` 五本の詳細
