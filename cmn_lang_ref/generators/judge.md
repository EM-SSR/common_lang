# 判定値の層

[← 総表](Index.md)

$\mathcal Q$ は大きさと構成語の対になる。大きさは $[0,1]$ の有理数、構成語は $D_\infty$ の元である。

$$
q=\bigl(\ \text{大きさ}\ a/b,\ \ \text{語}\ w,\ \ \text{符号}\ s\ \bigr)
$$

出口では五語へ開く：$a$、$b$、$m$、$\varepsilon$、$s$。

**定理 3.3**　$\mathcal Q$ は非可換 quantale をなす。

$$
a\star b\le c
\iff
b\le a\searrow c
\iff
a\le c\swarrow b
\tag{3.3}
$$

---

## 整合対

07 §6.2 が到達度から整合対を作る。

$$
\operatorname{ar}(a,c)=
\begin{cases}
1 & a=c=0\\
0 & a=0\neq c\\
\min(1,\ c\oslash a) & \text{その他}
\end{cases}
\qquad
(q\Leftrightarrow p)=\operatorname{ar}(q,p)\star\operatorname{ar}(p,q)
$$

| 音節 | 記号 | 型 |
|---|---|---|
| `to` | $q\Leftrightarrow p$ | $D\otimes D\to Q$ |
| `na` | $q\Leftrightarrow1$ | $D\to Q$ |
| `ni` | $q\Leftrightarrow0$ | $D\to Q$ |

```
hu hu ka ki se ka to
```

$1\Leftrightarrow\beta(1)=1\Leftrightarrow1$。大きさ $4/4=1$。`examples/vocabulary/to_agree.cmn`

`na` と `ni` は原型を書かずに済む形になる。分類器も特徴選択も現れない。

---

## 積と上限

| 音節 | 記号 | 型 | 性質 |
|---|---|---|---|
| `nu` | $\star$ | $Q\otimes Q\to Q$ | 非可換。語を接合する |
| `yu` | $\bigvee$ | $Q\otimes Q\to Q$ | 完備束の上限。結合的かつ可換 |
| `ra` | $\le$ | $Q\otimes Q\to B$ | 大きさの交差乗算で取る |

$\bigvee$ が結合的かつ可換なので、候補を畳む順序が値を変えない。
だから探索順が本文に現れない（[language/03_intent](../language/03_intent.md) §3）。

```
hu hu ka na na ka nu
```

`examples/vocabulary/nu_star.cmn`

---

## 残差

$$
q\searrow c=\max\bigl\{\,r\ \bigm|\ q\star r\le c\,\bigr\},
\qquad
c\swarrow q=\max\bigl\{\,r\ \bigm|\ r\star q\le c\,\bigr\}
$$

| 音節 | 記号 | 左に立つ入力 |
|---|---|---|
| `ye` | $\searrow$ | 第一 |
| `yo` | $\swarrow$ | 第二 |

残差は随伴なので、$\max$ の中身を探す手続きが要らない。

```
hu hu ka ki se ka na na ka yo
```

`examples/vocabulary/yo_resl.cmn`

---

## 忘却と二値化

| 音節 | 記号 | 型 | 何を落とすか |
|---|---|---|---|
| `ru` | $\pi_{\mathcal Q}$ | $Q\to Q$ | 構成語。大きさは動かない |
| `go` | $\Theta$ | $Q\to B$ | 大きさの正値だけ読む |
| `ne` | $\varphi_\partial\circ\pi$ | $Q\to B$ | 所属。閾値は現れない |

07 §6.3 の所属は二段の忘却になる。

$$
x\models m
\iff
\varphi_\partial\bigl(\pi(C_m(x))\bigr)=1,
\qquad
C_m(x)=\mathop{\bigstar}_{\ell\in L}\bigl(w(\ell,x)\Leftrightarrow p_\ell\bigr)
$$

目印ごとの整合対を $\star$ で畳み、境界で二値にする。閾値を書く席が構文に無い。

```
hu ka na ka go
```

値 $1$。`examples/vocabulary/go_theta.cmn`

---

## 到達度

### `ri` — $\hom$ &nbsp;&nbsp; $N\otimes N\to Q$

二つの名詞ノードの影響プロファイルを目印ごとに比べ、右残差を $\bigvee$ で畳む。

```
ma ma ka
ri ka
```

`examples/vocabulary/ri_hom.cmn`

## 参照

- [dyad](dyad.md) 二進有理数
- [noun](noun.md) 名詞ノードと影響
- [language/03_intent](../language/03_intent.md) 意図の判定条件
