# 作業領域と外部環境

[← 総表](Index.md)

意味レジストリ $\mathcal M$ の原子はそのまま降りる（16 §5.0）。正準添字を取らないので、
平文の側から届く。

$$
\operatorname{ord}(g)\in[0,11]\ \Longrightarrow\ \mathcal M\ \text{と一致},
\qquad
\text{だから降下は名前を変えない}
$$

---

## 作業領域

| 音節 | 記号 | 型 | 意味 |
|---|---|---|---|
| `mi` | $\mathrm{Load}$ | $D\to D$ | 語番号から読む |
| `mu` | $\mathrm{Store}$ | $D\otimes D\to I$ | 語番号へ書く |

番地も値もワイヤで来るので、正準添字が要らない。語の byte 幅は architecture package が
持つので source に現れない（§32.2）。

$\mathrm{Load}$ は深度を落とす唯一の箱になる。語には分子だけが載るためである。

### 退避語

二値の八箱は既定値を語へ退避する（16 §5.3）。退避語は本文の語の上へ置く。

$$
S=1+\max\Bigl(31,\ |\Gamma^+|-1,\ \bigl\{\text{定数から畳める Load / Store の番地}\bigr\}\Bigr)
$$

一段目の降下は $S$ を決めるためだけに走る。退避語は本文の番地へ流れないので、
二段目の番地は一段目と同じになる。

---

## 外部環境への報告

| 音節 | 記号 | 型 | 実行 |
|---|---|---|---|
| `me` | $\mathrm{Ok}$ | $I\to I$ | 成功報告。実行を閉じる |
| `di` | $\mathrm{Ko}$ | $I\to I$ | 失敗報告。実行を閉じる |
| `du` | $\mathrm{Put}$ | $D\to I$ | 一 byte 出力。実行を閉じない |

$\mathrm{Put}$ は $[0,255]$ の整数として読み、範囲外は下位 8 bit を採る。

```
hu ka du ka me
```

`examples/vocabulary/du_put.cmn`。境界が $I$ なので出力語を持たない。

$\varphi_\partial$ は原子に入らない。唯一の非可逆観測は path separation と外部報告の対で現れる。
$\mathrm{EqBr}$ / $\mathrm{LtBr}$ が連続量を二つの経路へ分け、$\mathrm{Ok}$ / $\mathrm{Ko}$ が
その結果を境界の外へ出す。この二段が $\varphi_\partial$ の実現形になる。

---

## 閉包

| 音節 | 記号 | 型 |
|---|---|---|
| `ya` | $\Omega$ の開き | $I\to I$ |
| `yi` | $\Omega$ の閉じ | $B\to I$ |

開きの層で本体の先頭箱番号と frontier を控え、閉じの層で単調フラグを一本受けて
後退分岐を置く。フラグが $0$ の間は本体へ戻る。

$$
F:X\otimes A\to A,
\qquad
\Omega_a[F]:X\to A
\tag{構成語 5.4}
$$

$$
h_n\le h_{n+1},
\qquad
\bigvee_n h_n=1\ \text{で境界へ集積}
\tag{構成語 5.5}
$$

有限高さの単調反復は有限段で不動点になる（04 定理 9.1）。

状態は作業領域が持つ。frontier は開きと閉じで同じでなければならないので、
繰り返しの間に持ち越す値はワイヤに載らない。

```
hu ka ya ka hu ka so ka yi
```

値 $1$。`examples/vocabulary/yi_omega.cmn`

---

## 平文へ届かない四つ

$\mathrm{Cst}$、$\mathrm{EqBr}$、$\mathrm{LtBr}$、$\mathrm{Br}$ は正準添字を取る。
平文に数字も label も現れないので（16 §3.1）、この四つは番号の席を占めるだけになる。

代わりに置く道は次のとおり。

| 要るもの | 平文での書き方 |
|---|---|
| 定数 | $\mathsf{one}$（`hu`）と算術の合成 |
| 条件分岐 | $\operatorname{sel}(c,a,b)=c\star a\oplus(1\ominus c)\star b$ |
| 後退分岐 | `ya` と `yi` の対 |

$$
\text{分岐命令は要らない。平文の側に literal も label も現れない}
\tag{16.5.11}
$$

## 参照

- [dyad](dyad.md) 二値を作る八箱
- [toolchain/01_build](../toolchain/01_build.md) 走らせ方
