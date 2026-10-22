module CounterType where

import Data.Bits
import Data.Word
import Data.List (transpose)

-- doc: complex.matrix influence.boundary
-- 単体複体行列のための型。
-- 単体 = 頂点番号のビット集合 (Word64)、境界作用素 = inc ∈ {-1,0,1} の行列。

newtype Simplex = Simplex Word64 deriving (Eq, Ord, Show)

simplex :: [Int] -> Simplex
simplex vs = Simplex (foldr (\p acc -> setBit acc p) (zeroBits :: Word64) vs)

dim :: Simplex -> Int
dim (Simplex a) = popCount a - 1

vertices :: Simplex -> [Int]
vertices (Simplex a) = [p | p <- [0 .. 63], testBit a p]

-- ビット位置 p = 頂点番号。∂ の符号 (−1)^k の k = p 未満の立位ビット数
boundary :: Simplex -> [(Int, Simplex)]
boundary (Simplex a) =
  [ (sgn, Simplex (clearBit a p))
  | p <- [0 .. 63]
  , testBit a p
  , let sgn = if even (popCount (a .&. (bit p - 1))) then 1 else -1
  ]

incRow :: Simplex -> [Simplex] -> [Int]
incRow sigma faces =
  [sum [c | (c, f) <- boundary sigma, f == tau] | tau <- faces]

incMatrix :: [Simplex] -> [Simplex] -> [[Int]]
incMatrix sigmas faces = map (`incRow` faces) sigmas

-- 行 = σ_n 列 = σ_{n-1}
boundaryMatrix :: [Simplex] -> [Simplex] -> [[Int]]
boundaryMatrix faces sigmas = transpose (incMatrix sigmas faces)

-- ∂∘∂ = 0
d2Zero :: Simplex -> Bool
d2Zero sigma = all ((== 0) . snd) terms
  where
    terms = foldr bump [] [ (c * c', v)
                          | (c, e) <- boundary sigma
                          , (c', v) <- boundary e ]
    bump (k, x) [] = [(x, k)]
    bump (k, x) ((y, m) : rest)
      | x == y    = (y, m + k) : rest
      | otherwise = (y, m) : bump (k, x) rest
