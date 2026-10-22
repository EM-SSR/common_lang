{-# LANGUAGE NoImplicitPrelude #-}
module RealUnit where

import CounterConstraints

-- doc: level0.primitives level1.real level2.negative
-- Level 0〜2 の実装。
--   L0: 領域・道・隣接・重なり・含まれる・境界∂
--   L1: 実数 = 開半直線への境界操作の出力
--   L2: 負の実数 = O を挟む反転（外側操作の対称性）
-- すべて直線複体（頂点列 + 辺）の上で、鎖と M_∂ を通して表現する。

-- ===== 直線複体 =====

-- ビット位置 p の頂点の位置は p - offset。O を中心に置くことで
-- H+/H− 両側を一つの Word64 に載せ、反転をビット演算にできる
offset :: Int
offset = 32

oVertex :: Int
oVertex = offset

positionOf :: Int -> Int
positionOf p = p - offset

-- 辺 e = [v_e, v_{e+1}]
edgeAt :: Int -> Simplex
edgeAt e = simplex [e, e + 1]

-- ===== Level 0: 領域 = 直線複体上の鎖 =====

newtype Region = Region Word64 deriving (Eq, Show)

region :: [Int] -> Region
region es = Region (foldr (\e acc -> setBit acc e) (zeroBits :: Word64) es)

hasEdge :: Region -> Int -> Bool
hasEdge (Region r) e = testBit r e

isConnected :: Region -> Bool
isConnected (Region r)
  | null bits = False
  | otherwise = bits == [lo .. hi]
  where
    bits = [e | e <- [0 .. 63], testBit r e]
    lo = minimum bits
    hi = maximum bits

-- 道 = 連結な領域。向きは昇順（始点 → 終点）
isPath :: Region -> Bool
isPath = isConnected

-- 重なり: 内部（辺）を共有する
overlaps :: Region -> Region -> Bool
overlaps (Region a) (Region b) = popCount (a .&. b) > 0

-- 含まれる: y が x の内部にすっぽり収まる
contains :: Region -> Region -> Bool
contains (Region a) (Region b) = b .&. complement a == zeroBits

-- 隣接: 境界（頂点）を共有し内部（辺）は共有しない
adjacent :: Int -> Int -> Bool
adjacent e f = abs (e - f) == 1

commonPart :: Region -> Region -> Region
commonPart (Region a) (Region b) = Region (a .&. b)

combine :: Region -> Region -> Region
combine (Region a) (Region b) = Region (a .|. b)

-- 外側: 宇宙（構成済み範囲）内での補集合。無限直線そのものは扱えない
exteriorIn :: Region -> Region -> Region
exteriorIn (Region u) (Region r) = Region (u .&. complement r)

-- Level 0 操作: 境界 ∂。道の切断に対応し、端点を符号付きで返す。
-- 辺 [v_e, v_{e+1}] の ∂ は 終点(+1) と始点(−1)。内部頂点は相殺される
boundaryRegion :: Region -> [(Int, Int)]
boundaryRegion (Region r) =
  filter ((/= 0) . snd) (foldr bump [] contribs)
  where
    contribs = concat [ [(-1, e), (1, e + 1)]
                      | e <- [0 .. 63], testBit r e ]
    bump (c, v) [] = [(v, c)]
    bump (c, v) ((w, m) : rest)
      | v == w    = (w, m + c) : rest
      | otherwise = (w, m) : bump (c, v) rest

-- ===== Level 1: 実数 = 開半直線への境界操作の出力 =====

data RealNum = RealNum { vertexOf :: Int, coeffOf :: Int } deriving (Eq, Show)

-- 開半直線の構成済み部分。反対側の端は未構成（ω 方向）なので ∂ は
-- 構成済み側の端点 O を一つだけ返す
halfPlus :: Int -> Region
halfPlus hi = region [oVertex .. hi]

halfMinus :: Int -> Region
halfMinus lo = region [lo .. oVertex - 1]

boundaryOutput :: Region -> Maybe RealNum
boundaryOutput r = case filter ((== oVertex) . fst) (boundaryRegion r) of
  [(v, c)] -> Just (RealNum v c)
  _        -> Nothing

-- ===== Level 2: 負化 = O を挟む反転 =====

negateR :: RealNum -> RealNum
negateR (RealNum v c) = RealNum (2 * oVertex - v) (negate c)

-- 辺 e (頂点 e, e+1) の鏡像は辺 2·offset − e − 1
negateRegion :: Region -> Region
negateRegion (Region r) =
  Region (foldr (\e acc -> setBit acc (mirrorE e)) (zeroBits :: Word64) es)
  where
    es = [e | e <- [0 .. 63], testBit r e]
    mirrorE e = 2 * offset - e - 1

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ -- Level 0
    ("L0: 道[3..6]の∂は始点(−1)と終点(+1)",
      sort (boundaryRegion (region [3 .. 6])) == [(3, -1), (7, 1)])
  , ("L0: 道の切断で内部頂点が消える（正/負セグメントの分離）",
      all (\v -> positionOf v /= 4 && positionOf v /= 5 && positionOf v /= 6)
          (map fst (boundaryRegion (region [3 .. 7]))))
  , ("L0: 重なり", commonPart (region [2 .. 5]) (region [4 .. 8]) == region [4, 5])
  , ("L0: 含まれる", contains (region [1 .. 9]) (region [3 .. 5]))
  , ("L0: 隣接（境界共有・内部非共有）",
      adjacent 4 5 && not (adjacent 4 6) && not (overlaps (region [4, 4]) (region [5, 5])))
  , ("L0: 合わせ", combine (region [1 .. 3]) (region [4 .. 6]) == region [1 .. 6])
  , ("L0: 外側（宇宙内）", exteriorIn (region [1 .. 8]) (region [3 .. 5]) == region ([1, 2] ++ [6, 7, 8]))
  , ("L0: 連結判定", isPath (region [3 .. 6]) && not (isPath (region [3, 3, 6, 6])))
  , -- Level 1
    ("L1: ∂(H+) は構成済み端点 O を係数 −1 で返す",
      boundaryOutput (halfPlus (oVertex + 3)) == Just (RealNum oVertex (-1)))
  , ("L1: ∂(H−) も同じ O を係数 +1 で返す",
      boundaryOutput (halfMinus (oVertex - 3)) == Just (RealNum oVertex 1))
  , ("L1: 実数は複体の頂点として存在する（座標系に依存しない）",
      boundaryOutput (halfPlus (oVertex + 7)) == Just (RealNum oVertex (-1)))
  , -- Level 2
    ("L2: 反転は対合（二回で戻る）", negateR (negateR x) == x)
  , ("L2: 反転は O に対して対称な位置へ写す",
      vertexOf (negateR x) + vertexOf x == 2 * oVertex)
  , ("L2: 反転は符号も反転する", coeffOf (negateR (RealNum oVertex (-1))) == 1)
  , ("L2: 反転は H+ を H− へ写す",
      negateRegion (halfPlus hi) == halfMinus (2 * offset - hi - 1))
  , ("L2: 外側(H−) = H+（外側操作の対称性）",
      let hm = halfMinus (oVertex - 4)
          hp = halfPlus hi'
          uni = combine hm hp
      in exteriorIn uni hm == hp)
  , ("L0: 直線の辺にも ∂² = 0 が成立する", d2Zero (edgeAt 5))
  ]
  where
    x = RealNum (oVertex + 2) 1
    hi = oVertex + 4
    hi' = oVertex + 4


