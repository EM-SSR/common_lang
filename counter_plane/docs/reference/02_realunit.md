# 02 RealUnit（Level 0〜2: 領域・境界・実数・負化）

## 役割

直線複体の上に Level 0〜2 の原始概念を実装する。領域は辺の鎖（ビット集合）、境界 ∂ は
単体複体行列 M_∂ の作用、実数は開半直線への ∂ の出力、負化は O を挟む反転。
「実数とは境界操作の出力である」という Level 1 の定義の直訳が `boundaryOutput` である。

## 直線複体

| 名前 | 意味 |
|---|---|
| `offset = 32` | O のビット位置 |
| `oVertex` | O の頂点番号 |
| `positionOf p` | 頂点 p の位置 (p − offset)。H⁻ 側は負になる |
| `edgeAt e` | 辺 [v_e, v_{e+1}] |

O を中心に置くことで H⁺/H⁻ 両側を一つの Word64 に載せ、反転をビット鏡映として書ける。

## Level 0: 領域とその操作

```haskell
newtype Region = Region Word64    -- 辺番号の集合（鎖）
region        :: [Int] -> Region
hasEdge       :: Region -> Int -> Bool
isConnected   :: Region -> Bool   -- 空領域は False
isPath        :: Region -> Bool   -- 道 = 連結な領域。向きは昇順
overlaps      :: Region -> Region -> Bool     -- 重なり: 内部（辺）共有
contains      :: Region -> Region -> Bool     -- contains x y ≡ y ⊆ x
adjacent      :: Int -> Int -> Bool           -- 隣接: |e − f| == 1
commonPart    :: Region -> Region -> Region   -- 共通部 = AND
combine       :: Region -> Region -> Region   -- 合わせ   = OR
exteriorIn    :: Region -> Region -> Region   -- 外側 = 第1引数（宇宙）内の補集合
boundaryRegion:: Region -> [(Int, Int)]       -- ∂: (頂点, 係数)
```

### 使用例

```
ghci> boundaryRegion (region [3..6])
[(7,1),(3,-1)]
```

道 [3..6] の ∂ は終点 (+1) と始点 (−1) だけを持つ。内部頂点 v4,v5,v6 は
+1 と −1 の寄与が打ち合って係数 0 になり、出力から除かれる。これが
「道を切断すると正セグメントと負セグメントに分かつ」ことの代数的な顔である。

定義: `boundaryRegion` は係数 0 の頂点を出力から除く。したがって道の境界は
常にちょうど二つの端点からなる。

定義: `exteriorIn u r` は宇宙 u 内での補集合を返す。無限直線全体は扱えず、
宇宙の外は次の構成（Level 3 以降の残余）へ委ねられる。

## Level 1: 実数

```haskell
data RealNum = RealNum { vertexOf :: Int, coeffOf :: Int }
halfPlus       :: Int -> Region          -- O から正方向へ hi まで
halfMinus      :: Int -> Region          -- lo から O の手前まで
boundaryOutput :: Region -> Maybe RealNum
```

`boundaryOutput` は構成済み側の端点 O を返す。H⁺ 側では係数 −1、H⁻ 側では +1。
反対側の端は未構成（ω 方向）なので決して出力にならない。

```
ghci> boundaryOutput (halfPlus (oVertex + 3))
Just (RealNum {vertexOf = 32, coeffOf = -1})
ghci> boundaryOutput (halfMinus (oVertex - 3))
Just (RealNum {vertexOf = 32, coeffOf = 1})
```

同じ O が両側で異なる符号を持つ——これが H⁺/H⁻ の非対称性の最初の現れであり、
Level 4/5 で i と j が別物になる根拠になる。

備考: 実数は複体の頂点として存在し、座標系に依存しない。座標値が必要な場面では
`positionOf` を明示的に呼ぶ。

## Level 2: 負化

```haskell
negateR      :: RealNum -> RealNum   -- O 対称の鏡像＋符号反転
negateRegion :: Region -> Region     -- 辺の鏡像: e ↦ 2·offset − e − 1
```

不変条件（いずれも検証コードあり）:

1. 反転は対合である。`negateR (negateR x) == x`
2. 反転後の位置は O に関して対称である。`vertexOf x + vertexOf (negateR x) == 2·offset`
3. 外側(H⁻) = H⁺。反転は半平面をもう一方へ写す。

```
ghci> negateR (RealNum 34 1)
RealNum {vertexOf = 30, coeffOf = -1}
```

## 落とし穴

- `contains x y` は「y が x に含まれる」。引数順に注意（過去に逆にしたバグが出た）。
- `isConnected` は空領域に対して False を返す。
- 除算（タレス構成）はこのモジュールにはない。除算は平面と四則演算の層に属し、
  dag 層の DagArith.divideThales として実装されている。
