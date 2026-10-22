# 生成元の総表

[← Index](../Index.md)

生成元は 69 語ある。名前は式 (1.2) がレジストリ順から決めるので、命名は無い。

型の略記：$D=\mathsf{Dyad}$、$B=\mathsf{Bit}$、$P=\mathsf{Point}$、$T=\mathsf{Trace}$、
$R=\mathsf{Reflection}$、$N=\mathsf{Noun}$、$Q=\mathcal Q$、$G=\mathsf{Region}$、
$C=\mathsf{Chain}$、$Q_r=\mathsf{Rational}$、$I$ は単位境界。

| # | 音節 | 記号 | $\Gamma^-\to\Gamma^+$ | 意味 | 頁 |
|---:|---|---|---|---|---|
| 0 | `ke` | $\mathrm{id}$ | $T\to T$ | 恒等道 | [plane](plane.md) |
| 1 | `ko` | $\mathrm{id}_{\mathrm{coord}}$ | $P\to P$ | 座標の恒等道 | [plane](plane.md) |
| 2 | `sa` | $i$ | $T\to T$ | 構成生成元 $i$ | [plane](plane.md) |
| 3 | `si` | $j$ | $T\to T$ | 構成生成元 $j$ | [plane](plane.md) |
| 4 | `su` | $\ominus$ | $T\to T$ | 履歴の負化 | [plane](plane.md) |
| 5 | `se` | $\beta$ | $D\to D$ | 二分割 $(x+1)/2$ | [dyad](dyad.md) |
| 6 | `so` | $\varphi_\partial$ | $D\to B$ | 観測 $[0<x]$ | [dyad](dyad.md) |
| 7 | `ta` | $\oplus_{\mathrm{coord}}$ | $P\otimes P\to P$ | 座標の加算 | [plane](plane.md) |
| 8 | `ti` | $\star$ | $D\otimes D\to D$ | 乗算 | [dyad](dyad.md) |
| 9 | `tu` | $\Delta_{\mathsf{Noun}}$ | $N\to N\otimes N$ | 名詞の複製（$\mu=\infty$ で不可） | [noun](noun.md) |
| 10 | `te` | $!_{\mathsf{Noun}}$ | $N\to I$ | 名詞の廃棄 | [noun](noun.md) |
| 11 | `to` | $\Leftrightarrow$ | $D\otimes D\to Q$ | 整合対 | [judge](judge.md) |
| 12 | `na` | $\Leftrightarrow1$ | $D\to Q$ | 原型 $1$ との整合 | [judge](judge.md) |
| 13 | `ni` | $\Leftrightarrow0$ | $D\to Q$ | 原型 $0$ との整合 | [judge](judge.md) |
| 14 | `nu` | $\star_{\mathcal Q}$ | $Q\otimes Q\to Q$ | 非可換積 | [judge](judge.md) |
| 15 | `ne` | $\varphi_\partial\circ\pi$ | $Q\to B$ | 所属 | [judge](judge.md) |
| 16 | `no` | $\oplus$ | $D\otimes D\to D$ | 加算 | [dyad](dyad.md) |
| 17 | `ha` | $\ominus$ | $D\to D$ | 負化 | [dyad](dyad.md) |
| 18 | `hi` | $\le$ | $D\otimes D\to B$ | 大小 | [dyad](dyad.md) |
| 19 | `hu` | $\mathsf{one}$ | $I\to D$ | 原点に立つ | [dyad](dyad.md) |
| 20 | `he` | $\Delta$ | $D\to D\otimes D$ | 複製 | [dyad](dyad.md) |
| 21 | `ho` | $!$ | $D\to I$ | 廃棄 | [dyad](dyad.md) |
| 22 | `ma` | $\mathsf{node}$ | $I\to N$ | 原点ノード $\hat O$ | [noun](noun.md) |
| 23 | `mi` | $\mathrm{Load}$ | $D\to D$ | 作業領域から読む | [machine](machine.md) |
| 24 | `mu` | $\mathrm{Store}$ | $D\otimes D\to I$ | 作業領域へ書く | [machine](machine.md) |
| 25 | `me` | $\mathrm{Ok}$ | $I\to I$ | 成功報告 | [machine](machine.md) |
| 26 | `mo` | $\pi$ | $B\to D$ | 型忘却 | [dyad](dyad.md) |
| 27 | `ya` | $\Omega$ 開き | $I\to I$ | 閉包の開き | [machine](machine.md) |
| 28 | `yi` | $\Omega$ 閉じ | $B\to I$ | 閉包の閉じ | [machine](machine.md) |
| 29 | `yu` | $\bigvee$ | $Q\otimes Q\to Q$ | 上限 | [judge](judge.md) |
| 30 | `ye` | $\searrow$ | $Q\otimes Q\to Q$ | 右残差 | [judge](judge.md) |
| 31 | `yo` | $\swarrow$ | $Q\otimes Q\to Q$ | 左残差 | [judge](judge.md) |
| 32 | `ra` | $\le_{\mathcal Q}$ | $Q\otimes Q\to B$ | 判定値の大小 | [judge](judge.md) |
| 33 | `ri` | $\hom$ | $N\otimes N\to Q$ | 到達度 | [noun](noun.md) |
| 34 | `ru` | $\pi_{\mathcal Q}$ | $Q\to Q$ | 語の忘却 | [judge](judge.md) |
| 35 | `re` | $\mathsf{trace}$ | $I\to T$ | 構成履歴 $O$ に立つ | [plane](plane.md) |
| 36 | `ro` | $\rho^-$ | $T\to T$ | 境界射 $H^+\to H^-$ | [plane](plane.md) |
| 37 | `wa` | $\rho^+$ | $T\to T$ | 境界射 $H^-\to H^+$ | [plane](plane.md) |
| 38 | `wi` | $\operatorname{endpoint}$ | $T\to P$ | 履歴の終点 | [plane](plane.md) |
| 39 | `wu` | $E$ | $I\to R$ | 折返し 恒等 | [plane](plane.md) |
| 40 | `we` | $R_r$ | $I\to R$ | 実軸反転 | [plane](plane.md) |
| 41 | `wo` | $R_{ij}$ | $I\to R$ | $ij$ 対角反転 | [plane](plane.md) |
| 42 | `ga` | 折返しの合成 | $R\otimes R\to R$ | $D_4$ の積 | [plane](plane.md) |
| 43 | `gi` | $\operatorname{act}$ | $R\otimes P\to P$ | 折返しの作用 | [plane](plane.md) |
| 44 | `gu` | $\beta^{-1}$ | $D\to D$ | 逆二分割 $2x-1$ | [dyad](dyad.md) |
| 45 | `ge` | $\mathsf{fix}$ | $D\to D$ | 集積点 | [dyad](dyad.md) |
| 46 | `go` | $\Theta$ | $Q\to B$ | 二値化 | [judge](judge.md) |
| 47 | `za` | $\beta_a$ | $D\otimes D\to D$ | 基準点つき二分割 | [dyad](dyad.md) |
| 48 | `zi` | $\Omega_a[\beta_a;x_0]$ | $D\otimes D\to D$ | 基準点つき集積点 | [dyad](dyad.md) |
| 49 | `zu` | $\rho_i$ | $N\to N$ | ノードへ $i$ | [noun](noun.md) |
| 50 | `ze` | $\rho_j$ | $N\to N$ | ノードへ $j$ | [noun](noun.md) |
| 51 | `zo` | $T_i$ | $N\otimes N\to N\otimes N$ | 関係述語 $i$ | [noun](noun.md) |
| 52 | `da` | $T_j$ | $N\otimes N\to N\otimes N$ | 関係述語 $j$ | [noun](noun.md) |
| 53 | `di` | $\mathrm{Ko}$ | $I\to I$ | 失敗報告 | [machine](machine.md) |
| 54 | `du` | $\mathrm{Put}$ | $D\to I$ | 一 byte 出力 | [machine](machine.md) |
| 55 | `de` | 実成分 | $P\to P$ | $(r,\omega)\mapsto(r,0)$ | [plane](plane.md) |
| 56 | `do` | 無限成分 | $P\to P$ | $(r,\omega)\mapsto(\omega,0)$ | [plane](plane.md) |
| 57 | `ba` | $\oslash$ | $D\otimes D\to Q_r$ | 除算 | [dyad](dyad.md) |
| 58 | `bi` | $\partial$ | $C\to C$ | 鎖の境界 | [region](region.md) |
| 59 | `bu` | $\oplus_{\mathsf{Chain}}$ | $C\otimes C\to C$ | 鎖の加算 | [region](region.md) |
| 60 | `kukeke` | 領域 | $N\to G$ | 単位領域 | [region](region.md) |
| 61 | `kukeko` | 共通部 | $G\otimes G\to G$ | $A\cap B$ | [region](region.md) |
| 62 | `kukesa` | 合わせ | $G\otimes G\to G$ | $A\cup B$ | [region](region.md) |
| 63 | `kukesi` | 外側 | $G\otimes G\to G$ | $U\setminus A$ | [region](region.md) |
| 64 | `kukesu` | 境界 $\partial$ | $G\to C$ | 領域の境界 | [region](region.md) |
| 65 | `kukese` | 含まれる | $G\otimes G\to B$ | $A\supseteq B$ | [region](region.md) |
| 66 | `kukeso` | 重なり | $G\otimes G\to B$ | $A\cap B\neq\varnothing$ | [region](region.md) |
| 67 | `kuketa` | 隣接 | $G\otimes G\to B$ | 境界を共有する | [region](region.md) |
| 68 | `kuketi` | 道 | $G\to B$ | 一続きの領域か | [region](region.md) |

## 音節から引く

```
ka  層境界      ki  無声ワイヤ    ku  三音節の名前の頭
ke  id          ko  id_coord      sa  i             si  j          su  ⊖_trace
se  β           so  φ∂            ta  ⊕_coord       ti  ⋆          tu  Δ_noun
te  !_noun      to  ⇔             na  ⇔1            ni  ⇔0         nu  ⋆_Q
ne  φ∂∘π        no  ⊕             ha  ⊖             hi  ≤          hu  one
he  Δ           ho  !             ma  node          mi  Load       mu  Store
me  Ok          mo  π             ya  Ω開き         yi  Ω閉じ      yu  ⋁
ye  ↘           yo  ↙             ra  ≤_Q           ri  hom        ru  π_Q
re  trace       ro  ρ⁻            wa  ρ⁺            wi  endpoint   wu  E
we  R_r         wo  R_ij          ga  合成          gi  act        gu  β⁻¹
ge  fix         go  Θ             za  β_a           zi  Ω_a        zu  ρ_i
ze  ρ_j         zo  T_i           da  T_j           di  Ko         du  Put
de  実成分      do  無限成分      ba  ⊘             bi  ∂_chain    bu  ⊕_chain

kukeke 領域    kukeko 共通部   kukesa 合わせ   kukesi 外側    kukesu 境界
kukese 含まれる kukeso 重なり  kuketa 隣接     kuketi 道
```

## 用例

`continuous_republic/examples/` に、生成元ごとの最小の一本が置いてある。

| ディレクトリ | 中身 |
|---|---|
| `cmn/` | 数と圏論層の入口 |
| `vocabulary/` | 生成元ひとつを見せる最小の平文 |
| `intent/` | 04 §17 の「計算すべき問い」 |
| `region/` | 幾何 Level 0 の操作と関係 |
| `edu/user/` | 採用語彙を使った学習用 |
