# 境界と型

[← Index](../Index.md)

## 1. 境界は決まる

チェンバーは境界と層列で書く（構成語 §2.3）。

$$
\operatorname{ser}(C)=\bigl\langle(\mu,d)\mid\Gamma^-\Rightarrow\Lambda_0;\cdots;\Lambda_h\Rightarrow\Gamma^+\bigr\rangle
\tag{1.1}
$$

平文では五つの欄を書かない。

| 欄 | 平文での扱い |
|---|---|
| $\mu$ | 全体で $\infty$ |
| $d$ | 本体から出る。$d(f;g)=d(f)+d(g)$ |
| $\Gamma^-$ | $I$。文章は何も受け取らずに始まる |
| $\Gamma^+$ | 層を順に当てれば決まる（定理 2.2） |
| $\operatorname{addr}$ | $\Omega$ の箱が自分の集積点を持つ |

$\Gamma^-=I$ なので、層 0 に置けるのは $\operatorname{pin}=0$ の箱だけになる。

$$
\{\,g\mid\operatorname{pin}(g)=0\,\}
=\{\ \texttt{hu},\ \texttt{ma},\ \texttt{re},\ \texttt{wu},\ \texttt{we},\ \texttt{wo},\ \texttt{me},\ \texttt{di},\ \texttt{ya}\ \}
$$

この九つが文章の入口になる。それぞれ二進有理数・名詞・履歴・折返し・報告・閉包の開きを立てる。

## 2. 型レジストリ

| 番号 | 型 | 内容 | 複製 |
|---:|---|---|---|
| 0 | $\mathsf{Point}$ | 座標点 $(r,\omega)$ | 可 |
| 1 | $\mathsf{Trace}$ | 構成履歴 $\sigma^\varepsilon a$ | 不可 |
| 2 | $\mathsf{Reflection}$ | $D_4$ の八元 | 可 |
| 3 | $\mathsf{Dyad}$ | 二進有理数 $x/2^\delta$ | 可 |
| 4 | $\mathsf{Bit}$ | 二値 | 可 |
| 5 | $\mathcal Q$ | 影響値 | 不可 |
| 6 | $\mathsf{Mono}$ | 単項式番号 $T\subseteq[n]$ | 可 |
| 7 | $\mathsf{Noun}$ | 名詞ノード $(y,\hat x)$ | $\mu=\infty$ で不可 |
| $-2$ | $\mathsf{Rational}$ | 有理数 $a/b$、$b>0$ | 可 |
| $-3$ | $\mathsf{Chain}$ | cell 上の符号つき係数 | 可 |
| $-4$ | $\mathsf{Region}$ | cell の集合 | 可 |
| $8+k$ | $\#k$ | 正準参照したチェンバー | 参照先が決める |

$\mathsf{Trace}$ と $\mathcal Q$ が複製できないのは、構成履歴を複製すると $ij$ と $ji$ の差が壊れるためになる（構成語 §3.5）。

$\mathsf{Noun}$ の複製 `tu` は平文に置けない。平文は $\mu=\infty$ だからである（13 §1.2、07 §8.4）。
書くと両方の compiler が image を出さずに止まる。

## 3. 層を当てる

層 $r$ の frontier を $F_r$ とする。層の箱を左から順に当てる手続きは三行で終わる。

$$
\begin{aligned}
\texttt{ki} &:\quad \text{位置を一つ進める}\\
g &:\quad F_r[\,q\,..\,q+|\Gamma^-_g|\,)=\Gamma^-_g\ \text{を検め、}\ \Gamma^+_g\ \text{を出力へ積む}\\
F_{r+1} &=\ (\text{積んだ出力})\ \|\ (\text{残った位置})
\end{aligned}
\tag{3.1}
$$

型が合わなければそこで止まる。診断は構成語 §15.4 の名前で出る。

```
層 2: kukeke の入力型が合わない（型と座標の混同）
層 1: ku の入力が frontier を越える（境界不一致）
```

## 4. 出口境界の読み

$\Gamma^+$ に残った席は、成分の順で作業領域の語 $0,1,2,\ldots$ へ開く。

| 型 | 開く語 |
|---|---|
| $\mathsf{Dyad}$、$\mathsf{Bit}$ | 分子 一語 |
| $\mathsf{Point}$ | 実成分、無限成分 |
| $\mathsf{Rational}$ | 分子、分母 |
| $\mathcal Q$ | 大きさ $a$、$b$、語 $m$、$\varepsilon$、符号 |
| $\mathsf{Noun}$ | 位置四語、目印の数、プロファイル |
| $\mathsf{Region}$ | cell の数、cell 番号（昇順） |
| $\mathsf{Chain}$ | 頂点の数、各頂点の（係数、頂点数 $1$、頂点番号） |

深度は compile 時の事実なので、語には分子だけが載る。読む側が深度表から引く。

$$
\text{値}=\frac{\text{語}}{2^{\delta}},
\qquad
\delta\ \text{は build 時の型}
$$

## 参照

- [01_source](01_source.md) 音節・層・frontier
- [generators/Index](../generators/Index.md) 生成元ごとの $\Gamma^-\to\Gamma^+$
