# 音節・層・frontier

[← Index](../Index.md)

## 1. 音節表

音節は子音と母音の積で作る（06 §1）。

$$
P=\{\sigma(c,v)=cv\mid c\in C,\ v\in V\},
\qquad
|C|=14,\quad|V|=5,\quad|P|=70
$$

```
        a    i    u    e    o
  k     ka   ki   ku   ke   ko
  s     sa   si   su   se   so
  t     ta   ti   tu   te   to
  n     na   ni   nu   ne   no
  h     ha   hi   hu   he   ho
  m     ma   mi   mu   me   mo
  y     ya   yi   yu   ye   yo
  r     ra   ri   ru   re   ro
  w     wa   wi   wu   we   wo
  g     ga   gi   gu   ge   go
  z     za   zi   zu   ze   zo
  d     da   di   du   de   do
  b     ba   bi   bu   be   bo
  p     pa   pi   pu   pe   po
```

先頭三つは予約されている。

| 番号 | 音節 | 役目 |
|---:|---|---|
| 0 | `ka` | 層境界 |
| 1 | `ki` | 無声ワイヤ（恒等箱ひとつ） |
| 2 | `ku` | 零標示音 $z_e$。三音節の名前の頭にもなる |

生成元 $k$ 番の名前は式 (1.2) が決める（10 §1）。

$$
\operatorname{name}(k)=
\begin{cases}
[\sigma_{3+k}] & k<60\\[4pt]
\texttt{ku}\cdot[\sigma_{3+q},\ \sigma_{3+r}] & k\ge60,\quad k-60=60q+r
\end{cases}
\tag{1.2}
$$

$\sigma_{63}\ldots\sigma_{69}$（`be` `bo` `pa` `pi` `pu` `pe` `po`）は採用語彙の字母 $\Sigma_V$ になる。
名前の頭に立つ `ku` はどの一音節名とも一致しないので、名前の集合は接頭自由になり、
最長一致の語彙引きが一意に決まる。

## 2. 層と frontier

層境界音が層を切る。層の中では、箱が **今の位置から** 入力を取る。

$$
S(k,q,r)=a
\tag{2.1}
$$

| テンソルの軸 | 音節列での現れ方 |
|---|---|
| $r$ 因果深度 | `ka` の出現回数 |
| $q$ frontier 位置 | 層の中での音節の位置 |
| $k$ 語位置 | 表示の都合。テンソルには現れない |

層の高さは前駆関係から出る（構成語 §2.2）。

$$
h(v)=
\begin{cases}
0 & \operatorname{Pred}(v)=\varnothing\\
1+\max_{u\in\operatorname{Pred}(v)}h(u) & \text{その他}
\end{cases}
\tag{2.2}
$$

定理 2.1 がこの分解を一意にする。だから読みは文法解析ではなく復号になる。

### 例

```
hu hu hu ka        層 0   frontier = [D, D, D]
ki no ka           層 1   位置 0 を素通し、位置 1〜2 を足す → [D, D]
no ka              層 2   位置 0〜1 を足す               → [D]
```

`ki` は「この位置のワイヤを次の層へそのまま渡す」を表す。位置を一つ進める。

## 3. 注記

境界を $I$ で閉じた文は、境界流を動かさない（16 §4）。

$$
C:I\to I,
\qquad
C_1;C;C_2=C_1;C_2
\quad(\text{境界の上で})
\tag{3.1}
$$

値を立てて廃棄で閉じれば、どんな長さの文でもこの形になる。

```
hu hu ka, ki ha ka, no ka, se ka, se ka, ho ka.
hu hu ka, no ka.
```

一文目は $3/4$ を立てて `ho`（$!$）で捨てる。二文目の値 $2$ は変わらない。
注記はテンソルに載り、$\operatorname{CNF}$ を持ち、$\#k$ で参照できる。

$$
\boxed{\ \text{コメントとコードの区別は構文に無い。境界の幅にしかない}\ }
$$

## 4. 表示の自由

命題 11.1 により、語境界は可逆表示の範囲で自由に動く。次の三つは同じチェンバーを与える。

```
hu hu ka ki ha ka no ka se ka se ka
huhuka, kihaka.
  noka
  seka seka!
```

## 参照

- [02_boundary](02_boundary.md) 境界と型
- [03_intent](03_intent.md) 意図の判定条件
- [generators/Index](../generators/Index.md) 生成元の総表
