{-# LANGUAGE NoImplicitPrelude #-}
module SparseTensor where

import CounterConstraints
import CommonChamber
import Speech (encode)

-- ===== 三次元疎テンソル（02_三次元疎テンソルと文法.md）=====
-- doc: tensor3d tensor3d.inverse frontier.width
--
-- S(k,q,r) = a:
--   k = 文章中の語位置、q = その深さでの frontier 位置、r = 語内部の因果深度
-- 因果深度は前駆関係から導かれ、最大平行層では層番号そのものになる。
-- 箱のない位置には値を置かない。密な直方体ではなく疎な部分写像である。

-- ===== E: チェンバー → 疎テンソル成分 =====

entries :: Chamber -> [((Int, Int), String)]
entries c =
  [ ((pos, r), atomTag a)
  | (r, layer) <- zip [0 ..] (chLay c)
  , (pos, a) <- layerAtoms layer ]

sentenceEntries :: [Chamber] -> [((Int, Int, Int), String)]
sentenceEntries cs =
  [ ((k, pos, r), tag)
  | (k, c) <- zip [0 :: Int ..] cs
  , ((pos, r), tag) <- entries c ]

depthOf :: (Int, Int) -> Int
depthOf (_, r) = r

-- ===== D: 疎テンソル → チェンバー復元（定理6.1）=====
--
-- 原始文字辞書を辞書に使い、(r, q) の昇順に並べて層を再構成する。
-- 原始文字は counter_plane の積み上げた演算なので、復元した語は同じ演算を走らせる

restore :: Mu -> Int -> [Port] -> [Port]
        -> [((Int, Int), String)] -> Maybe Chamber
restore mu dep gin gout es = case buildLayers (sortEntries es) of
  Just layers -> let c = Chamber mu dep gin layers gout
                 in if wellFormed c then Just c else Nothing
  Nothing     -> Nothing

-- The atom itself is required for parameterized and closure boxes: a registry
-- tag alone does not contain their operands or nested chambers.
data ChamberTensor = ChamberTensor Mu Int [Port] [Port]
  (Maybe ([Int], [Int])) Int [((Int, Int), Atom)]
  deriving (Eq, Read, Show)

toChamberTensor :: Chamber -> Maybe ChamberTensor
toChamberTensor c
  | not (wellFormed c) = Nothing
  | otherwise = Just (ChamberTensor (chMu c) (chDep c) (chIn c) (chOut c)
      grade (length (chLay c))
      [((q,r), a) | (r,Layer es) <- zip [0..] (chLay c), (q,a) <- es])
  where
    grade = case c of
      GradedChamber {} -> Just (chamberGrade c)
      _ -> Nothing

fromChamberTensor :: ChamberTensor -> Maybe Chamber
fromChamberTensor (ChamberTensor mu dep gin gout grade height cells)
  | height < 0 || any outside cells = Nothing
  | otherwise = if wellFormed result then Just result else Nothing
  where
    outside ((q,r),_) = q < 0 || r < 0 || r >= height
    layers = [Layer (foldr insertCell [] [(q,a) | ((q,k),a) <- cells, k == r])
             | r <- [0..height-1]]
    insertCell x [] = [x]
    insertCell x@(q,_) (y@(p,_):ys)
      | q <= p = x:y:ys
      | otherwise = y:insertCell x ys
    base = Chamber mu dep gin layers gout
    result = case grade of
      Nothing -> base
      Just (d,addresses) -> withGrade d addresses base

sortEntries :: [((Int, Int), String)] -> [[(Int, String)]]
sortEntries es = collect sorted
  where
    keyed = [(r, p, t) | ((p, r), t) <- es]
    sorted = foldr insertR [] keyed
    insertR x []         = [x]
    insertR x@(r1, p1, _) (y@(r2, p2, _) : rest)
      | (r1, p1) <= (r2, p2) = x : y : rest
      | otherwise            = y : insertR x rest
    collect [] = []
    collect ((r, p, t) : rest) =
      let (same, others) = spanR r rest
      in ((p, t) : map third same) : collect others
    spanR r xs = span (\(r', _, _) -> r' == r) xs
    third (_, p, t) = (p, t)

buildLayers :: [[(Int, String)]] -> Maybe [Layer]
buildLayers groups = go groups []
  where
    go [] acc = Just (reverse acc)
    go (g : rest) acc = case toLayer g of
      Just l  -> go rest (l : acc)
      Nothing -> Nothing

toLayer :: [(Int, String)] -> Maybe Layer
toLayer group = go group []
  where
    go [] acc = Just (Layer (reverse acc))
    go ((pos, tag) : rest) acc = case lookupAtom tag of
      Just a  -> go rest ((pos, a) : acc)
      Nothing -> Nothing

-- ===== 直方体への埋め込みとバイナリ列（02 §6、§7）=====
-- doc: tensor3d.ragged tensor3d.decode frontier.width
--
-- 意味上の定義域は ragged な部分写像である。
--
--   ℐ = { (k,q,r) | 0 ≤ k < N, 0 ≤ r ≤ h_k, 0 ≤ q < |Γ_{k,r}| }
--   S : ℐ ⇀ Atom                                                     (§7)
--
-- 外へ出すときだけ直方体へ詰める。
--
--   Q = max_{k,r} |Γ_{k,r}|,   H = 1 + max_k h_k,   S ∈ Sparse(N×Q×H)
--
-- 埋め込みで生じる空白は意味を持たないので 0 を置く。値は原子箱のレジストリ番号
-- e に 1 を足したものにする。0 を「箱が無い」に使うためで、e = 0（id）と
-- 空白が同じ byte にならない。
--
-- §6 は復元に三つが要ると言う。Γ_k^-、Γ_k^+、S(k,·,·) である。だから S だけを
-- 出しても語は戻らない。境界の幅は命題5.1 が型から与える。
--
--   |Γ_{k,r}|   = u_r + Σ_j m_j        層 r へ入る本数
--   |Γ_{k,r+1}| = u_r + Σ_j n_j        層 r から出る本数
--
-- 幅の列を語ごとに一行として持てば ragged 定義域 ℐ がそのまま復元でき、
-- 末尾の一つが Γ_k^+ になる。
--
-- ---- byte 列の形 ----
--
--   見出し    4 byte      N, Q, H, 0
--   語 k ごと
--     形 W_k   H+1 byte   |Γ_{k,0}|, …, |Γ_{k,h_k}|, |Γ_k^+|、余りは 0
--     行列 S_k H×Q byte   行 r、列 q。値は e+1。箱が無ければ 0
--
-- 全体は 4 + N·((H+1) + H·Q) byte になる。行を r、列を q に取るのは、
-- byte の並びが §6 の復元手順の読み順（層 r の昇順、その中で q の昇順）と
-- 一致するからである。
--
-- 各欄は 1 byte に収まる範囲に限る。越える文章はこの形式では表せないので、
-- 符号化は値を返さない。黙って切り詰めると別の文章へ復号されてしまう。

-- レジストリ番号。E_speech が音節番号 unitBase + e へ写す、その e になる
registryIndex :: String -> Maybe Int
registryIndex t = go 0 (map fst primitiveTable)
  where
    go _ []       = Nothing
    go k (x : xs) = if x == t then Just k else go (k + 1) xs

-- 語の形 W_k。層ごとの入口幅を並べ、末尾に出口幅を置く（§6 が保存を要求する三つ）
shapeOf :: Chamber -> [Int]
shapeOf c = case portFrontierSeqM (chIn c) (chLay c) of
  Just (ins, out) -> map length ins ++ [length out]
  Nothing         -> [length (chIn c)]

-- 語の中身。層 r の位置 q に置かれた原子箱のレジストリ番号
cellsOf :: Chamber -> [((Int, Int), Int)]
cellsOf c =
  [ ((r, pos), e)
  | (r, l) <- zip [0 ..] (chLay c)
  , (pos, a) <- layerAtoms l
  , Just e <- [registryIndex (atomTag a)] ]

-- Q。§7 の範囲は 0 ≤ r ≤ h_k、つまり層の入口 frontier だけを見る
widthMax :: Chamber -> Int
widthMax c = foldr max 0 (initOf (shapeOf c))

-- H = 1 + h_k。層の本数そのものになる
depthMax :: Chamber -> Int
depthMax c = length (chLay c)

initOf :: [a] -> [a]
initOf []       = []
initOf [_]      = []
initOf (x : xs) = x : initOf xs

headerOf :: [Chamber] -> (Int, Int, Int, Int)
headerOf cs =
  ( length cs
  , foldr max 0 (map widthMax cs)
  , foldr max 0 (map depthMax cs)
  , 0 )

inByte :: Int -> Bool
inByte v = v >= 0 && v < 256

-- 語 k の block。形の行と、H×Q の行列を続ける
blockOf :: Int -> Int -> Chamber -> [Int]
blockOf q h c = padTo (h + 1) (shapeOf c) ++ matrix
  where
    cs = cellsOf c
    matrix = [ cellAt r pos | r <- [0 .. h - 1], pos <- [0 .. q - 1] ]
    cellAt r pos = case lookup (r, pos) cs of
      Just e  -> e + 1
      Nothing -> 0

padTo :: Int -> [Int] -> [Int]
padTo n xs = take n (xs ++ replicate n 0)

encodeTensor :: [Chamber] -> Maybe [Int]
encodeTensor cs
  | all representable cs && all inByte bs = Just bs
  | otherwise     = Nothing
  where
    representable c = wellFormed c && null (snd (chamberGrade c))
      && all (\a -> lookupAtom (atomTag a) == Just a)
           [a | Layer es <- chLay c, (_,a) <- es]
    (n, q, h, z) = headerOf cs
    bs = [n, q, h, z] ++ concatMap (blockOf q h) cs

-- 復号。見出しから形が決まるので、block 幅の割り算が要らない
decodeTensor :: [Int] -> Maybe ((Int, Int, Int, Int), [([Int], [[Int]])])
decodeTensor bs = case bs of
  (n : q : h : z : rest) | all inByte bs && z == 0 -> case takeBlocks n q h rest of
    Just blocks -> Just ((n, q, h, z), blocks)
    Nothing     -> Nothing
  _ -> Nothing

takeBlocks :: Int -> Int -> Int -> [Int] -> Maybe [([Int], [[Int]])]
takeBlocks n q h bs
  | n <= 0    = if null bs then Just [] else Nothing
  | otherwise =
      let w    = take (h + 1) bs
          rest = drop (h + 1) bs
          rows = [ take q (drop (r * q) rest) | r <- [0 .. h - 1] ]
          rest2 = drop (h * q) rest
      in if length w < h + 1 || length rest2 + h * q /= length rest
           then Nothing
           else case takeBlocks (n - 1) q h rest2 of
             Just more -> Just ((w, rows) : more)
             Nothing   -> Nothing

-- ===== ドキュメント主張の実行可能証明 =====

sampleWord :: Chamber
sampleWord =
  Chamber MInf 0 [PtDyad]
    [Layer [(0, primBeta)], Layer [(0, primFold)]]
    [PtBit]

-- reverse2tensor の突き合わせに使う標本。
-- 平文（音節列）と byte 列の対応を両側から固定する。
--   dyadAddWord   入力アリティ 2 の箱。frontier が 2 本から 1 本へ落ちる
--   wireGapWord   位置 1 に箱を置く。手前の一本は恒等ワイヤで通るので q = 1 になる
dyadAddWord, wireGapWord :: Chamber
dyadAddWord = Chamber MInf 0 [PtDyad, PtDyad] [Layer [(0, primAddD)]] [PtDyad]
wireGapWord = Chamber MInf 0 [PtDyad, PtDyad] [Layer [(1, primNegD)]] [PtDyad, PtDyad]

-- 層をまたぐ標本。行列の r·Q のずらしと、層 1 の無声ワイヤを見る
deepWord, deepGapWord :: Chamber
deepWord =
  Chamber MInf 0 [PtDyad, PtDyad]
    [Layer [(0, primAddD)], Layer [(0, primBeta)]] [PtDyad]
deepGapWord =
  Chamber MInf 0 [PtDyad, PtDyad]
    [Layer [(1, primBeta)], Layer [(0, primAddD)]] [PtDyad]

sampleSentence :: [Chamber]
sampleSentence =
  [ sampleWord
  , Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]
  , Chamber MInf 0 [] [] []
  ]

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("(定理6.1): レジストリの全原子が疎テンソルを往復する",
      all (\a -> let (gin, gout) = atomPorts a
                 in case cnf (Chamber (if atomPrim a == PDupN then M1 else MInf) 0 gin [Layer [(0, a)]] gout) of
                      Just c  -> restore (chMu c) (chDep c) (chIn c) (chOut c)
                                         (entries c) == Just c
                      Nothing -> False)
          [ a | (_, a) <- primitiveTable ])
  , ("E: チェンバーが疎成分へ落ちる。空位置には値がない",
      let es = entries sampleWord
      in length es == 2
         && elem ((0, 0), "beta") es
         && elem ((0, 1), "fold") es
         && notElem ((1, 0), "fold") es)
  , ("ragged: 深さごとに frontier 幅が変わる（add で二本が一本へ）",
      portFrontierSeqM [PtCoord, PtCoord] [Layer [(0, primAdd)]]
        == Just ([[PtCoord, PtCoord]], [PtCoord]))
  , ("定理6.1: D(E(C)) ≅ C — 疎テンソルから語が構造的に可逆復元される",
      let es = entries sampleWord
      in restore (chMu sampleWord) (chDep sampleWord)
                 (chIn sampleWord) (chOut sampleWord) es
           == Just sampleWord)
  , ("定理6.1: 復元した語は同じ演算を走らせる（意味論まで可逆）",
      let es = entries sampleWord
          restored = restore (chMu sampleWord) (chDep sampleWord)
                             (chIn sampleWord) (chOut sampleWord) es
          input = [VDyad (7, 3)]
          direct = evalChamber sampleWord input
          viaRestored = case restored of
            Just c  -> evalChamber c input
            Nothing -> Nothing
      in direct /= Nothing && direct == viaRestored)
  , ("定理6.1: 文章全体でも復元できる",
      all (\c ->
        let es = entries c
        in restore (chMu c) (chDep c) (chIn c) (chOut c) es == Just c)
        sampleSentence)
  , ("原始文字のみで構成されている（未知の概念文字は復元できない）",
      let bad = [((0, 0), "unregisteredTag")]   -- レジストリに無い概念文字
      in restore MInf 0 [wCow] [wCow] bad == Nothing)

  , ("§7: 見出しは ragged を直方体へ詰める二つの量を持つ — Q と H",
      headerOf [sampleWord] == (1, 1, 2, 0)
      && headerOf sampleSentence == (3, 1, 2, 0)
      && headerOf [sampleWord, dyadAddWord, wireGapWord] == (3, 2, 2, 0))

  , ("§6: 形の行は層ごとの入口幅を並べ、末尾が Γ_k^+ になる",
      shapeOf sampleWord == [1, 1, 1]
      && shapeOf dyadAddWord == [2, 1]
      && shapeOf wireGapWord == [2, 2])

  , ("命題5.1: 幅は型から決まる。add は二本を一本へ、dup は一本を二本へ",
      shapeOf (Chamber MInf 0 [PtDyad, PtDyad] [Layer [(0, primAddD)]] [PtDyad])
        == [2, 1]
      && shapeOf (Chamber MInf 0 [PtDyad] [Layer [(0, primDupD)]] [PtDyad, PtDyad])
        == [1, 2])

  , ("§7: 語 beta;fold の直方体。形 [1,1,1] と 2×1 の行列 [6,7]",
      encodeTensor [sampleWord] == Just [1, 1, 2, 0,  1, 1, 1,  6, 7])

  , ("§7: 入力アリティ 2 の箱。Q = 2 になり、空いた列は 0 で埋まる",
      encode dyadAddWord == ["no", "ka"]
      && encodeTensor [dyadAddWord] == Just [1, 2, 1, 0,  2, 1,  17, 0])

  , ("§7: 無声ワイヤが q を一つ進める。行列の第 0 列が空白になる",
      encode wireGapWord == ["ki", "ha", "ka"]
      && encodeTensor [wireGapWord] == Just [1, 2, 1, 0,  2, 2,  0, 18])

  , ("§7: 三語の文章。層の浅い語は形も行列も 0 で埋まる",
      encodeTensor [sampleWord, dyadAddWord, wireGapWord]
        == Just [ 3, 2, 2, 0
                , 1, 1, 1,   6, 0,  7, 0
                , 2, 1, 0,  17, 0,  0, 0
                , 2, 2, 0,   0, 18, 0, 0 ])

  , ("§7: 全体の byte 数は 4 + N·((H+1) + H·Q) になる",
      case encodeTensor [sampleWord, dyadAddWord, wireGapWord] of
        Just bs -> length bs == 4 + 3 * ((2 + 1) + 2 * 2)
        Nothing -> False)

  , ("§7: 空白は 0、箱は e+1。id（e=0）と空白が同じ byte にならない",
      encodeTensor [Chamber MInf 0 [PtUnit] [Layer [(0, primId)]] [PtUnit]]
        == Just [1, 1, 1, 0,  1, 1,  1])

  , ("§7: 層をまたぐ語。行が r、列が q なので r·Q だけずれる",
      encode deepWord == ["no", "ka", "se", "ka"]
      && encodeTensor [deepWord] == Just [1, 2, 2, 0,  2, 1, 1,  17, 0,  6, 0])

  , ("§7: 層 1 の無声ワイヤ。形は [2,2,1]、行列の第 0 列が空く",
      encode deepGapWord == ["ki", "se", "ka", "no", "ka"]
      && encodeTensor [deepGapWord] == Just [1, 2, 2, 0,  2, 2, 1,  0, 6,  17, 0])

  , ("命題5.1: 形の隣り合う二つは同じ量を二通りに読んだものになる",
      let w = shapeOf deepWord
      in w == [2, 1, 1]
         && drop 1 (initOf w) == [1]
         && shapeOf deepGapWord == [2, 2, 1])

  , ("符号化と復号が往復する",
      case encodeTensor [sampleWord, dyadAddWord, wireGapWord] of
        Just bs -> decodeTensor bs
                     == Just ( (3, 2, 2, 0)
                             , [ ([1,1,1], [[6,0],[7,0]])
                               , ([2,1,0], [[17,0],[0,0]])
                               , ([2,2,0], [[0,18],[0,0]]) ] )
        Nothing -> False)

  , ("半端な byte 数は復号しない",
      decodeTensor [1, 1, 2, 0, 1, 1] == Nothing
      && decodeTensor [1, 1] == Nothing)

  , ("定理6.1: 直方体から語が戻る。Γ^- と Γ^+ を添えれば D(E(C)) ≅ C",
      case encodeTensor [sampleWord] of
        Just bs -> case decodeTensor bs of
          Just (_, [(w, rows)]) ->
            let es = [ ((pos, r), tagOfIndex (v - 1))
                     | (r, row) <- zip [0 ..] rows
                     , (pos, v) <- zip [0 ..] row, v /= 0 ]
            in restore (chMu sampleWord) (chDep sampleWord)
                       (chIn sampleWord) (chOut sampleWord) es
                 == Just sampleWord
               && take 1 w == [length (chIn sampleWord)]
               && drop 2 w == [length (chOut sampleWord)]
          _ -> False
        Nothing -> False)

  ]
  where
    wCow = PtUnit
    betaIdx = maybe 0 id (registryIndex "beta")
    foldIdx = maybe 0 id (registryIndex "fold")
    tagOfIndex e = case drop e (map fst primitiveTable) of
      (t : _) -> t
      []      -> ""
    ordered rs = and [ (k1, r1, q1) <= (k2, r2, q2)
                     | ((k1, q1, r1, _), (k2, q2, r2, _)) <- zip rs (drop 1 rs) ]   
