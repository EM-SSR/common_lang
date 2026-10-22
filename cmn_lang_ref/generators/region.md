# 領域と鎖の層

[← 総表](Index.md)

Level 0 の原始概念は六つになる（幾何 Index）。

> 領域・内側／外側・重なり・含まれる・隣接・道

操作は四つで尽きる。

| 操作 | 何をするか |
|---|---|
| 共通部 | 二つの領域が重なっている部分を取り出す |
| 合わせ | 二つの領域を一つにまとめた最小の領域を作る |
| 外側 | ある閉じた領域の外にある領域を取る |
| 境界 $\partial$ | 内側と外側を分ける面を取り出す |

関係はこの四つの上の述語になる。

$$
\begin{aligned}
\text{重なり}(A,B)&\iff A\cap B\neq\varnothing\\
\text{含まれる}(A,B)&\iff B\setminus A=\varnothing\\
\text{隣接}(A,B)&\iff A\cap B=\varnothing\ \wedge\ \bigl((2A\cap B)\cup(A\cap2B)\bigr)\neq\varnothing\\
\text{道}(A)&\iff A\neq\varnothing\ \wedge\ \text{立っている cell が一続き}
\end{aligned}
$$

---

## 単位領域はノードから立つ

### `kukeke` — 領域 &nbsp;&nbsp; $N\to G$

構成語は $D_\infty=\langle i,j\mid i^2=j^2=e\rangle$ の元であり、$(m,\varepsilon)$ の対で尽きる。

$$
\operatorname{cell}(w)=2\cdot\operatorname{zz}(m)+\varepsilon,
\qquad
\operatorname{zz}(m)=
\begin{cases}
2m & m\ge0\\
-2m-1 & m<0
\end{cases}
$$

$\operatorname{zz}$ は単射なので $\operatorname{cell}$ も単射になる。別のノードが同じ単位領域を指すことは無く、
共通部と合わせが目印の重なりを正しく写す。

| ノード | 平文 | $(m,\varepsilon)$ | cell |
|---|---|---|---:|
| $O$ | `ma` | $(0,0)$ | 0 |
| $i$ | `ma ka zu` | $(0,1)$ | 1 |
| $ij$ | `ma ka zu ka ze` | $(-1,0)$ | 2 |
| $ji$ | `ma ka ze ka zu` | $(1,0)$ | 4 |
| $j$ | `ma ka ze` | $(1,1)$ | 5 |

cell は 31 個までになる。commonc が領域を一語の mask で持つためで、
$O$ から 15 歩までの構成語がこの網に収まる。

```
ma ka
kukeke ka
```

出力は cell の数 $1$ と cell 番号 $0$ になる。`examples/region/01_cell.cmn`

---

## 四操作

| 音節 | 操作 | 型 | 例 |
|---|---|---|---|
| `kukeko` | 共通部 | $G\otimes G\to G$ | `examples/region/02_meet.cmn` |
| `kukesa` | 合わせ | $G\otimes G\to G$ | `03_join.cmn` |
| `kukesi` | 外側 | $G\otimes G\to G$ | `04_outside.cmn` |
| `kukesu` | 境界 $\partial$ | $G\to C$ | `11_boundary.cmn` |

外側は第一引数を宇宙、第二引数を抜く側に取る。

$$
\text{外側}(U,A)=U\setminus A
$$

```
ma ma ma ka
ki zu ki ka
kukeke kukeke kukeke ka
kukesa ki ka
kukesi ka
```

$\{O,i\}\setminus\{O\}=\{i\}$。出力は $1$ と $1$ になる。

---

## 関係

| 音節 | 関係 | 型 |
|---|---|---|
| `kukese` | 含まれる | $G\otimes G\to B$ |
| `kukeso` | 重なり | $G\otimes G\to B$ |
| `kuketa` | 隣接 | $G\otimes G\to B$ |
| `kuketi` | 道 | $G\to B$ |

値は compile 時に決まり、$\mathrm{Cst}$ 一箱で開いて実行時のワイヤになる。
だから $\pi$（`mo`）を通せば算術へ流せる。

```
ma ma ka
ki zu ka
kukeke kukeke ka
kuketa ka
```

$O$ の単位領域と $i$ の単位領域は cell 0 と 1 になり、隣り合う。値は $1$。
`examples/region/07_adjacent.cmn`

$j$ へ替えると cell は 0 と 5 になり、値は $0$ になる。`08_apart.cmn`

走査も隣接リストも本文に現れない（[language/03_intent](../language/03_intent.md) §6）。

---

## 鎖

$n$-単体の境界は符号つきの和になる（影響関数 証明3.2）。

$$
\partial\sigma_n=\sum_{k=0}^{n}(-1)^k[v_0,\ldots,\hat v_k,\ldots,v_n]
$$

係数は $\{-1,0,1\}$ に限られる。$\sigma_{n-1}$ が $\sigma_n$ の境界に符号つきで入るか、
入らないかの三択しかないためになる。

領域の境界は cell の両端に立つ。

$$
\partial A\ \text{の係数}(v)=[\,v-1\in A\,]-[\,v\in A\,],
\qquad
\text{正側}=2A\setminus A,
\quad
\text{負側}=A\setminus2A
$$

$2A$ は mask の倍であり、左シフトが乗算そのものなので箱を作らずに済む。

| 音節 | 記号 | 型 |
|---|---|---|
| `bi` | $\partial$ | $C\to C$ |
| `bu` | $\oplus$ | $C\otimes C\to C$ |

### 閉じた曲面に境界は無い

```
ma ka
kukeke ka
kukesu ka
bi ka
```

出力は $0$、つまり項の無い鎖になる。

$$
\partial(\partial G)=\varnothing
$$

$\mathbb R^3$ の閉じた曲面は内側と外側を分ける面であり、その面には境界が無い。
冪零性は代数の要請ではなく、この幾何的事実の係数表現になる。
`examples/region/12_nilpotent.cmn`

### 鎖の加算

$|$係数$|$ が $2$ になる和は鎖でなくなるので、両方の compiler が失敗を報告する。

```
ma ma ka
ki ze ka
kukeke kukeke ka
kukesu kukesu ka
bu ka
```

$\partial\{O\}\oplus\partial\{j\}$ は頂点 $0,1,5,6$ に $\mp1$ を立てる。出力の先頭は $4$ になる。
`examples/region/13_chainsum.cmn`

同じ領域を二度足すと係数が $2$ になり、image が出ない。`16_chain_two.cmn`

---

## 出口の語

| 型 | 開く語 |
|---|---|
| $\mathsf{Region}$ | cell の数、cell 番号（昇順） |
| $\mathsf{Chain}$ | 頂点の数、各頂点の（係数、頂点数 $1$、頂点番号） |

```
ma ka / kukeke ka / kukesu ka       →  2  −1 1 0  1 1 1
```

$\partial\{O\}$ は頂点 $0$ に $-1$、頂点 $1$ に $+1$ を立てる。

## 参照

- [noun](noun.md) 名詞ノード。cell 番号の出どころ
- [language/03_intent](../language/03_intent.md) 走査を書かずに済む問い
