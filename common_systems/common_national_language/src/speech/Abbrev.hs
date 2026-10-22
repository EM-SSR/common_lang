{-# LANGUAGE NoImplicitPrelude #-}
module Abbrev where

import CounterConstraints
import CounterComputeSystem (Dyad)
import CommonChamber
import JoinRank (rho1)
import Speech

-- ===== 短縮形＝採用語彙（06 §17、翻訳 06〜08）=====
-- doc: abbrev.assign abbrev.space abbrev.select abbrev.deterministic abbrev.preserve
-- doc: tr.abbrev.base tr.abbrev.alphabet tr.abbrev.prefix tr.abbrev.capacity
-- doc: tr.abbrev.order tr.hear.bound
--
-- 基準割当ては機械生成になる。語の各原子箱がレジストリ順 k の音節一つに写り
-- （E_speech）、発声時間は原子数に比例する。採用語彙 V は頻度の高い意味へ
-- 基準より短い列を配る部分関数になる。
--
--   V : 𝒞₀ ⇀ Σ*、  τ(V(C)) ≤ τ(E_speech(C))
--   D_full(y) = C  （y = V(C) のとき）、それ以外は基準の D_speech(y)
--
-- 走査に残る条件は三つだけになる。
--
--   字母  候補を Σ_V の上で取る            翻訳 06 定理 2.2
--   接頭  互いに接頭列にならない            翻訳 06 定理 3.3
--   短縮  τ(u) ≤ τ(E_speech(C))            06 (17.4)
--
-- 分離は走査の外へ出る。η > max(θ,δ,ι) を一度だけ確かめれば採用表全体に効く
-- （翻訳 07 系 3.2）。対ごとの経路計算が消え、jawiki 規模が現実の負荷に入る。

type FreqRec = (Chamber, Int)   -- 観測レコード (C, n)。n は観測回数（17.7）

-- 発声時間 τ。ここでは τ(p) = 1 の一様時間を使う。実測の τ(p) > 0 を入れる場合も
-- 決定性（命題17.5）と意味の保存（命題17.6）は壊れない
tauU :: Utterance -> Int
tauU = length

-- 基準割当て列。空本体のチェンバーは零標示音一つになる（06 §16.2）
baseCol :: Chamber -> Utterance
baseCol = encode

-- ρ(C) = n / N を深度 12 の冪二進へ落とす（17.7）
freqDyad :: [FreqRec] -> Chamber -> Dyad
freqDyad recs c = (toInteger num12, 12)
  where
    n    = sum [ m | (c', m) <- recs, c' == c ]
    tot  = sum [ m | (_, m) <- recs ]
    num12
      | tot <= 0  = 0
      | otherwise = (n * shiftL (1 :: Int) 12 + tot `div` 2) `div` tot

-- ===== 候補の空間（翻訳 06 §2）=====
--
-- 𝒞 は無限集合なので（命題 8.1）、「全意味の基準列と異なる」を候補ごとに検査する
-- 形では条件が閉じない。字母で切ると型として閉じる。
--
--   Σ_V = Σ ∖ Σ_base、  V(𝒞₀) ⊆ Σ_V⁺                          翻訳 06 (2.1)
--
-- 正準順は長さ昇順、同一長は音節番号の辞書順になる（17.3）。sigmaV は音節表の
-- 順に並んでいるので、この生成がそのまま正準順になる
canonCandidatesUpTo :: Int -> [Utterance]
canonCandidatesUpTo maxlen = concatMap seqs [1 .. maxlen]
  where
    seqs 0 = [[]]
    seqs n = [ p : rest | p <- sigmaV, rest <- seqs (n - 1) ]

-- 辞書順比較のための音節番号列。正準順 = このキーの昇順
uttKey :: Utterance -> [Int]
uttKey u = [ k | p <- u, Just k <- [idxOfPhone p] ]

-- ===== 接頭条件（翻訳 06 §3）=====
--
-- 字母の分離だけでは連接に曖昧さが残る。V(C₁) = mi、V(C₂) = mu、V(C₃;C₄) = mimu は
-- 互いに異なるが、C₁;C₂ を書くと mimu になり、最長一致で読むと C₃;C₄ が返る。

isPrefixU :: Utterance -> Utterance -> Bool
isPrefixU u v = take (length u) v == u

prefixFree :: Utterance -> [Utterance] -> Bool
prefixFree u vs = all (\v -> not (isPrefixU u v) && not (isPrefixU v u)) vs

-- ===== 採用の鍵（06 (17.5)、翻訳 08 (4.1)）=====
--
--   key(C) = ( −n_C, ρ₁(C), uttKey(E_speech(C)) )
--
-- 第二成分の接合秩は語チェンバーの上で定数になる（JoinRank の実測）。原型が
-- 全部廃棄で閉じるので、fr(Λ₁) から Γ⁺ へ渡る独立影響が語に依らない。
-- 鍵に置いても順序は動かないが、意味 program の語彙（10 §6）では効く
selKey :: [FreqRec] -> Chamber -> (Int, Int, [Int])
selKey recs c = (negate n, rho1 c, uttKey (baseCol c))
  where n = sum [ m | (c', m) <- recs, c' == c ]

-- ===== 採用列は正準番号の展開になる（10 §1.2）=====
--
-- 10 §1.2 は原子箱の名前を「正準番号を 45 進で音節列へ展開する」と定める。
-- 採用語彙も同じ写像を Σ_V の上で取る。
--
--   V(C) = ι(C) を |Σ_V| 進 n 桁で Σ_V へ展開                    10 (1.2)
--
-- 桁を揃えるので接頭条件が構成から立つ（翻訳 06 定理 3.3）。06 §12 の
-- 非可換性がそのまま位取りになり、順列が別の語になる。
--
-- 候補を一つずつ試す走査は使わない。長さ昇順の貪欲は |Σ_V| 語で行き止まる。
-- 長さ 1 の列を配り切った時点で、長さ 2 以上は全部が採用済みの接頭を持つ。

colOfIndex :: Int -> Int -> Utterance
colOfIndex width i = reverse (take width (expand i))
  where
    b = length sigmaV
    expand k = digit (mod k b) : expand (div k b)
    digit d = case drop d sigmaV of
      (p : _) -> p
      []      -> ""

-- 展開の逆。採用列から正準番号へ戻る
indexOfCol :: Utterance -> Int
indexOfCol = foldl step 0
  where
    b = length sigmaV
    step acc p = acc * b + pos 0 sigmaV
      where
        pos k (x : xs) = if x == p then k else pos (k + 1) xs
        pos _ []       = 0

-- ===== 選択手続き（06 §17.4）=====
--
-- 分離が破れたら表を作らない。系 3.2 の一回の比較がここに入る。
-- 走査に残るのは短縮だけになる。基準列が n 音節より短い意味は基準のまま置く
selectVocab :: Channel -> Dyad -> Dyad -> [FreqRec] -> [(Chamber, Utterance)]
selectVocab ch delP insP recs
  | not (separatedOnce ch delP insP) = []
  | otherwise =
      [ (c, u)
      | (i, c) <- zip [0 ..] ordered
      , u <- [colOfIndex width i]
      , tauU u <= tauU (baseCol c) ]
  where
    measured = dedupOn [ r | r@(_, n) <- recs, n > 0 ]
    -- Chamber は Ord を持たない（無断の順序づけを避けている）。正準直列化を
    -- 第四成分に置いて全順序を閉じる
    ordered  = [ byser s
               | (_, s) <- sort [ (selKey measured c, ser c) | (c, _) <- measured ] ]
    byser s  = case [ c | (c, _) <- measured, ser c == s ] of
      (c : _) -> c
      []      -> emptyBodyC
    width = neededLength (toInteger (length ordered))

    dedupOn []              = []
    dedupOn (r@(c, _) : xs) = r : dedupOn [ y | y@(c', _) <- xs, c' /= c ]

-- 採用後の列 V^ext(C)。採用があれば採用列、なければ基準列
extendVocab :: Int -> Channel -> Dyad -> Dyad -> [(Chamber,Utterance)]
            -> [FreqRec] -> Either String [(Chamber,Utterance)]
extendVocab width ch delP insP old recs
  | width < 1 = Left "採用列の桁数は正である必要がある"
  | any (\(_,u) -> null u || any (`notElem` sigmaV) u) old = Left "既存の採用字母が不正"
  | not (validOld old) = Left "既存の採用表に重複または接頭衝突がある"
  | not (separatedOnce ch delP insP) = Left "音声の分離条件を満たさない"
  | otherwise = appendNew old ordered (freeColumns width [])
  where
    validOld [] = True
    validOld ((c,u):xs) = notElem c (map fst xs) && prefixFree u (map snd xs) && validOld xs
    unique [] = []
    unique (c:cs) = c:unique (filter (/= c) cs)
    pending = unique [c | (c,n) <- recs, n > 0, notElem c (map fst old)]
    ordered = [c | (_,_,i) <- sort [(selKey recs c,ser c,i) | (i,c) <- zip [0..] pending],
                   c <- take 1 (drop i pending)]
    freeColumns left prefix
      | any (\(_,u) -> isPrefixU u prefix) old = []
      | left == 0 = [prefix | prefixFree prefix (map snd old)]
      | otherwise = concat [freeColumns (left-1) (prefix ++ [p]) | p <- sigmaV]
    appendNew table [] _ = Right table
    appendNew table (c:cs) candidates
      | width > length (baseCol c) = appendNew table cs candidates
      | otherwise = case candidates of
          [] -> Left "既存の採用表を保持できる未使用列がない"
          (u:us) -> appendNew (table ++ [(c,u)]) cs us

extCol :: [(Chamber, Utterance)] -> Chamber -> Utterance
extCol table c = case [ u | (c', u) <- table, c' == c ] of
  (u : _) -> u
  []      -> baseCol c

-- D_full（17.2）: 採用表を先に照合し、落ちたら基準の復号へ渡す
decodeFull :: [(Chamber, Utterance)] -> (Utterance -> Maybe Chamber)
           -> Utterance -> Maybe Chamber
decodeFull table baseDecode y = case [ c | (c, u) <- table, u == y ] of
  (c : _) -> Just c
  []      -> baseDecode y

-- ===== 容量（翻訳 06 §4）=====
--
-- 接頭符号なので、長さ n ちょうどの列で埋めれば |Σ_V|ⁿ 語が取れる

capacity :: Int -> Integer
capacity n = foldr (\_ acc -> acc * toInteger (length sigmaV)) 1 [1 .. n]

-- 語型数を収めるのに要る列の長さ
neededLength :: Integer -> Int
neededLength want = go 1
  where go n = if capacity n >= want then n else go (n + 1)

-- ===== ドキュメント主張の実行可能証明 =====

sampleLong :: Chamber
sampleLong = Chamber MInf 0 [PtDyad]
  [Layer [(0, primBeta)], Layer [(0, primFold)]] [PtBit]

sampleShort :: Chamber
sampleShort = Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]

sampleThird :: Chamber
sampleThird = Chamber MInf 0 [PtDyad] [Layer [(0, primNegD)]] [PtDyad]

testChannel :: Channel
testChannel = syllabicChannel

testDelP, testInsP :: Dyad
testDelP = (1, 1)      -- δ = 1/2
testInsP = (1, 3)      -- ι = 1/8

testRecs :: [FreqRec]
testRecs = [ (sampleLong, 100), (sampleShort, 10), (sampleThird, 5), (emptyBodyC, 0) ]

testTable :: [(Chamber, Utterance)]
testTable = selectVocab testChannel testDelP testInsP testRecs

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("(翻訳 06 命題1.1): 基準列は基準字母に閉じる",
      all (\c -> all (\p -> elem p sigmaBase) (baseCol c))
          [sampleLong, sampleShort, sampleThird, emptyBodyC, sampleWordBetaFold])
    -- 一音節の名前を使い切るまでは |Σ_base| = 3 + |𝒜| になる。使い切った後は
    -- 名前が三音節へ伸びるので、Σ_base は nameCap で止まり Σ_V は残る（10 §4）
  , ("(翻訳 06 (1.2)): Σ_base はレジストリから出る。|Σ_base| = min(nameCap, 3 + |𝒜|)",
      length sigmaBase == min nameCap (unitBase + length primitiveTable))
  , ("(翻訳 06 (2.1)): Σ_V は補集合。基準字母と交わらず、合わせて音節表になる",
      all (\p -> notElem p sigmaBase) sigmaV
      && length sigmaBase + length sigmaV == length syllabary
      && not (null sigmaV))
  , ("(翻訳 06 定理2.2): 採用列は Σ_V⁺ にあり、どの意味の基準列とも一致しない",
      all (\(_, u) -> all (\p -> elem p sigmaV) u) testTable
      && and [ u /= baseCol c
             | (_, u) <- testTable
             , c <- [sampleLong, sampleShort, sampleThird, emptyBodyC] ])
  , ("(翻訳 06 定理3.3): 接頭条件 — どの採用列も相手の接頭列にならない",
      and [ not (isPrefixU a b)
          | (_, a) <- testTable, (_, b) <- testTable, a /= b ])
  , ("(10 (1.2)): 採用列は正準番号の |Σ_V| 進展開になる。展開と逆読みが戻る",
      let b = length sigmaV
      in all (\i -> indexOfCol (colOfIndex 4 i) == i)
             [0, 1, b - 1, b, b * b + 3, b * b * b + b + 2]
         && colOfIndex 1 0 == take 1 sigmaV
         && colOfIndex 2 b == take 1 (drop 1 sigmaV) ++ take 1 sigmaV)
  , ("桁を揃えるので接頭条件は構成から立つ。長さが同じ列は互いに接頭でない",
      and [ length a == length b
          | (_, a) <- testTable, (_, b) <- testTable ])
  , ("(翻訳 07 系3.2): 分離は表を作る前の一回の比較で閉じる",
      separatedOnce testChannel testDelP testInsP)
  , ("分離が破れたチャネルでは表を作らない",
      null (selectVocab derivedChannel testDelP testInsP testRecs))
  , ("(17.4): 短縮 — 採用列の発声時間は基準列以下",
      all (\(c, u) -> tauU u <= tauU (baseCol c)) testTable)
  , ("(17.4): 高頻度の意味ほど正準順で先頭に近い列を採用する",
      uttKey (extCol testTable sampleLong) <= uttKey (extCol testTable sampleShort))
  , ("命題17.5: 同じ入力に対して採用表は一意である",
      testTable == selectVocab testChannel testDelP testInsP testRecs)
  , ("命題17.6: 意味の保存 — CNF(D_full(V^ext(C))) = CNF(C)",
      all (\c -> decodeFull testTable
                   (decode (chMu c) (chDep c) (chIn c) (chOut c))
                   (extCol testTable c) == Just c)
          [ c | (c, _) <- testTable ])
  , ("命題17.6: 単射性 — C₁ ≢ C₂ なら V^ext(C₁) ≠ V^ext(C₂)",
      extCol testTable sampleLong /= extCol testTable sampleShort)
  , ("(17.2): 採用表に無い列は基準の復号へ落ちる",
      decodeFull [] (decode MInf 0 (chIn sampleShort) (chOut sampleShort))
                 (baseCol sampleShort) == Just sampleShort)
  , ("(17.7): 頻度は観測レコードから冪二進へ落ちる — 100/115 → 深度 12",
      freqDyad testRecs sampleLong == (3562, 12))
  , ("頻度 0 の意味は採用対象にならない",
      all (\(c, _) -> c /= emptyBodyC) testTable)
  , ("版の安定性: 低頻度の意味を後から足しても既存の割当ては変わらない",
      let t1 = selectVocab testChannel testDelP testInsP
                 [ (sampleLong, 100), (sampleShort, 10) ]
          t2 = selectVocab testChannel testDelP testInsP
                 [ (sampleLong, 100), (sampleShort, 10), (sampleThird, 1) ]
      in all (\(c, u) -> extCol t2 c == u) t1)
  , ("(翻訳 06 §4.1): 容量は |Σ_V|ⁿ。長さを一つ伸ばすと |Σ_V| 倍になる",
      let b = toInteger (length sigmaV)
      in capacity 1 == b && capacity 5 == b * capacity 4
         && capacity 6 == b * capacity 5)
  , ("(翻訳 06 §4.2): 現在の採用字母で語型数を収める最短の音節数を求める",
      all (\n -> capacity (neededLength n) >= n
                 && capacity (neededLength n - 1) < n)
          [2933, 200000, 2000000])
  ]
