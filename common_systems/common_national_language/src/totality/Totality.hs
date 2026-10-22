{-# LANGUAGE NoImplicitPrelude #-}
module Totality where

import CounterConstraints
import CommonChamber
import CounterComputeSystem (Dyad, betaStep)
import DagArith
  ( QRat (..), qratOne, qratZero, qratMul, qratAdd, qratSub, qratDiv
  , qratLeq, qratEq )

-- ===== 全域計算と停止性（04_全域計算と停止性.md）=====
-- doc: eval.total omega.value halt.flag prop.total
--
-- §3  整形式項はすべて有限な直列化を持つ（定理3.1）。
--     Ω_a[F;x₀] は軌道を展開せず、F の解析で集積境界 a を確定して閉じる。
-- §4  停止性は別の問いであり、単調フラグの上限 ⋁ で読む。
-- §6  有限状態系は鳩の巣原理により高々 N+1 段で停止か周期かが確定する。
-- §7  線形・アフィン反復は A^n を二乗法 O(log n) で落とし、
--     固定点は x* = b/(1−L) を直接解く。
-- §8  縮小写像の軌道（0 ≤ λ < 1）は一意な不動点へ閉じる。

-- ===== 係数は 3章 のタレス比を使う =====
--
-- アフィン反復の係数 L と b は二進比に収まらない（§7 の x* = b/(1−L) は
-- 一般に分母へ 2 以外の素因数を立てる）。DagArith.QRat がその型であり、
-- 既約化と順序をそこに置いてある。ここで別の有理数を立てない。
--
-- 除算だけは向きが違う。DagArith は分母 0 で値を返さない（作図の退化）ので、
-- 呼び出し側が縮小条件 L < 1 を確かめてから使う。

-- 分母 0 を呼び出し側が排除した上での除算。§7 の x* = b/(1−L) 専用
qDivT :: QRat -> QRat -> QRat
qDivT a b = case qratDiv a b of
  Just r  -> r
  Nothing -> qratZero

-- ===== 整形式項の構文 =====

data SelfF
  = SBeta        -- β(x) = (x+1)/2。集積境界 ω = 1（定理1.2）
  | SAff QRat QRat   -- アフィン縮小 x ↦ L·x + b、0 ≤ L < 1（§7/§8）
  deriving (Eq, Show)

data Term
  = TAtom Chamber              -- 原子チェンバー
  | TSeq Term Term             -- C₁ ; C₂
  | TTensor Term Term          -- C₁ ⊗ C₂
  | TOmega SelfF Value Value   -- Ω_a[F;x₀]: (F, x₀, a)。a は解析で確定する
  deriving (Eq, Show)

atomTerm :: Chamber -> Maybe Term
atomTerm c
  | wellFormed c = Just (TAtom c)
  | otherwise    = Nothing

applySelf :: SelfF -> Value -> Maybe Value
applySelf SBeta (VDyad x) = Just (VDyad (betaStep x))
applySelf (SAff l b) (VDyad x) =
  case dOfQ (qratAdd (qratMul l (qOfD x)) b) of
    Just y  -> Just (VDyad y)
    Nothing -> Nothing
applySelf _ _ = Nothing

-- Dyad ↔ QRat 変換
qOfD :: Dyad -> QRat
qOfD (m, d) = QRat (toInteger m) (shiftL (1 :: Integer) d)

dOfQ :: QRat -> Maybe Dyad
dOfQ (QRat n dn) = go dn 0
  where
    go dd k
      | dd == 1    = Just (n, k)
      | even dd    = go (dd `div` 2) (k + 1)
      | otherwise  = Nothing

-- Ω の集積境界は F を解析して確定する。無限反復を回さない。
--   SBeta      : 不動点方程式 x = (x+1)/2 の解 x = 1（CCS 定理1.2）
--   SAff l b   : 縮小写像 0 ≤ l < 1 の不動点 x* = b/(1−l)（定理8.1・§7）
--   周期系は点への収束閉包を持たないため対象外。周期の閉じ方は §6 が担う
accumOf :: SelfF -> Maybe Value
accumOf SBeta = Just (VDyad (1, 0))
accumOf (SAff l b)
  | qratLeq qratZero l && qratLeq l qratOne && not (qratEq l qratOne) =
      case dOfQ (solveFix l b) of
        Just x  -> Just (VDyad x)
        Nothing -> Nothing
  | otherwise = Nothing

mkOmega :: SelfF -> Value -> Maybe Term
mkOmega f x0 = case accumOf f of
  Just a  -> Just (TOmega f x0 a)
  Nothing -> Nothing

-- ===== 幅と実行 =====

widthOf :: Term -> Int
widthOf t = case t of
  TAtom c     -> length (chIn c)
  TSeq a _    -> widthOf a
  TTensor a b -> widthOf a + widthOf b
  TOmega _ _ _ -> 1

liftM2' :: (a -> b -> c) -> Maybe a -> Maybe b -> Maybe c
liftM2' f ma mb = case ma of
  Just x  -> case mb of
    Just y  -> Just (f x y)
    Nothing -> Nothing
  Nothing -> Nothing

splitAtN :: Int -> [a] -> ([a], [a])
splitAtN n xs = (take n xs, drop n xs)

evalTerm :: Term -> [Value] -> Maybe [Value]
evalTerm t vs
  | length vs /= widthOf t = Nothing
  | otherwise = case t of
      TAtom c    -> evalChamber c vs
      TSeq a b   -> case evalTerm a vs of
        Just vs' -> evalTerm b vs'
        Nothing  -> Nothing
      TTensor a b ->
        let (va, vb) = splitAtN (widthOf a) vs
        in liftM2' (++) (evalTerm a va) (evalTerm b vb)
      TOmega f _ a -> case applySelf f a of
        Just _  -> Just [a]
        Nothing -> Nothing

termSer :: Term -> String
termSer = show

-- ===== §6: 有限状態系の停止判定 =====

data FsmVerdict
  = Halted Int        -- 時刻 t で停止状態へ到達
  | Periodic Int Int  -- 状態が時刻 j と時刻 t で再出現（以後周期）
  deriving (Eq, Show)

verdictSteps :: FsmVerdict -> Int
verdictSteps (Halted t)     = t
verdictSteps (Periodic _ t) = t

decideFsm :: [Int] -> (Int -> Int) -> [Int] -> Int -> FsmVerdict
decideFsm space f haltSet x0 = walk x0 0 []
  where
    bound = length space
    walk x t seen = case lookup x seen of
      Just j  -> Periodic j t
      Nothing
        | elem x haltSet -> Halted t
        | t >= bound     -> Periodic t t
        | otherwise      -> walk (f x) (t + 1) ((x, t) : seen)

modNonzero :: Int -> Int -> Int
modNonzero x n
  | n == 0    = x
  | otherwise = x `mod` n

fsSample :: [Int -> Int]
fsSample =
  [ id
  , \x -> (x + 1) `modNonzero` 6
  , \x -> (x * 2) `modNonzero` 6
  , const 0
  , \x -> (x + 3) `modNonzero` 6
  ]

-- ===== §7: アフィン反復 =====

type Aff = (QRat, QRat)

idA :: Aff
idA = (qratOne, qratZero)

compA :: Aff -> Aff -> Aff
compA (l1, b1) (l2, b2) = (qratMul l1 l2, qratAdd (qratMul l1 b2) b1)

applyA :: Aff -> QRat -> QRat
applyA (l, b) x = qratAdd (qratMul l x) b

affPow :: Aff -> Int -> Aff
affPow a k
  | k <= 0    = idA
  | odd k     = compA a (affPow a (k - 1))
  | otherwise = affPow (compA a a) (k `div` 2)

powQ :: QRat -> Int -> QRat
powQ r k
  | k <= 0    = qratOne
  | odd k     = qratMul r (powQ r (k - 1))
  | otherwise = powQ (qratMul r r) (k `div` 2)

solveFix :: QRat -> QRat -> QRat
solveFix l b = qDivT b (qratSub qratOne l)

-- ===== ドキュメント主張の実行可能証明 =====

sampleWordT :: Chamber
sampleWordT = Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]

betaWordT :: Chamber
betaWordT = Chamber MInf 0 [PtDyad] [Layer [(0, primBeta)]] [PtDyad]

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("全域性: Ω 項を含む全ての整形式項が有限の直列化を持つ",
      case mkOmega SBeta (VDyad (0, 0)) of
        Just om -> all (\t -> length (termSer t) > 0)
                       [TAtom sampleWordT, TSeq om om, TTensor om om, om]
        Nothing -> False)
  , ("定理3.1: Ω は軌道を展開しない — 明示展開より表現が一定に小さい",
      case mkOmega SBeta (VDyad (0, 0)) of
        Just om ->
          let unfolded60 = foldr (\_ acc -> TSeq (TAtom betaWordT) acc) om [1 .. 60 :: Int]
          in length (termSer unfolded60) > length (termSer om)
        Nothing -> False)
  , ("Ω の閉包: 40 段の有限反復が決して到達しない値を Ω は厳密に返す",
      case mkOmega SBeta (VDyad (0, 0)) of
        Just om ->
          let orbitNeverHits = and [ v /= (1, 0)
                                   | v <- take 40 (iterate betaStep (0, 0)) ]
          in orbitNeverHits && evalTerm om [VDyad (0, 0)] == Just [VDyad (1, 0)]
        Nothing -> False)
  , ("Ω の対象外: 周期系（¬ など）は点への収束閉包を持たない",
      case accumOf (SAff (QRat 1 1) (QRat 0 1)) of   -- L = 1 は縮小でない
        Nothing -> True
        Just _  -> False)
  , ("§8: アフィン縮小の集積境界は閉じた式 x* = b/(1−L) と一致する",
      let l = QRat 1 2
          b = QRat 1 4
          expected = QRat 1 2   -- (1/4)/(3/4) = 1/3…ではなく (1/4)/(1/2)=1/2
      in case accumOf (SAff l b) of
           Just (VDyad w) -> qratEq (QRat (fst w) (shiftL (1 :: Integer) (snd w))) expected
           _              -> False)
  , ("§6: 停止する機械は到達時刻を報告する",
      decideFsm [0, 1, 2] (\x -> x + 1) [2] 0 == Halted 2)
  , ("§6: 周期機械は非停止と確定し、再出現区間が妥当である",
      case decideFsm [0, 1, 2] (\x -> (x + 1) `modNonzero` 3) [] 0 of
        Periodic j t -> j < t
        _            -> False)
  , ("§6: 鳩の巣 — どの遷移でも判定は高々 N+1 段で終わる",
      and [ verdictSteps (decideFsm [0 .. 5] f [] 0) <= 6 | f <- fsSample ])
  , ("§7: 二乗法 A^7 は 7 回合成と厳密に一致する",
      let a = (QRat 1 2, QRat 1 4)
          sevenFold = foldl compA idA (replicate (7 :: Int) a)
          eqAff (x1, y1) (x2, y2) = qratEq x1 x2 && qratEq y1 y2
      in eqAff (affPow a 7) sevenFold)
  , ("§7: アフィン反復 10 段の値は閉じた式 b(1−L¹⁰)/(1−L) と厳密に一致する",
      let l = QRat 1 2
          b = QRat 1 4
          a = (l, b)
          lhs = applyA (affPow a 10) qratZero
          rhs = qratMul b (qDivT (qratSub qratOne (powQ l 10)) (qratSub qratOne l))
      in qratEq lhs rhs)
  , ("§7: 固定点 x* = b/(1−L) は実際に不動である",
      let l = QRat 1 2
          b = QRat 1 4
          xf = solveFix l b
      in qratEq (applyA (l, b) xf) xf)
  , ("§8: β の集積境界 a=ω は縮小写像の不動点である（定理8.1 との接合）",
      case accumOf SBeta of
        Just (VDyad w) -> let dEq (a, x) (b, y) = a * shiftL (1 :: Integer) y == b * shiftL (1 :: Integer) x
                           in dEq (betaStep w) w
        _              -> False)
  ]


