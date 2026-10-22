# 04 CounterUnits（Level 4/5+: 単位 i, j と分岐語による合成）

## 役割

ω・ω⁻ の非対称性から単位 i, j を導出し、単位適用を分岐語上の全域関数として実装する。
Level 6+ の合成（ij, ji, さらに深い塔）も含めてすべての入力が値を持つ。

## 標準構成と分岐の頂点割当

```haskell
stdIntegers :: [CInteger]   -- 標準構成（O から幅 16）の整数列
omega       :: Int          -- 収束先（頂点 48）
omegaMinus  :: Int          -- ω⁻ = 2·offset − ω
iBranchBase = 4             -- I 分岐の頂点帯（4..12）
jBranchBase = 60            -- J 分岐の頂点帯
segmentI    -- 辺 {ω, iBranchBase}: ω からの独立方向の正セグメント
segmentJ    -- 辺 {ωMinus, jBranchBase}
unitI/unitJ -- 分岐の最初の頂点。i = ∂(I)、j = ∂(J) の新端点
```

備考: 頂点割当は記帳であり幾何的意味を持たない。実軸が 32..47、i 分岐が低位、
j 分岐が高位に置かれているのは衝突回避である。

## 分岐語と単位適用

```haskell
data Op = I | J                     -- I: ω 型境界操作、J: ω⁻ 型折り返し
type BWord = [Op]                   -- 正規形: 交互語。[] が実軸

data UnitPoint = UnitPoint
  { branchOf :: BWord               -- 分岐語
  , spotOf   :: Int                 -- 分岐アンカーからのオフセット
  , signU    :: Int                 -- 符号
  }

anchorOf :: BWord -> Maybe Int     -- 基底三分枝 [], [I], [J] の絶対アンカー
mkReal    :: Int -> Int -> UnitPoint        -- 絶対頂点と符号から実軸上の点を作る
applyU    :: Op -> UnitPoint -> UnitPoint   -- 単位適用。全域関数
applyI    = applyU I
applyJ    = applyU J
negateUP  :: UnitPoint -> UnitPoint        -- 同分岐内の反転
```

### applyU の簡約規則

| 入力語の末尾 | 追加する単位 | 結果 |
|---|---|---|
| （任意） | 異なる単位 | 語を延長。オフセット・符号を保つ |
| `…I` | I | 語を一つ畳み、**オフセット反転＋符号反転**（i² = −1 の反射） |
| `…J` | J | 語を一つ畳み、そのまま（j² = +1 の折り返し） |

この規則により Level 6+ の合成もすべて計算される:

```
ghci> branchOf (applyI (applyJ (mkReal oVertex 1)))
[J,I]        -- 「j してから i」= ji 分岐
ghci> branchOf (applyJ (applyI (mkReal oVertex 1)))
[I,J]        -- ij 分岐。ji とは別方向（四則演算 §③ の ij ≠ ji）
ghci> let q = applyI (applyI (applyJ (mkReal oVertex 1)))
ghci> (branchOf q, signU q)
([J],-1)     -- II が反射として畳まれ、符号だけが反転する
```

### オフセットの意味論

点は「どの分岐にいるか（語）」「アンカーからの距離（オフセット）」「符号」の三組で
表される。座標が一致しても語が違えば別物である——減算の非対称性（−i ≠ j）が
この表現に直接対応する。

基底三分枝の絶対位置が必要なときは `anchorOf` を使う:
絶対位置 = anchor + offset。

- `anchorOf [] == Just oVertex`
- `anchorOf [I] == Just iBranchBase`
- `anchorOf [J] == Just jBranchBase`
- 合成分岐（[I,J] 以降）のアンカーは未固定。各作図ごとに導かれる量であり、
  計算はオフセットのまま閉じる。

## 不変条件（検証コードあり）

1. `applyI (applyI p) == negateUP p` — i² = −1。
2. `applyJ (applyJ p) == p` — j² = +1。
3. `applyI p /= negateUP p` — 一回目は i 分岐へ出るので反転ではない。
4. ij ≠ ji は語レベルで保持される。
5. i = ∂(I) の新端点であること（昇順規約では i 側 −1、ω 側 +1）。j も同様に検証。

## 落とし穴

- 往復式を手で書くときはオフセット基準で考えること。絶対座標で書くと
  アンカー項を消し忘れやすい（過去に `iBranchBase - iBranchBase` を落としたバグが出た）。
- `negateUP` は分岐語を変えない。分岐ごと移動するのは applyU だけである。
- 単位はメタ操作であって点ではない。「i という数」という言い方はしない。
