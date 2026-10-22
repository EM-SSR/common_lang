{-# LANGUAGE NoImplicitPrelude #-}
module DagArith where

import CounterConstraints
import CounterUnits
import DagPlane

-- ===== 「幾何連合論理集合における四則演算」と「先んじて除算が必要になる」=====
-- doc: arith.add arith.sub arith.mul arith.div star.thales
--
-- 加減算: 終点の座標で決まる（経路を忘れる）。ω 軸成分の符号で型が切替わる
-- 乗除算: 構成の履歴で決まる（経路を保持する）。方向合成は分岐語、
--         大きさの合成はタレス比

-- ===== スケール付き平面座標: 値 = (x, y) / 2^depth =====

type SCoord = (Int, Int, Int)

negateS :: SCoord -> SCoord
negateS (x, y, d) = (negate x, negate y, d)

alignDepth :: SCoord -> SCoord -> (SCoord, SCoord)
alignDepth (x, y, d) (x', y', d')
  | d <= d'   = ((shiftL x (d' - d), shiftL y (d' - d), d'), (x', y', d'))
  | otherwise = ((x, y, d), (shiftL x' (d - d'), shiftL y' (d - d'), d))

-- 加算 = 平行四辺形則。加算は経路を忘れるので分岐情報を持たない
addS :: SCoord -> SCoord -> SCoord
addS p q =
  let ((a, b, c), (a', b', _)) = alignDepth p q
  in (a + a', b + b', c)

subS :: SCoord -> SCoord -> SCoord
subS p q = addS p (negateS q)

-- 加算の型切替: ω 軸成分の符号が正なら Si 型、負なら Sj 型、0 なら実軸通過
typeSide :: SCoord -> Maybe Side
typeSide (_, y, _)
  | y > 0     = Just Si
  | y < 0     = Just Sj
  | otherwise = Nothing

-- ===== タレス除算とタレス乗算（大きさ）=====

-- 比 r = n / d（既約とは限らない生の比）。
-- 除算は d ≠ 0 では相似比を返し、d = 0 では参照三角形が退化して
-- 交点は ω 方向に飛ぶ（BeyondOmega）
data Ratio2 = Ratio Int Int | BeyondOmega deriving (Eq, Show)

divideThales :: Int -> Int -> Ratio2
divideThales _ 0 = BeyondOmega
divideThales n d = Ratio n d

multiplyThales :: Ratio2 -> Ratio2 -> Ratio2
multiplyThales BeyondOmega _ = BeyondOmega
multiplyThales _ BeyondOmega = BeyondOmega
multiplyThales (Ratio a b) (Ratio c d) = Ratio (a * c) (b * d)

-- 比 n/d が二進比 n'/2^s に正規化できるときだけ、その (n', s) を返す。
-- ドキュメント 6d の通り、構成可能な比は k/2^n の列の極限であり、
-- 正確な適用ができるのは二進比に限られる（1/3 等は近似の対象）。
--
-- 判定は既約化した分母が 2 の冪であることに尽きる。s を 0 から順に試して
-- n·2^s が d で割り切れるかを見る形は、s が Int の幅を越えた所で
-- shiftL が 0 を返し、どんな比でも「0/2^64」として通してしまう。
asScale :: Ratio2 -> Maybe (Int, Int)
asScale BeyondOmega = Nothing
asScale (Ratio n d)
  | d == 0    = Nothing
  | otherwise = case log2Exact (abs (div d g)) of
      Just s  -> Just (sgn * div n g, s)
      Nothing -> Nothing
  where
    g   = gcd n d
    sgn = if d < 0 then negate 1 else 1

-- k = 2^s のときだけ s を返す。桁を落とすだけなので溢れない
log2Exact :: Int -> Maybe Int
log2Exact k = go k 0
  where
    go 1 s = Just s
    go m s
      | m <= 0    = Nothing
      | odd m     = Nothing
      | otherwise = go (div m 2) (s + 1)

-- ===== タレス比 = Level 1 の実数（3章「除算の定義」）=====
--
-- 除算の作図は二つの構成済み長さの比 r = |p_1| / |p_2| を返す。この比は
-- 二進比とは限らない。(1/4) / (5/16) = 4/5 が例で、分母に 5 が立つ。
-- だから既約有理数の対として正確に持つ。分母は常に正へ寄せる。
--
--   Ratio2 … 作図の出力そのもの。分母 0 は ω 方向への退化
--   QRat  … 既約化した値。比較と演算はこちらで行う
--
-- 影響関数 w(ℓ,x) の値（4章 証明3.1）も、豊穣の基底 𝒬 の大きさ（圏論 定理3.3）も
-- この型になる。座標の分子（SCoord）とは別物である: 座標は二進、比は一般の有理数。

data QRat = QRat Integer Integer deriving (Eq, Read, Show)

-- 既約化。gcd 0 x = x なので分子が零のときは分母 1 へ落ちる。
-- 正規化しておくと derived な Eq が値の相等と一致し、
-- QRat を含む値型（CommonChamber.Value）の構造的比較が安全になる
qnorm :: QRat -> QRat
qnorm (QRat a b)
  | b < 0     = qnorm (QRat (negate a) (negate b))
  | b == 0    = QRat a b
  | otherwise = QRat (a `div` g) (b `div` g)
  where g = if gcd a b == 0 then 1 else gcd a b

qratZero, qratOne :: QRat
qratZero = QRat 0 1
qratOne  = QRat 1 1

qratOf :: Integer -> Integer -> QRat
qratOf n d = qnorm (QRat n d)

-- 二進比 n/2^d からの持ち上げ。6d が構成する値はすべてここを通る
qratDyad :: Integer -> Int -> QRat
qratDyad n d = qnorm (QRat n (shiftL (1 :: Integer) d))

qratNum, qratDen :: QRat -> Integer
qratNum (QRat a _) = a
qratDen (QRat _ b) = b

-- 交差乗算。分母は正なので不等号の向きは変わらない
qratEq, qratLeq, qratLt :: QRat -> QRat -> Bool
qratEq  (QRat a b) (QRat c d) = a * d == c * b
qratLeq (QRat a b) (QRat c d) = a * d <= c * b
qratLt  (QRat a b) (QRat c d) = a * d <  c * b

qratMax, qratMin :: QRat -> QRat -> QRat
qratMax x y = if qratLeq x y then y else x
qratMin x y = if qratLeq x y then x else y

-- 大きさの乗算（① タレス構成）。分子どうし・分母どうしを掛ける
qratMul :: QRat -> QRat -> QRat
qratMul (QRat a b) (QRat c d) = qnorm (QRat (a * c) (b * d))

-- 加算（平行四辺形則）の比版。整合条件 Σ_ℓ w(ℓ,x) = 1 の検査で使う
qratAdd :: QRat -> QRat -> QRat
qratAdd (QRat a b) (QRat c d) = qnorm (QRat (a * d + c * b) (b * d))

qratSub :: QRat -> QRat -> QRat
qratSub x y = qratAdd x (qratNeg y)

qratNeg :: QRat -> QRat
qratNeg (QRat a b) = QRat (negate a) b

-- 大きさ。符号を落とす。型忘却 π が読むのはこの側になる
qratAbs :: QRat -> QRat
qratAbs (QRat a b) = QRat (abs a) b

-- 除算 ⊘。作図は p_2 = 0 で参照三角形が退化するので、そこだけ値を返さない。
-- クランプや零の拡張は quantale の残差の仕事であって、作図の仕事ではない
qratDiv :: QRat -> QRat -> Maybe QRat
qratDiv (QRat a b) (QRat c d)
  | c == 0    = Nothing
  | otherwise = Just (qnorm (QRat (a * d) (b * c)))

-- Ratio2 との橋。asScale が二進比へ落ちない値も QRat なら保てる
qratOfRatio :: Ratio2 -> Maybe QRat
qratOfRatio BeyondOmega = Nothing
qratOfRatio (Ratio n d)
  | d == 0    = Nothing
  | otherwise = Just (qratOf (toInteger n) (toInteger d))

-- 除算の値をスケール付き量へ適用する
quotApply :: Ratio2 -> SCoord -> Maybe SCoord
quotApply r (x, y, dep) = case asScale r of
  Just (n, s) -> Just (n * x, n * y, dep + s)
  Nothing     -> Nothing

scaleBy :: (Int, Int) -> SCoord -> SCoord
scaleBy (n, s) (x, y, d) = (n * x, n * y, d + s)

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("加算は可換かつ結合的（経路を忘れる）",
      let p = (1, 2, 3) :: SCoord
          q = (4, negate 1, 3)
          r = (0, 3, 5)
      in addS p q == addS q p && addS (addS p q) r == addS p (addS q r))
  , ("加算の型切替: ω 成分の符号で Si/Sj/実軸が決まる",
      typeSide (3, 2, 3) == Just Si
      && typeSide (3, negate 8, 3) == Just Sj
      && typeSide (5, 0, 3) == Nothing)
  , ("減算: −(i 型) と j 型は同じ下側領域に属するが起源が別物",
      let negI = negateUP (UnitPoint [I] 0 1)
          jP   = UnitPoint [J] 0 1
      in negate (signU negI) == signU jP && branchOf negI /= branchOf jP)
  , ("乗算の分配律: スケール分割して足しても結果は変わらない（§③ の根拠）",
      let s = (3, 1)
          p = (2, 4, 3)
          q = (1, 6, 3) :: SCoord
      in scaleBy s (addS p q) == addS (scaleBy s p) (scaleBy s q))
  , ("除算: d ≠ 0 では比を返し、r·d = n を復元できる",
      divideThales 6 3 == Ratio 6 3
      && quotApply (divideThales 6 3) (4, 4, 2) == Just (8, 8, 2))
  , ("ゼロ除算は ω 方向への退化として定義される",
      divideThales 5 0 == BeyondOmega
      && multiplyThales (Ratio 2 1) BeyondOmega == BeyondOmega)
  , ("タレス比は二進比に閉じない — (1/4) ⊘ (5/16) = 4/5 が正確に出る",
      qratDiv (qratDyad 1 2) (qratDyad 5 4) == Just (QRat 4 5)
      && asScale (Ratio 4 5) == Nothing)
  , ("比の順序 ≤ は交差乗算で決まる（𝒬 の台になる順序）",
      qratLt (QRat 1 3) (QRat 1 2) && qratLeq (QRat 2 4) (QRat 1 2)
      && qratEq (QRat 2 4) (QRat 1 2) && not (qratLt (QRat 1 2) (QRat 2 4)))
  , ("比の乗算は結合的・可換（大きさだけを見る段では経路が消えている）",
      let a = QRat 3 5; b = QRat 2 7; c = QRat 5 3
      in qratMul (qratMul a b) c == qratMul a (qratMul b c)
         && qratMul a b == qratMul b a)
  , ("比の乗算は ≤ を保つ（非負の大きさによるスケーリング）",
      let a = QRat 2 3
      in qratLeq (qratMul a (QRat 1 4)) (qratMul a (QRat 1 2)))
  , ("比の加算は結合的・可換。1/3 + 1/6 = 1/2 が既約で出る",
      let a = QRat 1 3; b = QRat 1 6; c = QRat 1 4
      in qratAdd a b == QRat 1 2
         && qratAdd (qratAdd a b) c == qratAdd a (qratAdd b c)
         && qratAdd a b == qratAdd b a)
  , ("除算は乗算の逆を復元する: (a ⊘ b) ⋆ b = a",
      case qratDiv (QRat 3 4) (QRat 2 5) of
        Just r  -> qratEq (qratMul r (QRat 2 5)) (QRat 3 4)
        Nothing -> False)
  , ("除算は分母 0 でだけ値を持たない（参照三角形の退化）",
      qratDiv (QRat 1 2) qratZero == Nothing
      && qratOfRatio BeyondOmega == Nothing)
  ]


