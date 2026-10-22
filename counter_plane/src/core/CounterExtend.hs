{-# LANGUAGE NoImplicitPrelude #-}
module CounterExtend where

import CounterConstraints
import RealUnit
import CounterInteger
import CounterUnits

-- ===== 検証: I/J の導出が実数のみから閉じているか =====
-- doc: level4.i level5.j

-- Index.md L4: 「ω を起点に道を二回独立方向に取る合成は、
-- 単位長さで取れば H− 上の単位点に対応」。整数 1 の頂点から出発し、
-- 着地がその鏡像（H− の単位点）であることを検証する
unitSquareLandsMinus1 :: Bool
unitSquareLandsMinus1 =
  case stdIntegers of
    (c0 : _) -> applyI (applyI (mkReal (pointOf c0) 1))
                  == mkReal (2 * oVertex - pointOf c0) (negate 1)
    []       -> False

-- Index.md L4: 「I の上にも整数 1 の 1/2 漸減性に基づく構成は
-- 同じ形で繰り返し可能。そうすると I 上にも収束点が現れる（ω_I）」
lineOnI :: ([CInteger], Int)
lineOnI = convergedLine iBranchBase 8

omegaI :: Int
omegaI = snd lineOnI

-- ===== 実験A: ω_I からさらに独立方向（Z）へ脱出した数 =====

-- I 分岐の標準構成は頂点 4..12 を使う。実軸（32..48）とは無関係
zBase :: Int
zBase = 24   -- ω⁻(16) と継続帯(49..53)を避け、実軸 32 以降とも衝突しない

segmentK :: Simplex
segmentK = simplex [omegaI, zBase]

unitZ :: Simplex
unitZ = simplex [zBase]

data ZPoint = OnI Int Int | OnZ Int Int deriving (Eq, Show)

-- z 操作: ω_I の非対称性を参照して Z 分岐へ運ぶ。
-- アンカーが ω 型なので i と同型の振る舞いをする（二回で I 分岐内の反転）
applyZ :: ZPoint -> ZPoint
applyZ (OnI v c) = OnZ (zBase + (v - iBranchBase)) c
applyZ (OnZ v c) = OnI (iBranchBase + zBase - v) (negate c)

negateOnI :: ZPoint -> ZPoint
negateOnI (OnI v c) = OnI (2 * iBranchBase - v) (negate c)
negateOnI z         = z

zSamples :: [ZPoint]
zSamples = [OnI v s | v <- [iBranchBase .. iBranchBase + 4], s <- [1, negate 1]]

-- ===== 実験B: i/J を経由せず H± を直接 Z 方向へ延長した数 =====

-- ω で線を継続するには「ω における新しい単位幅」を選ばなければならない。
-- これは追加データであり、既存の構成からは一意に決まらない
continuationWidth :: Int
continuationWidth = 4

continuation :: ([CInteger], Int)
continuation = convergedLine (omega + 1) continuationWidth

contPoints :: [CInteger]
contPoints = fst continuation

-- 直進の輸送。分岐タグが変わらないことが本質（線上に留まる）
advanceAlongLine :: Int -> UnitPoint -> UnitPoint
advanceAlongLine step (UnitPoint [] s c) = UnitPoint [] (s + step) c
advanceAlongLine _ u = u

-- ===== 検証と実験の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("検証: i² は単位点を H− の単位点へ写す（Index.md L4 の原文どおり）",
      unitSquareLandsMinus1)
  , ("検証: ω_I が I 分岐上の再帰構成の収束先として現れる",
      all (\ci -> pointOf ci < omegaI) (fst lineOnI)
      && omegaI == maximum (map pointOf (fst lineOnI)) + 1)
  , ("検証: I 分岐の構成点は実軸の頂点帯と無関係な位置に立つ",
      all (\ci -> pointOf ci < oVertex) (fst lineOnI))
  , ("実験A: K は ω_I から独立方向へ伸びる辺",
      vertices segmentK == sort [zBase, omegaI])
  , ("実験A: k = ∂(K) の符号対応（昇順規約）",
      sort (boundary segmentK)
        == [(negate 1, simplex [omegaI]), (1, unitZ)])
  , ("実験A: z² は I 分岐内の反転（ω 型アンカーは C4 型単位を生成する）",
      all (\p -> applyZ (applyZ p) == negateOnI p) zSamples)
  , ("実験A: z 一回は反転ではない（Z 分岐へ出るから）",
      all (\p -> applyZ p /= negateOnI p) zSamples)
  , ("実験B: 継続点は全て ω より先にあり、順序が反転しない",
      all (\ci -> pointOf ci > omega) contPoints)
  , ("実験B: ω は実軸側の終端かつ継続側の始端である",
      maximum (map pointOf stdIntegers) < omega
      && omega < minimum (map pointOf contPoints))
  , ("実験B: ω での第一間隔は選択した新単位で決まる（任意選択＝追加データ）",
      case contPoints of
        (c0 : _) -> pointOf c0 - (omega + 1) == continuationWidth `div` 2
        []       -> False)
  , ("実験B: 直進の合成は反転にならない（新しい単位が発生しない）",
      let adv = advanceAlongLine 2
      in all (\p -> adv (adv p) /= negateUP p
                 && branchOf (adv (adv p)) == [])
           [mkReal (oVertex + v) 1 | v <- [1 .. 3]])
  ]

