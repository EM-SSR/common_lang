# Common Assembler 実装ノート

仕様は `docs/Common_Assembler_specification.md`。実装が要求する具体化は
`docs/common-compiler/` にある。この文書はその二つと source tree の対応について。

## 使い方

```
common <src.cam> [-t <target>] [-o <image>] [-p <proof>] [--list]
common <src.cam> --run [--steps N]
common <src.ll>  --llvm [--addr N] [--in name=value,...] [--steps N]
```

`.cam` の書式は `docs/common-compiler/lang/12`。例は `continuous_republic/examples/`。
`--run` は core 意味論 $\llbracket P\rrbracket_C$ で走らせる（`14 章`）。
`--llvm` は Common-Lang/3 の変換写像 $\mathcal T$ で `.ll` をステップ行列へ写す。

## source tree

分類は `docs/common-compiler/` の章立てと一対一に対応する。

| path | 章 | 中身 |
|---|---|---|
| `src/Common/Lang/NL.hs` | lang/10 | source 層。意味レジストリ、音節名、logical file unit |
| `src/Common/Lang/Source.hs` | lang/12 | `.cam` の読み取り |
| `src/Common/Lang/Anf.hs` | Common-Lang/3 §2 | 𝔽₂ 上の一意正規形と、共有ノードを持つ系 |
| `src/Common/Lang/LLVM.hs` | Common-Lang/3 §1〜§3 | 状態空間、命令表、ステップ行列 |
| `src/Common/Lang/LLVMText.hs` | Common-Lang/3 §4.1 | `.ll` の字面から抽象構文へ |
| `src/Common/Lang/LLVMRef.hs` | Common-Lang/3 §4、§6 | 抽象機械の参照実装と軌道の突き合わせ |
| `src/Common/Lang/Descend.hs` | 16 章 §5 | チェンバー → 11 原子の降下 |
| `src/Common/Lang/Cmn.hs` | 16 章 | Common 言語の入口。平文から実行まで |
| `src/Common/Core/Pipe.hs` | core/03 | MBox、制御流れ、Allocate、Link、Pack |
| `src/Common/Core/Dyad.hs` | core/01 | 二進有理定数の深度と疑似命令 |
| `src/Common/Core/Proof.hs` | core/02 | proof object の構成・直列化・検査 |
| `src/Common/Arch/Lane.hs` | arch/07 | 実行位相 $\mathcal X_A$ と active mask |
| `src/Common/Arch/RV64.hs` | arch/06 | riscv64 |
| `src/Common/Arch/AARCH64.hs` | arch/05 | aarch64 |
| `src/Common/Arch/X86.hs` | arch/04 | x86-64 |
| `src/Common/Arch/GFX1200.hs` | arch/08 | AMD gfx1200 |
| `src/Common/Arch/SM120.hs` | arch/09 | NVIDIA sm_120 native |
| `src/Common/Program/Arith.hs` | program/11 | 分数を含む算術の意味 program |
| `src/Common/Program/Compiler.hs` | program/11 | 正準スケジュールの compiler |
| `app/Compile.hs` | lang/12 | compile driver |
| `app/Verify.hs` | — | build family の実行と proof object の書き出し |

## Common 言語からの入口

`16 章` は、コモン公用語の平文がそのまま program になる条件を定める。

$$
\texttt{.cmn}=E_{\mathrm{speech}}(C_P)\in\Sigma^*,
\qquad
D_{\mathrm{text}}=D_{\mathrm{speech}}\circ\operatorname{filter}_\Sigma
$$

欄も行構文も語境界も無い。音節でない字は落ちる。列の形は構成語 §2.2 の
最大平行層形式が決めており、定理 2.1 の一意性があるので読みは復号になる。

降下は一箱を MBox の有限列へ開く（16 §5）。$\Delta$ と $!$ は箱を作らない。
ワイヤの世界では複製が無料であり、廃棄はワイヤを落とすだけになる（§14）。

定理 5.1（降下は意味を保つ）は、チェンバー側の `evalChamber` と core 意味論
$\llbracket\cdot\rrbracket_C$ を突き合わせて確かめる。

```
common continuous_republic/examples/cmn/yonbunnosan.cmn
```

## LLVM IR からの入口

`docs/Common-Lang/3` は、任意の `.ll` を Common の共通表現へ写す写像 $\mathcal T$ を定める。

$$
X' = X \oplus (1\oplus h)\bigoplus_B \chi_{\beta(B)}(\mathrm{pc})\bigl(F_B(X)\oplus X\bigr),
\qquad
X_t = M_{\mathrm{step}}^{\,t}X_0
$$

$M_{\mathrm{step}}$ を $2^\sigma$ の表として持つことはできないので、実装は
「状態ビットごとの次の値」を共有ノードつきの系 `Sys` として持つ。桁上がり $c_k$ は
平坦化すると $2^k-1$ 項になるので、提示形はノードのままにする（§6）。

定理 4.3（意味の保存）は、`LLVMRef` の素朴な参照機械と軌道をビット単位で
突き合わせて確かめる。幅 3 の全頂点について、二項演算・比較・シフト・
選択と型変換・分岐と phi・switch・メモリ・ループの八系統を通す。

```
common continuous_republic/examples/llvm/count.ll --llvm --in n0=6
```

## コモン公用語との接続

算術の意味原子はコモン公用語のチェンバーそのものである。原始文字を新しく作らず、
counter_plane に積み上げた演算を参照する。

| 意味原子 | チェンバー | 中身 |
|---|---|---|
| `ko` (Add) | `primAddD` | `DagArith.alignDepth` + `addS` |
| `sa` (Mul) | `primMul` | タレス積。大きさは比の積、深度は指数の和 |
| `si` (Neg) | `primNegD` | `DagArith.negateS` |
| `se` (LtBr) の判定 | `primLeqD` | 深度をそろえてから分子を比べる |

したがって次がそのまま適用でき、build ごとに certificate として保存する。

- `Speech.encode` / `decode` — 発音符号の可逆性（06 §2）
- `SparseTensor.entries` / `restore` — 三次元疎テンソルの可逆性（02 定理 6.1）
- `Ideogram.mkWord` — 表意語。同一性は CNF 一致で決まる
- `Multimodal.roundTrips` — text / glyph / image / audio の四読み（05 §1）
- `Abbrev.selectVocab` — 採用語彙。頻度の高い意味へ短い列（06 §17）
- `Totality.decideFsm` — 反復の停止（04 §6）

残りの原子（定数の物質化、path separation、address space、外部報告）は
§55 の boundary atom であり、チェンバーを持たない。音節名だけ同じ規則で振る。

## build と検証

```
powershell -ExecutionPolicy Bypass -File continuous_republic\common_systems\common_lang\common_assembler\tools\BuildAndRun.ps1
```

CPU 三 target は QEMU で走らせて終了コードを照合する。

| target | 実行環境 | pass | fail |
|---|---|---|---|
| riscv64 | QEMU virt + sifive_test | 0 | 42 |
| arm64 | QEMU virt + semihosting | 0 | 42 |
| x86_64 | QEMU pc + multiboot + isa-debug-exit | 0 | 41 |

x86-64 の失敗値が 41 なのは isa-debug-exit が $(v\ll1)\,|\,1$ を返すからである。

GPU 二 target は vendor の逆アセンブラで符号を確かめる。

| target | oracle |
|---|---|
| gfx1200 | `llvm-mc -disassemble -triple=amdgcn-amd-amdhsa -mcpu=gfx1200` |
| sm_120 | `nvdisasm --binary SM120` |

どちらも生成した byte 列を意図どおりの命令列として読み返す。
proof object は `builds/common-assembler/proof.cnl` へ書き出し、
読み直してから検査する。検査は architecture package を持たなくても走る（core/02 §1）。

## 設計方針

1. **意味と符号を混ぜない**（§0）。source unit が意味、architecture package が座標、
   flat image が実行イメージ
2. **target 名を core へ入れない**（定理 52.1）。名前は package が `Built` の中で返す data である
3. **算術を二度書かない**。値の型も四則の規則も counter_plane のものを使う
4. **符号を宣言で済ませない**。vendor の道具が手元にあるなら、それを oracle にする
5. **raw encoding を第一級にする**（§23）。encoder は最終 bit pattern を直接出し、
   decode 往復を毎 build 検査する
