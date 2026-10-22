# common_qbit

Counter 量子情報論（`docs/docs_pending/Counter量子情報論_確定測定とPi_j計算.md`）の Qiskit バックエンド。
Common の量子回路 target「lane-qbit」を呼ぶ。

```
Qiskit の回路 ─ transcribe ─▶ .cmn ─ commonc（lane-qbit 版）─▶ image ─ vqpu ─▶ 結果
                                        compile 時の作図                u0 と境界の比較
```

量子状態の計算は全部、commonc の lane-qbit 版（`commonc/src/qstate.cam`）が compile 時の作図で済ませる。
image に残るのは、測定座標 $u_0$ と境界の表の比較だけになる。

| 段 | 場所 | 持つもの |
|---|---|---|
| 回路 → 平文 | `circuit/transcribe.py` | 命令を語へ写す。回転の角は表に集める |
| 平文 → image | `circuit/image.py` → `commonc/src/qbit.cam`、`qstate.cam` | 作図の置き場と表を host が置く。作図は cam |
| image の実行 | `common_vcpu/vqpu.py` | $x=[\theta_{BI}\le U_0]$、$BI\leftarrow2BI+x$ |
| 状態の保存 | `circuit/state.py` | 作図した係数を `Statevector` へ写す |
| Qiskit との接続 | `backend.py`、`provider.py` | `BackendV2`、`run`、結果 |

---

## 作図

### 状態

枝ごとに $2^n$ 個の振幅を持つ。振幅は $\zeta=e^{i\pi/4}$ の整数係数で、規格化しない。

$$
\alpha=a+b\zeta+c\zeta^2+d\zeta^3,\qquad
|\alpha|^2=(a^2+b^2+c^2+d^2)+\sqrt2\,(ab+bc+cd-ad)
$$

量子ビット $q$ は二分の段 $q$ に当たる。番号 $k$ と $k+2^q$ の振幅が、段 $q$ で隣り合う二つの領域の点になる。

### ゲート

| ゲート | 作図 |
|---|---|
| X | 対角の折返し：$(\alpha_0,\alpha_1)\to(\alpha_1,\alpha_0)$ |
| Z | 実軸の折返し：$\alpha_1\to-\alpha_1$ |
| H | 二つの折返しの像の平行四辺形の和：$(\alpha_0+\alpha_1,\ \alpha_0-\alpha_1)$ |
| S、T | $\Pi_i$ の回転：$\alpha_1\to\zeta^2\alpha_1$、$\zeta\alpha_1$ |
| Y、SX | $\zeta^2XZ$、$HSH$ |
| CX、CZ、SWAP | 段 $q_1$、$q_2$ の領域の組での入れ替えと負 |
| rx、ry、rz | 角の閉包の点 $z=\lim_{d\to\infty}(1+i\varepsilon)^{2^d}$、$\varepsilon=\varphi/2^d$ を対の二点へ当てる |

回転の点は、角 $\theta=m/2^e$（float の値そのもの）から整数の点 $(2^K,\ m\cdot2^{128})$ を作り、二乗と二分の割り算で
$d=3\max(B,0)+64$ 段たどる（$|\varphi|\le2^B$）。点の大きさは対の二点に同じく掛かるので、重みの比で消える。

### 測定

枝ごとに、$u_0$ から今の測定座標への写像を射影の形で持つ。

$$
u_0=\frac{\alpha u+\beta}{\gamma u+\delta},\qquad
T=\frac{\alpha w_0+\beta N}{\gamma w_0+\delta N},\qquad
\theta=\lceil T\cdot2^{62}\rceil
$$

$\theta$ は二分の作図で 62 桁決める。各桁の判定は $X+Y\sqrt2\ge0$ で、二次形式の符号で決まる。境界は右の領域に入る（論文 5.4）。

回転を含む回路では、重みのずれの上界 $R\cdot2^{-125-X}$（$R$ は回転の数）で境界を確かめる。桁が決まらないときは、
host が足す桁 $X$ を $0\to64\to256\to1024$ と増やして作図をやり直す。

### 写像を動かす作用

どれも写像へ右から一つの行列を掛ける。$u_{\text{前}}=(m_{11}u+m_{12})/(m_{21}u+m_{22})$。

| 作用 | $M$ | 論文 |
|---|---|---|
| 測定 $x=0$、$x=1$ | $\begin{pmatrix}w_0&0\\0&N\end{pmatrix}$、$\begin{pmatrix}w_1&w_0\\0&N\end{pmatrix}$ | 3.7 |
| 移送 $A_{x,\varepsilon}$（$\varepsilon=1$ が $B_x$） | $\begin{pmatrix}N\varepsilon_d&-\varepsilon_nW\\0&N(\varepsilon_d-\varepsilon_n)+\varepsilon_nw_x\end{pmatrix}$ | 6.2、15.11 |
| メビウス $A_f$ | $\begin{pmatrix}f_d&0\\-(f_n-f_d)&f_n\end{pmatrix}$ | 16.5 |
| $\beta_a$ | $\begin{pmatrix}2a_d&-a_n\\0&a_d\end{pmatrix}$ | 1.11 |

---

## 論文が形を書かない作用

次の二つは実機で測る対象なので、`run` の引数で候補を必ず明示する。省くと止まる。

| 引数 | 対象 | 候補 |
|---|---|---|
| `reset` | リセットが $u$ にする作用（12.16 の $R_C$） | `"consume"`：測定と同じく $u$ を使う |
| `actions` | ゲートの後に $u$ へ当てる作用（12.7 の $A_g$） | ゲートの名前 → `("mobius", f)`、`("beta", a)`。結合を零に置くなら `{}`（14.1） |

観測された結果の列と合う $u_0$ の領域は `vqpu.region(image, 結果)` が出す。結果 1 の境界で下を、0 の境界で上を削る
（3.16）。空なら、その候補は観測と合わない。

---

## 使う

```python
from fractions import Fraction
from qiskit import QuantumCircuit
from common_qbit import CommonQbitBackend, CounterTransport

qc = QuantumCircuit(2, 2); qc.h(0); qc.cx(0, 1); qc.measure([0, 1], [0, 1])
backend = CommonQbitBackend()
backend.run(qc, shots=1000, seed_simulator=7, actions={}).result().get_counts()
backend.run(qc, shots=2, initial_u0=[Fraction(1, 4), Fraction(3, 4)], memory=True, actions={})
```

$u_0$ は 62 桁の二進有理数で渡す。`seed_simulator` からは 62 桁の二進有理数を shot の数だけ作る（論文 3.11）。

## 検査

```bash
build_tools/venv/Scripts/python.exe -m pytest continuous_republic/common_apps/other_lang/python_lib/common_qbit/tests/test_construction.py -q
```

Qiskit-Aer の標準テストは `tests/run_aer_suite.py <テストのファイル名>` で走らせる（リセットの候補は `consume`、`actions={}`）。

## build

commonc の lane-qbit 版の image を作り直したら、`common_qbit/data/` へ写す。

```bash
builds/dist/build/x86_64-windows/ghc-9.10.3/common-assembler-0.2.0.0/x/common/build/common/common.exe continuous_republic/common_systems/common_lang/commonc/src/commonc_lane_qbit.cam -t lane64 --no-sim -o builds/commonc/commonc_lane_qbit.bin
```
