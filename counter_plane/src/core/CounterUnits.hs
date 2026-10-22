{-# LANGUAGE NoImplicitPrelude #-}
module CounterUnits where

import CounterConstraints
import RealUnit
import CounterInteger

-- ===== Level 4/5: ω・ω⁻ の非対称性と単位 i・j =====
-- doc: level4.i level5.j plane.counter
--
-- Index.md Level 4/5 より:
--   - ω は整数列の収束先で、H+ 側にのみ構成点が存在する（非対称）
--   - 対称な道の条件を満たす道は直線上には取れないため、
--     独立な方向（直線外）に正セグメント I を取り、i = ∂(I)
--   - I 上で同じ再帰構成が回り、合成は H− の −1 に対応する (i² = −1)
--   - ω⁻ から同様に J を取り j = ∂(J)。写像先は H+ 側 (j² = +1)
--
-- 単位は実体ではなくメタ操作なので、点への操作として表す。
-- 分岐は「適用した単位の語」で識別し、Level 6+ の合成も含めて
-- 適用は全域関数である（語の正規化により必ず値が出る）。

stdIntegers :: [CInteger]
stdIntegers = fst stdLine

omega :: Int
omega = snd stdLine

omegaMinus :: Int
omegaMinus = 2 * oVertex - omega

-- 分岐の頂点割当。ビット位置は大域資源で、実軸の構成は
-- 頂点 32..47（辺 32..46）を使うので、i 分岐は低位、j 分岐は高位に置く
iBranchBase, jBranchBase :: Int
iBranchBase = 4
jBranchBase = 60

-- I = ω を通る対称な道の正セグメント。J は ω⁻ から同様
segmentI, segmentJ :: Simplex
segmentI = simplex [omega, iBranchBase]
segmentJ = simplex [omegaMinus, jBranchBase]

unitI, unitJ :: Simplex
unitI = simplex [iBranchBase]
unitJ = simplex [jBranchBase]

-- ===== 分岐語と単位適用 =====

-- 単位操作の語彙。I は ω の非対称性を参照する境界操作、
-- J は ω⁻ の非対称性を参照する折り返し（Level 4/5 で導出済み）
data Op = I | J deriving (Eq, Ord, Read, Show)

-- 分岐 = 適用した単位の語（正規形: 交互語）。空語が実軸、
-- [I] が i 分岐、[J] が j 分岐、[J,I] は「j してから i」の合成分岐、
-- 以降いくらでも延長できる。これが Level 6+ の晴れ上がりの表現
type BWord = [Op]

data UnitPoint = UnitPoint
  { branchOf :: BWord   -- 正規形の分岐語
  , spotOf   :: Int     -- 分岐アンカーからのオフセット
  , signU    :: Int
  } deriving (Eq, Read, Show)

-- 基底三分枝の絶対アンカー。合成分岐のアンカーは各作図ごとに
-- 導かれるものであり、ここでは固定しない（オフセットで計算は閉じる）
anchorOf :: BWord -> Maybe Int
anchorOf []  = Just oVertex
anchorOf [I] = Just iBranchBase
anchorOf [J] = Just jBranchBase
anchorOf _   = Nothing

mkReal :: Int -> Int -> UnitPoint
mkReal v c = UnitPoint [] (v - oVertex) c

-- 単位適用は全域関数である。
--   語の末尾と異なる単位の追加: 語を延長し、オフセットと符号を保つ
--   II の合成（畳み）: オフセット反転＋符号反転（i² = −1 の反射）
--   JJ の合成（畳み）: そのまま（j² = +1 の折り返し）
applyU :: Op -> UnitPoint -> UnitPoint
applyU u (UnitPoint w s c) = case reverse w of
  (u' : rest) | u' == u -> case u of
    I -> UnitPoint (reverse rest) (negate s) (negate c)
    J -> UnitPoint (reverse rest) s c
  _ -> UnitPoint (w ++ [u]) s c

applyI, applyJ :: UnitPoint -> UnitPoint
applyI = applyU I
applyJ = applyU J

negateUP :: UnitPoint -> UnitPoint
negateUP (UnitPoint w s c) = UnitPoint w (negate s) (negate c)

realSamples :: [UnitPoint]
realSamples =
  [mkReal v s | v <- [oVertex - 3 .. oVertex + 5], s <- [1, negate 1]]

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("L4: ω の非対称性 — 構成点は全て ω 未満、ω 以上の構成点はない",
      all (\ci -> pointOf ci < omega) stdIntegers
      && null [() | ci <- stdIntegers, pointOf ci >= omega])
  , ("L4: ω を跨ぐ対称な道は実線上に構成できない（構成済み辺は全て ω の手前）",
      all (\e -> e < omega) (edgesOf (fullHistory stdIntegers)))
  , ("L4: I は ω から独立方向へ伸びる辺である",
      vertices segmentI == sort [iBranchBase, omega])
  , ("L4: i = ∂(I) の新端点（昇順規約では i 側が −1、ω が +1）",
      sort (boundary segmentI)
        == [(negate 1, unitI), (1, simplex [omega])])
  , ("L4: i² = −1（往復すると H− へ符号反転で着地する）",
      all (\p -> applyI (applyI p) == negateUP p) realSamples)
  , ("L4: i 一回は反転ではない（i 分岐へ出るから）",
      all (\p -> branchOf (applyI p) == [I] && applyI p /= negateUP p)
          realSamples)
  , ("L5: ω⁻ は O に対して ω と対称な位置にある",
      omegaMinus == 2 * oVertex - omega && omegaMinus < oVertex)
  , ("L5: J は ω⁻ から独立方向へ伸びる辺である",
      vertices segmentJ == sort [jBranchBase, omegaMinus])
  , ("L5: j = ∂(J) の新端点",
      sort (boundary segmentJ)
        == [(negate 1, simplex [omegaMinus]), (1, unitJ)])
  , ("L5: j² = +1（折り返しなので符号を保って戻る）",
      all (\p -> applyJ (applyJ p) == p) realSamples)
  , ("L5: i ≠ j（同じ入力でも行き先の分岐が違う）",
      all (\p -> applyI p /= applyJ p) realSamples)
  , ("L5: j ≠ ±1（j 分岐上の構成物であって実軸の点ではない）",
      branchOf (applyJ (mkReal oVertex 1)) == [J])
  , -- Level 6+: 合成も全域関数として計算される
    ("L6+: j してから i は ji 分岐へ着地する",
      all (\p -> applyI (applyJ p) == UnitPoint [J, I] (spotOf p) (signU p))
          realSamples)
  , ("L6+: i してから j は ij 分岐へ着地し、ji とは別方向",
      all (\p -> applyJ (applyI p) == UnitPoint [I, J] (spotOf p) (signU p)
              && applyJ (applyI p) /= applyI (applyJ p))
          realSamples)
  , ("L6+: 三連適用も畳みまで計算される（II は反射として畳む）",
      all (\p -> let q = applyI (applyI (applyJ p))
                 in branchOf q == [J] && signU q == negate (signU p))
          realSamples)
  ]


