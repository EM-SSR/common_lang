# ツイ数平面の層

[← 総表](Index.md)

ツイ数平面は連続な $\mathbb R^2$ ではない。操作の DAG が生む点の網と、それを支える領域の組になる。

$$
\text{ツイ数平面}
=\Pi_i\ \sqcup_{\ \mathbb R\text{-軸}}\ \Pi_j
$$

$\Pi_i$ は $\omega$ の非対称性を参照して出る半平面、$\Pi_j$ は $\omega^-$ の側になる。
両者は実軸でだけ接続する。

$$
i^2=-1,
\qquad
j^2=+1\ \ (j\neq1,\ j\neq-1)
$$

座標的に $(1,1)$ と書ける位置は、和ではなく「$O$ に操作 $ij$ を当てて到達した端点」になる。

---

## 履歴 $\mathsf{Trace}$

構成履歴は $\sigma^\varepsilon a$ の形で持つ。複製できない（構成語 §3.5）。

| 音節 | 記号 | 型 | 意味 |
|---|---|---|---|
| `re` | $\mathsf{trace}$ | $I\to T$ | 原点 $O$ に立つ |
| `sa` | $i$ | $T\to T$ | 構成生成元 $i$ を当てる |
| `si` | $j$ | $T\to T$ | 構成生成元 $j$ を当てる |
| `ke` | $\mathrm{id}$ | $T\to T$ | 恒等道。値も箱も動かない |
| `su` | $\ominus$ | $T\to T$ | 履歴の負化 |
| `ro` | $\rho^-$ | $T\to T$ | 境界射 $H^+\to H^-$ |
| `wa` | $\rho^+$ | $T\to T$ | 境界射 $H^-\to H^+$ |

出口は四語になる：$m$、$\varepsilon$、spot、符号。

```
re ka ke ka        →  0  0  1  1        恒等道は履歴を動かさない
re ka ro ka        →  0  0 -1 -1        ρ⁻ は spot と符号を反転する
re ka wa ka        →  0  0  1  1        j² = +1 なので ρ⁺ は値を動かさない
re ka su           →  0  0 -1 -1        履歴の負化は ρ⁻ と同じ式になる
```

`examples/vocabulary/` の `ke_id` `ro_rho_minus` `wa_rho_plus` `su_trace_neg`

---

## 点 $\mathsf{Point}$

### `wi` — $\operatorname{endpoint}$ &nbsp;&nbsp; $T\to P$

履歴の終点を座標へ落とす。正準点は構成語 §7.4 の並びになる。

$$
\mathcal A=\{O,\ \omega,\ \omega^-,\ i,\ j,\ p_{++},\ p_{-+},\ p_{+-},\ p_{--}\}
$$

| 音節 | 記号 | 型 | 意味 |
|---|---|---|---|
| `ko` | $\mathrm{id}_{\mathrm{coord}}$ | $P\to P$ | 座標の恒等道 |
| `ta` | $\oplus_{\mathrm{coord}}$ | $P\otimes P\to P$ | 平行四辺形則。深い側へそろえる |
| `de` | 実成分 | $P\to P$ | $(r,\omega)\mapsto(r,0)$ |
| `do` | 無限成分 | $P\to P$ | $(r,\omega)\mapsto(\omega,0)$ |

```
re ka wi ka ko                       →  1  0
re ka sa ka si ka wi ka de           →  1  0
re ka wi ka re ki ka wi ki ka ta     →  2  0
```

---

## 折返し $\mathsf{Reflection}$

$D_4$ の八元を持つ。合成は符号つき置換の積になるので、表を写さずに済む。

| 番号 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| 折返し | $E$ | $R_r$ | $R_\omega$ | $R_{ij}$ | $R_{ji}$ | $Q_+$ | $Q_-$ | $C_\pi$ |

| 音節 | 記号 | 型 |
|---|---|---|
| `wu` | $E$ | $I\to R$ |
| `we` | $R_r$ | $I\to R$ |
| `wo` | $R_{ij}$ | $I\to R$ |
| `ga` | 合成 | $R\otimes R\to R$ |
| `gi` | $\operatorname{act}$ | $R\otimes P\to P$ |

$R$ が引数つきの一箱でなく四箱に分かれているのは、平文が正準添字を書けないためになる（16 §3.1）。
§7.3 の生成関係が八元すべてを合成で出すので、表現力はそろう。

```
wu            →  0        恒等
we wo ka ga   →  5        R_r · R_ij = Q_+
```

---

## 五語でツイ数平面を歩く

`examples/cmn/tsuisuu.cmn`

```
we re ka, ki sa ka, ki si ka, ki wi ka, gi ka.
```

| 層 | 音節 | 箱 | frontier |
|---|---|---|---|
| 0 | `we` `re` | $R_r$ を立てる、履歴 $O$ に立つ | $\mathsf{Reflection}\otimes\mathsf{Trace}$ |
| 1 | `ki` `sa` | 素通し、$i$ | 同上 |
| 2 | `ki` `si` | 素通し、$j$ | 同上 |
| 3 | `ki` `wi` | 素通し、$\operatorname{endpoint}$ | $\mathsf{Reflection}\otimes\mathsf{Point}$ |
| 4 | `gi` | $\operatorname{act}$ | $\mathsf{Point}$ |

$i$ の後に $j$ を当てた履歴の終点は $ij=(+1,+1)=p_{++}$ になり、実軸反転がそれを $p_{+-}$ へ送る。

$$
\operatorname{act}\bigl(R_r,\ \operatorname{endpoint}(O\,i\,j)\bigr)=R_r(p_{++})=p_{+-}=(1,-1)
$$

出口は $1$ と $-1$ になる。

## 参照

- [noun](noun.md) 名詞ノード。構成語の非可換性が値になる層
- [region](region.md) 領域。ノードの位置が cell 番号を決める
