{-# LANGUAGE NoImplicitPrelude #-}
module JoinRank where

import CounterConstraints
import CommonChamber

-- ===== 接合秩（翻訳 08_接合秩による採用順序）=====
-- doc: tr.joinrank.layer tr.joinrank.word tr.joinrank.sep joinrank
--
-- R4 は「縮約が短さを生むのは接合秩が小さいとき」と言う。採用の順序へこの量を
-- 挟むと、短縮の利得が大きい語から短い列が配られ、平均発声時間 τ̄ が下がる。
--
--   ρ₁(C) = rank_F2( A_h ⋯ A_1 )                                翻訳 08 (3.2)
--
-- A_r は層 r の影響行列。原子箱は内部に分解を持たないので分離の宣言もなく、
-- 全ての入力ポートが全ての出力ポートへ届く。
--
--   T_a = J_{n×m}                                               翻訳 08 (2.1)
--
-- 積は Boole の (∨,∧) で取り、階数は F₂ 上で読む（翻訳 08 §2.3）。二つを混ぜると
-- 「影響が渡るか」と「独立に渡るか」が入れ替わる。前者が積、後者が階数になる。

-- 列数を持たせる。廃棄だけの層は行が一本も無く、[[Int]] だけでは幅が消える。
-- 幅が消えると次の積が黙って別の形になる
data Mat = Mat { matCols :: Int, matRows :: [[Int]] } deriving (Eq, Show)

matRowsN :: Mat -> Int
matRowsN = length . matRows

-- 層 r の影響行列。行の並びは stepPorts と同じにする。次の層の位置がこの並びを
-- 索くので、順序を変えると層の接続が合わなくなる。
--
-- pin = 0 の箱は位置を進めない。同じ層に並ぶ one は全部が位置 0 に載る
layerMatrix :: [Port] -> Layer -> Maybe Mat
layerMatrix front (Layer xs) = go 0 [] xs
  where
    total = length front
    wire q = [ if c == q then 1 else 0 | c <- [0 .. total - 1] ]
    -- 箱の行。pos から k 本を消費するので、その区間だけが 1 になる。
    -- k = 0 の箱（one、node）は零行を出す。無から立つワイヤは入口へ届かない
    boxRow pos k = [ if c >= pos && c < pos + k then 1 else 0 | c <- [0 .. total - 1] ]
    go cur acc [] = Just (Mat total (acc ++ [ wire q | q <- [cur .. total - 1] ]))
    go cur acc ((pos, a) : rest)
      | pos < cur       = Nothing
      | pos + k > total = Nothing
      | otherwise       = go (pos + k) (acc ++ [ wire q | q <- [cur .. pos - 1] ]
                                            ++ replicate n (boxRow pos k)) rest
      where
        k = length (fst (atomPorts a))
        n = length (snd (atomPorts a))

atOf :: [Int] -> Int -> Int
atOf r c = case drop c r of
  (x : _) -> x
  []      -> 0

-- (a·b)_{ij} = ⋁_k a_ik ∧ b_kj。a が p×q、b が q×r
boolMul :: Mat -> Mat -> Mat
boolMul (Mat _ arows) (Mat r brows) =
  Mat r [ [ hit row j | j <- [0 .. r - 1] ] | row <- arows ]
  where
    hit row j = if any (\(x, k) -> x > 0 && atOf (rowAt k) j > 0) (zip row [0 ..])
                  then 1 else 0
    rowAt k = case drop k brows of
      (x : _) -> x
      []      -> []

-- F₂ 上のガウス消去。行の追加は排他的論理和になる
rankF2 :: Mat -> Int
rankF2 (Mat w rows0) = go (map (map (\x -> mod x 2)) rows0) 0
  where
    go rows col
      | col >= w  = 0
      | null rows = 0
      | otherwise = case span (\r -> atOf r col == 0) rows of
          (_, [])          -> go rows (col + 1)
          (zs, p : others) -> 1 + go (map (elim p) (zs ++ others)) (col + 1)
      where
        elim p r = if atOf r col == 0 then r else zipWith (\x y -> mod (x + y) 2) r p

-- 層ごとの入口 frontier。i 番目が層 i の入口になる
frontiers :: Chamber -> Maybe ([[Port]], [Port])
frontiers c = portFrontierSeqM (chIn c) (chLay c)

-- ρ₁(C)。平文は Γ⁻ = I から始まるので層 0 に置けるのは pin = 0 の箱だけになり、
-- fr(Λ₀) = ∅。最初に切れる境界が fr(Λ₁) になる（翻訳 08 (3.1)）
rho1 :: Chamber -> Int
rho1 c = case frontiers c of
  Nothing       -> 0
  Just (ins, _) -> case product1 (drop 1 (zip ins (chLay c))) of
    Nothing -> 0
    Just m  -> rankF2 m
  where
    product1 []             = Nothing
    product1 ((f, l) : rest) = case layerMatrix f l of
      Nothing -> Nothing
      Just a  -> case product1 rest of
        Nothing  -> Just a
        Just acc -> Just (boolMul acc a)

-- 上限は frontier 幅（翻訳 08 命題 3.1）
frontierWidth1 :: Chamber -> Int
frontierWidth1 c = case frontiers c of
  Just (ins, _) -> case drop 1 ins of
    (f : _) -> length f
    []      -> 0
  _ -> 0

-- 採用表全体の平均。ρ(C) は頻度の重みになる（翻訳 08 §6）
meanRho1 :: [(Chamber, Int)] -> (Integer, Int)
meanRho1 recs
  | tot <= 0  = (0, 0)
  | otherwise = (toInteger ((wsum * shiftL (1 :: Int) 12 + div tot 2) `div` tot), 12)
  where
    tot  = sum [ n | (_, n) <- recs ]
    wsum = sum [ n * rho1 c | (c, n) <- recs ]

-- ===== ドキュメント主張の実行可能証明 =====

-- 翻訳 08 §3.3 の実測。2 = 1 ⊕ 1 は平文 `hu hu ka, no ka`。
--   Λ₀ = {one, one}、fr(Λ₁) = [Dyad, Dyad]、A₁ = J_{1×2}、ρ₁ = 1 < 2
chTwo :: Chamber
chTwo = Chamber MInf 2 []
  [ Layer [(0, primOne), (0, primOne)], Layer [(0, primAddD)] ] [PtDyad]

-- 語チェンバー C_t = P_t ; node（翻訳 03 (3.2)）。原型は廃棄で閉じるので Dyad は
-- 一本も出力境界へ届かず、node は pin = 0 なので入口 frontier から立たない
chWord :: Chamber
chWord = Chamber MInf 4 []
  [ Layer [(0, primOne), (0, primOne)]
  , Layer [(0, primAddD)]
  , Layer [(0, primDropD)]
  , Layer [(0, primNode)] ] [PNoun]

-- 正準の最大平行層形式では h(node) = 0 になり（構成語 §2.2）、node は層 0 へ落ちる。
-- Noun のワイヤが入口 frontier に入るので ρ₁ = 1 になる。書いた順のままでも
-- 正準形でも、語チェンバーの上では値が語に依らない
chWordCanon :: Chamber
chWordCanon = Chamber MInf 4 []
  [ Layer [(0, primOne), (0, primOne), (0, primNode)]
  , Layer [(0, primAddD)]
  , Layer [(0, primDropD)] ] [PNoun]

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("(08 §3.3): 2 = 1 ⊕ 1 の接合秩は 1。⊕ が経路を忘れる分だけ階数が落ちる",
      rho1 chTwo == 1)
  , ("(08 命題3.1): ρ₁ ≤ |fr(Λ₁)| — 1 < 2",
      rho1 chTwo < frontierWidth1 chTwo && frontierWidth1 chTwo == 2)
  , ("(08 (2.1)): 原子箱は J 行列。⊕ の一層は 1×2 の全 1 になる",
      layerMatrix [PtDyad, PtDyad] (Layer [(0, primAddD)]) == Just (Mat 2 [[1, 1]]))
  , ("(08 (2.2)): 恒等ワイヤは自分の位置へだけ届く",
      layerMatrix [PtDyad, PtDyad] (Layer [(1, primNegD)])
        == Just (Mat 2 [[1, 0], [0, 1]]))
  , ("廃棄の層は行を持たない。列数は残る",
      layerMatrix [PtDyad] (Layer [(0, primDropD)]) == Just (Mat 1 []))
  , ("(08 §2.3): 積は Boole。(∨,∧) で二本が一本へ合流する",
      boolMul (Mat 2 [[1, 1]]) (Mat 2 [[1, 0], [0, 1]]) == Mat 2 [[1, 1]])
  , ("F₂ 階数: 同じ行が二本あれば階数は 1 になる",
      rankF2 (Mat 2 [[1, 1], [1, 1]]) == 1 && rankF2 (Mat 2 [[1, 0], [0, 1]]) == 2)
  , ("語チェンバーの接合秩は 0。原型は全部廃棄で閉じ、node は無から立つ",
      rho1 chWord == 0)
  , ("正準の層形式でも語に依らない。node が層 0 へ落ちて ρ₁ = 1 になる",
      rho1 chWordCanon == 1)
  , ("(08 §6): ρ̄₁ は語チェンバーの上で定数になる。頻度で重みを付けても動かない",
      meanRho1 [(chWord, 100), (chWord, 1)] == (0, 12)
        && meanRho1 [(chWordCanon, 100), (chWordCanon, 1)] == (4096, 12))
  ]
