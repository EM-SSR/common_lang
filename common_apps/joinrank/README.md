# joinrank — 接合秩

$$
\operatorname{joinrank}:\ \mathcal C\times\mathrm{Cut}\longrightarrow\mathbb N
$$

構成語 §15 の表がこの型を与える。値は「境界を渡る独立影響の最小本数」になる。

---

## 1. 何を計算するか

### 1.1 定義（Common-Lang/1 R4 定理 4.1）

入力の分割 $[n]=A\sqcup B$ に対し、値の行列を

$$
F_{\alpha\beta}=f(\alpha,\beta),
\qquad
\alpha\in\{0,1\}^A,\quad\beta\in\{0,1\}^B
$$

と置く。$\mathbb F_2$ 上の階数を $\rho$ とすると、

$$
f(x_A,x_B)=\bigoplus_{r=1}^{\rho}p_r(x_A)\,q_r(x_B)
$$

を満たす組が存在し、**この形の分離積の最小本数がちょうど $\rho$ になる**。

カット $A\vert B$ が実軸（接合の共通境界）、$p_r$ が $\Pi_i$ 側、$q_r$ が $\Pi_j$ 側に住む。
分解が立つとき縮約行列はテンソル積へ割れる。

$$
M_f=M_g\,(M_{h_A}\otimes M_{h_B})
$$

### 1.2 入口は頂点値だけでよい

定理 2.2 が $X(f(x))=M_f X(x)$ を全頂点で与え、定理 2.3 がその一意性を与える。
頂点基底 $\{X(\mathbf 1_R)\}$ が $\mathbb R^{2^n}$ を張るので、チェンバー $C$ の意味は
頂点値 $2^n$ 個で決まりきる。だから入口は表 $\mathrm{TAB}[v]=[\![C]\!](v)$ 一つになる。

頂点番号は

$$
v=\alpha+2^{\kappa}\beta,
\qquad
A=\{0,\dots,\kappa-1\},\quad B=\{\kappa,\dots,n-1\}
$$

---

## 2. 階数を意図として書く

掃き出しは書かない。ピボットの選び方は本文に現れない量になるので、$H(C)=\varnothing$ を破る。
代わりに行の $\oplus$ 閉包の高さを取る。

$$
V_0=\{0\},
\qquad
V_{\alpha+1}=V_\alpha\cup\bigl(V_\alpha\oplus R_\alpha\bigr),
\qquad
\rho=\log_2\bigl\lvert V_{2^{\kappa}}\bigr\rvert
$$

$R_\alpha[\beta]=\mathrm{TAB}[\alpha+2^{\kappa}\beta]$ が第 $\alpha$ 行になる。
単調かつ有界なので有限段で不動点に着く（04 定理 9.1）。倍化そのものが独立性の判定になる。

$$
\bigl\lvert V\cup(V\oplus R)\bigr\rvert=2\,\lvert V\rvert
\iff
R\notin V
$$

$\mathbb F_2$ の加算は $\{0,1\}$ の上で算術に落ちる。生成元は $\oplus$、$\ominus$、$\star$ の三つで足りる。

$$
a\oplus b=a+b-2ab
$$

### 2.1 係数がそのまま分離積になる

閉包の索引 $m$ は、その要素を作った行の集合を表す。

$$
V_m=\bigoplus_{r:\,m_r=1}R_{\alpha_r}
$$

だから、行 $\alpha$ が閉包の索引 $m(\alpha)$ に一致したとき、

$$
q_r=R_{\alpha_r},
\qquad
p_r(\alpha)=\bigl(m(\alpha)\bigr)_r
$$

が定理 4.1 の組そのものになる。`rank.cmn` は倍化のたびに係数の表 $\mathrm{COF}$ を一緒に伸ばすので、
索引のビットを取り出す操作が要らない。

### 2.2 費用と容量

倍化の行き先は $m+\lvert V\rvert$ なので、閉包の行は $2\lvert V\rvert$ 要る。
見本と係数の添字は $r=0,\dots,\rho$ を取るので、席は $\rho_{\max}+1$ 要る。語の容量が

$$
\rho\le8,
\qquad
\lvert V\rvert=2^{\rho}\le256,
\qquad
\text{閉包 }512\text{ 行},
\qquad
2^{\,n-\kappa}\le512
$$

を決める。越えたら溢れの語が立ち、`build.read` が止める。走査の回数は

$$
C_{\text{閉包}}=2^{\kappa}\cdot\lvert V\rvert\cdot2^{\,n-\kappa}=2^{n}\cdot2^{\rho}
$$

で、カットの位置に依らない。定理 6.3 が言うとおり、R4 が利得を生むのは $\rho$ が小さいときに限る。

---

## 3. 平文

| ファイル | 式 | 出すもの |
|---|---|---|
| `size.cmn` | $N_A=2^{\kappa}$、$N_B=2^{\,n-\kappa}$、$N_V=2^{n}$ | 表の大きさ |
| `nvt.cmn` | $N_V=2^{n}$ だけ | 正規形だけを読むときの入口 |
| `anf.cmn` | $a_T=\bigoplus_{R\subseteq T}f(R)$（R1 のメビウス変換） | 正規形の係数 |
| `rank.cmn` | §2 の閉包 | $\rho$、見本 $q_r$、係数 |
| `factor.cmn` | $p_r(\alpha)=\mathrm{COF}[m(\alpha)][r]$ | 分離積の左側 |

連接が合成になる（16 式 1.3）ので、綴じた並びが一本の文になる。

```
joinrank = size ; anf ; rank ; factor
anf      = nvt ; anf
```

`joinrank.dic` が番地と番地の式を持つ。見出しは $\Sigma_V=\{$`be bo pa pi pu pe po`$\}$ の三音節で、
どれも同じ長さなので接頭自由になる。

メビウス変換は蝶の形で書く。桁の取り出しが要らないので、生成元は算術だけで済む。

$$
\mathrm{step}\leftarrow1,
\qquad
a[\,b+\mathrm{step}+j\,]\ \mathrel{\oplus}=\ a[\,b+j\,],
\qquad
\mathrm{step}\leftarrow2\,\mathrm{step}
$$

負荷は $C_\zeta(n)=n\,2^{n-1}$ で、$2^n\times2^n$ の行列積 $O(4^n)$ を避ける。

---

## 4. 描画

`svg/draw.py` は座標を写すだけ。座標は Common-Lang/2 定義 4.1 が決めている。

$$
r(T)=1-2^{-\lvert T\rvert},
\qquad
\theta(T)=\pi\sum_{k\in T}2^{-(k+1)}\in(0,\pi)
\qquad(\Pi_i)
$$

$$
r(y_u)=\tfrac12,
\qquad
\theta(y_u)=-\pi\frac{u}{m+1}
\qquad(\Pi_j)
$$

辺は二種類になる。

$$
E_\star=\bigl\{(T\setminus\{\max T\},\,T)\bigr\},
\qquad
E_\oplus=\bigl\{(T,y_u):(M)_{\{u\},T}=1\bigr\}
$$

### 4.1 交点を厳密に置く

$E_\star$ は $\Pi_i$ の中の弦なので直線で描く。上半平面は凸なので、両端が上半平面にあれば
線分も上半平面から出ない。

$E_\oplus$ は実軸を一度横切って $\Pi_j$ へ降りる弧になる。制御点を中点の水平方向だけへ寄せると、
制御点の $y$ が中点のままなので

$$
B_y(t)=(1-t)^2P_{0y}+2t(1-t)\cdot\frac{P_{0y}+P_{1y}}{2}+t^2P_{1y}
=P_{0y}+t\,(P_{1y}-P_{0y})
$$

と $t$ の一次式に落ちる。したがって実軸と交わるのは一度だけになり、交点は

$$
t^{*}=\frac{P_{0y}}{P_{0y}-P_{1y}},
\qquad
x^{*}=B_x(t^{*})
$$

で厳密に決まる。端点の一次補間では曲線の上に乗らない。

カットの弦を渡る太弦も、線形な汎関数

$$
\varphi(P)=P_x\,d_y-P_y\,d_x,
\qquad
d=(\cos\theta_\kappa,\ -\sin\theta_\kappa)
$$

の零点として同じ式で解く。`test_joinrank.py` が毎回この点を数で確かめる。

### 4.2 カットの弦

カット $\kappa$ の直径は偏角

$$
\theta_\kappa=\pi\,2^{-\kappa}
$$

に立つ。$T\subseteq B$ なら重みは全部 $2^{-(k+1)}\le2^{-(\kappa+1)}$ で、和は $2^{-\kappa}$ に届かない。
$T$ が $A$ に触れれば重みは $2^{-\kappa}$ 以上になる。

$$
\theta(T)<\theta_\kappa\iff T\subseteq B
$$

だから直径一本が $[n]=A\sqcup B$ をそのまま平面の扇へ分ける。

### 4.3 分離積の重ね描き

定理 4.1 の組は、$p_r$ が $A$ 側の扇、$q_r$ が $B$ 側の扇に住む。それぞれの台は
`nvt ; anf` をもう一度走らせて読む。図では

- 赤の細線が、$p_r$ と $q_r$ がそれぞれ読む単項式
- 赤の太弦が、$\hat q_r$ から $\hat p_r$ へカットを渡る一本

になり、太弦はちょうど $\rho$ 本になる。$\hat p_r$ と $\hat q_r$ は合算の点なので $y_u$ と同じく
半径 $\tfrac12$ の近くに置き、偏角は台の平均から出す（$r$ ごとの僅かな半径差は重なり避け）。

内積 $\bigoplus_{k<3}x_k\,x_{k+3}$、$\kappa=3$ では

$$
\operatorname{supp}(p_r)=\{x_0\},\ \{x_1\},\ \{x_2\},
\qquad
\operatorname{supp}(q_r)=\{x_3\},\ \{x_4\},\ \{x_5\}
$$

となり、対ごとに一本ずつ渡ることが図から読める。

### 4.4 読み方の辞書

凡例はこの表をそのまま出す。

| 図の要素 | 意味 |
|---|---|
| 環の番号（半径） | 相互作用の次数 $\lvert T\rvert$ |
| 弦の角度差 $\pi2^{-k}$ | どの入力 $x_k$ で伸びたか |
| 縁 $r=1$ | $\mathsf{fix}$、$\omega$ での読み |
| 実軸を渡る弧 | $\oplus$ による合算。経路の忘却 |
| 直径の弦 | R4 のカット。渡る弧の本数が $\rho$ |
| 接合ノード | 定理 4.1 の分離積 $p_r\,q_r$ |

### 4.5 引数

```
python svg/draw.py --table <0/1 列> --cut <κ> --out fig.svg
```

| 引数 | 効き |
|---|---|
| `--table` `--hex` `--n` | 頂点値。十六進なら `--n` が要る |
| `--cut` | カットの位置 |
| `--view` | `raw` は $\Phi_{\mathrm{gr}}$ だけ、`factor` は分離積を主役にする |
| `--hide` | `wedge,rings,axis,cut,star,plus,crossdot,junction,labels,output,legend` を落とす |
| `--dim` | 挙げた単項式を薄くする |
| `--highlight` | 挙げた単項式だけを濃く出し、他を薄くする |
| `--fade` | 薄くしたものの不透明度。既定 0.13 |
| `--theme` | `light` / `dark` |
| `--radius` `--scale` `--title` | 大きさと見出し |

四枚を一度に作る。

```
python figures.py
```

---

## 5. 検査

```
python test_joinrank.py
```

十四本について二つを、図について一つを突き合わせる。

1. $\rho$ が値の行列の $\mathbb F_2$ 階数に等しい
2. 平文が出した分離積が元の関数を復元する

$$
F_{\alpha\beta}=\bigoplus_{r<\rho}p_r(\alpha)\,q_r(\beta)
$$

3. 図の交点が曲線の上と境界の上に乗り、太弦の本数が $\rho$ に等しい

期待値は Python で別に掃き出して出す。検査のためだけで、平文の側は語しか受け取らない。

同じ関数 $x_0x_1\oplus x_2x_3\oplus x_4x_5$ をカットの位置で見比べると

| $\kappa$ | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| $\rho$ | 2 | 2 | 3 | 2 | 2 |

真ん中のカットだけ対 $x_2x_3$ を割るので一本増える。

---

## 6. 使う側

`common_apps/ai/Neural_Network/LTLS` が、道の値のベクトルの代わりにこの $\rho$ を運ぶ。
水準集合 $T_\delta=\{b:S_x(b)\ge\theta^{*}-\delta\}$ の接合秩をカットごとに取ると、
「曖昧さがどの段にあるか」が整数の並びで出る。

---

## 7. 道具立て

```
.dic + .cmn ──(commonc_lane64.bin on vcpu.py)──▶ lane64 image ──▶ vcpu.py
```

Haskell は `commonc_lane64.cam` から image を作るときにだけ出てくる。

```
common commonc_lane64.cam -t lane64 --no-sim -o builds/commonc/commonc_lane64.bin
```

綴じと実行は `common_apps/ai/automaton/toolchain.py` が持つ。問題に依らない部分なので共有する。

---

## 8. 出典

| 記号 | 文書 |
|---|---|
| R1–R6 | `docs/Common-Lang/1.関数の一般形と縮約規則.md` |
| 定義 4.1、三位同型 | `docs/Common-Lang/2.Common言語の基礎.md` §3、§4 |
| $\operatorname{joinrank}$ の型 | `docs/Common-Lang/Common言語のチェンバー構文と構成語の意味的正規形.md` §15 |
| 接合多様体 | `docs/幾何連合論理集合/Index.md`、`ツイ数平面とか/接合多様体としての「ツイ数平面」.md` |
| 平文の書式 | `docs/common-compiler/16_平文がプログラムになる条件.md` |
| 採用語彙 | `docs/common_national_language/06_音声符号と誤り訂正.md` §17 |
| 走らせ方 | `docs/common-compiler/program/19_commonc.md` §3、§7 |
