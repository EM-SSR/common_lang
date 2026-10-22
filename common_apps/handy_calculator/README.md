# ツイ数関数計算機

このアプリケーションは、厳密有理式、ツイ数の構成履歴、影響量、接合秩を Common で計算します。Python は入力、MCP、画面、グラフを受け持ちます。計算は `commonc_lane64.bin` と `vcpu.py` を通ります。

## 起動

作業ディレクトリをこのディレクトリにします。

```powershell
python -m pip install -r requirements.txt
python app.py
```

GUI と stdio MCP サーバーを一つのプロセスで使う場合は、次を実行します。

```powershell
python app.py --both
```

MCP サーバーだけを使う場合は、次を実行します。

```powershell
python app.py --mcp
```

## 入力

- 四則演算: `+`, `-`, `*`, `/`
- 整数べき: `**`。指数の範囲は (-8\le n\le8) です。
- 二分割: `beta(x)=(x+1)/2`
- 基準点付き二分割: `bisect(x,a)=(x+a)/2`
- 変数: `x`
- 構成履歴: `i` と `j` からなる語
- 影響量: 0 から 1 までの二進有理数
- 接合秩: 長さが 4 から 1024 までの 0/1 真理値表とカット `κ`

整数、小数、分数は厳密有理数として扱います。真理値表の添字では `x0` が最下位bitになります。

## MCP の道具

- `calculate`: 厳密有理式を計算します。
- `sample_function`: 二進格子上の関数値を返します。
- `trace_twinned`: 構成語の終点を返します。
- `calculate_influence`: 影響量の積、上限、右残差、左残差を返します。
- `calculate_joinrank`: 接合秩、分離積、カット別profileを返します。
- `calculation_history`: GUI と MCP の共通履歴を返します。

履歴は `build/history.jsonl` に追記します。各行は入力元、Common 文、採用語彙、観測値、vCPU の実行量、lane64 image の識別値を持ちます。

## 独立版commonc

`.cmn` をlane64 imageへ変換します。

```powershell
python ..\..\..\tools\independent_compile_test\vcpu.py `
  ..\..\..\tools\independent_compile_test\commonc_lane64.bin `
  --words 500000 --in source.cmn --in-base 393216 --emit program.bin
```

生成したimageを実行し、語0から語15までを表示します。

```powershell
python ..\..\..\tools\independent_compile_test\vcpu.py `
  program.bin --words 65536 --dump 16
```

`PUT`のbyte列は `out` に出ます。`tu` は正常終了、`te` はCommon側の失敗報告です。
