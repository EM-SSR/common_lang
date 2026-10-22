# 平文層の API と意味論

仕様は `16 章_平文がプログラムになる条件.md`。対応モジュールは
`src/text/PlainText.hs`。降下と実行は `common_assembler` 側の
`Common.Lang.Descend` と `Common.Lang.Cmn` が持つ。

## この層が確定させること

$$
\boxed{
\text{平文で program を書くのではない。}
\quad
\text{平文が program である。}
}
$$

$$
\texttt{.cmn}=E_{\mathrm{speech}}(C_P)\in\Sigma^*,
\qquad
D_{\mathrm{text}}=D_{\mathrm{speech}}\circ\operatorname{filter}_\Sigma
$$

## PlainText.hs

| 数式 | 実装 | 出典 |
|---|---|---|
| $\operatorname{filter}_\Sigma$ | `sigmaOf` | 16 §1 |
| 語彙 $\Sigma^*\rightharpoonup\mathsf{Atom}$ | `baseLexicon`, `lexAt`（最長一致） | 06 §2、§17 |
| 層境界音・無声ワイヤ音 | `sepP`, `gapP`, `splitLayers` | 06 §2 |
| 一層の組み立てと診断 | `layerStep` | 構成語 §2.2、§15.4 |
| $D_{\mathrm{text}}$ | `readPlain` / `readWith` | 16 §1 |
| $d(f;g)=d(f)+d(g)$ | `depthOf` | 13 §2.1 |
| $E_{\mathrm{text}}$ | `writePlain`（`Speech.encode`） | 06 §2 |
| $C:I\to I$ の判定 | `isAside` | 16 §4 |

## 書き手が管理しないもの

構成語 §2.2 と定理 2.1 が、最大平行層形式の一意性を与える。

$$
h(v)=
\begin{cases}
0 & \operatorname{Pred}(v)=\varnothing\\
1+\max\limits_{u\in\operatorname{Pred}(v)}h(u) & \text{その他}
\end{cases}
$$

同じ層の箱は消費する入力区間の左端で昇順に並び、変化しない区間には恒等箱が入る。
だから

- **深度 $r$** は前駆関係から出る。書かない
- **位置 $q$** は frontier の中の位置。書かない
- **中間境界** は $\Gamma^-$ から一意に決まる（定理 2.2）。書かない
- **語境界** は表示の都合になる（命題 11.1）。空白・改行・句読点は落ちる

残るのは、層の切れ目と素通りするワイヤの位置だけになる。どちらも発声できる
音節であり（06 §2）、文の中の語として現れる。

## 音節の割当て

`primitiveTable` の順が $\operatorname{name}(k)=\operatorname{nameOfIdx}(3+k)$ で音節に写る。
予約帯は $0$ が層境界、$1$ が無声ワイヤ、$2$ が零標示音になる。

| 音節 | 意味 | 型 |
|---|---|---|
| `ka` | 層境界 | — |
| `ki` | 無声ワイヤ（恒等箱） | — |
| `hu` | $\mathsf{one}$ | $I\to\mathsf{Dyad}$ |
| `no` | $\oplus$ | $\mathsf{Dyad}^{\otimes2}\to\mathsf{Dyad}$ |
| `ha` | $\ominus$ | $\mathsf{Dyad}\to\mathsf{Dyad}$ |
| `se` | $\beta$ | $\mathsf{Dyad}\to\mathsf{Dyad}$ |
| `ti` | $\star$ | $\mathsf{Dyad}^{\otimes2}\to\mathsf{Dyad}$ |
| `so` | $\varphi_\partial$ | $\mathsf{Dyad}\to\mathsf{Bit}$ |
| `he` | $\Delta$ | $\mathsf{Dyad}\to\mathsf{Dyad}^{\otimes2}$ |
| `ho` | $!$ | $\mathsf{Dyad}\to I$ |

## 三つだけ注意が要る

### 1. $\beta$ の基準点は $1$ になる

実装の $\beta$ は Level 3 の梯子 $t_n=1-2^{-n}$ を一段登る。構成語 §8.1 の
$\beta_a(x)=(x+a)/2$ で $a=1$ を採った形になる。

$$
\beta(x)=\frac{x+1}{2},
\qquad
\beta(1)=1
$$

$1$ は不動点なので、$1$ から半分は作れない。零を先に立てる。

$$
0=1\oplus(\ominus1),
\qquad
\tfrac12=\beta(0),
\qquad
\tfrac34=\beta(\beta(0))
$$

### 2. 数の literal は無い

$\mathsf{one}$ 一つあれば $\mathbb Z[1/2]$ の全部が合成で書ける（命題 8.1）。
だから平文に数字も括弧もラベルも現れない。全部が音節になる。

### 3. コメントという構文は無い

計算に効かない文は $C:I\to I$ になる。値を立てて $!$ で閉じれば、どんな長さの
文でもこの形になる。$I$ はテンソル単位なので境界流を動かさないが、テンソルには
載り $\operatorname{CNF}$ を持つ。

$$
\boxed{
\text{コメントとコードの区別は構文に無い。境界の幅にしかない。}
}
$$

`writePlain` は注記も含めて書き戻す。落とすと注記というデータが消える。

## 例

`continuous_republic/examples/cmn/` にある。

```
common continuous_republic/examples/cmn/yonbunnosan.cmn
```

| file | 平文 | 値 |
|---|---|---|
| `futatsu.cmn` | `hu hu ka, no ka.` | $2$ |
| `yonbunnosan.cmn` | `hu hu ka, ki ha ka, no ka, se ka, se ka.` | $3/4$ |
| `hitotsu.cmn` | `hu hu hu hu ka, no ki ha ka, ki no ka, ki se ka, ti ka.` | $1$ |
| `tsuiki.cmn` | 注記を挟んだ $1\oplus1$ | $2$ |
