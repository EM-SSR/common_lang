{-# LANGUAGE NoImplicitPrelude #-}
module Common.Arch.Lane where

import CounterConstraints

-- ===== 実行位相 𝒳_A（docs/common-compiler/arch/07、仕様 §7、§21、§22）=====
-- doc: casm.lane.mask casm.lane.diverge casm.lane.verify
--
-- CPU package は |𝒳_A| = 1 で済ませてきた。GPU package はここを広げる。
-- core は 𝒳_A を知らないままでよい（定理 52.1）。広げる作業は package の中で閉じる。
--
--   𝒳_A = {0, …, W−1}、  active relation A_t ⊆ 𝒳_A  を bit vector m で持つ
--
--   δ_i(σ)[ℓ] = δ_i^lane(σ[ℓ])   （m[ℓ] = 1）
--             = σ[ℓ]              （m[ℓ] = 0）
--
-- W = 1、m = (1) とおけば CPU の δ に一致する。CPU package を書き直す必要はない。

type Mask = [Bool]

fullMask :: Int -> Mask
fullMask w = replicate w True

activeCount :: Mask -> Int
activeCount m = length [ () | True <- m ]

-- lane ごとの値の族。mask の下でだけ新しい値を採る（式 2.1）
maskedWrite :: Mask -> [a] -> [a] -> [a]
maskedWrite m old new = [ if a then n else o | (a, (o, n)) <- zip m (zip old new) ]

-- 判定が全 active lane で一致するか（式 3.1）。一致すれば pc の分岐で実現できる
isUniform :: Mask -> [Bool] -> Bool
isUniform m c = case [ b | (True, b) <- zip m c ] of
  []       -> True
  (b : bs) -> all (== b) bs

-- divergence（式 3.2）。真の側と偽の側へ mask を割る
splitMask :: Mask -> [Bool] -> (Mask, Mask)
splitMask m c =
  ( [ a && b | (a, b) <- zip m c ]
  , [ a && not b | (a, b) <- zip m c ] )

-- reconvergence（式 3.3）
joinMask :: Mask -> Mask -> Mask
joinMask a b = [ x || y | (x, y) <- zip a b ]

-- 配置 κ_A（式 21.2）。互いに依存しない chamber を lane へ割る。
-- 定理 21.1 により、あふれた分を逐次化しても観測は変わらない
placeLanes :: Int -> Int -> [Int]
placeLanes w n = [ k `mod` w | k <- [0 .. n - 1] ]

-- 最大平行層を lane へ割る。層の中の箱は互いに依存しないので（02 §1）、
-- そのまま κ_A の入力になる。Core.Pipe.scheduleLayers が返す層を渡す。
--
--   placeLayer w is = [ (箱番号, lane) ]
--
-- W = 1 は CPU package の既定であり、割当てが恒等になって逐次実行に一致する。
-- GPU package と CPU package で同じ式を使うのはこのためになる。
placeLayer :: Int -> [Int] -> [(Int, Int)]
placeLayer w is = zip is (placeLanes w (length is))

-- lane ごとの箱。あふれた分は同じ lane へ積み上がり、その中では逐次になる
byLane :: Int -> [Int] -> [[Int]]
byLane w is = [ [ i | (i, l) <- placeLayer w is, l == lane ] | lane <- [0 .. w - 1] ]
