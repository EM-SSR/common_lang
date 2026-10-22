# -*- coding: utf-8 -*-
"""Common の作図を前向きと逆向きに微分する PyTorch ライブラリ（文書 docs_pending/common_gradient_diagram.md）。

各語の局所微分箱を .cmn に手で書き、GPU の lane で実行する。手順に沿った組み合わせ（連鎖律と共有の合流）は autograd が行う。

| 場所 | 役割 |
|---|---|
| `cmn/box/*.cmn` | 局所微分箱。値（.value）、逆向き（.rev）、前向き（.fwd） |
| `cmn/example/*.cmn` | 手で書いた全体の作図。共有ノード、XOR、Eligibility Trace |
| `cmn/swap.cmn` | 主作図の入れ替え sw（he、no、ha の 8 層） |
| `boxes` | 箱を lane で実行する |
| `ops` | 箱を torch.autograd.Function にする。backward と jvp |
| `chain` | 手順を箱の列として実行する。𝒬 の語は降下後の原子に開く |
| `torch_fn` | 手順を PyTorch の関数として使う（evaluate、Construction） |
| `trace` | Eligibility Trace |
| `assemble`、`run` | 主作図を .cmn に書き出し、commonc で compile して実行する |
| `synth` | 点の作図の問題と、標準 Transformer の学習 |
"""
__version__ = "0.1.0"
