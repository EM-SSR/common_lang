# examples

`.cmn` は Common 言語の source である。コモン公用語の平文そのものであり、
欄も行構文も語境界も無い（`16 章`）。

```
common <src.cmn>
```

| file | 平文 | 値 |
|---|---|---|
| `cmn/futatsu.cmn` | `hu hu ka, no ka.` | $2$ |
| `cmn/yonbunnosan.cmn` | `hu hu ka, ki ha ka, no ka, se ka, se ka.` | $3/4$ |
| `cmn/hitotsu.cmn` | 四つの one から $(1\oplus1)\star\beta(0)$ | $1$ |
| `cmn/tsuiki.cmn` | 注記（$I\to I$）を挟んだ $1\oplus1$ | $2$ |
| `cmn/tsuisuu.cmn` | 圏論層。$R_r(ij)$ | $(1,-1)=p_{+-}$ |

音節でない字は落ちるので、句読点も空白も改行も自由に置ける。値を立てて
廃棄で閉じた文は $I\to I$ になり、計算に効かないまま文章に残る（16 §4）。

`.cam` は Common Assembler の source である。意味レジストリの音節だけで書き、
mnemonic も register 名も現れない。

```
common <src.cam> [-t <target>] [-o <image>] [-p <proof>] [--list]
```

`-t` を省くと登録済みの全 target で build して結果を並べる。

## 置いてあるもの

| file | 何を計算するか | 目的 |
|---|---|---|
| `dyadic_series.cam` | $\sum_{k=0}^{4}2^{-k}=\dfrac{31}{16}$ | 二進有理定数と深度そろえ |
| `eratosthenes.cam` | $\pi(200)=46$ | 反復・memory・比較の全部 |
| `eratosthenes_bench.cam` | $\pi(10^6)=78498$ | 速度の比較 |
| `put.cam` | `Hi` と改行を外へ出す | $\mathrm{Put}$（10 章 §2 の ord 11） |

`put.cam` の局所片を持つのは `x86_64` と `lane64` だけになる。
他の target は式 (50.3) の実現不能で build が止まり、それが正しい返り値になる。

## 圏論層の平文（13 章 §1.1、構成語 §7）

`cmn/tsuisuu.cmn` は五語の一文でツイ数平面を歩く。

```
we re ka, ki sa ka, ki si ka, ki wi ka, gi ka.
```

| 層 | 音節 | 箱 | frontier |
|---|---|---|---|
| 0 | `we` `re` | $R_r$ を立てる、構成履歴 $O$ に立つ | $\mathsf{Reflection}\otimes\mathsf{Trace}$ |
| 1 | `ki` `sa` | 素通し、$i$ | 同上 |
| 2 | `ki` `si` | 素通し、$j$ | 同上 |
| 3 | `ki` `wi` | 素通し、$\operatorname{endpoint}$ | $\mathsf{Reflection}\otimes\mathsf{Point}$ |
| 4 | `gi` | $\operatorname{act}$ | $\mathsf{Point}$ |

$i$ の後に $j$ を当てた履歴の終点は $ij=(+1,+1)=p_{++}$ になり（圏論 定理 3.1）、
実軸反転がそれを $p_{+-}=(1,-1)$ へ送る（構成語 §7.4 の作用表）。

$$
\operatorname{act}\bigl(R_r,\ \operatorname{endpoint}(O\,i\,j)\bigr)
= R_r(p_{++}) = p_{+-}
$$

この文は 16 章 §5 の降下表に無い箱を含むので、Common Assembler の意味 program へは
降りない。driver はそこで止めた理由を出し、チェンバーの側で走らせた値を返す。

`llvm/` は LLVM IR からの入口の見本である（`docs/Common-Lang/3`）。

```
common <src.ll> --llvm [--addr N] [--in name=value,...]
```

| file | 何を計算するか | 目的 |
|---|---|---|
| `llvm/min.ll` | $\min(a,b)$ | 分岐と phi（$\mathrm{pc}_{\mathrm{prev}}$ の読み） |
| `llvm/count.ll` | $n_0$ からの数え下げ回数 | 単調停止フラグと $\omega$ 読み |
| `llvm/memsum.ll` | 二語書いて読み直した和 | load / store のマルチプレクサ |

## 二進有理級数

深度は加算のたびに $\max(\delta_u,\delta_v)$ へそろう。register が持つのは分子だけで、
深度は build 時の型として消える。どの段にも除算が現れないので値は $\mathbb Z[1/2]$ に留まる。

$$
\begin{aligned}
s_1 &= 1 \oplus \tfrac12 : \delta=1,\ \text{分子}\ 1\cdot2+1=3\\
s_2 &= s_1 \oplus \tfrac14 : \delta=2,\ 3\cdot2+1=7\\
s_3 &= s_2 \oplus \tfrac18 : \delta=3,\ 7\cdot2+1=15\\
s_4 &= s_3 \oplus \tfrac1{16} : \delta=4,\ 15\cdot2+1=31
\end{aligned}
$$

五 target すべてで走り、観測は 0（成功報告）になる。

## エラトステネスの篩

作業領域は語の並びであり、`ta` / `ti` は語番号で指す。語の byte 幅は
architecture package が持つので source には現れない（§32.2）。

```
語 0   i    語 1  j    語 2  c    語 3  N    語 64〜  篩
```

篩を自分で零埋めするので、作業領域の初期値に依存しない。

## 実行の結果

| target | 実行環境 | dyadic_series | eratosthenes |
|---|---|---|---|
| riscv64 | QEMU virt | exit 0 | exit 0 |
| arm64 | QEMU virt + semihosting | exit 0 | exit 0 |
| x86_64 | QEMU pc + multiboot | exit 0 | exit 0 |
| gfx1200 | package の simulator | 観測 0 | 観測 0 |
| sm_120 | package の simulator | 観測 0 | 観測 0 |

判定の語は意味レジストリのものを使う。tu が成功報告、te が失敗報告になる（10 章 §2）。

GPU の二つは vendor の道具で符号を検証する。

```
llvm-mc -disassemble -triple=amdgcn-amd-amdhsa -mcpu=gfx1200
nvdisasm --binary SM120
```

どちらも生成した byte 列を意図どおりの命令列として読み返す。

## 速度の比較

同じ算法を C で書き、`clang -O2 --target=riscv64-unknown-elf` で組んだものを
ベースラインにする。作業領域も終了規約も Common Assembler 版と同じにした。
同じ QEMU、同じ machine、同じ $N=10^6$ で測る。

QEMU の起動時間は両者とも 118 ms で一致したので、そのぶんを引いた。

| | 静的命令数 | image | 計算部の時間 |
|---|---:|---:|---:|
| clang -O2 | 49 | 196 B | **48 ms** |
| Common Assembler | 130 | 520 B | **70 ms** |
| 比 | 2.7× | 2.7× | **1.46×** |

差の出どころは三つで、どれも最適化の欠落である（§27 の等価類の中の変換を
まだ一つも実装していない）。

1. **定数の再物質化** — 意味 program が定数を使うたびに `ke` の箱が立ち、
   そのまま一命令になる。定数伝播が無い
2. **address の再計算** — `ta` / `ti` のたびに $\mathrm{base}+(i\ll3)$ を作り直す。
   強度低減も addressing mode の利用も無い
3. **並べ替えが無い** — Schedule は依存を保存した恒等写像である（§28 の退化形）

静的な比（2.6×）より動的な比（1.46×）が小さいのは、増えた命令の大半が
依存の浅い定数materialization で、pipeline がそれを吸収するからである。

## common_qbit

Counter 量子情報論の Qiskit バックエンド `common_qbit`（lane-qbit）の例。

- `common_qbit/*.cmn` — 手書きの平文。`python -m common_qbit.circuit.trace x.cmn out.png` が、実行される量子の命令を回路図にする
- `common_qbit/families/` — 論文 §13.9 の回路族 56 本。各回路に、回路図、OpenQASM 3、論文の式から出る予言と実行結果（`expected.json`）。一覧は `common_qbit/families/Index.md`
