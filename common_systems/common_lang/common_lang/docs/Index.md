# Common 言語 実装ノート

拡張子は二つに分かれる。

| 拡張子 | 何か | 仕様 |
|---|---|---|
| `.cmn` | Common 言語。コモン公用語の平文そのもの | `16 章` |
| `.cam` | Common Assembler。意味 program | `docs/common-compiler/lang/12` |

この文書は `.cam` で書いた 14 本について書く。`.cmn` の側は
`common_national_language/docs/text.md` にある。

仕様は `docs/Common-Lang/` の三文書にある。書式と core 意味論の具体化は
`13 章`、`14 章` にある。この文書はその二つと
source tree の対応だけを書く。

## 実装の形

Common 言語は Common Assembler の意味 program として書く。ソースは `.cam` だけで、
他の言語は使わない。入力表と期待表は program が自分で作業領域へ置き、
出力と期待値を 1 語ずつ $\mathrm{EqBr}$ で突き合わせて $\mathrm{Ok}$ / $\mathrm{Ko}$ を返す
（13 章 §5）。

$$
\llbracket X_T\rrbracket_T
=
\begin{cases}
\mathsf{tu} & \mathrm{OUT}=\mathrm{EXP}\\
\mathsf{te} & \text{一致しない}
\end{cases}
$$

この判定は core 意味論でも五つの architecture package でも同じ値を返さなければならない
（定理 33.1）。

## 走らせ方

core 意味論だけで走らせる。package を一つも使わないので速い。

```
common continuous_republic/common_systems/common_lang/common_lang/src/<dir>/<name>.cam --run
```

五 target で build して、simulator の観測を並べる。

```
common continuous_republic/common_systems/common_lang/common_lang/src/<dir>/<name>.cam
```

## source tree

ディレクトリは出典の文書で分かれる。program は文書の定理をそのまま確かめるので、
分類の軸は文書以外に無い。

| ディレクトリ | 出典 | 本数 |
|---|---|---:|
| `src/chamber/` | Common言語のチェンバー構文と構成語の意味的正規形 | 6 |
| `src/reduce/` | 1. 関数の一般形と縮約規則 | 4 |
| `src/lang/` | 2. Common 言語の基礎 | 3 |
| `src/category/` | 幾何連合論理集合/圏論 | 1 |

各 program の 2 行目に `# doc:` がある。counter-search はこの行から
該当章とその前提章を供給する。


| path | 出典 | 確かめる内容 |
|---|---|---|
| `src/chamber/snf.cam` | 構成語 §6 | 定理 6.1 意味的正規形 $\operatorname{snf}(w)=\sigma^\varepsilon a$。書換え系、停止性、合流性 |
| `src/chamber/d4.cam` | 構成語 §7、§9.3 | $D_4$ の八折返し、完全合成表、正準点への作用表、観測表 |
| `src/chamber/beta.cam` | 構成語 §8、§9.1、§9.2 | 定理 8.1 基準点の輸送、閉形、逆二分割、二分割の合成と非可換性 |
| `src/chamber/omega.cam` | 構成語 §5、§10 | 集積点への収束、共役輸送、単調フラグ、順序数の作図深度、観測の移動 |
| `src/chamber/layernf.cam` | 構成語 §2.2、§2.6 | 定理 2.1 最大平行層形式、定理 2.2 型付けの一意性、非正準層の診断 |
| `src/chamber/parse.cam` | 構成語 §2.4、§13.1、§15.4 | $\operatorname{code}(C)$ の読み取り、整形式検査、$\operatorname{parse}\circ\operatorname{ser}=\mathrm{id}$、診断七種 |
| `src/reduce/zeta.cam` | Common-Lang/1 §1、R1 | 高速ゼータ $Z_n=Z_1^{\otimes n}$、$C_\zeta(n)=n2^{n-1}$、メビウスとの往復 |
| `src/reduce/mf.cam` | Common-Lang/1 §2、§3 | 定理 2.4 $M_f=Z_m^\top P_f(Z_n^\top)^{-1}$、定理 2.2、R2 $M_{g\circ f}=M_gM_f$ |
| `src/reduce/rules.cam` | Common-Lang/1 §4 | R3 次数の劣加法性、R4 接合秩、R5 軌道縮約と Lucas の閉形評価 |
| `src/reduce/fix.cam` | Common-Lang/1 §4 R6 | 定理 6.1 冪零解消、定理 6.2 線形反復の対数解消 |
| `src/lang/sched.cam` | Common-Lang/2 §2、11 章 | 正準スケジュール $\operatorname{Sched}$、命題 3.2 の負荷、$\operatorname{Sym}\circ\operatorname{Sched}=\mathrm{id}$ |
| `src/lang/phigr.cam` | Common-Lang/2 §4 | 定義 4.1 正準座標、命題 4.2 単射性、命題 4.3 上下半平面の分離 |
| `src/lang/assert.cam` | Common-Lang/2 §5 | 定義 5.1 厳密検証、定理 5.2 確率的検証 $(n/p)^t$ |
| `src/category/quantale.cam` | 圏論 定理 3.3 | 𝒬 の束構造。冪等・可換・吸収・順序、そして分配 $a\starigvee_k b_k=igvee_k(a\star b_k)$ |

## 三位同型のどこを誰が担うか

$$
\Phi_{\mathrm{eq}}(C)
\longleftrightarrow
\operatorname{ser}(C)
\longleftrightarrow
\Phi_{\mathrm{gr}}(C)
\longleftrightarrow
\Phi_{\mathrm{ex}}(C)
$$

| 写像 | 担う program |
|---|---|
| $\operatorname{ser}$ / $\operatorname{parse}$ | `layernf.cam`、`parse.cam` |
| $\Phi_{\mathrm{eq}}$ | `mf.cam`（縮約行列の各行が方程式になる） |
| $\Phi_{\mathrm{gr}}$ | `phigr.cam`（正準座標への埋め込み） |
| $\Phi_{\mathrm{pr}}$ | `sched.cam`（正準スケジュールと記号実行） |
| $\operatorname{nf}$ | `snf.cam`、`d4.cam`、`beta.cam`、`omega.cam`、`zeta.cam` |
| $\operatorname{assert}_\mu$ | `assert.cam` |

正規化の順序は §12 の八段になる。

$$
\operatorname{NF}
=
\operatorname{NF}_{\mathrm{observe}}
\circ
\operatorname{NF}_{\Omega}
\circ
\operatorname{NF}_{\partial}
\circ
\operatorname{NF}_{\beta}
\circ
\operatorname{NF}_{\mathrm{reflect}}
\circ
\operatorname{NF}_{\mathrm{trace}}
\circ
\operatorname{NF}_{\mathrm{layer}}
\circ
\operatorname{TypeResolve}
$$

| 段階 | program |
|---|---|
| $\operatorname{TypeResolve}$ | `parse.cam` |
| $\operatorname{NF}_{\mathrm{layer}}$ | `layernf.cam` |
| $\operatorname{NF}_{\mathrm{trace}}$ | `snf.cam` |
| $\operatorname{NF}_{\mathrm{reflect}}$ | `d4.cam` |
| $\operatorname{NF}_{\beta}$ | `beta.cam` |
| $\operatorname{NF}_{\partial}$ | `beta.cam`（§9.1）、`d4.cam`（§9.3） |
| $\operatorname{NF}_{\Omega}$ | `omega.cam`、`fix.cam` |
| $\operatorname{NF}_{\mathrm{observe}}$ | `omega.cam`（§10.3 の半共役） |

観測を最後に置くのは、観測前の履歴が後続演算の結果を変えるためになる。
先に $\varphi_\partial$ を当てると、$-i$ と $j$ のような座標一致を誤って同一視する。

## 書くときの制約

Common Assembler の原子は 11 個しかない（10 章 §2）。除算も剰余もビット演算も無い。
だから次の書き方を守る。

1. **けたは引き算で読む**。上のけたから冪を引けるかどうかを見れば、部分集合の包含も
   ハミング重みも二進の桁包含も読める。ビット表 `BIT[n·T + k]` は program 自身が作る
2. **排他的論理和は等値の判定で作る**。成分が 0 と 1 に限る層では、これが和になる
3. **中間の値は作業語へ退避する**。値を wire に長く載せると、landmark が十本しかない
   target で割り当てが尽きる（§13 の wire-to-landmark embedding）
4. **戻り先の振り分けを置かない**。分岐先は literal だけなので、共通の手続きを
   タグで呼び戻す形にすると制御流れグラフが一つの強連結成分になり、生存区間が
   program 全体へ広がる。手続きは呼び出しごとに展開する
5. **表の区間を重ねない**。作業領域の割付は program の冒頭で宣言する（13 章 §4）

## 作業領域の割付

program ごとに冒頭のコメントで宣言する。共通の骨格は次になる。

| 区間 | 内容 |
|---|---|
| 語 0〜31 | 走査、ループ変数、退避 |
| 語 16〜 | 冪表 $2^k$ |
| 語 32〜 | ビット表、または生成元ごとの表 |
| 中間 | 係数表、行列、frontier |
| OUT | 出力 |
| EXP | 期待値 |
