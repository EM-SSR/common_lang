# 一般情報理論層（InfoTheory.hs）

仕様: 03_一般情報理論.md

## 情報の本体と情報量の区別（§1〜§3）

| 概念 | 定義 | 実装 |
|---|---|---|
| 情報内容 I_∞(C) | `CNF(C)`。境界・層・箱順・μ・d を含む | `iInf` / `iInfEq` |
| 忘却列 | I_∞ → I_2 → I_1 → I_0 | 係数レベルでは GclsCategory の `piForget` / `thetaBin` |
| 情報量 L | `L(2^{-n}) = n` — 対数ではなく作図深度そのもの | `logDyad` |

`logDyad (m, d)` は分子 m が 2 の冪のときだけ `Just (d − log2 m)` を返す。
一般の dyadic（3/4 など）は二分割列の極限として閉じる対象であり、
この観測の管轄外である（Ω_a 閉包の実装が前提になる）。

## 加法性と離散 ELLA（命題3.1 / 定理4.1）

```haskell
starDyad :: Dyad -> Dyad -> Dyad      -- タレス乗算: 分子積・深度和
additivityHolds q r                  -- L(qr) == L(q)+L(r)
ella       :: (Dyad,Int) -> (Dyad,Int)  -- E(q,I) = (q/2, I+1)
ellaPow n                             -- E^n(1,0) = (2^{-n}, n)
```

定理4.1 の帰納法をそのまま実行形にしたもので、第二成分が dyadic 対数に
厳密一致する。外部の対数関数は一切呼ばない。

## Shannon entropy と Boltzmann 特殊形（§5/§6）

```haskell
entropyBits :: [Dyad] -> Maybe (Integer, Int)
```

重みが同深度の冪二進 dyadic（値 = m/2^d、Σm = 2^d）に限り、
`H = Σ m_i·L(p_i) / 2^d` を整数演算だけで厳密に返す。

検証済みの値:

- `(1/2, 1/2)` → ちょうど 1 bit
- `(1/2, 1/4, 1/4)` → ちょうど 3/2 bits
- 一様 N=8 → log2 8 = 3 bits（Boltzmann 型 log N の特殊形）

範囲外: 未正規化な重み、非冪二進の重み（例: 1/3）。これらは近似であり、
この関数は Nothing を返して境界を明示する。

## 条件付き情報は左右二種（§8 定義8.1)

```haskell
residualRight :: Dyad -> Dyad -> Ratio2   -- a ∖ c = c/a
residualLeft  :: Dyad -> Dyad -> Ratio2   -- c ∠ b = c/b
starLeq       :: Dyad -> Dyad -> Dyad -> Bool
```

随伴律 `a⋆b ≤ c ⟺ b ≤ a∖c ⟺ a ≤ c∠b` を両方向で検証する。

**実装上の発見**: 残余における零の扱いは、除算のそれとは異なる。

- 除算 `divideThales n 0`: 相似三角形の退化で交点は ω 方向へ飛ぶ（BeyondOmega）
- 残余 `a ∖ c` with a=0: 任意の b が成立するので上限は **top = 1** に閉じる

残余は sup を取る演算であって除算そのものではない——除算は残余の
非零場合の計算手段である。可換な特殊系では左右の残余が一致し、
通常の条件付き情報へ落ちることまで検証してある。

## §7 非可換性で失われるもの

QCoeff の i⋆j と j⋆i について:

- 情報内容（語）は異なる — I∞ レベルでは順序が生きている
- π 後の大きさは等しい — μ=1 へ落とすと順序が消える
- L も等しくなる — スカラー観測では構成順序は復元できない

「完全な情報を −log q だけで表すことはしない」の実行可能版である。
