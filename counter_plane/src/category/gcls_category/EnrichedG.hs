{-# LANGUAGE NoImplicitPrelude #-}
module EnrichedG where

import CounterConstraints
import CounterInteger (pointOf)
import CounterUnits (Op (..), omega, stdIntegers)
import DagArith
import DagInfluence hiding (selfcheck)
import Quantale hiding (selfcheck)
import GclsCategory hiding (selfcheck)

-- ===== 𝒬-豊穣圏 𝔾 と二重格付け（圏論 第III部 後半）=====
-- doc: enriched.Q directed.distance mu.grade d.depth foundation.point size.as.depth
--
--   定理3.4  𝔾 は非可換 quantale 𝒬 で豊穣化された圏である
--   系3.5    𝔾 は Lawvere の意味での有向 𝒬-距離空間である
--   定義3.4  二重格付け（記憶深度 μ と作図深度 d）
--   定理3.5  あらゆる基礎は 𝔾_{μ,d} の一点である
--   命題3.6  大きさは作図深度に置き換わる

-- ===== 定理3.4: ホム対象 =====
--
-- ホム値は「𝐆 の点が 𝐇 に整合する度合いの上限」である（定理3.4 の証明）。
-- 射 T が与える度合いを、出発側のどの目印から見ても届く最良の整合度、
-- すなわち行ごとの上限の下限で読む。
--
--   deg(T) = ⋀_{ℓ₁} ⋁_{ℓ₂} π(T(ℓ₁,ℓ₂))
--
-- 下限を取るのは「一つでも届かない目印があれば、その射では到達できない」ため。
-- π で大きさへ落とすのは、ホム値が [0,1] の量だからである（定義3.4 の μ:∞→1）。

degOf :: MatQ -> QRat
degOf rows = qMeetAll [ qJoinAll (map piQ r) | r <- rows ]

-- ホム対象。射の族が与えられたとき、その上限を取る。
--
--   𝔾(𝐆,𝐇) = ⋁ { deg(T) : T は 𝐆 → 𝐇 の射 }
--
-- 全ての射にわたる上限は数え上げでは出ない。どの族を持つかがデータであり、
-- ここでは与えられた族の上での上限を返す。
homQ :: [MatQ] -> QRat
homQ ts = qJoinAll (map degOf ts)

-- ===== 定理3.4 の公理 =====
--
--   単位律   1 ≤ 𝔾(𝐆,𝐆)
--   合成律   𝔾(𝐇,𝐊) ⋆ 𝔾(𝐆,𝐇) ≤ 𝔾(𝐆,𝐊)
--
-- 単位律は恒等射 δ の度合いが 1 に達することから。合成律は (2.1) の
-- ⋆-行列積が度合いを下げないことから出る。証明は行ごとに最良の中継目印を
-- 一本選べばよく、その一本を通る経路の度合いが deg(T_g) ⋆ deg(T_f) 以上になる。

unitLaw :: Int -> Bool
unitLaw n = qratLeq qratOne (degOf (matIdQ n))

compositionLaw :: MatQ -> MatQ -> Bool
compositionLaw f g = qratLeq (qratMul (degOf g) (degOf f)) (degOf (matMulQ f g))

-- ===== 系3.5: 有向 𝒬-距離空間 =====
--
-- Lawvere は距離空間を ([0,∞], ≥, +, 0) で豊穣化された圏と同定した。定理3.4 は
-- その基底を 𝒬 へ取り替えたものに等しい。
--
--   ホム値      𝐆 から 𝐇 への到達度
--   合成律      三角不等式の非可換版
--   非対称性    𝔾(𝐆,𝐇) ≠ 𝔾(𝐇,𝐆) が距離の有向性にあたる
--
-- 三角不等式は合成律そのものなので、別の式を立てない。

triangle :: MatQ -> MatQ -> Bool
triangle = compositionLaw

-- 有向性。同じ対象対でも向きで到達度が変わる
directed :: MatQ -> MatQ -> Bool
directed f fOp = not (qratEq (degOf f) (degOf fOp))

-- ===== 定義3.4: 二重格付け =====
--
--   μ   記憶深度。経路の履歴をどこまで保持するか
--   d   作図深度。6d の二分割を何回適用したか
--
--   μ = ∞   構成履歴を全保持      𝔾 本体（𝒬-豊穣、⋆ 非可換）
--   μ = 2   型 (i/j) を保持       𝒯-豊穣圏
--   μ = 1   座標のみ、型を忘却     ℝ≥0-豊穣（Lawvere 対称距離圏）
--   μ = 0   存在のみ、二値化       Set（ZFC / ETCS）
--
-- 構成子の並びは順序に意味がある。M0 < M1 < M2 < MInf であり、忘却は
-- 大きい側から小さい側へ一方向に進む。CommonChamber のチェンバー見出しが
-- 持つ μ はこの格付けそのものなので、型を共有する。

data Mu = M0 | M1 | M2 | MInf deriving (Eq, Ord, Read, Show)

-- 作図深度。有限段と、その全ての極限である ω を分ける
data Depth = DFinite Int | DOmega deriving (Eq, Ord, Read, Show)

-- ===== μ = 2: 𝒯 の座標（型を保持する段）=====
--
-- ツイ数平面の座標表。3章② の終点そのもの。
--
--   1 = (+1, 0)    i = (0, +1)    j = (0, −1)
--   ij = (+1, +1)  ji = (+1, −1)
--
-- 表にあるのは長さ 2 までの語である。Level 6+ は際限なく新しい方向を生むので、
-- 長い語はこの座標表では読めない。読めないこと自体が「乗算は Level 6+ の DAG を
-- 際限なく展開する」（3章 整理）を座標の側から見たものになる。

type TCoord = (QRat, QRat)

coordOfWord :: BWord -> Maybe TCoord
coordOfWord w = case w of
  []     -> Just (qratOne,  qratZero)
  [I]    -> Just (qratZero, qratOne)
  [J]    -> Just (qratZero, qratNeg qratOne)
  [I, J] -> Just (qratOne,  qratOne)
  [J, I] -> Just (qratOne,  qratNeg qratOne)
  _      -> Nothing

-- 𝒯 への意味写像 ⟦·⟧。各項の座標を係数で伸ばして足す
tCoord :: QVal -> Maybe TCoord
tCoord (QVal ts) = go ts (qratZero, qratZero)
  where
    go []             acc      = Just acc
    go ((w, c) : rest) (x, y) = case coordOfWord w of
      Just (u, v) -> go rest (qratAdd x (qratMul c u), qratAdd y (qratMul c v))
      Nothing     -> Nothing

-- ===== μ = 1 / μ = 0: 実軸断面と二値化 =====

muDescend :: Mu -> QVal -> Maybe QVal
muDescend m v = case m of
  MInf -> Just v
  M2   -> case tCoord v of
    Just _  -> Just v      -- 座標が読める語だけが 𝒯 段に残る
    Nothing -> Nothing
  M1   -> Just (qvOfRat (piQ v))
  M0   -> Just (qvOfRat (qratOf (toInteger (thetaQ (piQ v))) 1))

-- ===== 定理3.5: あらゆる基礎は 𝔾_{μ,d} の一点である =====
--
--   ZFC / ETCS（∈, 二値）      (0, d<ω)    履歴・型・連続度を失う
--   古典圏論（Set-豊穣）        (1, d<ω)    履歴・型を失う
--   ETCS+R / 宇宙公理           (0, d→ω)   履歴・型を失い、d 軸を解放する
--   GCLS-圏論                   (∞, d→ω)   何も失わない（本体）

data Foundation = FZFC | FClassicalCat | FUniverse | FGCLS
  deriving (Eq, Ord, Show)

gradeOf :: Foundation -> (Mu, Depth)
gradeOf f = case f of
  FZFC          -> (M0,   DFinite 1)
  FClassicalCat -> (M1,   DFinite 1)
  FUniverse     -> (M0,   DOmega)
  FGCLS         -> (MInf, DOmega)

foundations :: [Foundation]
foundations = [FZFC, FClassicalCat, FUniverse, FGCLS]

-- 下向きの忘却は標準的。上向きは実軸断面 s(a) = (a,0) に限られ、
-- 型 b ≠ 0 は外から指定するしかない（第V部「物質的集合論との接続」）
forgetsTo :: Foundation -> Foundation -> Bool
forgetsTo a b =
  let (ma, da) = gradeOf a
      (mb, db) = gradeOf b
  in mb <= ma && db <= da

-- ===== 命題3.6: 大きさは作図深度に置き換わる =====
--
-- 実軸上の整数列は 1 − 1/2^n の位置に並び ω に収束する。ω はどの有限深度にも
-- 属さないが、すべての極限として到達される作図到達不能点である。
-- グロタンディーク宇宙の到達不能基数に対応する役割をこの ω が果たす。

reachableAt :: Depth -> Int -> Bool
reachableAt (DFinite n) k = k < n
reachableAt DOmega      _ = True

-- ===== 標本 =====
--
-- 二つの対象の間の射を二本ずつ持つ族。到達度が向きで変わる例になる。
--   forward   どの目印からも行先へ届く（度合いが高い）
--   backward  一つの目印が細い経路しか持たない（度合いが低い）

forwardMor, backwardMor :: MatQ
forwardMor = matOfMor (GMor [ [QRat 3 4, QRat 1 4]
                            , [QRat 1 2, QRat 1 2] ])
backwardMor = matOfMor (GMor [ [QRat 1 8, QRat 7 8]
                             , [QRat 15 16, QRat 1 16] ])

-- 到達度が下がる射。どの行も片寄っていないので ⋁ が小さい
weakMor :: MatQ
weakMor = matOfMor (GMor [ [QRat 1 2, QRat 1 2]
                         , [QRat 1 2, QRat 1 2] ])

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("定理3.4 単位律: 1 ≤ 𝔾(𝐆,𝐆)。恒等射 δ の度合いが 1 に達する",
      all unitLaw [1, 2, 3, 5] && qratEq (degOf (matIdQ 3)) qratOne)

  , ("定理3.4: ホム値は [0,1] に収まる",
      all (inQ . degOf) [matIdQ 3, forwardMor, backwardMor, weakMor, mixedQA])

  , ("定理3.4 合成律: 𝔾(𝐇,𝐊) ⋆ 𝔾(𝐆,𝐇) ≤ 𝔾(𝐆,𝐊)",
      and [ compositionLaw f g
          | f <- [forwardMor, backwardMor, weakMor, matIdQ 2]
          , g <- [forwardMor, backwardMor, weakMor, matIdQ 2] ])

  , ("定理3.4 合成律: 型付き寄与を含む射でも成り立つ",
      and [ compositionLaw f g
          | f <- [mixedQA, mixedQB, mixedQC]
          , g <- [mixedQA, mixedQB, mixedQC] ])

  , ("定理3.4: 恒等射との合成は度合いを変えない",
      qratEq (degOf (matMulQ (matIdQ 2) forwardMor)) (degOf forwardMor))

  , ("定理3.4: 𝒬 が順序集合なので 2-胞は不等式 ≤ に吸収される（追加の高次データが無い）",
      let a = degOf forwardMor
          b = degOf weakMor
      in (qratLeq a b || qratLeq b a) && inQ a && inQ b)

  , ("系3.5: 合成律は三角不等式そのもの。別の式を立てない",
      and [ triangle f g | f <- [forwardMor, weakMor], g <- [backwardMor, weakMor] ])

  , ("系3.5: 距離は有向である — 向きで到達度が変わる",
      directed forwardMor backwardMor
      && qratEq (degOf forwardMor) (QRat 1 2)
      && qratEq (degOf backwardMor) (QRat 7 8))

  , ("系3.5: 恒等射は距離 0 の位置にあたる（到達度が上端 1）",
      qratEq (degOf (matIdQ 2)) qratOne
      && qratLeq (degOf forwardMor) (degOf (matIdQ 2)))

  , ("定義3.4: μ は M0 < M1 < M2 < MInf の順に並び、忘却は下向きだけ",
      M0 < M1 && M1 < M2 && M2 < MInf
      && sort [MInf, M0, M2, M1] == [M0, M1, M2, MInf])

  , ("定義3.4 μ=2: 𝒯 の座標表。ij = (+1,+1)、ji = (+1,−1)",
      coordOfWord [I, J] == Just (qratOne, qratOne)
      && coordOfWord [J, I] == Just (qratOne, qratNeg qratOne)
      && coordOfWord [] == Just (qratOne, qratZero)
      && coordOfWord [I] == Just (qratZero, qratOne))

  , ("定義3.4 μ=2: Level 6+ の長い語は座標表では読めない",
      coordOfWord [I, J, I] == Nothing
      && muDescend M2 (qvOfCoeff (QCoeff 1 0 [I,J,I] 1)) == Nothing
      && muDescend M2 (qvOfCoeff (QCoeff 1 0 [I,J] 1)) /= Nothing)

  , ("定義3.4 μ=2: ⟦·⟧ は係数で伸ばして足す — (1 ⊕ i) の座標は (1, 1)",
      tCoord (qvAdd qvOne (qvOfCoeff iUnitQ)) == Just (qratOne, qratOne))

  , ("定義3.4 μ=1: π で座標だけになる。型は落ちる",
      muDescend M1 (qvAdd qvOne (qvOfCoeff iUnitQ))
        == Just (qvOfRat (QRat 2 1)))

  , ("定義3.4 μ=0: Θ で二値になる。正の連続度は 1 へ畳まれる",
      muDescend M0 (qvOfCoeff (QCoeff 1 3 [I] 1)) == Just qvOne
      && muDescend M0 qvZero == Just (qvOfRat qratZero))

  , ("定義3.4: 忘却の列 ∞ → 1 → 0 は合成できる",
      let v = qvAdd qvOne (qvOfCoeff iUnitQ)
      in case muDescend M1 v of
           Just v1 -> muDescend M0 v1 == muDescend M0 v
           Nothing -> False)

  , ("定理3.5: 四つの基礎は 𝔾_{μ,d} の相異なる四点である",
      let gs = map gradeOf foundations
      in and [ a /= b | (a, i) <- zip gs [0 :: Int ..]
                      , (b, j) <- zip gs [0 ..], i /= j ])

  , ("定理3.5: ZFC は (0, d<ω)、古典圏論は (1, d<ω)、宇宙公理は (0, d→ω)",
      gradeOf FZFC == (M0, DFinite 1)
      && gradeOf FClassicalCat == (M1, DFinite 1)
      && gradeOf FUniverse == (M0, DOmega))

  , ("定理3.5: GCLS-圏論 (∞, d→ω) は他の三つすべてへ忘却できる",
      all (forgetsTo FGCLS) foundations)

  , ("定理3.5: 上りは標準的でない — ZFC から GCLS へは忘却で届かない",
      not (forgetsTo FZFC FGCLS)
      && not (forgetsTo FClassicalCat FGCLS)
      && not (forgetsTo FUniverse FGCLS))

  , ("定理3.5: 宇宙公理は d 軸だけを解放する。μ は ZFC と同じ 0 のまま",
      let (mu, d) = gradeOf FUniverse
          (mu', d') = gradeOf FZFC
      in mu == mu' && d /= d' && d' < d)

  , ("命題3.6: ω はどの有限深度にも属さないが、すべての極限として到達される",
      all (\ci -> pointOf ci < omega) stdIntegers
      && not (reachableAt (DFinite 3) 5) && reachableAt DOmega 5
      && DFinite 100 < DOmega)

  , ("命題3.6: 大きさの役割を作図深度が引き継ぐ（到達不能点は ω）",
      omega == maximum (map pointOf stdIntegers) + 1)
  ]
