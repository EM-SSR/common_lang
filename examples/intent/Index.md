# 意図を書く五本

`.cmn` は $E_{\mathrm{speech}}(C_P)$ そのものになる（16 式 1.1）。ここに置いた五本は、
04 §17 の「計算すべき問い」を平文で書けることを見せる。

## 合格条件

チェンバー $C$ について

$$
H(C)=\bigl\{\,\text{$\llbracket C\rrbracket$ を得るのに要り、かつ $C$ の本文に現れない量}\,\bigr\}
$$

と置く。

$$
\boxed{\;C\ \text{は意図}\iff H(C)=\varnothing\;}
$$

命令列は $H$ が空でない。`ke 1 0; ke 1 0; ko` は $2$ を返すが、なぜ足すか、
いくつで止めるか、どれが答えかは本文の外に残る。

五本のどれにも、走査順・停止条件・閾値・候補の並べ方が現れない。

## 使う生成元

| 音節 | 生成元 | 書かずに済むもの |
|---|---|---|
| `yu` | $\bigvee$ | 探索順、打ち切り |
| `zi` | $\Omega_a[\beta_a;x_0]$ | 反復回数、収束判定 |
| `ye` `yo` | $\searrow$、$\swarrow$ | 逆算の手続き |
| `na` `ni` `to` | $q\Leftrightarrow p$ | 分類器、特徴選択 |
| `ne` | $\varphi_\partial\circ\pi$ | 閾値 |

どれも随伴・上限・不動点になる。定義から一意に決まるので、手続きを書く場所が構文に無い。

## 注記

各本の先頭に $C:I\to I$ の注記が入る（16 §4）。注記は扱う量を立てて `ho` で閉じる。

$$
C_1;C;C_2=C_1;C_2
\qquad(\text{境界の上で})
$$

境界流を変えないが、テンソルに載り $\operatorname{CNF}(C)$ を持つ。
注記はデータであり、同時にコードになる。

## 五本

### 01_sup.cmn — 候補のうちいちばん良いもの

$$
P:X\otimes Y\to\mathcal Q,
\qquad
\bigvee_{y\in Y}P(x,y)
\tag{04.17}
$$

候補 $Y=\{\tfrac12,\tfrac14,\tfrac34\}$、原型 $1$。評価は整合対 `na`（$q\Leftrightarrow1$）。

注記は原型 $1$ を立てて閉じる。

$$
\bigvee\Bigl\{\tfrac12,\ \tfrac14,\ \tfrac34\Bigr\}=\tfrac34
$$

出力は $\mathcal Q$ の分子と分母で $3$ と $4$ になる。

$\bigvee$ は完備束の上限なので結合的かつ可換になる（定理 3.3）。
畳む順序は値を変えないので、探索順は本文に現れない。

### 02_omega.cmn — 半分ずつ寄っていく先

$$
x=\frac{x+a}{2}
\quad\Longrightarrow\quad
x=a,
\qquad
\Omega_a[\beta_a;x_0]=a
\tag{構成語 5.2}
$$

注記は集積点 $\tfrac34=\beta(\beta(0))$ を立てて閉じる。本体は初期値 $1$ と集積点 $\tfrac34$ を
並べ、`zi` で閉じる。出力は $3/2^2$ になる。

書くのは方程式と集積点だけになる。反復を回す箱は $\mathcal G$ に無い（16 §5.2）。

### 03_residual.cmn — 届かせるのに何が要るか

$$
a\star b\le c
\iff
b\le a\searrow c
\iff
a\le c\swarrow b
\tag{定理 3.3}
$$

$q=\tfrac12$ を持ち、$c=\tfrac14$ へ届かせたい。

$$
q\searrow c=\max\bigl\{\,r\ \bigm|\ q\star r\le c\,\bigr\}=\tfrac12
$$

出力は $2$ と $4$ になる。残差は随伴なので、$\max$ の中身を探す手続きが要らない。

### 04_member.cmn — 重心は頂点 $ij$ か

07 §10.7 をそのまま採る。目印 $L=\{O,i,ij\}$、原型 $\hat p=(0,0,1)$。

$$
C_m(x)=\mathop{\bigstar}_{\ell\in L}\bigl(w(\ell,x)\Leftrightarrow p_\ell\bigr),
\qquad
x\models m\iff\varphi_\partial\bigl(\pi(C_m(x))\bigr)=1
$$

候補は例 2.1 の $\hat x=(\tfrac14,\tfrac14,\tfrac12)$ になる。

$$
\bigl(\tfrac12\Leftrightarrow1\bigr)\star\bigl(\tfrac14\Leftrightarrow0\bigr)\star\bigl(\tfrac14\Leftrightarrow0\bigr)=0
\qquad\Longrightarrow\qquad
\text{所属}=0
$$

`na` が $\Leftrightarrow1$、`ni` が $\Leftrightarrow0$、`nu` が $\star$、`ne` が $\varphi_\partial\circ\pi$ になる。
閾値は現れない。

### 05_vertex.cmn — 頂点そのものは頂点 $ij$ か

同じ概念に $\hat x=(0,0,1)$ を当てる。

$$
\bigl(1\Leftrightarrow1\bigr)\star\bigl(0\Leftrightarrow0\bigr)\star\bigl(0\Leftrightarrow0\bigr)=1
\qquad\Longrightarrow\qquad
\text{所属}=1
$$

04 と 05 が別の値を返すことが、概念が区別を持つことの証拠になる。

## 走らせ方

```
common continuous_republic/examples/intent/01_sup.cmn --run
```

lane64 で走らせる道は `19 §7.1` になる。
