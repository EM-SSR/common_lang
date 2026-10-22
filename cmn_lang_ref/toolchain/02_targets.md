# target と実行台

[← Index](../Index.md)

## 1. build family

$$
\mathscr B(P)=\bigl\{(T,\ \operatorname{Compile}_T(P))\ \bigm|\ T\in\mathcal T\bigr\}
$$

**定理 33.1**　$\mathcal T$ の増減は $\operatorname{Sem}(P)$ を変えない。

core は target 名を知らない。build の結果は一つの組で返る。

$$
\mathrm{Built}_T=\bigl(\text{name}(T),\ X_T,\ \llbracket X_T\rrbracket_T,\ \{R_i\}\bigr)
$$

第一成分は package が持つ data であり、core の型には現れない。

---

## 2. 登録済みの target

| target 名 | 章 | 実行台 |
|---|---|---|
| `riscv64` | 06 | QEMU virt |
| `arm64` | 05 | QEMU virt + semihosting |
| `x86_64` | 04 | QEMU pc + multiboot |
| `x86_64-hosted` | 18 | `common_host`（彩色した覆い） |
| `x86_64-hosted-w` | 18、19 §6 | `common_host`（語割付けの覆い） |
| `gfx1200` | 08 | package 内蔵 simulator |
| `sm_120` | 09 | package 内蔵 simulator |
| `lane64` | 20 | `Python_vCPU/vcpu.py` |

```bash
common <src> -t <target> -o <image>
```

`-t` を省くと登録済みの全 target で build して結果を並べる。

---

## 3. compile の段

$$
\operatorname{Compile}_{T,\mu}
=\operatorname{Pack}_T\circ\operatorname{Link}_T\circ\operatorname{Encode}_A
\circ\operatorname{Schedule}_A\circ\operatorname{Allocate}_A\circ\operatorname{Cover}_{A,\mu}
\circ\operatorname{Refine}_{T,\mu}\circ\operatorname{CNF}_\infty\circ\operatorname{Parse}
$$

$\operatorname{Parse}$ から $\operatorname{Refine}$ までが target 非依存の core になり、
$\operatorname{Cover}$ 以降が architecture package に属する（定理 52.1）。

---

## 4. lane64

実行位相を state の第一成分に置く（20 章）。

$$
T=c_{\mathrm{dis}}B+\sum_i\beta_i\nu_i
$$

| | x86-64 | lane64 |
|---|---|---|
| scalar register | 持つ | lane へ複製する |
| 箱あたりの byte | 最大 33 | 112 |
| 覆いの倍数 | 128 | 288 |

`vcpu.py` は三つの道を持つ。

| 道 | 何をするか |
|---|---|
| 翻訳器（既定） | image を Python の文へ落とす |
| `--interp` | 式 (2.1) の mask 付き意味をそのまま解釈する |
| `--cupy` | 語も述語も bit のまま GPU で走らせる |

GPU の道は語を bit 平面で持つ。

$$
V\in\mathbb B^{NB\times W},
\qquad
m\in\mathbb B^{W}
$$

lane の bit がそのまま述語 mask になるので、選択が `(new & m) | (old & ~m)` の一行になる。
加算は Kogge-Stone で $\log NB$ 段に畳み、乗算は carry-save で潰す。

語の幅 $NB$ は引数になる（既定 32）。lane64 の語は $\mathbb Z$ なので、
$NB$ bit を越えた時点で core 意味論と離れる。越えたら桁上がりを見て報告する。

```bash
python vcpu.py <image> --words 4096 --dump 1 --cupy --bits 32
```

---

## 5. 三つの道の一致

`Check.ps1 -Cupy` が corpus の全部で三つを突き合わせる。

$$
\llbracket X\rrbracket_{\text{翻訳器}}
=\llbracket X\rrbracket_{\text{解釈器}}
=\llbracket X\rrbracket_{\mathrm{GPU}}
=\llbracket\operatorname{Desc}(\texttt{.cmn})\rrbracket_C
$$

## 参照

- [01_build](01_build.md) compile して走らせる
- `docs/common-compiler/arch/20_lane64_package.md` lane64 の仕様
