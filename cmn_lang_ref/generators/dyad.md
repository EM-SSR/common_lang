# 二進有理数の層

[← 総表](Index.md)

$$
\mathsf{Dyad}=\mathbb Z\!\left[\tfrac12\right],
\qquad
\text{値}=\frac{x}{2^{\delta}}
$$

語には分子 $x$ だけが載る。深度 $\delta$ は build 時の型なので、走らせる側には現れない。

---

## 入口

### `hu` — $\mathsf{one}$ &nbsp;&nbsp; $I\to\mathsf{Dyad}$

$$
\llbracket\mathsf{one}\rrbracket=\langle1,0\rangle
\tag{16.3.1}
$$

幾何の読みは「原点 $O$ に立つ」になる。数の literal はこの一語だけであり、
残りは全部合成で作る。

$$
2=1\oplus1,\qquad
0=1\oplus(\ominus1),\qquad
\tfrac12=\beta(0),\qquad
\tfrac34=\beta(\beta(0)),\qquad
\tfrac14=\beta(\ominus\beta(0))
\tag{16.5.5}
$$

---

## 算術

| 音節 | 記号 | 型 | 深度 |
|---|---|---|---|
| `no` | $\oplus$ | $D\otimes D\to D$ | $\max(\delta_u,\delta_v)$ へそろう |
| `ha` | $\ominus$ | $D\to D$ | 変わらない |
| `ti` | $\star$ | $D\otimes D\to D$ | $\delta_u+\delta_v$ |
| `ba` | $\oslash$ | $D\otimes D\to\mathsf{Rational}$ | 分子と分母の二語 |

加算は平行四辺形則であり、経路を忘れる。乗算はタレス比であり、経路を保持する。
この非対称が体系の土台になる（幾何 3 章）。

```
hu hu ka
no ka
```

値 $2$。`examples/cmn/futatsu.cmn`

除算は二進比へ閉じないので、出口の型が $\mathsf{Rational}$ になる。
零で割ると実行時に失敗を報告する。

```
hu hu ka ki se ka ba
```

分子 $2$、分母 $2$。`examples/vocabulary/ba_div.cmn`

---

## 二分割

### `se` — $\beta$ &nbsp;&nbsp; $D\to D$

$$
\beta(x)=\frac{x+1}{2},
\qquad
\beta(1)=1
\tag{16.5.4}
$$

基準点が $1$ であり、$1$ は不動点になる。だから半分は零から立てる。
降下は四箱へ開く。

$$
\operatorname{Desc}(\beta)(u)=\bigl[\mathrm{Cst}(1,0),\ \mathrm{Add}(u,\cdot),\ \mathrm{Cst}(1,1),\ \mathrm{Mul}(\cdot,\cdot)\bigr]
\tag{16.5.6}
$$

```
hu hu ka, ki ha ka, no ka, se ka, se ka.
```

値 $3/2^2$。`examples/cmn/yonbunnosan.cmn`

### `gu` — $\beta^{-1}$ &nbsp;&nbsp; $D\to D$

$$
\beta^{-1}(x)=2x-1
$$

像は深度 $1$ 以上に限る（構成語 §4 の $\operatorname{im}\beta_a$）。深度 $0$ の入力は失敗になる。

### `za` — $\beta_a$ &nbsp;&nbsp; $D\otimes D\to D$

$$
\beta_a(x)=\frac{x+a}{2}
\tag{22.9}
$$

基準点をワイヤで受ける形になる。16 式 (5.6) の $\mathrm{Cst}(1,0)$ が第二ワイヤに変わる。

```
hu hu ka
za ka
```

値 $2/2^1$。`examples/vocabulary/za_bisect.cmn`

---

## 不動点

### `ge` — $\mathsf{fix}$ &nbsp;&nbsp; $D\to D$

$$
x=\frac{x+1}{2}
\ \Longrightarrow\
x=1,
\qquad
\operatorname{Desc}(\mathsf{fix})(x_0)=\bigl[\mathrm{Cst}(1,0)\bigr]
\tag{16.5.8}
$$

集積点は初期値に依らないので、入力ワイヤは落ちる。

### `zi` — $\Omega_a[\beta_a;x_0]$ &nbsp;&nbsp; $D\otimes D\to D$

$$
\Omega_a[\beta_a;x_0]=a
\tag{22.10}
$$

箱を作らず、第二ワイヤをそのまま返す。反復を回す箱は生成元レジストリに無い。

```
hu ka ge
```

値 $1$。`examples/vocabulary/ge_fix.cmn`

---

## 観測と二値

| 音節 | 記号 | 型 | 値 |
|---|---|---|---|
| `so` | $\varphi_\partial$ | $D\to B$ | $[\,0<x\,]$ |
| `hi` | $\le$ | $D\otimes D\to B$ | $[\,u\le v\,]$ |
| `mo` | $\pi$ | $B\to D$ | 型を忘れる |

どちらも 16 §5.3 の八箱へ降りる。$\mathcal M$ は値の join を memory しか持たないので、
既定値を退避語へ置き、path separation の片側で書き換えてから読み戻す。

$$
\operatorname{Desc}(\text{判定})=
\left[
\begin{aligned}
&n{+}0:\ \mathrm{Cst}(0,0)\\
&n{+}1:\ \mathrm{Cst}(s,0)\\
&n{+}2:\ \mathrm{Cst}(\mathrm d,0)\\
&n{+}3:\ \mathrm{Store}(n{+}1,\ n{+}2)\\
&n{+}4:\ \mathrm{LtBr}(A,\ B,\ n{+}7)\\
&n{+}5:\ \mathrm{Cst}(1-\mathrm d,0)\\
&n{+}6:\ \mathrm{Store}(n{+}1,\ n{+}5)\\
&n{+}7:\ \mathrm{Load}(n{+}1)
\end{aligned}
\right]
\tag{16.5.9}
$$

$\pi$ が型を忘れると、選択が生成元の合成で書ける。

$$
\operatorname{sel}(c,a,b)=c\star a\ \oplus\ (1\ominus c)\star b,
\qquad
c\in\{0,1\}
\tag{16.5.11}
$$

分岐命令は要らない。

```
hu ka so ka mo ka
```

値 $1$。`examples/vocabulary/mo_pi.cmn`

---

## 複製と廃棄

| 音節 | 記号 | 型 | 降下 |
|---|---|---|---|
| `he` | $\Delta$ | $D\to D\otimes D$ | 空列。同じワイヤを二度使う |
| `ho` | $!$ | $D\to I$ | 空列。ワイヤを落とす |

$!$ は境界を $I$ へ閉じる道になる。注記はこれで閉じる（[language/01_source](../language/01_source.md) §3）。

## 参照

- [judge](judge.md) 判定値 $\mathcal Q$
- [machine](machine.md) 作業領域と報告
