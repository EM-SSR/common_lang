# counter_plane リファレンス

対象: `continuous_republic/counter_plane/src` 配下の Haskell 実装。
対応ドキュメント: `docs/幾何連合論理集合` およびその配下。

## ファイル構成

| ファイル | 内容 |
|---|---|
| [01_counter_type.md](01_counter_type.md) | 土台: 単体複体行列と語彙ゲート |
| [02_realunit.md](02_realunit.md) | Level 0〜2: 領域・境界・実数・負化 |
| [03_counter_integer.md](03_counter_integer.md) | Level 3: 対称な道と整数、ω |
| [04_counter_units.md](04_counter_units.md) | Level 4/5+: 単位 i, j と分岐語による合成 |
| [05_dag_layer.md](05_dag_layer.md) | dag 層: 平面・四則演算・影響関数・DAG・拡張実験 |
| [06_category_layer.md](06_category_layer.md) | 圏論層: 影響圏・一意正規形・CCS |

## 規約

本書では次の語を使い分ける。

- **しなければならない**: 実装が満たすべき要件。検証コード (`selfcheck`) が検証する。
- **定義**: 用語の意味。定義に反する入力は存在しない。入力は常に何らかの値へ計算される。
- **備考**: 規定ではない補足。

原則: 計算可能なものはすべて計算して値を返す。操作の禁止は設けない。
導出の順序だけが制約である。土台がまだない概念を先に書くことだけが誤りであり、
土台が得られた時点でその概念は計算対象になる。

## モジュール依存規則

派生モジュールは `{-# LANGUAGE NoImplicitPrelude #-}` を付け、`import CounterConstraints`
のみを行わなければならない（プロジェクト内モジュールの追加分を除く）。語彙の全一覧と
各モジュールへの適用は `tools/CheckImports.ps1` が静的に検査する。

| モジュール | import を許されるモジュール |
|---|---|
| CounterType / CounterConstraints | base のみ（土台） |
| RealUnit | CounterConstraints |
| CounterInteger | CounterConstraints, RealUnit |
| CounterUnits | CounterInteger まで |
| DagPlane | CounterUnits まで |
| DagArith / DagInfluence / CounterExtend / CounterDag | DagPlane まで |
| GclsCategory | CounterUnits, CounterInteger, DagPlane |
| NormalizedBool / CounterComputeSystem | CounterConstraints |

違反があると `CheckImports.ps1` が violations 数を出力する。0 でなければならない。
また、語彙外の識別子を使った瞬間コンパイルエラーになる（NoImplicitPrelude ゲート）。

## 検証手順

SelfCheck は `src/spec/SelfCheck.hs` にある。全モジュールの `selfcheck` を連結して実行し、
fail 数を出力する。

```
runghc -i src/core -i src/dag `
       -i src/category/gcls_category -i src/category/normalized_bool -i src/category/counter_compute_system `
       -i src/spec src/spec/SelfCheck.hs
powershell tools/CheckImports.ps1
```

fail が 0、violations が 0 でなければならない。テストを追加したときは、
対応モジュールの `selfcheck` へ項目を足し、ここに挙げたコマンドで確認する。

## 表現の基礎（全層共通）

- 単体は 64 ビット幅の整数で表す。ビット位置 p は頂点番号 v_p を表す。頂点番号は大域固定であり、単体ごとに付け直さない。
- 境界作用素 ∂ の符号 (−1)^k の k は「除く頂点の、単体内での昇順ランク」である。「マスク内で該当ビットより下位に立っているビット数」に等しい。
- 領域 (Region) は辺番号の集合として同じく 64 ビット整数に載せる。構成履歴はこのビット表現そのものである。
- 有理量は「分子 × 2^{-depth}」の二進比で持つ。一般比が必要な場所では生の分数 (n, d) も使う。
- 構成履歴のグラフ (Level 6+) は接続行列で表す。行 = 親ノード、立位ビット = 子ノード。
