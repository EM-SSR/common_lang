# 01 CounterType（土台: 単体複体行列）と CounterConstraints

## 役割

CounterType はこの系の唯一の表現基盤である。単体をビット集合として持ち、境界作用素と
接続行列を提供する。上位モジュールはここで定義した型と規約からだけ演繹される。
CounterConstraints は語彙ゲートであり、派生モジュールが持ち込める base 語彙を列挙する。

## API

```haskell
newtype Simplex = Simplex Word64        -- 頂点番号のビット集合
simplex      :: [Int] -> Simplex        -- 頂点番号リストから単体を構成
dim          :: Simplex -> Int          -- 次元 = popCount − 1
vertices     :: Simplex -> [Int]        -- 昇順の頂点番号列
boundary     :: Simplex -> [(Int, Simplex)]   -- ∂: (符号, 面)
incRow       :: Simplex -> [Simplex] -> [Int]
incMatrix    :: [Simplex] -> [Simplex] -> [[Int]]   -- (n単体)×(n−1面)
boundaryMatrix :: [Simplex] -> [Simplex] -> [[Int]] -- 行=σ_n, 列=σ_{n−1}
d2Zero       :: Simplex -> Bool         -- ∂∘∂ = 0 の検算
```

## 規約

1. ビット位置 p は頂点番号 v_p を表す。頂点番号は大域固定であり、単体ごとに付け直さない。
2. `boundary` の符号 (−1)^k の k は「単体内での昇順ランク」、すなわち
   `popCount (a .&. (bit p - 1))` の偶奇である。これは「k 番目に立ったビット」ではない。
   過去にこの誤解釈でバグを出した経緯があるため、明示してある。

### 例: Q1 = (O, i, ij) = {0, 1, 3} の境界

```
ghci> boundary (simplex [0,1,3])
[(-1, {0,3}), (1, {1,3}), (1, {0,1})]
```

除く頂点 v0=O はランク 0 → +1 で面 {i,ij}、v1=i はランク 1 → −1 で面 {O,ij}、
v3=ij はランク 2 → +1 で面 {O,i}。∂Q1 = [i,ij] − [O,ij] + [O,i] がそのまま出る。

∂² = 0 も同じ列で書き下せる:

```
(+[v3] − [v1]) − (+[v3] − [v0]) + (+[v1] − [v0]) = 0
```

## 不変条件

- 任意の単体 σ に対して `d2Zero σ == True` でなければならない。これは機械検証可能であり、
  検証コードが常時確認している。
- `incMatrix` / `boundaryMatrix` の全成分は {−1, 0, 1} に属さなければならない。

## 使用上の注意

- `Simplex` は Word64 を包む newtype なので、64 頂点が上限である。それ以上の頂点数が必要な
  場合は構成を分割するか、層ごとに別の番号表を使う。
- `simplex` に重複した頂点番号を渡してもエラーにはならないが、意味は「和集合」になる。
- 面の列挙順はビット位置の昇順であり、「提示順」とは無関係である。重心座標など提示順が
  意味を持つ文脈では、DagPlane の `cellVertsP` のように別途順序を管理する。

## CounterConstraints（語彙ゲート）

派生モジュールは `{-# LANGUAGE NoImplicitPrelude #-}` を付けて
`import CounterConstraints` のみを行う。語彙に含まれるもの:

- 型: Bool, Maybe, Char/String, Eq/Ord/Show/Read, Int, Integer, Word64
- クラス: Num(..), Enum(..), Integral(..)（div/mod/toInteger を含む）
- リスト操作: map filter foldr foldl concat concatMap reverse length null all any and elem
  notElem sum zip zipWith lookup (++) repeat replicate take drop maximum minimum sort
- 補助: not otherwise maybe (&&)(||) even odd uncurry curry flip const id (.) ($)
- Bits: setBit clearBit testBit complement popCount zeroBits bit shiftL shiftR (.&.)(.|.) xor

含まれないもの: Rational・Complex 等の数体系、head/tail などの部分関数、IO 系すべて。
幾何的概念は必ず CounterType から演繹されなければならず、base 語彙は記帳用に限る。

備考: SelfCheck.hs（src/spec）は検証ランナーであり、この規則の適用外である。
