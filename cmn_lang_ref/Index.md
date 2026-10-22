# cmn 言語リファレンス

`.cmn` は Common 言語の source である。中身はコモン公用語の平文そのものになる。

$$
\boxed{\ \texttt{.cmn}\;=\;E_{\mathrm{speech}}(C_P)\;\in\;\Sigma^*\ }
\tag{1.1}
$$

$C_P$ は文章全体のチェンバー、$\Sigma$ は 70 音節の表である。読みはその復号になる。

$$
D_{\mathrm{text}}=D_{\mathrm{speech}}\circ\operatorname{filter}_\Sigma
\tag{1.2}
$$

$\operatorname{filter}_\Sigma$ が音節でない字を落とすので、空白・改行・句読点はどこへ置いてもよい。

---

## 最初の一本

```
hu hu ka
no ka
```

値は $2$ になる。読み方はこうなる。

| 音節 | 何が起きるか |
|---|---|
| `hu` | $\mathsf{one}$。$1$ を一本立てる |
| `hu` | もう一本立てる |
| `ka` | 層を閉じる |
| `no` | $\oplus$。左から二本を取って足す |
| `ka` | 層を閉じる |

走らせる。

```bash
common continuous_republic/examples/cmn/futatsu.cmn --run
```

---

## 三つの規則

書式の全部が三行で終わる。

1. 音節表 $\Sigma$ の元だけが意味を持つ
2. 層境界音 `ka` が層を切り、無声ワイヤ音 `ki` が恒等箱ひとつを表す
3. $\Gamma^-=I$、$\mu=\infty$

数字も括弧もラベルも変数名も現れない。定数は $\mathsf{one}$ と算術の合成で作る。

$$
2=1\oplus1,\qquad
0=1\oplus(\ominus1),\qquad
\tfrac12=\beta(0),\qquad
\tfrac34=\beta(\beta(0))
$$

---

## 読む順

| | 内容 |
|---|---|
| [language/01_source](language/01_source.md) | 音節・層・frontier。平文が疎テンソルになる仕組み |
| [language/02_boundary](language/02_boundary.md) | 境界と型。どの箱がどこに置けるか |
| [language/03_intent](language/03_intent.md) | 意図の判定条件 $H(C)=\varnothing$ |
| [generators/Index](generators/Index.md) | 生成元 69 語の総表 |
| [toolchain/01_build](toolchain/01_build.md) | compile して走らせる |
| [toolchain/02_targets](toolchain/02_targets.md) | target と実行台 |

## 層ごとの入口

生成元は境界の型で六つに分かれる。

| 層 | 型 | 頁 |
|---|---|---|
| 二進有理数 | $\mathsf{Dyad}=\mathbb Z[1/2]$ | [generators/dyad](generators/dyad.md) |
| 判定値 | $\mathcal Q$ | [generators/judge](generators/judge.md) |
| ツイ数平面 | $\mathsf{Trace}$、$\mathsf{Point}$、$\mathsf{Reflection}$ | [generators/plane](generators/plane.md) |
| 名詞 | $\mathsf{Noun}$ | [generators/noun](generators/noun.md) |
| 領域 | $\mathsf{Region}$、$\mathsf{Chain}$ | [generators/region](generators/region.md) |
| 実行台 | 作業領域と外部環境 | [generators/machine](generators/machine.md) |

## 出典

この頁の式は次の文書から取る。

| 記号 | 文書 |
|---|---|
| 16 | `docs/common-compiler/16_平文がプログラムになる条件.md` |
| 13 | `docs/common-compiler/13_Common言語のソース書式.md` |
| 10 | `docs/common-compiler/lang/10_意味レジストリとコモン公用語の字体.md` |
| 19 | `docs/common-compiler/program/19_commonc.md` |
| 06 | `docs/common_national_language/06_音声符号と誤り訂正.md` |
| 07 | `docs/common_national_language/07_名詞と影響ネットワーク.md` |
| 構成語 | `docs/Common-Lang/Common言語のチェンバー構文と構成語の意味的正規形.md` |
| 幾何 | `docs/幾何連合論理集合/Index.md` |
| 影響関数 | `docs/幾何連合論理集合/ツイ数平面とか/4. 影響関数と整合条件.md` |
