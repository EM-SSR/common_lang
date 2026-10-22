# compile して走らせる

[← Index](../Index.md)

## 1. 誰が何を出すか

$$
\texttt{.cam}\ \xrightarrow{\ \text{Haskell}\ }\ \text{image}
\qquad\qquad
\texttt{.cmn}\ \xrightarrow{\ \text{commonc の image}\ }\ \text{image}
$$

Haskell が出してよいのはバイナリだけになる。`.cmn` を compile するのは常に
commonc の image であり、その image を走らせるのは C か Python の実行台になる。

```
commonc/src/
  front.cam       .cmn → 疑似命令。target を知らない
  qlayer.cam      判定値 𝒬 の層
  qword.cam       構成語の算術
  region.cam      領域と鎖の層
  back_x86h.cam   → commonc_x86h.cam
  back_lane64.cam → commonc_lane64.cam
```

`use` は名前空間を一つにする。ラベルの解決は展開の後に一度だけ走る。

$$
\operatorname{res}(\texttt{use}\ f)=\operatorname{res}\bigl(\text{$f$ の中身をその行へ置いた source}\bigr)
\tag{12.1.1}
$$

---

## 2. 一本を走らせる

### 2.1 core 意味論で読む

```bash
common continuous_republic/examples/cmn/futatsu.cmn --run
```

```
source : .../futatsu.cmn  層 2  d係数=[2]
境界   : [PtDyad]
平文   : huhukanoka
降下   : 箱 4  退避語 32
  出力[0] = 2
```

### 2.2 commonc で compile する

作業領域の刻みは入力から出る（19 式 3.1）。

$$
B=\max(N+80,\ 4096),
\qquad
\mathrm{InBase}=288B,
\qquad
\mathrm{Words}=288B+N+4096
$$

$288$ は lane64 の覆いの倍数になる。x86-64 hosted 版では $128$ を採る。

```bash
python continuous_republic/common_systems/Python_vCPU/vcpu.py \
  builds/commonc/commonc_lane64.bin \
  --words 1183761 --in-base 1179648 \
  --in continuous_republic/examples/cmn/futatsu.cmn \
  --emit out.bin
```

### 2.3 出た image を走らせる

```bash
python continuous_republic/common_systems/Python_vCPU/vcpu.py out.bin --words 4096 --dump 1
```

```
lane 0    tu
  w[0] = 2
```

`tu` が成功報告、`te` が失敗報告になる（10 §2）。

---

## 3. 実行台

| 実行台 | 走らせ方 | 中身 |
|---|---|---|
| C | `builds/common-host/common_host.exe` | thread で lane を配る |
| Python 翻訳器 | `vcpu.py` | image を Python の文へ落とす |
| Python 解釈器 | `vcpu.py --interp` | 式 (2.1) の mask 付き意味をそのまま持つ |
| GPU | `vcpu.py --cupy` | 語も述語も bit のまま持つ（cuvcpu） |

どれも image の中身を読まない。

---

## 4. 検査

```bash
continuous_republic/common_systems/common_lang/commonc/tools/Check.ps1 -Cupy
```

三つを同時に見る。

$$
\operatorname{commonc}_{\mathrm{x86h}}(\texttt{.cmn})=\operatorname{Compile}_{\mathrm{x86h}}(\texttt{.cmn})
\qquad\text{byte 単位}
\tag{19.5.1}
$$

$$
\bigl\llbracket\operatorname{commonc}_{\mathrm{lane64}}(\texttt{.cmn})\bigr\rrbracket
=\bigl\llbracket\operatorname{Desc}(\texttt{.cmn})\bigr\rrbracket_C
\tag{19.43.2}
$$

GPU の実行台の観測も同じ列に並ぶ。

```
07_adjacent      式(5.1) 一致     式(43.2) 一致     分子 1 / 1  GPU 一致     1
```

降下の表に無い箱を含む平文は、どちらも image を出さない。それも一致のうちになる。

```
tu_no_copy       式(5.1) 一致     式(43.2) 一致     分子 — / —
```

`.cam` が image を出さなかったときは、そこで止まる。古い image で走ると、
直したはずの誤りが検査を通ってしまう。

### 他の runner

| runner | 何を走らせるか |
|---|---|
| `common_assembler/tools/BuildAndRun.ps1` | 全体 |
| `common_lang/common_lang/tools/Run.ps1` | 意味 program 14 本を C と Python で |
| `Python_vCPU/tools/Run.ps1` | lane64 の image を翻訳器と解釈器で |
| `reverse2tensor/tools/Run.ps1` | 平文からテンソルへの逆写像 |
| `examples/edu/run.py` | 採用語彙を展開してから走らせる |

## 参照

- [02_targets](02_targets.md) target と実行台の対
