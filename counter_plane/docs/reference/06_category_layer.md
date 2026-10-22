# 06 圏論層（GclsCategory / NormalizedBool / CounterComputeSystem）

## GclsCategory（影響圏 𝒢）

「GCLS-圏論」の第 I〜III 部の実装。対象 = 影響対象、射 = 遷移係数行列、
合成 = ★-行列積、豊穣基底 = 非可換 quantale。

```haskell
type Mat = [[Int]]                 -- 遷移行列（行 = ソース目印）
matId      :: Int -> Mat           -- クロネッカー δ（定理2.3）
matMul     :: Mat -> Mat -> Mat    -- (2.1) の行列積
transM     :: [Int] -> [Int] -> VertMap -> [[Int]]

data QCoeff = QCoeff { qNum, qDep :: Int, qWord :: [Op], qSign :: Int }
star       :: QCoeff -> QCoeff -> QCoeff   -- ★: 大きさはタレス乗算、語は経路保持
piForget   :: QCoeff -> (Int, Int)         -- μ=1 型忘却 π
thetaBin   :: (Int, Int) -> Int            -- μ=0 二値化 Θ
compat     :: CellPt -> Bool               -- 整合 ◁: Σλ=2^depth ∧ λ≥0
```

検証される主張と使い方:

| 主張 | 実行形 |
|---|---|
| 命題1.4 外延性の反転 | プロファイル（λ 三組）の一致が点の同一 |
| 定理2.2 結合性 | `matMul (matMul a b) c == matMul a (matMul b c)`。符号 −1 を含めても壊れない |
| 定理2.2 合成律 | `matMul (transM f) (transM g) == transM (g . f)`（行=ソース規約） |
| 定理3.1 非可換性 | `star i j /= star j i`。ただし大きさは等しく、語だけが違う |
| 命題3.2 型忘却 | `piForget (star i j) == piForget (star j i)` — π で可換化する |
| 命題3.6 到達不能 | ω はどの有限深度の整数でもない |

備考: ★ が非可換でも結合律は保たれる。行列積の結合性が要求するのは係数の
結合律と分配律だけであり可換律は不要である——これが定理2.2 の核心で、
`starAssoc` のテストがそれを機械確認している。

## NormalizedBool（論理関数の一意正規形）

「論理関数の一意正規形」の実装。部分集合をビットマスク Int で表す。

```haskell
isSub      :: Sub -> Sub -> Bool                    -- T ⊆ R（Level 0 の「含まれる」）
mobiusCoef :: Int -> (Sub -> Integer) -> Sub -> Integer   -- (M) メビウス変換
zetaVal    :: Int -> (Sub -> Integer) -> Sub -> Integer   -- (Z) ゼータ変換
anfBit     :: Int -> (Sub -> Integer) -> Sub -> Integer   -- a_T = c_T mod 2 → ANF
evalAnf    :: Int -> (Sub -> Integer) -> Sub -> Integer   -- ⊕_{T⊆R} a_T
wAtVertex  :: Sub -> Sub -> Bool                    -- W_S(1_R) = [S=R]
```

検証される主張:

- 性質1/性質2: W_S(頂点) = δ、Σ_S W_S = 1（凸性拘束の立方体版）。
- Z の三角性: |T| > |R| なら T⊄R、対角は 1。これが一意性の全てを支える。
- 往復: mobius → zeta が元の真理値表に戻る＝正規形の一意性。
- OR = x1 ⊕ x2 ⊕ x1x2（a_∅=0, a_1=1, a_2=1, a_12=1）。再構成も一致。
- 最簡性: OR に一致する ANF マスクを全 16 通り列挙するとちょうど 1 個で項数 3。
  SOP 最小化が NP 困難であるのに対し、ANF はメビウス変換一回で決定的に求まる。

## CounterComputeSystem（CCS）

「GCLS-計算機理論」の実装。二進有理数 `type Dyad = (Integer, Int)`（値 = m/2^d）で
すべて正確に計算する。

```haskell
betaStep    :: Dyad -> Dyad            -- β(x) = (x+1)/2（Level 3 梯子の自己相似写像）
ladderPoint :: Int -> Dyad             -- t_n = 1 − 2^{−n}
omegaDy     :: Dyad                    -- ω = 1。β の不動点として有限に解ける
data Tape = Tape { rightBits, leftBits :: [Int], headPos :: Int }
step        :: Int -> Dir -> Tape -> Tape   -- 書き込み＋移動（定理2.2）
readBit     :: Tape -> Int                  -- s = ⌊2r⌋ に相当するヘッド読み
supFlag     :: [Int] -> Int                 -- ⋁（単調停止フラグの上限読み）
negD        :: Dyad -> Dyad                 -- ¬x = 1 − x。連続では不動点 1/2
phiPartial  :: Dyad -> Int                  -- φ∂: 二値抽出（唯一の非可逆操作）
negBit      :: Int -> Int                   -- 二値の ¬。不動点を持たない
```

検証される主張:

- 定理1.2: β(ω)=ω が一次方程式一本で確定。梯子の距離 1−t_n は各ステップで
  正確に半減する。
- 定理2.2: テープ表現 (rightBits, leftBits) は書き込み・右移動・左移動で保たれる。
  右移動は先頭桁を ω 側へ押し出し r を繰り上げる操作そのもの。
- 定理3.2: 単調フラグに対して停止 ⟺ ⋁h_n = 1。
- 定理4.2/系4.3: ¬ の不動点は連続 [0,1] では 1/2 に確定する（対角プログラムは
  矛盾ではなく確定値を返す）。二値 {0,1} の ¬ には不動点がない——対角化の
  足場はこちら側だけにある。
- 命題4.4: φ∂ は鋭い答えの上でのみ作用し、二値の ¬ と組み合わせても
  普通の問いの答えは鋭い二値で正しい。
