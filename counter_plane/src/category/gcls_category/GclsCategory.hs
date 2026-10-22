{-# LANGUAGE NoImplicitPrelude #-}
module GclsCategory (module GclsCategory, module Quantale) where

import CounterConstraints
import CounterInteger (pointOf)
import CounterUnits (Op (..), UnitPoint (..), mkReal, applyI, applyJ, spotOf, omega, stdIntegers)
import DagPlane hiding (selfcheck)
import DagInfluence hiding (selfcheck)
import Quantale hiding (selfcheck)

-- ===== 影響圏 𝒢（圏論 第 I・II 部）=====
-- doc: cat.object cat.point cat.coherent cat.extensionality
-- doc: cat.morphism compose.star cat.identity cat.G
-- doc: star.noncommute pi.forget qcoeff
--
--   定義1.1  影響対象 𝐆 = (G, L, w)
--   定義1.2  点とは影響のプロファイル x̂ である
--   定義1.3  帰属の代替——整合性関係 ◁
--   命題1.4  外延性の幾何版
--   定義2.1  射と遷移係数 T_f(ℓ₁,ℓ₂) = w₂(ℓ₂, f(ℓ₁))
--   定理2.2  整合条件は結合的な合成律である
--   定理2.3  恒等射はクロネッカーの δ
--   定理2.4  影響圏 𝒢 の成立
--   定理3.1  ホムの非対称性
--   命題3.2  対称化は型忘却に等しい
--
-- 定義1.1〜1.4 と定義2.1 の幾何的な中身は DagInfluence（4章）が持つ。この module は
-- それを圏の言葉へ載せ替え、係数を 𝒬 へ広げる。広げる理由は定義5 の注にある:
-- 目印が i-型・j-型の寄与を持つとき、係数の乗算は順序を持つ。だから遷移係数は
-- QVal（形式和）で持ち、(2.1) の積は ⋆ になる。実成分だけの射は語が空の
-- QVal になるので、4章の GMor がそのまま部分系として入る。

-- ===== 定義2.1: 射 = 𝒬 係数の遷移行列 =====
--
-- 行 = 出発側の目印 ℓ₁、列 = 行先の目印 ℓ₂。行優先で持つ。

type MatQ = [[QVal]]

colsQ :: MatQ -> MatQ
colsQ []   = []
colsQ rows = foldr (zipWith (:)) (replicate (widthQ rows) []) rows

widthQ :: MatQ -> Int
widthQ (r : _) = length r
widthQ []      = 0

-- 定理2.3: 恒等射の遷移係数はクロネッカーの δ。
-- 目印が正準単体の頂点であるとき、6c の重心座標は対応成分だけ 1、他は 0 になる
matIdQ :: Int -> MatQ
matIdQ n = [ [ if i == j then qvOne else qvZero | j <- ks ] | i <- ks ]
  where ks = [0 .. n - 1]

-- 定理2.2 の (2.1):
--
--   T_{g∘f}(ℓ₁,ℓ₃) = ⊕_{ℓ₂} T_g(ℓ₂,ℓ₃) ⋆ T_f(ℓ₁,ℓ₂)
--
-- ⋆ の左に g、右に f が来る順序は式のとおりで、非可換なので入れ替えられない。
-- 和 ⊕ は 3章 の加算（平行四辺形則）。
matMulQ :: MatQ -> MatQ -> MatQ
matMulQ a b =
  [ [ qvSum (zipWith (\aij bjk -> qvStar bjk aij) row col) | col <- colsQ b ]
  | row <- a ]

-- 係数の積の順序を入れ替えた合成。定理3.1 を測るための対照であって、
-- 圏の合成ではない。実成分だけなら matMulQ と一致し、型付き寄与があると割れる
matMulQFlip :: MatQ -> MatQ -> MatQ
matMulQFlip a b =
  [ [ qvSum (zipWith (\aij bjk -> qvStar aij bjk) row col) | col <- colsQ b ]
  | row <- a ]

-- 4章の射（実成分のみ）を 𝒬 係数へ持ち上げる。語は空になる
matOfMor :: GMor -> MatQ
matOfMor (GMor rows) = [ [ qvOfRat c | c <- r ] | r <- rows ]

-- 頂点写像から作る δ 型の行列
matOfVertexMap :: Int -> Int -> (Int -> Int) -> MatQ
matOfVertexMap n m f = matOfMor (vertexMor n m f)

-- ===== 命題3.2: 対称化は型忘却に等しい =====
--
-- π を成分ごとに当てると、係数は大きさだけになり合成は可換化する。
-- これが 3章 の「加算は経路を忘れる」を係数の段で実行した操作にあたる。

type MatR = [[QRat]]

piMat :: MatQ -> MatR
piMat = map (map piQ)

matMulR :: MatR -> MatR -> MatR
matMulR a b =
  [ [ qsum (zipWith qratMul row col) | col <- colsR b ] | row <- a ]

colsR :: MatR -> MatR
colsR []   = []
colsR rows = foldr (zipWith (:)) (replicate (widthR rows) []) rows

widthR :: MatR -> Int
widthR (r : _) = length r
widthR []      = 0

-- ===== 定義1.2 / 定義1.3 / 命題1.4 =====
--
-- 点は中身を持たない。目印から測った値の並びがそのまま点になる。
-- 帰属 ∈ は消え、整合 ◁ が代わる。◁ は二値ではなく連続な量を伴う。

type Point = Profile

coherent :: GObj -> Point -> Bool
coherent = constraintsHold

-- 命題1.4。プロファイルが一致することと点が同一であることが同値。
-- 逆向きの復元（プロファイル → 作図の比の列）は DagInfluence が持つ
samePoint :: Point -> Point -> Bool
samePoint = (==)

-- ===== 定義2.1 の (⋆): 点の像 =====
--
--   w₂(ℓ₂, f(x)) = ⊕_{ℓ₁} T_f(ℓ₁,ℓ₂) ⋆ w₁(ℓ₁,x)
--
-- 点の側も 𝒬 の元として持つと、型付きの目印を持つ図形でも同じ式で書ける。

type PointQ = [QVal]

pointQOf :: Point -> PointQ
pointQOf = map qvOfRat

applyQ :: PointQ -> MatQ -> PointQ
applyQ x m = [ qvSum (zipWith (\xi mij -> qvStar mij xi) x col) | col <- colsQ m ]

-- ===== 第 II 部: 非可換性が運ぶもの =====
--
-- 定理3.1。実成分のみの射の合成は可換だが、型付き寄与を含む合成は非可換で、
-- その非可換性は厳密に ij = (+1,+1)、ji = (+1,−1)、ij ≠ ji に由来する。
--
-- 型付きの目印を持つ射の例。i 型の寄与を運ぶ行列と j 型の寄与を運ぶ行列。

iMat, jMat :: MatQ
iMat = [ [ qvOfCoeff iUnitQ, qvZero ]
       , [ qvZero, qvOne ] ]
jMat = [ [ qvOfCoeff jUnitQ, qvZero ]
       , [ qvZero, qvOne ] ]

-- 実成分のみの射。μ = 1 の像と同じ振る舞いになる
realMatA, realMatB :: MatQ
realMatA = [ [ qvOfRat (QRat 1 2), qvOfRat (QRat 1 2) ]
           , [ qvOfRat (QRat 1 4), qvOfRat (QRat 3 4) ] ]
realMatB = [ [ qvOfRat (QRat 1 3), qvOfRat (QRat 2 3) ]
           , [ qvOfRat qratOne,    qvOfRat qratZero   ] ]

-- 型付きの寄与を混ぜた射。3章③ の一般の積が効く場所
mixedQA, mixedQB, mixedQC :: MatQ
mixedQA = [ [ qvAdd (qvOfRat (QRat 1 2)) (qvOfCoeff (QCoeff 1 1 [I] 1))
            , qvOfRat (QRat 1 2) ]
          , [ qvOfCoeff (QCoeff 1 2 [J] 1)
            , qvAdd (qvOfRat (QRat 3 4)) (qvOfCoeff (QCoeff 1 2 [I,J] 1)) ] ]
mixedQB = [ [ qvOfCoeff (QCoeff 1 1 [J] 1)
            , qvAdd (qvOfRat (QRat 1 4)) (qvOfCoeff (QCoeff 1 1 [I] 1)) ]
          , [ qvOfRat (QRat 2 3), qvOfCoeff (QCoeff 1 0 [I] 1) ] ]
mixedQC = [ [ qvOfRat (QRat 1 5), qvOfCoeff (QCoeff 3 2 [I] 1) ]
          , [ qvAdd (qvOfCoeff jUnitQ) (qvOfRat (QRat 1 3))
            , qvOfRat (QRat 1 2) ] ]

-- ===== 定理2.4 の対象側: 標本となる影響対象 =====

t1Cat :: GObj
t1Cat = GObj RConvex 3

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("定義1.2: 点は中身を持たない。目印から測った値の並びがそのまま点になる",
      let p = profileOfCellPt (mkT1Pt 1 3 2)
      in profileRank p == gRank t1Cat && p == profileOfDescent (Descent [QRat 1 4, QRat 2 3]))

  , ("定義1.3: 整合 ◁ は Σw = 1 かつ w ≥ 0。二値ではなく連続な量を伴う",
      coherent t1Cat (profileOfCellPt (mkT1Pt 1 3 2))
      && coherent t1Cat (profileOfCellPt (mkT1Pt 5 11 4))
      && not (coherent t1Cat [QRat 1 2, QRat 1 2, QRat 1 2]))

  , ("命題1.4: プロファイルの一致が点の同一性（外延性の幾何版）",
      let p = profileOfCellPt (mkT1Pt 1 3 2)
      in samePoint (profileOfCellPt (mkT1Pt 4 12 4)) p
         && not (samePoint (profileOfCellPt (mkT1Pt 2 3 2)) p))

  , ("定理2.3: 恒等射の遷移係数はクロネッカーの δ",
      matIdQ 3 == matOfVertexMap 3 3 id)

  , ("定理2.3: δ は (2.1) の両側単位元（型付き成分を含む射でも）",
      matMulQ (matIdQ 2) mixedQA == mixedQA
      && matMulQ mixedQA (matIdQ 2) == mixedQA)

  , ("定理2.2: (2.1) は結合的である — 型付き成分を含む三つの射で確かめる",
      matMulQ (matMulQ mixedQA mixedQB) mixedQC
        == matMulQ mixedQA (matMulQ mixedQB mixedQC))

  , ("定理2.2: 結合性は ⋆ の結合性に帰着する。非可換性は結合性を壊さない",
      matMulQ mixedQA mixedQB /= matMulQ mixedQB mixedQA
      && matMulQ (matMulQ mixedQB mixedQA) mixedQC
           == matMulQ mixedQB (matMulQ mixedQA mixedQC))

  , ("定理2.2: 頂点写像の合成は T_{g∘f} = T_g · T_f を満たす",
      let vs = 5
          f v = mod (v + 1) vs
          g v = mod (v * 3) vs
      in matMulQ (matOfVertexMap vs vs f) (matOfVertexMap vs vs g)
           == matOfVertexMap vs vs (\v -> g (f v)))

  , ("定理2.2: 実成分だけの射では 4章の (2.1) と同じ結果になる",
      matMulQ (matOfMor mixedMor) (matOfMor mixedMor2)
        == matOfMor (composeMor mixedMor mixedMor2))

  , ("定理3.1: ホムの非対称性 — ij ≠ ji が行列の段まで貫く",
      matMulQ iMat jMat /= matMulQ jMat iMat)

  , ("定理3.1: 非可換性は型から出る。大きさは等しい",
      let ij = matMulQ iMat jMat
          ji = matMulQ jMat iMat
      in piMat ij == piMat ji
         && qvWords (qvSum (concat ij)) /= qvWords (qvSum (concat ji)))

  , ("定理3.1: 実成分のみの射では係数の積が順序に依らない（Q1 と Q4 の区別が消える）",
      matMulQ realMatA realMatB == matMulQFlip realMatA realMatB)

  , ("定理3.1: 型付き寄与を含むと係数の積の順序が結果を変える",
      matMulQ mixedQA mixedQB /= matMulQFlip mixedQA mixedQB)

  , ("命題3.2: π の像では ij と ji が一致し、合成が可換化する",
      matMulQ iMat jMat /= matMulQ jMat iMat
      && piMat (matMulQ iMat jMat) == piMat (matMulQ jMat iMat)
      && matMulR (piMat iMat) (piMat jMat) == matMulR (piMat jMat) (piMat iMat))

  , ("命題3.2: 実成分だけの射では π が合成をそのまま送る",
      piMat (matMulQ (matOfMor mixedMor) (matOfMor mixedMor2))
        == matMulR (piMat (matOfMor mixedMor)) (piMat (matOfMor mixedMor2)))

  , ("定義2.1: 点の像は (⋆) で与えられる。行列の合成と可換する",
      let x = pointQOf (profileOfCellPt (mkT1Pt 1 3 2))
          f = matOfMor mixedMor
          g = matOfMor mixedMor2
      in applyQ (applyQ x f) g == applyQ x (matMulQ f g))

  , ("定理2.4: 圏の公理が揃う — 恒等・結合・(⋆) の整合",
      matMulQ (matIdQ 3) (matOfMor mixedMor) == matOfMor mixedMor
      && matMulQ (matOfMor mixedMor) (matIdQ 3) == matOfMor mixedMor
      && convexMor (composeMor mixedMor mixedMor2))

  , ("定理3.1 の幾何的起源: ij は Q1 を、ji は Q4 を経由する",
      sideOfCell q1 == Si && sideOfCell q4 == Sj)

  , ("格付け: 実軸断面は型を忘れた側にのみある（μ: ∞ → 1 は一方向的）",
      spotOf (applyI (applyJ originP)) == spotOf (applyJ (applyI originP))
      && applyI (applyJ originP) /= applyJ (applyI originP))

  , ("命題3.6: ω はどの有限深度の整数でもない（作図到達不能点）",
      all (\ci -> pointOf ci < omega) stdIntegers)
  ]
  where
    originP = mkReal pO 1
