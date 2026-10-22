{-# LANGUAGE NoImplicitPrelude #-}
module DagPlane where

import CounterConstraints
import RealUnit
import CounterInteger
import CounterUnits

-- ===== 「接合多様体としてのツイ数平面」と 6a/6c/6d =====
-- doc: plane.counter plane.junction bary.6c dyadic.6d simplex.canonical
--
-- 接合多様体: 平面 = Π_i ⊔_ℝ Π_j。両半平面は実軸でのみ接続される。
-- 6a: 四つの正準 2-単体 Q1..Q4 の同定
-- 6c: 重心座標 λ と拘束 Σλ = 1
-- 6d: 小数点以下 = 二進分割 k/2^n（分母は常に 2 の冪なので
--     λ は「共通分母 2^depth に対する分子三つ」として正確に持てる）

-- ===== 正準点の頂点割当 =====

pO, pOne, pI, pJ, pIJ, pJI, pNIJ, pNJI :: Int
pO   = oVertex                       -- O = (0,0)
pOne = minimum (map pointOf stdIntegers)   -- 整数 1
pI   = iBranchBase                   -- i = (0,+1) 方向の単位点
pJ   = jBranchBase                   -- j = (0,−1) 方向の単位点
pIJ  = 28                            -- ij = (+1,+1)
pJI  = 29                            -- ji = (+1,−1)
pNIJ = 30                            -- −ij = (−1,+1)
pNJI = 31                            -- −ji = (−1,−1)

-- ===== 6a: 正準 2-単体 =====

cellsP :: [Simplex]
cellsP = [q1, q2, q3, q4]

q1, q2, q3, q4 :: Simplex
q1 = simplex [pO, pI, pIJ]     -- ω 型アンカー側
q2 = simplex [pO, pI, pNIJ]
q3 = simplex [pO, pJ, pNJI]    -- ω⁻ 型アンカー側
q4 = simplex [pO, pJ, pJI]

facesP :: [Simplex]
facesP = foldr (\x acc -> x : filter (/= x) acc) []
               (concatMap (map snd . boundary) cellsP)

-- 行 = 面、列 = cell の単体複体行列 M_∂
mPartialP :: [[Int]]
mPartialP = transposeP (incMatrix cellsP facesP)

transposeP :: [[Int]] -> [[Int]]
transposeP = foldr (zipWith (:)) (repeat [])

data Side = Si | Sj deriving (Eq, Show)

sideOfCell :: Simplex -> Side
sideOfCell c | testBit m pI = Si
             | otherwise    = Sj
  where Simplex m = c

-- ===== 6c/6d: 重心座標（二進分割の分子表現）=====

-- 値 = 分子 / 2^depth。λ_O + λ_i(または λ_j) + λ_対角 == 2^depth が拘束
data CellPt = CellPt
  { ptCell  :: Simplex
  , lamNums :: (Int, Int, Int)
  , lamDep  :: Int
  } deriving (Eq, Show)

lawTotal :: CellPt -> Bool
lawTotal (CellPt _ (a, b, c) d) = a + b + c == shiftL (1 :: Int) d

-- T1 = (O, i, ij) 内の点 x=(a,b): λ_O = 2^d−b, λ_i = b−a, λ_ij = a
mkT1Pt :: Int -> Int -> Int -> CellPt
mkT1Pt a b d =
  CellPt q1 (shiftL (1 :: Int) d - b, b - a, a) d

vxOf, vyOf :: Int -> Int
vxOf p
  | p == pIJ || p == pJI   = 1
  | p == pNIJ || p == pNJI = negate 1
  | otherwise              = 0
vyOf p
  | p == pI || p == pIJ || p == pNIJ = 1
  | p == pJ || p == pJI || p == pNJI = negate 1
  | otherwise                        = 0

-- cell の頂点を「λ の並び順（O, 脚, 対角）」で返す。
-- 備考: boundary の昇順規約とは別の、重心座標用の提示順である
cellVertsP :: Simplex -> [Int]
cellVertsP c
  | c == q1   = [pO, pI, pIJ]
  | c == q2   = [pO, pI, pNIJ]
  | c == q3   = [pO, pJ, pNJI]
  | otherwise = [pO, pJ, pJI]

xyOf :: CellPt -> (Int, Int, Int)
xyOf (CellPt c (l0, l1, l2) d) =
  ( sum (zipWith (\l p -> l * vxOf p) ls ps)
  , sum (zipWith (\l p -> l * vyOf p) ls ps), d )
  where
    ps = cellVertsP c
    ls = [l0, l1, l2]

-- スケールが違う二つの座標の等値性（交叉乗算）
eqScaled :: (Int, Int, Int) -> (Int, Int, Int) -> Bool
eqScaled (x, y, d) (x', y', d') =
  shiftL x d' == shiftL x' d && shiftL y d' == shiftL y' d

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("接合: Πi 側(Q1,Q2) と Πj 側(Q3,Q4) は行を共有しない（実軸でのみ接続）",
      all ok mPartialP)
  , ("公理: inc ∈ {−1,0,1}", all (\e -> abs e <= 1) (concat mPartialP))
  , ("公理: ∂² = 0", all d2Zero cellsP)
  , ("M_∂ 形状 10×4", length mPartialP == 10 && all ((== 4) . length) mPartialP)
  , ("6a: side(Q1)=Si / side(Q4)=Sj",
      sideOfCell q1 == Si && sideOfCell q4 == Sj)
  , ("6c: 拘束 Σλ = 2^depth",
      all lawTotal [mkT1Pt a b d | d <- [2, 4], let s = shiftL (1 :: Int) d,
                                   a <- [1, s `div` 4], b <- [s - a]])
  , ("6c: 重心座標から xy への復元",
      eqScaled (xyOf (mkT1Pt 1 3 2)) (1, 3, 2)
      && eqScaled (xyOf (mkT1Pt 5 11 4)) (5, 11, 4))
  , ("6d: 分割深度を上げても同じ点である（k/2^n の精緻化）",
      eqScaled (xyOf (mkT1Pt 1 3 2)) (xyOf (mkT1Pt 4 12 4)))
  ]
  where
    ok r = let sup = [i | (i, e) <- zip [0 :: Int ..] r, e /= 0]
           in all (`elem` [0, 1]) sup || all (`elem` [2, 3]) sup

