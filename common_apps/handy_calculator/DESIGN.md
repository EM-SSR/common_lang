# 設計仕様

## 1. 計算対象

計算値の基礎を二進有理数とします。

\[
D=\mathbb Z[1/2]
=\left\{\frac{m}{2^d}\mid m\in\mathbb Z,\ d\in\mathbb N\right\}.
\]

一般の有理数は二本の Dyad 席で表します。

\[
Q=\{(a,b)\in D\times D\mid b\ne0\}/\sim,
\qquad (a,b)\sim(c,d)\Longleftrightarrow ad=bc.
\]

入力式は次の閉包です。

\[
e::=q\mid x\mid-e\mid e+e\mid e-e\mid e\mathbin\ast e
\mid e/e\mid e^n\mid\beta(e)\mid\beta_a(e).
\]

ここで (q\in\mathbb Q), (-8\le n\le8),
\(\beta(x)=(x+1)/2\), \(\beta_a(x)=(x+a)/2\) です。

## 2. Common への写像

各式を分子と分母へ写します。

\[
\begin{aligned}
N(a+b)&=N(a)D(b)+N(b)D(a),&D(a+b)&=D(a)D(b),\\
N(a\star b)&=N(a)N(b),&D(a\star b)&=D(a)D(b),\\
N(a/b)&=N(a)D(b),&D(a/b)&=D(a)N(b).
\end{aligned}
\]

この写像が作るチェンバーは、採用語彙、`ha`、`no`、`ti`、`mi`、`ba` の合成です。出口は Rational 席を一つ持ちます。Python の算術演算は結果値を作りません。

整数は処理手順として綴りません。生成した `.dic` が、たとえば

```text
bebe	=37
```

という意図語を定義します。`.cmn` は `bebe` を値として使います。`commonc` が採用語彙をチェンバーへ展開するため、定数の構築もCommonの計算に残ります。

生成した `.cmn` は、処理順の命令文を持ちません。各行は入力境界と出力境界の間にある箱の層です。`ki` は既存の席を次の境界へ接続します。式の意味はチェンバー全体の合成で決まります。

## 3. ツイ数幾何

ツイ数平面を二つの半平面の接合として扱います。

\[
\Pi=\Pi_i\sqcup_{\mathbb R}\Pi_j,
\qquad i^2=-1,
\qquad j^2=+1,
\qquad ij\ne ji.
\]

座標 ((1,1)) は (1+i) ではありません。これは原点から構成語 (ij) を適用した終点です。

\[
\operatorname{endpoint}(ij)=(1,1),
\qquad
\operatorname{endpoint}(ji)=(1,-1).
\]

画面は構成語と終点を同時に示します。座標観測後も履歴を保持します。

## 4. 影響値

判断値の台を次で固定します。

\[
\mathcal Q=[0,1]\times D_\infty,
\qquad
(\mu,u)\star(\nu,v)=(\mu\nu,uv).
\]

\(\star\) は構成語の順序を保ちます。積、上限、右残差、左残差は Common の `nu`、`yu`、`ye`、`yo` が表します。GUI と MCP は、単位構成語を持つ二進有理の判断値を入力として受け取ります。結果は大きさ、構成語状態、符号を返します。

## 5. 実行状態

共有状態を次で表します。

\[
S=(V,Q,J).
\]


- (V): scalar実行、commonc、vector laneを所有する一つの `SharedVCPU`
- (Q): vCPU を直列化する再入可能ロック
- (J): 連番を持つ共通履歴

GUI と MCP は同じ `CalculatorSession` を参照します。`--both` は両方の入口を一つのプロセスで開始します。

\[
\operatorname{eval}(e,\rho)
=\operatorname{observe}\left(
V\left(\operatorname{commonc}(\operatorname{cmn}(e,\rho))\right)
\right).
\]

`commonc` 自体も同じ (V) で実行します。アプリケーションは Haskell のビルドを呼びません。既存の `commonc_lane64.bin` が `.cmn` を lane64 image にします。

独立した標本はlaneごとに別の状態を持ちます。

\[
\Sigma^{(W)}=\prod_{\ell=0}^{W-1}\Sigma_\ell,
\qquad
\Sigma_\ell\cap\Sigma_m=\varnothing\quad(\ell\ne m).
\]

この条件では、vector実行の観測はscalar実行を並べた観測と一致します。

\[
\operatorname{Obs}\!\left(V_W(P;s_0,\ldots,s_{W-1})\right)
=\left(\operatorname{Obs}(V_1(P;s_0)),\ldots,
\operatorname{Obs}(V_1(P;s_{W-1}))\right).
\]

標本計算とカット別接合秩は64 laneずつ束ねます。最大4個の常駐processへlaneを配ります。64 bitを越える値を検出した実行台は、多倍長整数を使うscalar実行へ戻ります。

## 6. グラフ

関数の軌跡は有限の二進格子で観測します。

\[
X_d([a,b])=\left\{\frac{k}{2^d}\in[a,b]\right\}.
\]

各 (x\in X_d) に対して Common が (f(x)) を計算します。同じimageと異なる入力をvector laneへ配ります。画面座標への浮動小数点変換は、観測値をpixel位置へ写す時だけ使います。

計算チェンバーの表示は、入力式の依存関係を有向グラフで示します。演算ノードは入力から結果へ向きます。

## 7. 接合秩

真理値表をカット \([n]=A\sqcup B\) で行列にします。

\[
F_{\alpha\beta}=f(\alpha+2^\kappa\beta),
\qquad
\rho=\operatorname{rank}_{\mathbb F_2}F.
\]

既存の `common_apps/joinrank` が、次の最小分離積をCommonで観測します。

\[
f(x_A,x_B)=\bigoplus_{r<\rho}p_r(x_A)q_r(x_B).
\]

GUIは \(\rho\)、値の行列、\(p_r\) と \(q_r\) の接合線、全カットのprofileを同時に表示します。Pythonは返された分離積から行列を復元し、Commonの観測と入力表の一致を監査します。

## 8. 失敗条件

次の条件は計算結果を作りません。

- 分母が 0 になる。
- 未指定の変数を参照する。
- 許可していない構文または関数を使う。
- 数式、整数、指数、標本数が定めた上限を超える。
- `commonc` または計算 image が成功報告を返さない。
- 真理値表の長さが 2 の累乗ではない。
- 接合秩または右側の変数数が既存語彙の容量を超える。

失敗は履歴の成功列へ追加しません。入力欄は元の値を保持します。

## 9. 完了条件

次の観測を自動試験で確認します。

\[
\frac{1+3}{2}=2,
\qquad
0.1+0.2=\frac3{10},
\qquad
\beta(0)=\frac12,
\]

\[
\operatorname{endpoint}(ij)=(1,1),
\qquad
\operatorname{endpoint}(ji)=(1,-1).
\]

\[
\operatorname{joinrank}(0110,1)=2,
\qquad
F_{\alpha\beta}=\bigoplus_{r<2}p_r(\alpha)q_r(\beta).
\]

さらに、vector標本がscalarと同じ厳密値を返すこと、GUI起点とMCP起点の計算が同じセッション識別値と一つの連番を使うことを確認します。
