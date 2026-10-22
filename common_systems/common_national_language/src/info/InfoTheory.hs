{-# LANGUAGE NoImplicitPrelude #-}
module InfoTheory where

import CounterConstraints
import CommonChamber (Chamber (..), cnf, iWord, Layer (..), primI)
import CounterComputeSystem (Dyad, halfOf)
import CounterUnits (Op (..))
import DagArith (Ratio2 (..), divideThales)
import GclsCategory (QCoeff (..), star, piForget, thetaBin)

-- ===== 一般情報理論（03_一般情報理論.md）=====
-- doc: info.body info.L info.shannon residual.adjoint channel.compose
--
-- 情報の本体は確率ではなく、経路を保持する非可換な合成にある。
--   §2     情報内容 I_∞(C) := CNF(C)。忘却列 I_∞ → I_2 → I_1 → I_0
--   §3     情報量 L(2^{-n}) = n。対数は外部関数ではなく作図深度そのもの
--   命題3.1 L(qr) = L(q) + L(r)
--   定理4.1 離散 ELLA は dyadic 対数を厳密に実行する
--   §5/§6  Shannon entropy・Boltzmann 型 log N は忘却後のスカラー観測の特殊形
--   §7     π の可換化により構成順序はスカラーへは残らない
--   §8     条件付き情報は左右二種。残余は除算そのもの（DagArith.divideThales）

-- ===== §2: 情報内容 =====

iInf :: Chamber -> Maybe Chamber
iInf = cnf

iInfEq :: Chamber -> Chamber -> Bool
iInfEq a b = cnf a == cnf b

-- ===== §3: dyadic 対数と Ω 閉包 =====

-- L(m/2^d) = d − log2(m)。分子が 2 の冪のときは厳密値。
-- 一般の dyadic は二分割列の極限であり、§4 の通り Ω 閉包として
-- 「下界・上界の括弧」を有限な構成対象として保持する
data LogQ = LClosed Int | LOmegaBracket Int Int deriving (Eq, Show)

logDyad :: Dyad -> Maybe Int
logDyad (m, d)
  | m <= 0    = Nothing
  | otherwise = go m 0
  where
    go v k
      | v == 1    = Just (d - k)
      | even v    = go (v `div` 2) (k + 1)
      | otherwise = Nothing

floorLog2 :: Integer -> Int
floorLog2 v
  | v <= 1    = 0
  | otherwise = 1 + floorLog2 (v `div` 2)

-- L(q) の観測: 冪二進なら厳密値、一般 dyadic なら括弧 [d−k−1, d−k]
logClosure :: Dyad -> LogQ
logClosure (m, d)
  | m <= 0    = LOmegaBracket 0 0
  | otherwise = case logDyad (m, d) of
      Just n  -> LClosed n
      Nothing -> LOmegaBracket (d - k - 1) (d - k)
  where k = floorLog2 m

-- ===== 命題3.1: タレス乗算下での加法性 =====

starDyad :: Dyad -> Dyad -> Dyad
starDyad (a, x) (b, y) = (a * b, x + y)

additivityHolds :: Dyad -> Dyad -> Bool
additivityHolds q r = case (logDyad q, logDyad r, logDyad (starDyad q r)) of
  (Just lq, Just lr, Just lqr) -> lq + lr == lqr
  _                            -> False

-- ===== §4: 離散 ELLA =====

ella :: (Dyad, Int) -> (Dyad, Int)
ella (q, i) = (halfOf q, i + 1)

ellaStart :: (Dyad, Int)
ellaStart = ((1, 0), 0)

ellaPow :: Int -> (Dyad, Int)
ellaPow n = case dropNth n (iterate ella ellaStart) of
  Just x  -> x
  Nothing -> ellaStart

dropNth :: Int -> [a] -> Maybe a
dropNth _ []      = Nothing
dropNth 0 (x : _) = Just x
dropNth k (_ : xs) = dropNth (k - 1) xs

-- ===== §5/§6: Shannon entropy と Boltzmann 特殊形 =====
--
-- 重みは同深度の冪二進 dyadic (m_i, d)（値 = m_i/2^d、Σ m_i = 2^d）。
-- 全重みが冪二進なら H は厳密値（HExact）、
-- 一般の dyadic 重みでは括弧（下界・上界）を HBracket として返す。
-- いずれも §4 の Ω 閉包の観測である

data EntropyObs
  = HExact Integer Int             -- 値 = 分子 / 2^depth bits
  | HBracket Integer Integer Int   -- (下界分子, 上界分子) / 2^depth
  deriving (Eq, Show)

entropyQ :: [Dyad] -> Maybe EntropyObs
entropyQ ps
  | null ps        = Nothing
  | not sameDepth  = Nothing
  | sumMs /= pow2  = Nothing   -- 未正規化
  | otherwise      = Just obs
  where
    ds        = map snd ps
    d         = pickD ds
    pickD (x : _) = x
    pickD []      = 0
    sameDepth     = and [x == d | x <- ds]
    pow2          = shiftL (1 :: Integer) d
    ms            = map fst ps
    sumMs         = foldr (+) 0 ms
    logs          = map logClosure ps
    exactAll      = and [case l of LClosed _ -> True; _ -> False | l <- logs]
    floOf l = case l of
      LClosed n    -> n
      LOmegaBracket lo _ -> lo
    ceiOf l = case l of
      LClosed n    -> n
      LOmegaBracket _ hi -> hi
    lowN  = sum [toInteger m * toInteger (floOf l) | ((m, _), l) <- zip ps logs]
    hiN   = sum [toInteger m * toInteger (ceiOf l) | ((m, _), l) <- zip ps logs]
    obs
      | exactAll  = HExact lowN d
      | otherwise = HBracket lowN hiN d

-- 冪二進限定の厳密版（後方互換）
entropyBits :: [Dyad] -> Maybe (Integer, Int)
entropyBits ps = case entropyQ ps of
  Just (HExact n d) -> Just (n, d)
  _                 -> Nothing

-- ===== §8: 左右条件付き情報（残差）=====
--
-- a ⋆ b ≤ c ⟺ b ≤ a ∖ c（= c/a）⟺ a ≤ c ∠ b（= c/b）
-- 正のスカラー上では残余は除算そのものであり、DagArith.divideThales が担う。
-- a = 0 のとき任意の b が成立するので、残余の上限は top = 1 になる。
-- 可換な特殊系では左右が一致し、通常の条件付き情報へ落ちる。
-- 非可換系での左右の区別は語のレベルにあり、GclsCategory の検証を参照。

dyMul :: Dyad -> Dyad -> Dyad
dyMul = starDyad

-- 右残余 a ∖ c = sup{b | a⋆b ≤ c} = c/a = (mc·2^{da}) / (ma·2^{dc})
-- 備考: a = 0 のとき任意の b が成立するので、残余の上限は top = 1 に閉じる。
-- これは除算（分母零で ω 方向へ退化する）とは異なる演算である。
residualRight :: Dyad -> Dyad -> Ratio2
residualRight (ma, da) (mc, dc)
  | ma == 0   = Ratio 1 1
  | otherwise =
      divideThales (fromInteger (mc * shiftL (1 :: Integer) da))
                   (fromInteger (ma * shiftL (1 :: Integer) dc))

-- 左残余 c ∠ b = sup{a | a⋆b ≤ c} = c/b = (mc·2^{db}) / (mb·2^{dc})
-- b = 0 のときも同様に top = 1 へ閉じる
residualLeft :: Dyad -> Dyad -> Ratio2
residualLeft (mb, _) _
  | mb == 0   = Ratio 1 1
residualLeft (mb, db) (mc, _)
  | otherwise =
      divideThales (fromInteger (mc * shiftL (1 :: Integer) db))
                   (fromInteger mb)

dyLeq :: Dyad -> Dyad -> Bool
dyLeq (a, x) (b, y) =
  a * shiftL (1 :: Integer) y <= b * shiftL (1 :: Integer) x

starLeq :: Dyad -> Dyad -> Dyad -> Bool
starLeq a b c = dyLeq (dyMul a b) c

-- ===== ドキュメント主張の実行可能証明 =====

firstLayerOf :: Chamber -> Layer
firstLayerOf c = case chLay c of
  (l : _) -> l
  []      -> Layer []

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("§2: 情報内容は CNF であり、同一性は正準形の一致で決まる",
      case iInf iWord of
        Just c' -> iInfEq iWord iWord
                   && layerAtoms (firstLayerOf c') == [(0, primI)]
        Nothing -> False)
  , ("定理4.1: 離散 ELLA の第二成分が dyadic 対数に厳密に一致する",
      let (q, i) = ellaPow 5
      in q == (1, 5) && i == 5
         && logDyad q == Just 5)
  , ("命題3.1: L(qr) = L(q)+L(r)",
      additivityHolds (1, 1) (1, 2)
      && additivityHolds (1, 3) (1, 4)
      && additivityHolds (1, 0) (1, 5))
  , ("§3: L(1)=0, L(1/2)=1",
      logDyad (1, 0) == Just 0 && logDyad (1, 1) == Just 1)
  , ("§5: Shannon — (1/2,1/2) はちょうど 1 bit",
      entropyBits [(1, 1), (1, 1)] == Just (2, 1))
  , ("§5: Shannon — (1/2,1/4,1/4) はちょうど 3/2 bits",
      entropyBits [(2, 2), (1, 2), (1, 2)] == Just (6, 2))
  , ("§6: Boltzmann — 一様分布 N=8 の H は log2 8 = 3 bits",
      entropyBits [(1, 3) | _ <- [1 .. 8 :: Int]] == Just (24, 3))
  , ("§5: 非冪二進の重みは括弧観測 HBracket へ落ちる（Ω 閉包）",
      entropyQ [(3, 2), (1, 2)] == Just (HBracket 2 5 2))
  , ("§5: 未正規化な重みには値を与えない",
      entropyBits [(1, 1)] == Nothing)
  , ("§8: 右残余 a∖c は c/a であり、a=0 では上限 top=1 に閉じる",
      residualRight (1, 1) (1, 0) == Ratio 2 1
      && residualRight (0, 7) (1, 0) == Ratio 1 1)
  , ("§8: 随伴 a⋆b ≤ c ⟺ b ≤ a∖c が両方向で成立する",
      let a = (1, 1)
          samples = [((3, 2), True), ((5, 2), True), ((5, 1), False)]
      in and [ starLeq a b (1, 0) == expect
             && expect == dyLeq b (2, 0)
             | (b, expect) <- samples ])
  , ("§8: 可換な特殊系では左右の残余が一致する",
      residualRight (1, 1) (1, 0) == residualLeft (1, 1) (1, 0))
  , ("§7: π の可換化で構成順序は失われるが、情報内容では残る",
      let a = QCoeff 1 0 [I] 1
          b = QCoeff 1 0 [J] 1
          ab = star a b
          ba = star b a
      in ab /= ba
         && piForget ab == piForget ba
         && thetaBin (piForget ab) == thetaBin (piForget ba))
  ]


