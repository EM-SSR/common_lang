{-# LANGUAGE NoImplicitPrelude #-}
module PlainText where

import CounterConstraints
import CommonChamber
import Speech (Utterance, encode)

-- ===== 平文がプログラムになる（16 章）=====
-- doc: plain.text plain.gamma plain.wordfree plain.tensor plain.one plain.dupdrop
-- doc: plain.comment plain.rules layer.maximal layer.nf
--
-- .cmn は文章チェンバー C_P の音節列そのものになる。欄も行構文も語境界も無い。
--
--   .cmn   = E_speech(C_P) ∈ Σ*                                    式 (1.1)
--   D_text = D_speech ∘ filter_Σ                                   式 (1.2)
--
-- 列の形は構成語 §2.2 の最大平行層形式が決めている。
--
--   h(v) = 0                         Pred(v) = ∅
--   h(v) = 1 + max_{u∈Pred(v)} h(u)  その他
--
--   同じ層の箱は消費する入力区間の左端位置で昇順に並べる。
--   変化しない区間には恒等箱を挿入する。
--
-- 定理 2.1 により、この分解は一意になる。だから読みは文法解析ではなく復号であり、
-- 書き手が座標を管理する場所はどこにも無い。層境界音が層を切り、無声ワイヤ音が
-- 恒等箱を表す。どちらも発声できる音節である（06 §2）。
--
-- SOV は公理ではない。02 §9 命題 9.1 が層順の一次元表示として導いている。
-- 引数を作るチェンバーは第 0 層、作用チェンバーは第 1 層に落ちる。

-- ===== 1. filter_Σ =====
--
-- 音節表の元だけが意味を持つ。空白、改行、句読点、括弧、説明の記号は落ちる。
-- ただし ASCII 小文字が音節へ切れない所だけは誤りとして上げる。黙って捨てると
-- 訳し間違いが静かに別の program になる。

sigmaOf :: String -> Either String Utterance
sigmaOf = go 0 []
  where
    go _ acc [] = Right (reverse acc)
    go i acc (c : rest)
      | isLower c = case rest of
          (v : more) | elem [c, v] syllabary -> go (i + 2) ([c, v] : acc) more
          _ -> Left ("位置 " ++ showI i ++ " の字が音節にならない: "
                     ++ take 4 (c : rest))
      | otherwise = go (i + 1) acc rest

isLower :: Char -> Bool
isLower c = c >= 'a' && c <= 'z'

showI :: Int -> String
showI k = go (abs k) ""
  where
    go n acc
      | n < 10    = digit n : acc
      | otherwise = go (n `div` 10) (digit (n `mod` 10) : acc)
    digit d = case drop d "0123456789" of
      (x : _) -> x
      []      -> '?'

-- ===== 2. 語彙 =====
--
-- 一語は音節の列であり、意味は原子箱になる。基準割当ては機械生成で、
-- レジストリ順 k が unitBase + k の音節ひとつに写る（06 §2）。採用語彙
-- （06 §17）を足すときは頻度の高い意味へ別の列を割り当て、lexicon の前へ置く。
-- 最長一致で引くので基準列は常に残る。

type Lexeme = (Utterance, Chamber)

baseLexicon :: [Lexeme]
baseLexicon = [ (nameOfIdx (unitBase + k), atomC a)
              | (k, (_, a)) <- zip [0 ..] primitiveTable ]
  where atomC a = Chamber MInf 1 (fst (atomPorts a)) [Layer [(0, a)]] (snd (atomPorts a))

-- doc: plain.lexicon plain.splice plain.emit abbrev.select
validateLexicon :: [Lexeme] -> Either String ()
validateLexicon lex0
  | any (null . fst) lex0 = Left "採用列が空"
  | any (not . wellFormed . snd) adopted = Left "語彙のチェンバーが整形式でない"
  | any ((/= MInf) . chMu . snd) lex0 = Left "平文の語彙は mu=inf が必要"
  | any badAlphabet adopted = Left "採用列が基準字母と衝突する"
  | any overlap [(u, v) | (i, (u, _)) <- zip [0 :: Int ..] lex0,
                            (j, (v, _)) <- zip [0 :: Int ..] lex0, i < j] =
      Left "語彙の列が接頭関係にある"
  | otherwise = Right ()
  where
    adopted = filter (`notElem` baseLexicon) lex0
    badAlphabet (u, _) = any (`notElem` sigmaV) u
    overlap (u, v) = take (length u) v == u || take (length v) u == v

readLexicon :: String -> Either String [Lexeme]
readLexicon txt = case mapM row [x | x <- splitOnC '\n' txt, not (null x), x /= "\r"] of
  Left e -> Left e
  Right adopted -> case validateLexicon (adopted ++ baseLexicon) of
    Left e -> Left e
    Right () -> Right (adopted ++ baseLexicon)
  where
    row s = case splitOnC '\t' (filter (/= '\r') s) of
      [u, body] -> case (sigmaOf u, parse body) of
        (Right ps, Just c) -> Right (ps, c)
        _ -> Left "語彙表の音節列またはチェンバーが読めない"
      _ -> Left "語彙表は音節列と正準チェンバーをtabで区切る"

sepP, gapP :: Phone
sepP = phoneOfIdx idxBoundary
gapP = phoneOfIdx idxSilent

-- 最長一致。採用語彙が基準列より長い場合も正しく引ける
lexAt :: [Lexeme] -> Utterance -> Maybe (Chamber, Utterance)
lexAt lex0 ps = pick Nothing lex0
  where
    pick best [] = best
    pick best ((u, a) : rest)
      | take (length u) ps == u = pick (better best (length u) a) rest
      | otherwise               = pick best rest
    better Nothing n a = Just (a, drop n ps)
    better (Just (a0, r0)) n a
      | length ps - n < length r0 = Just (a, drop n ps)
      | otherwise                 = Just (a0, r0)

-- ===== 3. 層への切り分け =====

splitLayers :: Utterance -> [Utterance]
splitLayers = foldr step [[]]
  where
    step x acc
      | x == sepP = [] : acc
      | otherwise = case acc of
          (g : gs) -> (x : g) : gs
          []       -> [[x]]

-- 層を一つ組む。診断の名前は構成語 §15.4 のものを使う
layerStep :: [Lexeme] -> Int -> [Port] -> Utterance -> Either String ([Layer], [Port])
layerStep lex0 r front = go 0 [] []
  where
    total = length front
    at = "層 " ++ showI r ++ ": "
    go cur outAcc acc [] =
      Right ([Layer (reverse acc)], reverse outAcc ++ drop cur front)
    go cur outAcc acc ps@(ph : rest)
      | ph == gapP = case drop cur front of
          (w : _) -> go (cur + 1) (w : outAcc) acc rest
          []      -> Left (at ++ "無声ワイヤが frontier の外を指す（暗黙廃棄）")
      | otherwise = case lexAt lex0 ps of
          Nothing -> Left (at ++ "語彙に無い音節 " ++ ph)
          Just (c, more) ->
            let ins = chIn c
                outs = chOut c
                k = length ins
            in if cur + k > total
                 then Left (at ++ ph ++ " の入力が frontier を越える（境界不一致）")
                 else if take k (drop cur front) /= ins
                   then Left (at ++ ph ++ " の入力型が合わない（型と座標の混同）")
                   else case chLay c of
                     [] -> go (cur + k) (reverse outs ++ outAcc) acc more
                     [Layer xs] -> go (cur + k) (reverse outs ++ outAcc)
                                       (reverse [(cur + q, a) | (q, a) <- xs] ++ acc) more
                     ls | not (null acc) || any (/= gapP) more ->
                            Left (at ++ "複数層の語と他の箱が同じ層にある")
                        | cur + k + length more > total ->
                            Left (at ++ "無声ワイヤが frontier の外を指す")
                        | otherwise ->
                            let expanded = [Layer [(cur + q, a) | (q, a) <- xs] | Layer xs <- ls]
                            in case runPorts front expanded of
                              Just final -> Right (expanded, final)
                              Nothing -> Left (at ++ "合成語の内部境界が合わない")

-- ===== 4. D_text =====
--
-- Γ⁻ = I、μ = ∞。Γ⁺ は層を当てて導く（定理 2.2）。d は本体から計算する。

readPlain :: String -> Either String Chamber
readPlain = readWith baseLexicon

readWith :: [Lexeme] -> String -> Either String Chamber
readWith lex0 txt = case validateLexicon lex0 of
  Left e -> Left e
  Right () -> case sigmaOf txt of
    Left e    -> Left e
    Right utt -> fromUtterance lex0 utt

fromUtterance :: [Lexeme] -> Utterance -> Either String Chamber
fromUtterance lex0 utt
  | null utt || utt == [zeroMarkPhone] = Right (Chamber MInf 0 [] [] [])
  | otherwise = case build 0 [] groups [] of
      Left e -> Left e
      Right (ls, gout) -> case mapM wordsOf groups of
        Left e -> Left e
        Right rows ->
          let plain = Chamber MInf (depthOf ls) [] ls gout
              grade = foldl ordinalPlus []
                [foldl ordinalMax [] [fst (chamberGrade w) | w <- row] | row <- rows]
              addresses = concat [snd (chamberGrade w) | row <- rows, w <- row]
              graded (GradedChamber {}) = True
              graded _ = False
              c = if any graded (concat rows) then withGrade grade addresses plain else plain
          in if wellFormed c then Right c else Left "語の複製・廃棄が型で許されない"
  where
    groups = [ g | g <- splitLayers utt, not (null g) ]
    wordsOf [] = Right []
    wordsOf (p:ps) | p == gapP = wordsOf ps
    wordsOf ps = case lexAt lex0 ps of
      Just (c,rest) -> case wordsOf rest of
        Right cs -> Right (c:cs)
        Left e -> Left e
      Nothing -> Left "語彙に無い音節"
    build _ front [] acc = Right (reverse acc, front)
    build r front (g : rest) acc = case layerStep lex0 r front g of
      Left e            -> Left e
      Right (ls, front') -> build (r + length ls) front' rest (reverse ls ++ acc)

-- 作図深度。d(f;g) = d(f) + d(g)、原始箱は 1、恒等ワイヤは 0（13 §2.1）。
-- 有限のチェンバーでは層ごとの最大値の和になり、空でない層の数に一致する
depthOf :: [Layer] -> Int
depthOf ls = length [ () | Layer xs <- ls, not (null xs) ]

-- ===== 5. E_text =====
--
-- 06 §2 の E_speech をそのまま使う。層境界音で層を切り、覆われない位置へ
-- 無声ワイヤ音を置く。これが §2.2 の「変化しない区間には恒等箱を挿入する」の
-- 発音側の姿になる。

writePlain :: Chamber -> String
writePlain = concat . encode

writeWith :: [Lexeme] -> Chamber -> Either String String
writeWith lex0 c = case validateLexicon lex0 of
  Left e -> Left e
  Right () | not (wellFormed c) -> Left "書き出すチェンバーが整形式でない"
           | null (chLay c) && not (null (snd (chamberGrade c))) ->
               Left "空の発音では閉包アドレスを再現できない"
           | null (chLay c) -> Right zeroMarkPhone
           | otherwise -> fmapE concat (go (snd (chamberGrade c)) (chIn c) (chLay c))
  where
    fmapE f (Right x) = Right (f x)
    fmapE _ (Left e) = Left e
    adopted = filter (`notElem` baseLexicon) lex0
    best = foldr (\x acc -> case acc of
                    [] -> [x]
                    (y : _) -> if key x < key y then [x] else acc) []
    key (n, u, _) = (n, [k | p <- u, Just k <- [idxOfPhone p]])
    go [] _ [] = Right []
    go _ _ [] = Left "採用語彙で閉包アドレスを再現できない"
    go addresses front ls@(l : rest) = case best
      [ (negate (length (chLay word)), u, word)
      | (u, word) <- adopted, not (null (chLay word)),
        chIn word == front, take (length (chLay word)) ls == chLay word,
        let wordAddresses = snd (chamberGrade word),
        take (length wordAddresses) addresses == wordAddresses ] of
      ((_, u, word) : _) -> fmapE ((u ++ [sepP]) ++)
                              (go (drop (length (snd (chamberGrade word))) addresses)
                                  (chOut word) (drop (length (chLay word)) ls))
      [] | any (\(_,a) -> notElem a (map snd primitiveTable)) (layerAtoms l) ->
             Left "基準発音を持たない構成には採用語彙が必要"
         | otherwise -> case stepPorts front l of
        Nothing -> Left "出力境界が合わない"
        Just out -> fmapE (encode (Chamber (chMu c) 1 front [l] out) ++)
                          (go addresses out rest)

-- 読みやすさのために音節を n 個ごとに区切る。意味は変わらない（命題 11.1）
groupBy2 :: Int -> String -> String
groupBy2 n s = go s
  where
    go [] = []
    go xs = case (take (n * 2) xs, drop (n * 2) xs) of
      (a, [])   -> a
      (a, rest) -> a ++ " " ++ go rest

-- ===== 6. 境界の幅がコメントを決める（16 §4）=====
--
-- 計算に効かない文は Γ⁻ = Γ⁺ = I のチェンバーになる。I はテンソル単位なので
-- 境界流を変えないが、テンソルには載り CNF を持ち、#k で参照できる。
-- 構文としてのコメントは存在しない。

isAside :: Chamber -> Bool
isAside c = null (chIn c) && null (chOut c)

-- ===== ドキュメント主張の実行可能証明 =====
--
-- 音節の割当ては primitiveTable の順で決まる。
--   ka 層境界   ki 無声ワイヤ
--   hu one   no ⊕   ha ⊖   se β   ti ⋆   so φ∂   he Δ   ho !

-- 2 = 1 ⊕ 1
textTwo :: String
textTwo = "hu hu ka, no ka."

-- β は基準点 1 の二分割になる（構成語 §8.1 で a = 1、Level 3 の梯子）。
--   β(x) = (x+1)/2、  β(1) = 1
-- 1 は不動点なので半分は 1 から作れない。零を先に立てる。
--   0 = 1 ⊕ (⊖1)、  1/2 = β(0)、  3/4 = β(β(0))
textThreeQuarter :: String
textThreeQuarter = "hu hu ka, ki ha ka, no ka, se ka, se ka."

-- 複製で値を使い回す。暗黙の複製は §15.4 の診断になるので必ず he を通す
textReuse :: String
textReuse = "hu ka, he ka, no ka."

-- 計算に効かない文（16 §4）。値を立てて廃棄で閉じるので I → I になる
textAside :: String
textAside = "hu ka, se ka, se ka, ho ka."

textEmpty :: String
textEmpty = ""

valueOf :: Chamber -> Maybe [Value]
valueOf c = evalChamber c []

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("(16 §1): 平文を読むと Γ⁻ = I、μ = ∞ のチェンバーになる",
      case readPlain textTwo of
        Right c -> null (chIn c) && chMu c == MInf
        Left _  -> False)
  , ("(16 §3): one が I → Dyad を立てる。1 ⊕ 1 = 2",
      case readPlain textTwo of
        Right c -> valueOf c == Just [VDyad (2, 0)]
        Left _  -> False)
  , ("(命題9.1): 引数は第 0 層、作用は第 1 層へ落ちる（SOV の一次元表示）",
      case readPlain textTwo of
        Right c -> map (map (atomTag . snd) . layerAtoms) (chLay c)
                     == [["one", "one"], ["addd"]]
        Left _  -> False)
  , ("(16 §3.1): 数の literal は要らない。3/4 が合成だけで書ける",
      case readPlain textThreeQuarter of
        Right c -> valueOf c == Just [VDyad (3, 2)]
        Left _  -> False)
  , ("(§2.2): 変化しない区間には恒等箱が入る。無声ワイヤ音がその位置を送る",
      case readPlain textThreeQuarter of
        Right c -> length (chLay c) == 5
        Left _  -> False)
  , ("(§3.5): 再利用は明示の複製を通す。暗黙の複製は書けない",
      case readPlain textReuse of
        Right c -> valueOf c == Just [VDyad (2, 0)]
        Left _  -> False)
  , ("(16 §4): 廃棄で閉じた文は I → I になる。注記はデータでありコードになる",
      case readPlain textAside of
        Right c -> isAside c && valueOf c == Just [] && length (chLay c) == 4
        Left _  -> False)
  , ("(命題11.1): 空白・改行・句読点は意味を作らない",
      readPlain "huhukanoka" == readPlain "hu hu ka\n\nno ka\n"
      && readPlain "huhukanoka" == readPlain "hu, hu ka. no ka!")
  , ("(06 §2): E_text ∘ D_text = id（注記を含めて音節列へ戻る）",
      and [ case readPlain t of
              Right c -> readPlain (writePlain c) == Right c
              Left _  -> False
          | t <- [textTwo, textThreeQuarter, textReuse, textAside] ])
  , ("(02 §12): 単射。違う平文は違うチェンバーへ落ちる",
      readPlain textTwo /= readPlain textThreeQuarter)
  , ("(16 §4): 語が一つも無い文は I → I になり、境界流を変えない",
      case readPlain textEmpty of
        Right c -> isAside c && valueOf c == Just []
        Left _  -> False)
  , ("(16 §1.2): 音節へ切れない字は誤りとして上がる",
      case readPlain "huhuz" of
        Left _  -> True
        Right _ -> False)
  , ("(§15.4): 入力が frontier を越える文は境界不一致で止まる",
      case readPlain "no ka" of
        Left _  -> True
        Right _ -> False)
  , ("(§15.4): 型が合わない接続は止まる — φ∂ の出力へ β は当たらない",
      case readPlain "hu ka, so ka, se ka" of
        Left _  -> True
        Right _ -> False)

  , ("合成語の展開は基準列と同じチェンバーになる",
      case readPlain textThreeQuarter of
        Right c -> readWith (([head sigmaV], c) : baseLexicon) (head sigmaV ++ sepP) == Right c
        _ -> False)
  , ("合成語は前後の層へ接続できる",
      case readPlain textTwo of
        Right c -> case readWith (([head sigmaV], c) : baseLexicon)
                                   (head sigmaV ++ sepP ++ "heka noka") of
          Right d -> valueOf d == Just [VDyad (4, 0)]
          _ -> False
        _ -> False)
  , ("複数層の語と同層の別の箱は衝突する",
      case readPlain textTwo of
        Right c -> case readWith (([head sigmaV], c) : baseLexicon)
                                   (head sigmaV ++ "hu" ++ sepP) of
          Left _ -> True
          _ -> False
        _ -> False)
  , ("採用列は接頭関係を拒否する",
      case readPlain textTwo of
        Right c -> case validateLexicon (([head sigmaV], c) : ([head sigmaV, head sigmaV], c) : baseLexicon) of
          Left _ -> True
          _ -> False
        _ -> False)
  , ("採用列の書き出しと復号が一致する",
      case readPlain textThreeQuarter of
        Right c -> let lex0 = ([head sigmaV], c) : baseLexicon
                   in writeWith lex0 c == Right (head sigmaV ++ sepP)
                      && readWith lex0 (head sigmaV ++ sepP) == Right c
        _ -> False)

  ]
