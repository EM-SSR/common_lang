# 名詞の層

[← 総表](Index.md)

名詞ノードは原点から関係語で到達する点になる。個体ごとの literal は要らない。

$$
\mathsf{node}:\ I\to\mathsf{Noun},
\qquad
\llbracket\mathsf{node}\rrbracket=\hat O
\tag{16.3.2}
$$

$\hat O=\mathrm{QCoeff}\ 1\ 0\ [\,]\ 1$ が原点になる。

---

## 入口と関係

| 音節 | 記号 | 型 | 意味 |
|---|---|---|---|
| `ma` | $\mathsf{node}$ | $I\to N$ | 原点ノード $\hat O$ |
| `zu` | $\rho_i$ | $N\to N$ | ノードへ $i$ を当てる |
| `ze` | $\rho_j$ | $N\to N$ | ノードへ $j$ を当てる |
| `zo` | $T_i$ | $N\otimes N\to N\otimes N$ | 関係述語 $i$。主語へ語を当て、目的語を素通しにする |
| `da` | $T_j$ | $N\otimes N\to N\otimes N$ | 関係述語 $j$ |
| `te` | $!_{\mathsf{Noun}}$ | $N\to I$ | 廃棄 |
| `ri` | $\hom$ | $N\otimes N\to Q$ | 到達度 |

出口は五語になる：位置の四語（大きさ $n$、深度 $d$ を畳んだ値、語の $m$、$\varepsilon$、符号）と目印の数。

---

## 非可換性が値になる

構成語は $D_\infty=\langle i,j\mid i^2=j^2=e\rangle$ の元であり、$(m,\varepsilon)$ の対で尽きる。

$$
i=(0,1),
\qquad
j=(1,1),
\qquad
(m,\varepsilon)\cdot(m',\varepsilon')=\bigl(m+(1-2\varepsilon)m',\ \varepsilon+\varepsilon'-2\varepsilon\varepsilon'\bigr)
$$

```
ma ka zu ka ze      →  1 -1  0  1  0        ij  の位置は m = −1
ma ka ze ka zu      →  1  1  0  1  0        ji  の位置は m = +1
```

$ij\neq ji$ が語の値として見える。07 例5.1 が要求する

$$
T_{j\circ i}:O\mapsto ij,
\qquad
T_{i\circ j}:O\mapsto ji,
\qquad
T_f\star T_g\neq T_g\star T_f
$$

がこの二本で確かめられる。`examples/vocabulary/noun_ij.cmn`、`noun_ji.cmn`

$\mathsf{Dyad}$ の $\star$ は可換なので、この差は $\mathsf{Dyad}$ では表せない（17 §2）。

---

## 複製の禁止

`tu`（$\Delta_{\mathsf{Noun}}$）は平文に置けない。13 §1.2 が $\mathsf{Noun}$ を $\mu=\infty$ で複製不可と定め、
平文は $\mu=\infty$ だからである（16 §1.1）。

```
ma ka
tu ka
```

両方の compiler が image を出さずに止まる。`examples/vocabulary/tu_no_copy.cmn`

廃棄 `te` に同じ制限は無い。

---

## SOV の文

02 (9.1) の層構造を、名詞ワイヤの位置で組む（17 §4.3）。

$$
\Lambda_0=C_S\otimes C_O\otimes C_E,
\quad
\Lambda_1=T_{w_S}\,@\,0,
\quad
\Lambda_2=T_{w_O}\,@\,1,
\quad
\Lambda_3=T_{w_V}\,@\,0,
\quad
\Lambda_4={!}^{\otimes3}
$$

$C_E$ は文末ノードになる。二項の $T$ は位置 $q$ と $q+1$ を読むので、
末尾に一本余分なワイヤがあれば目的語側にも関係語を当てられる。文末の廃棄が $\Gamma^+=I$ を閉じる。

---

## 影響プロファイル

名詞の同一性は、共通の目印族 $L$ で測ったプロファイルの一致で与える（07 §10）。

$$
\hat x=\bigl(w(\ell_0,x),\ \ldots,\ w(\ell_n,x)\bigr),
\qquad
\sum_{\ell\in L}w(\ell,x)=1
$$

重心拘束は凸性から出る（影響関数 証明3.1）。ネットワークは一つであり、概念はその上の測定装置になる。

プロファイルを平文から立てる生成元は無い。正準添字を取るので `.cml` の側になる

## 参照

- [plane](plane.md) ツイ数平面
- [region](region.md) ノードの位置が単位領域を決める
- [judge](judge.md) 到達度と整合対
