{-# LANGUAGE NoImplicitPrelude #-}
module CounterInteger where

import CounterConstraints
import RealUnit

-- ===== Level 3: 対称な道と整数 =====
-- doc: level3.integer level3.halving
--
-- Index.md Level 3 より:
--   - 「O を挟んで正セグメントの外側が負セグメントになる対称な道」を切断する
--   - 正セグメントに ∂ を適用した出力が整数 1
--   - 1 を始点として残余に同じ構成を再帰適用して 2, 3, ... を演繹
--   - 負の整数は H− 側の対称点として同時に得られる
--   - 各ステップで残余の半分が取られる（1/2 漸減性）

edgesOf :: Region -> [Int]
edgesOf (Region r) = [e | e <- [0 .. 63], testBit r e]

-- 対称な道: 中心 c を跨ぐ道（辺幅 2w）
symmetricPath :: Int -> Int -> Region
symmetricPath c w = region [c - w .. c + w - 1]

positiveSeg :: Int -> Int -> Region
positiveSeg c w = region [c .. c + w - 1]

negativeSeg :: Int -> Int -> Region
negativeSeg c w = region [c - w .. c - 1]

-- 対称性条件: 正セグメントの外側が負セグメントに等しい
symmetricOnLine :: Int -> Int -> Bool
symmetricOnLine c w =
  exteriorIn (symmetricPath c w) (positiveSeg c w) == negativeSeg c w

-- 道の切断: c で二つの開セグメントに分ける
cutAt :: Region -> Int -> (Region, Region)
cutAt path c = (region [lo .. c - 1], region [c .. hi])
  where
    es = edgesOf path
    lo = minimum es
    hi = maximum es

-- 整数 = 構成の順序・複体上の頂点・O からの正セグメント鎖（構成履歴＝ビット）
data CInteger = CInteger
  { orderOf   :: Int
  , pointOf   :: Int
  , historyOf :: Region
  } deriving (Eq, Show)

-- 整数列の構成と収束先 ω。
-- 残余幅 w の半分 h を新しい正セグメントとし、遠端点 p+h が次の整数。
-- 残余が 1 辺まで縮んだら停止し、その先端が ω（収束先。この段階では
-- 点としては未構成で、名前だけ現れる）
convergedLine :: Int -> Int -> ([CInteger], Int)
convergedLine start w0 = go 1 start w0 (region []) []
  where
    go _ p w _ acc
      | w < 2     = (reverse acc, p + w)
    go n p w hist acc =
      let h   = w `div` 2
          pt  = p + h
          seg = region [p .. p + h - 1]
          ci  = CInteger n pt (combine hist seg)
      in go (n + 1) pt (w - h) (combine hist seg) (ci : acc)

-- 負の整数: O を挟んで対称な位置・履歴として同時に得られる
negateCInteger :: CInteger -> CInteger
negateCInteger (CInteger n pt h) =
  CInteger n (2 * oVertex - pt) (negateRegion h)

fullHistory :: [CInteger] -> Region
fullHistory = foldr (combine . historyOf) (region [])

-- ===== ドキュメント主張の実行可能証明 =====

stdLine :: ([CInteger], Int)
stdLine = convergedLine oVertex 16

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("L3: 対称な道は対称性条件を満たす", symmetricOnLine oVertex 4)
  , ("L3: 道の切断で負/正セグメントに分かれる",
      let (neg, pos) = cutAt (symmetricPath oVertex 4) oVertex
      in pos == positiveSeg oVertex 4 && neg == negativeSeg oVertex 4)
  , ("L3: 正セグメントの ∂ 出力に最初の整数が現れる",
      case stdInts of
        (c0 : _) -> sort (boundaryRegion (historyOf c0))
                      == [(oVertex, negate 1), (pointOf c0, 1)]
        []       -> False)
  , ("L3: 履歴全体の ∂ は O と最新点のみ（内部頂点は相殺）",
      case reverse stdInts of
        (cl : _) -> sort (boundaryRegion (fullHistory stdInts))
                      == [(oVertex, negate 1), (pointOf cl, 1)]
        []       -> False)
  , ("L3: 1/2 漸減性 — 第一間隔は残余の半分、以後さらに半減",
      case stdInts of
        (c0 : rest) ->
          let pts = map pointOf (c0 : rest)
          in pointOf c0 - oVertex == 8
             && zipWith (-) (drop 1 pts) pts == [4, 2, 1]
        [] -> False)
  , ("L3: 全ての整数は ω の手前にあり、ω は収束先として一意",
      omega == maximum (map pointOf stdInts) + 1
      && all (\ci -> pointOf ci < omega) stdInts)
  , ("L3: 負の整数は O に対して対称な位置に同時に得られる",
      case stdInts of
        (c0 : _) -> pointOf (negateCInteger c0) == 2 * oVertex - pointOf c0
        []       -> False)
  , ("L3: 負の整数の履歴も道である",
      case stdInts of
        (c0 : _) -> isPath (historyOf (negateCInteger c0))
        []       -> False)
  ]
  where
    stdInts = fst stdLine
    omega   = snd stdLine
