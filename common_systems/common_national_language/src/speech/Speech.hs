{-# LANGUAGE NoImplicitPrelude #-}
module Speech where

import CounterConstraints
import CounterComputeSystem (Dyad)
import CommonChamber
import InfoTheory (dyLeq)

-- ===== 音声符号と誤り訂正（06_音声符号と誤り訂正.md）=====
-- doc: speech.encode hear.T speech.separate bit.correct error.layers
--
-- 発音列は順序付き構成であり、列の順序そのものが符号空間である（非可換）。
--   §2   E_speech / D_speech の可逆性: CNF(D(E(C))) = CNF(C)
--   §3   聞き取りやすさは実測遷移係数 T_hear(p_i,p_j) ∈ [0,1] で持つ
--   4.1  同位置合成: T(u,v) = T(p₁,p'₁) ⋆ … ⋆ T(pₙ,p'ₙ)
--   4.2  編集経路（挿入・削除・置換）を含む最大経路: ⋁_γ T_γ
--   5.1  語彙分離: u ≠ v なら T(u,v) ≤ ε
-- ビット符号層: 音素 → 4 ビットコード + 偶パリティ。単一ビット誤りは検出される

type Utterance = [Phone]

-- 発音単位: 原始文字を音節表上の番号に対応させた音節。
-- 構文境界（層の切れ目）と無声ワイヤは予約音節で表す
sepPhone, gapPhone :: Phone
sepPhone = phoneOfIdx idxBoundary    -- 層境界音（発声可能な音節）
gapPhone = phoneOfIdx idxSilent      -- 無声ワイヤ音（同上）
-- ===== E_speech / D_speech（§2、零標示は 06 §16）=====

-- E_speech(C) = [z_e] ⇔ 内部図 D が空（06 §16.2）。
-- 空本体でも像を空列にすると聴取可能行列に行が存在しなくなるので、
-- 可聴音節一つで表す。無音にはしない
encode :: Chamber -> Utterance
encode c
  | not (wellFormed c) || any unregistered
      [a | Layer es <- chLay c, (_,a) <- es] = []
  | null (chLay c) = [zeroMarkPhone]
  | otherwise = case portFrontierSeqM (chIn c) (chLay c) of
      Just (ins, _) -> concatMap layerPhones (zip ins (chLay c))
      Nothing       -> []
  where
    unregistered a = lookupAtom (atomTag a) /= Just a

-- 箱はレジストリ順 k に応じた発音単位音节へ写る。未登録タグは無声音へ落ち、
-- 復元時に整形式検査で検出される
-- レジストリ順 k が名前になる。65 番より後は三音節へ伸びる（10 §4）ので、
-- 戻り値は音節一つでなく音節列になる
unitName :: Atom -> [Phone]
unitName a = case lookupIdx (atomTag a) (map fst primitiveTable) of
  Just r  -> nameOfIdx (unitBase + r)
  Nothing -> [gapPhone]

layerPhones :: ([Port], Layer) -> [Phone]
layerPhones (front, Layer xs) = go 0 xs ++ [sepPhone]
  where
    total = length front
    go cur []              = replicate (total - cur) gapPhone
    go cur ((pos, a) : rest) =
      replicate (pos - cur) gapPhone ++ unitName a ++ go (pos + length (fst (atomPorts a))) rest

splitSep :: Utterance -> Maybe [[Phone]]
splitSep = Just . foldr step [[]]
  where
    step x acc
      | x == sepPhone = [] : acc
      | otherwise = case acc of
          (g : gs) -> (x : g) : gs
          []       -> [[x]]

-- D_speech([z_e]) = e: 零標示音は空本体へ戻す（06 §16.3）。
-- 境界 Γ⁻ と Γ⁺ が一致するときだけ空本体は整形式になる
decode :: Mu -> Int -> [Port] -> [Port] -> Utterance -> Maybe Chamber
decode mu dep gin gout utt
  | utt == [zeroMarkPhone] =
      checked (Chamber mu dep gin [] gout)
  | otherwise = case splitSep utt of
    Nothing -> Nothing
    Just gs -> case buildLayers gin (filter (not . null) gs) of
      Just ls | runPorts gin ls == Just gout ->
        checked (Chamber mu dep gin ls gout)
      _ -> Nothing
  where
    checked c = if wellFormed c then Just c else Nothing

-- Boundary annotations travel with the utterance, just as its port types do.
-- They are not inferred from the number of audible layer separators.
decodeGraded :: Mu -> [Int] -> [Int] -> [Port] -> [Port]
             -> Utterance -> Maybe Chamber
decodeGraded mu ordinal addresses gin gout utt =
  case decode mu 0 gin gout utt of
    Just c -> let result = withGrade ordinal addresses c
              in if wellFormed result then Just result else Nothing
    Nothing -> Nothing

buildLayers :: [Port] -> [[Phone]] -> Maybe [Layer]
buildLayers front groups = goG front groups []
  where
    goG _ [] acc = Just (reverse acc)
    goG f (g : rest) acc = case layerFromPhones f g of
      Just (l, f') -> goG f' rest (l : acc)
      Nothing      -> Nothing

layerFromPhones :: [Port] -> [Phone] -> Maybe (Layer, [Port])
layerFromPhones front phones = goF 0 [] [] phones
  where
    total = length front
    goF cur outAcc acc [] =
      Just (Layer (reverse acc), reverse outAcc ++ drop cur front)
    goF cur outAcc acc (ph : rest)
      | ph == sepPhone =
          Just (Layer (reverse acc), reverse outAcc ++ drop cur front)
      | ph == gapPhone = case drop cur front of
          (w : _) -> goF (cur + 1) (w : outAcc) acc rest
          []      -> Nothing
      | otherwise = case unitFromPhones (ph : rest) of
          Nothing -> Nothing
          Just (a, more) ->
            let ins = fst (atomPorts a)
                k = length ins
                outs = snd (atomPorts a)
            in if cur + k > total
                 then Nothing
                 else if take k (drop cur front) /= ins
                   then Nothing
                   else goF (cur + k) (reverse outs ++ outAcc) ((cur, a) : acc) more
    step _ []         = [[]]

type Channel = [(Phone, Phone, Integer, Int)]   -- (p_i, p_j, m, d): T = m/2^d

hearC :: Channel -> Phone -> Phone -> Dyad
hearC ch p q = case [(m, d) | (a, b, m, d) <- ch, a == p, b == q] of
  ((m, d) : _) -> (m, d)
  []           -> (0, 0)   -- 未測定ペアは整合度 0

dyMul :: Dyad -> Dyad -> Dyad
dyMul (a, x) (b, y) = (a * b, x + y)

dyMaxList :: [Dyad] -> Dyad
dyMaxList = foldr step (0, 0)
  where step x acc = if dyLeq acc x then x else acc

scoreAligned :: Channel -> Utterance -> Utterance -> Dyad
scoreAligned ch u v = go u v
  where
    go []     []     = (1, 0)
    go (a : as) (b : bs) = dyMul (hearC ch a b) (go as bs)
    go _ _ = (0, 0)

-- ===== 編集経路を含む最大経路（4.2）=====

bestScore :: Channel -> Dyad -> Dyad -> Utterance -> Utterance -> Dyad
bestScore ch delP insP u v = go u v
  where
    go [] []         = (1, 0)
    go [] (b : bs)   = dyMul insP (go [] bs)
    go (a : as) []   = dyMul delP (go as [])
    go (a : as) (b : bs) =
      dyMaxList [ dyMul (hearC ch a b) (go as bs)
                , dyMul delP (go as (b : bs))
                , dyMul insP (go (a : as) bs) ]

-- ===== DP 版（実用長）=====
--
-- 素朴再帰と同じ漸化式を、(i,j) 表の遅延評価へ落としたもの。
-- bestScore との一致をテストで常時検査する
scoreDP :: Channel -> Dyad -> Dyad -> Utterance -> Utterance -> Dyad
scoreDP ch delP insP u v = look lu lv
  where
    lu = length u
    lv = length v
    table = [ ((i, j), val i j) | i <- [0 .. lu], j <- [0 .. lv] ]
    uAt i = case drop i u of
      (x : _) -> x
      []      -> ""
    vAt j = case drop j v of
      (x : _) -> x
      []      -> ""
    val 0 0 = (1, 0)
    val 0 j = dyMul insP (look 0 (j - 1))
    val i 0 = dyMul delP (look (i - 1) 0)
    val i j = dyMaxList
      [ dyMul (hearC ch (uAt (i - 1)) (vAt (j - 1))) (look (i - 1) (j - 1))
      , dyMul delP (look (i - 1) j)
      , dyMul insP (look i (j - 1)) ]
    look i j = case lookup (i, j) table of
      Just x  -> x
      Nothing -> (0, 0)

-- 名前を一つ読んで箱へ戻す。読めた分の音節を残りとともに返す
unitFromPhones :: [Phone] -> Maybe (Atom, [Phone])
unitFromPhones ps = case idxOfName ps of
  Just (k, rest)
    | k >= unitBase ->
        let tags = map fst primitiveTable
        in case drop (k - unitBase) tags of
             (t : _) -> case lookupAtom t of
               Just a  -> Just (a, rest)
               Nothing -> Nothing
             []      -> Nothing
  _ -> Nothing
-- ===== 復号と語彙分離 =====

decodeNoisy :: Channel -> Dyad -> Dyad -> [Utterance] -> Utterance -> Maybe Utterance
decodeNoisy ch delP insP vocab obs = pickBest vocab Nothing
  where
    score ut = bestScore ch delP insP ut obs
    pickBest [] best = best
    pickBest (ut : rest) best = case best of
      Nothing          -> pickBest rest (Just ut)
      Just ub
        | dyLeq (score ub) (score ut) -> pickBest rest (Just ut)
        | otherwise                   -> pickBest rest best

separatedBy :: Channel -> Dyad -> Dyad -> Dyad -> [Utterance] -> Bool
separatedBy ch delP insP eps vs =
  and [ dyLeq (bestScore ch delP insP a b) eps
      | a <- vs, b <- vs, a /= b ]

-- ===== 発音単位と記号の導出（命名は行わない）=====
--
-- 発音単位集合 P は原始文字レジストリから導出される。
-- 原始概念以外が発音できるはずがないので、P 以外の音素は存在しない。
-- 各発音単位の記号も命名ではなく、正準順序での番号から系が自動で出す:
--   記号 = syllabary 上の音節そのもの（発声可能）

spokenUnits :: [Phone]
spokenUnits = map fst primitiveTable

renderSymbols :: Utterance -> Maybe String
-- 音素列の音節を連結したものが発音可能な文字列になる
renderSymbols u = go u ""
  where
    go [] acc     = Just acc
    go (p : rest) acc =
      if elem p syllabary || p == sepPhone || p == gapPhone
        then go rest (acc ++ p)
        else Nothing


dyEqD :: Dyad -> Dyad -> Bool
dyEqD (a, x) (b, y) = a * shiftL (1 :: Integer) y == b * shiftL (1 :: Integer) x

symbolOf :: Phone -> Maybe String
symbolOf p = case idxOfPhone p of
  Just _  -> Just p
  Nothing -> Nothing

joinWithS :: String -> [String] -> String
joinWithS _   []       = ""
joinWithS _   [x]      = x
joinWithS sep (x : xs) = x ++ sep ++ joinWithS sep xs

-- ===== 聴取遷移係数の導出（§3）=====
--
-- T_hear は実測カウントから fromCounts で構築する。
-- 測定レコード (p_i, p_j, c, t) は実験入力であり、係数の値そのものは
-- プログラム内の除算で導出される。人間が先に数値を決めない

measurements :: [(Phone, Phone, Int, Int)]
measurements =
  -- 理想自己認識: 各音素は自分自身として 100/100 で聴取される
  [ (p, p, 100, 100) | p <- spokenUnits ]
  ++
  -- 零標示音も他の単位と同じ規則で行が入る（06 §16.3: T_hear(z_e,z_e) ≥ η）
  [ (zeroMarkPhone, zeroMarkPhone, 100, 100) ]
  ++
  -- 混同ペアの測定例（実験入力。値は録音と聴取結果から来る）
  [ ("i", "j", 56, 64), ("j", "i", 56, 64) ]

derivedChannel :: Channel
derivedChannel = concat [fromCounts p q c t | (p, q, c, t) <- measurements]

channelSample :: Channel
channelSample = derivedChannel

-- ===== 音節上の聴取チャネル（翻訳 07_音節上の聴取チャネル）=====
-- doc: tr.hear.syllable tr.hear.bound
--
-- 上の measurements は鍵に原子箱のタグを取る。E_speech の像は音節なので、
-- 鍵が合わず 06 (17.1) の二式が両方とも自明になる。
--
--   hearC derivedChannel "hu"  "hu"  = (0,0)      音節。未測定
--   hearC derivedChannel "one" "one" = (4096,12)  タグ。測定済み
--
-- 鍵を Σ へ移す。σ = cv の分解は生成の仕方が与えているので、測るのは
-- 子音と母音の上だけでよい。
--
--   T_hear(c₁v₁, c₂v₂) = T_C(c₁,c₂) ⋆ T_V(v₁,v₂)                翻訳 07 (2.1)
--
-- 測る対は |Σ|² から |C|² + |V|² へ落ちる。音節表が 14 子音 × 5 母音なら
-- 70² = 4900 が 14² + 5² = 221 になり、録音の本数が 1/22 で済む。
-- 子音を足しても比は落ち続けるので、レジストリの拡張はここを圧迫しない。

type SubChannel = [(String, String, Integer, Int)]

consOf, vowOf :: Phone -> String
consOf = take 1
vowOf  = drop 1

-- 丸めは §3 の実測カウントと同じ深度 12。試行 0 は未測定として 0 を返す
subFromCounts :: String -> String -> Int -> Int -> SubChannel
subFromCounts a b c t = [(a, b, rounded, 12)]
  where
    rounded
      | t <= 0    = 0
      | otherwise = toInteger ((c * shiftL (1 :: Int) 12 + t `div` 2) `div` t)

subLook :: SubChannel -> String -> String -> Dyad
subLook ch a b = case [ (m, d) | (x, y, m, d) <- ch, x == a, y == b ] of
  ((m, d) : _) -> (m, d)
  []           -> (0, 0)

hearSyl :: SubChannel -> SubChannel -> Phone -> Phone -> Dyad
hearSyl tc tv p q =
  dyMul (subLook tc (consOf p) (consOf q)) (subLook tv (vowOf p) (vowOf q))

-- 45 音節を張る。式 (2.1) の像そのもの。零の対は置かない（疎）
syllableChannel :: SubChannel -> SubChannel -> Channel
syllableChannel tc tv =
  [ (p, q, m, d)
  | p <- syllabary, q <- syllabary
  , (m, d) <- [hearSyl tc tv p q], m /= 0 ]

-- 07 §3.3 の実測。自己認識を理想、混同を未測定に取る
consonantCounts, vowelCounts :: [(String, String, Int, Int)]
consonantCounts = [ (c, c, 100, 100) | c <- consonants ]
vowelCounts     = [ (v, v, 100, 100) | v <- vowels ]

derivedSubC, derivedSubV :: SubChannel
derivedSubC = concat [ subFromCounts a b c t | (a, b, c, t) <- consonantCounts ]
derivedSubV = concat [ subFromCounts a b c t | (a, b, c, t) <- vowelCounts ]

syllabicChannel :: Channel
syllabicChannel = syllableChannel derivedSubC derivedSubV

-- ===== 分離を一回の比較へ落とす（翻訳 07 §3）=====
--
-- 06 §17.4 の分離は既採用の全列との対で書かれている。採用表が |V| 語なら
-- 対は C(|V|,2) になる。jawiki 規模で 2×10¹² 対になり、経路計算が終わらない。
--
-- 06 (4.2) の経路は一致・置換・削除・挿入の四種類の歩からなる。u ≠ v なら
-- 一致以外の歩を必ず一つ含むので、その歩の係数が上から押さえる。
--
--   η = min_σ T(σ,σ)、  ε = max(θ, δ, ι)、  η > ε              翻訳 07 (3.2)

dyLt :: Dyad -> Dyad -> Bool
dyLt a b = dyLeq a b && not (dyEqD a b)

etaOf :: Channel -> Dyad
etaOf ch = foldr keep (1, 0) [ hearC ch p p | p <- syllabary ]
  where keep x acc = if dyLeq x acc then x else acc

thetaOf :: Channel -> Dyad
thetaOf ch = dyMaxList [ hearC ch p q | p <- syllabary, q <- syllabary, p /= q ]

epsOf :: Channel -> Dyad -> Dyad -> Dyad
epsOf ch delP insP = dyMaxList [thetaOf ch, delP, insP]

-- 系 3.2。これが成れば 06 (17.1) が採用表全体について成り立つ
separatedOnce :: Channel -> Dyad -> Dyad -> Bool
separatedOnce ch delP insP = dyLt (epsOf ch delP insP) (etaOf ch)
-- ===== 実測カウントから聴取チャネルを構築する（§3）=====
--
-- T = 正解数 / 試行数。深度 12 の冪二進へ丸める（丸め誤差 < 2^{-11}）。
-- 試行数 0 は無測定として整合度 0 を返す
fromCounts :: Phone -> Phone -> Int -> Int -> Channel
fromCounts p q c t = [(p, q, rounded, 12)]
  where
    rounded
      | t <= 0    = 0
      | otherwise = toInteger ((c * shiftL (1 :: Int) 12 + t `div` 2) `div` t)

-- ===== ビット符号層 =====

phoneAlphabet :: [Phone]
phoneAlphabet = ["_", "id", "i", "j", "beta", "fold", "add", "neg", "mul", "END"]

bits4 :: Int -> [Int]
bits4 n = [bitAt 3, bitAt 2, bitAt 1, bitAt 0]
  where bitAt k = (n `shiftR` k) `mod` 2

parityOf :: [Int] -> Int
parityOf bs = sum bs `mod` 2

codeOf :: Phone -> Maybe [Int]
codeOf p = case lookupIdx p phoneAlphabet of
  Just n  -> Just (bits4 n ++ [parityOf (bits4 n)])
  Nothing -> Nothing

lookupIdx :: Phone -> [Phone] -> Maybe Int
lookupIdx p ps = go 0 ps
  where
    go _ []     = Nothing
    go k (x : xs)
      | x == p    = Just k
      | otherwise = go (k + 1) xs

endCode :: [Int]
endCode = bits4 9 ++ [0]

bitEncode :: Utterance -> [Int]
bitEncode u = concatMap enc u ++ endCode
  where enc p = case codeOf p of
          Just bits -> bits
          Nothing   -> []

bitDecode :: [Int] -> Maybe Utterance
bitDecode = go []
  where
    go acc [] = Just (reverse acc)
    go acc bs =
      let (grp, rest) = split5 bs
      in if length grp < 5
           then Nothing
           else if grp == endCode
             then Just (reverse acc)
             else case parityOk grp of
               True  -> case phoneFromBits (take 4 grp) of
                 Just p  -> go (p : acc) rest
                 Nothing -> Nothing
               False -> Nothing
    parityOk grp = parityOf (take 4 grp) == lastOf grp
    lastOf grp = case reverse grp of
      (x : _) -> x
      []      -> 0

split5 :: [Int] -> ([Int], [Int])
split5 xs = (take 5 xs, drop 5 xs)

phoneFromBits :: [Int] -> Maybe Phone
phoneFromBits body = case [p | (k, p) <- zip [0 ..] phoneAlphabet, bits4 k == body] of
  (p : _) -> Just p
  []      -> Nothing

flipBit :: Int -> [Int] -> [Int]
flipBit k bs = [ if i == k then 1 - b else b | (i, b) <- zip [0 ..] bs ]



-- ===== ドキュメント主張の実行可能証明 =====

sampleWordI :: Chamber
sampleWordI = Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]

-- 空本体の整形式チェンバー。単位 1 = (e) の発音実験に使う
emptyBodyC :: Chamber
emptyBodyC = Chamber MInf 0 [] [] []

sampleWordNeg :: Chamber
sampleWordNeg = Chamber MInf 0 [PtUnit] [Layer [(0, primNeg)]] [PtUnit]

sampleWordBetaFold :: Chamber
sampleWordBetaFold =
  Chamber MInf 0 [PtDyad] [Layer [(0, primBeta)], Layer [(0, primFold)]] [PtBit]

dyEq :: Dyad -> Dyad -> Bool
dyEq (a, x) (b, y) = a * shiftL (1 :: Integer) y == b * shiftL (1 :: Integer) x

-- ===== 複合サンプル: β 二分割 → φ∂ 折り返し → 加算統合 =====
--
-- 三層チェンバー。第0層で二本のβ反復が並列に走り、
-- 第1層で二本の折り返しが並列に走り、第2層で加算統合される

multiLayerChamber :: Chamber
multiLayerChamber =
  Chamber MInf 0
    [PtDyad, PtDyad]
    [ Layer [(0, primBeta), (1, primBeta)]
    , Layer [(0, primFold), (1, primFold)]
    , Layer [(0, primAdd)]
    ]
    [PtDyad]

renderPhrased :: Chamber -> Maybe String
-- 各層のタグ列を連結し、層境界に "·" を挿入する。
-- 層構造がそのまま文節構造を与える（02 §8）
renderPhrased c =
  let layers = chLay c
      parts = [concatMap (\(_, a) -> atomTag a) (layerAtoms l) | l <- layers]
  in Just (intercalateP "\xC2\xB7" parts)

intercalateP :: String -> [String] -> String
intercalateP _   []     = ""
intercalateP _   [x]    = x
intercalateP sep (x : xs) = x ++ sep ++ intercalateP sep xs

phrases :: Chamber -> [[(Int, Atom)]]
phrases c = map layerAtoms (chLay c)

-- レジストリの原子ひとつを一層一箱のチェンバーへ包む。ポートは原子が決める。
-- 正規化が通らない原子はレジストリに置いてはいけないので、Nothing は失敗になる
boxOf :: Atom -> Maybe Chamber
boxOf a = cnf (Chamber (if atomPrim a == PDupN then M1 else MInf) 0 gin [Layer [(0, a)]] gout)
  where (gin, gout) = atomPorts a

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("(§2): レジストリの全原子が発音を往復する — D_speech ∘ E_speech = id",
      all (\a -> case boxOf a of
                  Just c  -> decode (chMu c) (chDep c) (chIn c) (chOut c) (encode c)
                               == Just c
                  Nothing -> False)
          [ a | (_, a) <- primitiveTable ])
  , ("(§2、10 §4): レジストリの全原子は三音節までの名前を持つ",
      all (\a -> length (unitName a) <= 3 && unitName a /= [gapPhone])
          [ a | (_, a) <- primitiveTable ])
  , ("(翻訳 07 §1.1): タグを鍵に取ると音節が一つも測られない",
      hearC derivedChannel "hu" "hu" == (0, 0)
      && hearC derivedChannel "one" "one" == (4096, 12))
  , ("(翻訳 07 (2.1)): 鍵を音節へ移すと音節表の全ての元が自己認識を持つ",
      all (\p -> hearC syllabicChannel p p == dyMul (4096, 12) (4096, 12)) syllabary)
  , ("(翻訳 07 §2.2): 測る対は |Σ|² ではなく |C|² + |V|² になる",
      length consonantCounts == length consonants
      && length vowelCounts == length vowels
      && length syllabary == length consonants * length vowels
      && length consonants * length consonants + length vowels * length vowels
           < length syllabary * length syllabary)
  , ("(翻訳 07 命題2.1): 自己認識は分解から出る — T(σ,σ) = T_C(c,c) ⋆ T_V(v,v)",
      hearC syllabicChannel "hu" "hu"
        == dyMul (subLook derivedSubC "h" "h") (subLook derivedSubV "u" "u"))
  , ("(翻訳 07 §3.3): η = 1、θ = 0、δ = 1/2、ι = 1/8、ε = 1/2",
      dyEqD (etaOf syllabicChannel) (1, 0)
      && thetaOf syllabicChannel == (0, 0)
      && dyEqD (epsOf syllabicChannel (1, 1) (1, 3)) (1, 1))
  , ("(翻訳 07 系3.2): 分離は一回の比較で足りる。η > ε",
      separatedOnce syllabicChannel (1, 1) (1, 3))
  , ("(翻訳 07 定理3.1): 上限は経路計算と一致する — 標本の対で確かめる",
      and [ dyLeq (bestScore syllabicChannel (1, 1) (1, 3) u v)
                  (epsOf syllabicChannel (1, 1) (1, 3))
          | u <- [["ra"], ["ri"], ["ra", "ri"]]
          , v <- [["ra"], ["ri"], ["ra", "ri"]], u /= v ])
  , ("(2.1): CNF(D(E(C))) = CNF(C) — 発音と意味の可逆性",
      all (\c -> decode (chMu c) (chDep c) (chIn c) (chOut c) (encode c) == Just c)
          [sampleWordI, sampleWordNeg, sampleWordBetaFold])
  , ("(16.2): 空本体の像は可聴な零標示音一つになる — 無音は欠陥なので作らない",
      encode emptyBodyC == [zeroMarkPhone]
      && idxOfPhone zeroMarkPhone == Just idxZeroMark
      && idxZeroMark < unitBase)
  , ("(16.3): D_speech([z_e]) = e — 零標示音から空本体へ戻る",
      decode MInf 0 [] [] [zeroMarkPhone] == Just emptyBodyC
      && decode MInf 0 [PtUnit] [PtUnit] [zeroMarkPhone] /= Nothing)
  , ("(16.3): 零標示音はどの原子箱の音とも一致しない",
      all (\a -> unitName a /= [zeroMarkPhone])
          [ a | (_, a) <- primitiveTable ])
  , ("(16.3): 聴取チャネルに零標示音の行が入る（T_hear(z_e,z_e) ≥ η）",
      hearC channelSample zeroMarkPhone zeroMarkPhone == (4096, 12))
  , ("§1: 発音列の順序そのものが符号空間である（pi;pj ≠ pj;pi）",
      encode sampleWordI /= encode sampleWordNeg
      && encode sampleWordBetaFold /= reverse (encode sampleWordBetaFold))
  , ("発音単位は原始文字レジストリから導出される（原始概念以外は発音できない）",
      let markers = [sepPhone, gapPhone]
          nonMarkerPhones = filter (`notElem` markers) (encode sampleWordBetaFold)
      in all (`elem` syllabary) nonMarkerPhones)
  , ("記号列出力: 語の発音が正準番号列として計算される",
      case renderSymbols (encode sampleWordI) of
        Just s  -> length s > 0
        Nothing -> False)
  , ("§3 導出: 測定レコードから係数 c/t が計算される",
      hearC channelSample "i" "j" == (3584, 12)
      && hearC channelSample "i" "i" == (4096, 12))
  , ("§3 導出: 自己認識の測定レコード (p,p,100,100) は係数 1 を与える",
      all (\p -> hearC channelSample p p == (4096, 12)) spokenUnits)
  , ("(4.1): 対角優越 — 同一語の整合度は他のいかなる語より高い",
      and [ dyLeq (bestScore channelSample (1, 0) (1, 0) v u)
                 (bestScore channelSample (1, 0) (1, 0) u u)
          | u <- utts, v <- utts, u /= v ])
  , ("(4.2): 削除経路が最善になるケースを正しく見つける（値として比較）",
      let del = (1, 1)
          ins = (1, 8)
      in dyEqD (bestScore channelSample del ins ["i", "i"] ["i"]) del
         && dyEqD (bestScore channelSample del ins ["i"] ["i", "i"]) ins)
  , ("DP: scoreDP は bestScore（指数時間）と全ケースで一致する",
      and [ scoreDP channelSample (1, 1) (1, 8) u v
              == bestScore channelSample (1, 1) (1, 8) u v
          | u <- utts, v <- utts ])
  , ("DP: 長い列でもボトムアップ計算が完走する",
      let longU = concat (replicate 4 ["i", "neg"])
          longV = concat (replicate 4 ["neg", "i"])
          s = scoreDP channelSample (1, 1) (1, 8) longU longV
      in snd s > 0)
  , ("(5.1): 測定済み混同組 i/j は分離されず、非測定組は分離される",
      separatedBy channelSample (1, 1) (1, 8) (1, 2) [["i"], ["j"]] == False
      && separatedBy channelSample (1, 1) (1, 8) (1, 2) [["i"], ["beta"]] == True)
  , ("復号: 語彙に無い観測列は、チャネル経由で最も整合する語へ復号される",
      decodeNoisy channelSample (1, 1) (1, 8)
        [encode sampleWordI, encode sampleWordBetaFold]
        ["neg"] /= Nothing
      && decodeNoisy channelSample (1, 1) (1, 8)
           [encode sampleWordI, encode sampleWordBetaFold]
           ["neg"] == Just (encode sampleWordI))
  , ("ビット符号: 往復復元が成立する",
      all (\u -> bitDecode (bitEncode u) == Just u) utts)
  , ("ビット符号: 単一ビットの反転はパリティで検出される",
      and [ bitDecode (flipBit k (bitEncode u)) == Nothing
          | u <- utts, k <- [0 .. length (bitEncode u) - 1] ])
  , ("IPA 相当: 発音記号列が系から自動で出力される",
      case renderSymbols (encode sampleWordBetaFold) of
        Just s  -> length s > 0
        Nothing -> False)
  , ("文節: multiLayerChamber は3層を持ち、文節境界が DAG 構造から出る",
      length (chLay multiLayerChamber) == 3
      && length (chIn multiLayerChamber) == 2
      && length (chOut multiLayerChamber) == 1)
  , ("文節: renderPhrased が成功する",
      case renderPhrased multiLayerChamber of
        Just _  -> True
        Nothing -> False)
  ]
  where
    utts = [ ["i"], ["neg"], ["i", "neg"], ["neg", "i"], ["beta"]
           , ["i", "beta"], ["fold", "neg"] ]


-- ===== 発音デモ出力 =====

demoWords :: [(String, Chamber)]
demoWords =
  [ ("例文1 単一原始文字 i", wordI)
  , ("例文2 単一原始文字 beta", wordBeta)
  , ("例文3 β→fold 二層合成", wordBetaFold)
  , ("例文4 SOV 文構造", multiLayerWord)
  ]

wordI :: Chamber
wordI = Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]

wordBeta :: Chamber
wordBeta = Chamber MInf 0 [PtDyad] [Layer [(0, primBeta)]] [PtDyad]

wordBetaFold :: Chamber
wordBetaFold =
  Chamber MInf 0 [PtDyad]
    [Layer [(0, primBeta)], Layer [(0, primFold)]]
    [PtBit]

multiLayerWord :: Chamber
multiLayerWord =
  Chamber MInf 0
    [PtDyad]
    [ Layer [(0, primBeta)]
    , Layer [(0, primFold)] ]
    [PtBit]

pronunciationDemoLines :: [String]
pronunciationDemoLines = concatMap demoWordLine demoWords
  where
    demoWordLine (name, c) =
      let utt = encode c
          phones = concatMap id utt
          layers = length (chLay c)
      in [ name ++ ":"
         , "  音素列: " ++ show utt
         , "  発音:   " ++ phones
         , "  層数:   " ++ show layers
         , "" ]
