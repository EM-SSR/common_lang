# コモン公用語 実装ノート

このプロジェクトは `docs/common_national_language`（仕様）を、
`counter_plane` に積み上げたツイ数幾何の実装の上に構造化して実装するものである。

## 現在の実装範囲

| 仕様書 | 状態 | 対応モジュール |
|---|---|---|
| 共通の前提（チェンバー） | **実装済み** | chamber/CommonChamber.hs |
| 01 意味対象と表意語 | **実装済み**（§1〜§5, §7, §8, §9 の中核） | word/Ideogram.hs |
| 02 三次元疎テンソルと文法 | **実装済み**（§1〜§7, §8〜§11 の中核） | grammar/SparseTensor.hs, grammar/SentenceGrammar.hs |
| 03 一般情報理論 | **実装済み**（§1〜§8 の中核。残差は DagArith の除算で実行） | info/InfoTheory.hs |
| 04 全域計算と停止性 | **実装済み**（実行項・Ω 閉包・FSM 判定・アフィン二乗法・固定点） | totality/Totality.hs |
| 05 多モーダル文法 | **実装済み**（text/glyph/image/audio の観測射と定理1.1） | multimodal/Multimodal.hs |
| 06 音声符号と誤り訂正 | **実装済み**（E/D 可逆・聴取チャネル・編集経路 ⋁・語彙分離・復号・零標示音 z_e（§16）・採用語彙 V（§17）） | speech/Speech.hs, speech/Abbrev.hs |
| 07 名詞と影響ネットワーク | **実装済み**（プロファイル・挙動・Nerode 合同・メタ名詞・所属・具体名詞。残差と整合対は counter_plane 側） | noun/NounNet.hs, noun/Metanoun.hs |
| 08 経路代数と離散ELLA学習 | **実装済み**（𝔸 と QCoeff の単項同型・格子更新・支持分離・許容帯） | learn/PathAlgebra.hs |
| 16 平文がプログラムになる条件 | **実装済み**（filter_Σ・最大平行層の復号・注記の I→I） | text/PlainText.hs |
| 13 §1.1 生成元レジストリ $\mathcal G$ | **実装済み**（47 語。後半 12 語が圏論層） | chamber/CommonChamber.hs |

生成元は 47 語で、音節表 70 のうち $\mathrm{unitBase}=3$ から 50 番までを占める。
残る 20 音節が 06 §17 の採用語彙 $\Sigma_V$ になる。

$\Omega_a$、$\#k$、$\mathsf{ext}_k$、$\mathsf{acc}_u$ は正準添字を取るので平文へ届かず、
`.cml` の側の仕事になる（13 §3）。$\partial_G$ は鎖の型を先に立てる必要がある。

未実装の項目に着手する前に、対応する GCLS 側の土台（残差・閉包・観測射）を
counter_plane 側で固めること。先に言語側へ手を出さない。
07 の土台は `GclsCategory` の `residualRightQ` / `residualLeftQ` / `agreeQ`
（`QRat` 付き）として固まっている。`agreeQ` は 07 §6.2 と 08 命題 4.2 に合わせて
右残差を両向きに取る（訂正の diff は `15 章`）。

## 設計方針

1. **原始文字は新しく作らない。** 原始文字とは counter_plane に積み上げた演算そのもの
   （applyU, negateUP, betaStep, phiPartial, addS）であり、CommonChamber.Prim はそれらへの
   参照である。新しい概念文字が必要になったときは、まず counter_plane 側でその演算が
   定義され検証されていなければならない。
2. **依存は単方向。** CommonChamber → (CounterUnits, CounterComputeSystem, DagArith, GclsCategory)、
   Ideogram / SparseTensor → CommonChamber、SentenceGrammar → Ideogram。
   逆流や飛び越えはしない。tools/CheckImports.ps1 が静的に検査する。
3. **整形式性と真偽は分離する。** wellFormed はポート型の接合だけを見る。
   evalChamber の結果が現実に整合するかは別の観測（sharp / φ∂）である。
4. **表示は意味を作らない。** ser / renderDecorated / parseRendered はどれも
   CNF 一致という同じ同一性基準へ落ちる。

## 検証手順

検査はリポジトリ直下から cabal で走る。`SelfCheck` は不一致が一件でもあれば
非零で終わるので、test-suite の合否がそのまま合格条件になる。

```
cabal test all
powershell tools/CheckImports.ps1
```

fail 0、violations 0 が現在の合格条件である。

## 各ファイル

- [chamber.md](chamber.md) — チェンバー層の API と意味論
- [ideogram.md](ideogram.md) — 表意語層の API と意味論
- [grammar.md](grammar.md) — 文法層（疎テンソル・SOV）の API と意味論
- [info.md](info.md) — 一般情報理論層の API と意味論
- [totality.md](totality.md) — 全域計算と停止性層の API と意味論
- [multimodal.md](multimodal.md) — 多モーダル層の API と意味論
- [speech.md](speech.md) — 音声符号層の API と意味論
- [noun.md](noun.md) — 名詞層（影響ネットワーク・メタ名詞）の API と意味論
- [learn.md](learn.md) — 学習層（経路代数・格子更新・支持分離）の API と意味論
- [text.md](text.md) — 平文層（.cmn の読み書き）の API と意味論





