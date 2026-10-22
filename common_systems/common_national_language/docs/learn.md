# 学習層の API と意味論

仕様は `docs/common_national_language/08_経路代数と離散ELLA学習.md`。対応モジュールは
`src/learn/PathAlgebra.hs`。ELLA 文書の NN 実行系（ゲイン $g_\theta$、辺微分、
チャート変換）は使わない。要るのは「符号を越えない有限到達」だけになる。

## この層が確定させること

$$
\boxed{
(\mathbb A_1,\star)\ \cong\ (\mathsf{QCoeff},\star)
\qquad\text{かつ}\qquad
\text{輸送できる学習則は残差随伴・格子更新・支持分離の三つ}
}
$$

## PathAlgebra.hs

| 数式 | 実装 | 出典 |
|---|---|---|
| $\Lambda=\mathbb Z[\tfrac12]$、$\Lambda_F=2^{-F}\mathbb Z$ | `Lam`, `lamNorm`, `lamAdd`, `lamMul` | §1 |
| $\mathbb A=\{\sum a_\omega[\omega]\}$、$\mathrm{supp}$ 有限 | `PathAlg`, `mkAlg`, `supp` | §1 |
| $a[\omega]\star b[\nu]=ab\,[\operatorname{nf}(\omega\nu)]$ | `monoStar`, `starA` | §1 |
| $\oplus$（同語の係数加算） | `oplus` | §1 |
| $\varphi:\mathbb A_1\to\mathsf{QCoeff}$ | `phiOf` / `psiOf` / `qReduce` | 定理 2.2 |
| $n(q,q^\natural)=(q^\natural-q)/\Delta_F$ | `lamSteps` | §3.2 |
| $1\le s(n)\le\lvert n\rvert$ の一歩 | `lattStep`, `stepMinimal`, `stepHalving` | §3.2 |
| $\lvert q^\natural-q_{t+1}\rvert<\lvert q^\natural-q_t\rvert$ | `lattRun`, `strictlyCloser` | ELLA 定理 12.1 |
| $\operatorname{supp}(\Delta Q)\cap\Omega=\varnothing\Rightarrow Y$ 不変 | `readOn`, `disjointSupp` | ELLA 定理 17.1 |
| $(\lambda\Leftrightarrow p)=\min/\max$ | `agreeScalar`（`GclsCategory.agreeQ` の大きさ欄） | 命題 4.2 |
| $p_\ell\in[\eta\lambda_\ell,\ \lambda_\ell/\eta]$ | `bandOf`, `inBand` | 命題 4.2 |
| $C_m(x)=\bigstar_\ell(w(\ell,x)\Leftrightarrow p_\ell)$ | `conceptScore`（`judgeMag` と一致する） | 定義 10.1 |
| $K_a n_\omega=n_{\operatorname{nf}(a\omega)}$ | `transportHistory` | §4.4、ELLA 定理 14.1 |

## 四点だけ注意が要る

### 1. $\varphi$ が全単射になるのは既約代表の上でになる

`QCoeff` は $(1,1)$ と $(2,2)$ を別の値として持つ。$\varphi$ の像は常に
$\mathbb Z[\tfrac12]$ の既約形なので、逆向きは `qReduce` を通した上で一致する。

$$
\varphi\circ\psi=\operatorname{qReduce},
\qquad
\psi\circ\varphi=\mathrm{id}
$$

### 2. $\oplus$ を係数の内部へ持ち込まない

$\oplus$ は $\mathrm{supp}$ を広げる。`QCoeff` は $\mathrm{supp}$ の大きさが 1 の
正規形しか持たないので、合算は中間境界の $\bigvee$（`joinAtBoundary`）に置く。
係数内部の加算は「加算は経路を忘れ、乗算は経路を保持する」という位置制約を壊す
（命題 2.3）。

### 3. $\pi$ は語と符号をまとめて落とす

$K_a$ は係数 $1$ の単項なので、$\star$ は大きさを動かさずに語だけを動かす。
$II\Rightarrow\sigma$ で $\sigma^\varepsilon$ は変わりうるが、それは

$$
\pi(q)=\bigl(\lvert q\rvert\ \text{の分子},\ \text{深度}\bigr)
$$

の外にある。ELLA 定理 14.1「核履歴の書込みは現在の実数意味論を変えない」は、
この $\pi$ の像で読む。

### 4. 共有観測面では支持分離が退化する

全概念が同じ目印族 $L$ を読むと $\operatorname{supp}$ が完全に重なる。
非忘却学習は二択に落ちる。

| 方式 | 条件 | 代償 |
|---|---|---|
| 成分分割 | 各 $m$ が固有の $L_m\subseteq L$ を読む | 比較が $L_m$ の共通部分に限られる |
| 追加のみ | 既得の $p_\ell$ を凍結する | 修正は教師の明示的な削除と再登録になる |

選択は運用決定であり、数学としては `readOn` の不変性に帰着する。

## 例 4.3 は文書と値が違う

文書 §4.3 は $p^{(O)}_O$ を寄せる更新として書くが、それが上げるのは $C_O$ であり
分類は動かない。教師の指示へ反転させる更新は $p^{(D)}_{ij}$ になる。数値は同じ。
訂正の diff は `15 章_整合対と例4.3の訂正.md` に置いた。
`selfcheck` は両方を検査に持ち、向きが逆になることを示す。

## 整合対 $\Leftrightarrow$ の訂正

`GclsCategory.agreeQ` は第二因子に左残差を使っていた。07 §6.2 と 08 命題 4.2 に
合わせて右残差を両向きに取る形へ替えた。

$$
(q\Leftrightarrow p)
=(q\searrow p)\star(p\searrow q)
=\frac{\min(q,p)}{\max(q,p)}
$$

これで $q\Leftrightarrow p=p\Leftrightarrow q$ になる。同じく
`15 章` に diff がある。
