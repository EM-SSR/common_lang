{-# LANGUAGE NoImplicitPrelude #-}
module Common.Lang.NL where

import CounterConstraints
import CommonChamber
import qualified SparseTensor as ST
import qualified Speech as Sp
import qualified Abbrev as Ab
import qualified Ideogram as Ig
import qualified Multimodal as Mm

-- ===== コモン公用語による Common Assembler の source 層 =====
-- doc: casm.nl.name casm.nl.registry casm.nl.wf casm.nl.vocab casm.nl.modal casm.nl.unit
-- 参照: 仕様 §32.1、§4、docs/common-compiler/lang/10
--
-- source は mnemonic 列ではない。正準化したチェンバーを三次元疎テンソル
-- S(k,q,r)=Atom へ写したものが source の本体になる。ここでは logical file
-- unit（式 32.6）をコモン公用語の音節列だけで直列化する。

-- ===== 音節名 =====

-- 名前は CommonChamber.nameOfIdx が決める（10 式 1.2）。ここでは音節列を
-- 連結して token にする。NL の直列化は token を空白で切るので、平文の側で
-- 要る接頭自由性はここでは効かない
kindNameOfIdx :: Int -> String
kindNameOfIdx = concat . nameOfIdx

-- ===== 意味レジストリ（§32.2）=====
--
-- target 非依存の構成生成元だけを置く。machine 命令名・register 名・符号は
-- ここに現れない（§53）。順序が正準番号を決めるので、並べ替えると名前が変わる。

data MKind
  = MCst    -- 二進有理定数 x/2^δ の物質化
  | MAdd    -- 加算。平行四辺形則（経路を忘れる）
  | MMul    -- 乗算。タレス比（経路を保持する）
  | MNeg    -- 負化。O を挟む反転
  | MEqBr   -- 等値判定と path separation（§16）
  | MLtBr   -- 大小判定と path separation
  | MBr     -- 無条件 path separation。後退参照が Ω 閉包そのものになる（§18）
  | MLoad   -- 作業領域の語番号から読む（§19）
  | MStore  -- 作業領域の語番号へ書く
  | MOk     -- 外部環境への成功報告。実現は target の interface 規約（§32.4）
  | MKo     -- 外部環境への失敗報告
  | MPut   -- 外部環境への一 byte 出力（03 章 §7）。報告と違い実行を閉じない
  deriving (Eq, Ord, Show, Enum)

meaningRegistry :: [MKind]
-- 追加は末尾に置く。順序が正準番号を決めるので、途中へ挿すと既存の program の
-- 音節名が全部ずれる（§32.2）
meaningRegistry =
  [ MCst, MAdd, MMul, MNeg, MEqBr, MLtBr, MBr, MLoad, MStore, MOk, MKo, MPut ]

-- 予約帯（0 層境界 / 1 無声ワイヤ / 2 零標示音）を避けて unitBase から始める。
-- これを外すと原子箱の像が z_e と衝突し、06 §16.2 の条件が破れる
kindName :: MKind -> String
kindName k = kindNameOfIdx (unitBase + fromEnum k)

kindByName :: String -> Maybe MKind
kindByName s = case [ k | k <- meaningRegistry, kindName k == s ] of
  (k : _) -> Just k
  []      -> Nothing

-- ポート幅。境界の型はワイヤ本数として持つ（§54 の制約の最小形）
portsOf :: MKind -> (Int, Int)
portsOf k = case k of
  MCst   -> (0, 1)
  MAdd   -> (2, 1)
  MMul   -> (2, 1)
  MNeg   -> (1, 1)
  MEqBr  -> (2, 0)
  MLtBr  -> (2, 0)
  MBr    -> (0, 0)
  MLoad  -> (1, 1)
  MStore -> (2, 0)
  MOk    -> (0, 0)
  MKo    -> (0, 0)
  MPut   -> (1, 0)

-- 引数の本数。wire 番号・定数・label をまとめて数える
arityOf :: MKind -> Int
arityOf k = case k of
  MCst   -> 2   -- 分子 x と深度 δ
  MAdd   -> 2
  MMul   -> 2
  MNeg   -> 1
  MEqBr  -> 3
  MLtBr  -> 3
  MBr    -> 1
  MLoad  -> 1
  MStore -> 2
  MOk    -> 0
  MKo    -> 0
  MPut   -> 1

-- 引数のうちワイヤ参照になる位置。残りは定数か label である
wireArgs :: MKind -> [Int]
wireArgs k = case k of
  MAdd   -> [0, 1]
  MMul   -> [0, 1]
  MNeg   -> [0]
  MEqBr  -> [0, 1]
  MLtBr  -> [0, 1]
  MLoad  -> [0]
  MStore -> [0, 1]
  MPut   -> [0]
  _      -> []

-- 引数のうち label になる位置
labelArgs :: MKind -> [Int]
labelArgs k = case k of
  MEqBr -> [2]
  MLtBr -> [2]
  MBr   -> [0]
  _     -> []

-- 入力ポートの本数はワイヤ参照の本数に等しい。この不変量が破れると
-- portsOf と wireArgs のどちらかが古い
portsAgree :: Bool
portsAgree = and [ fst (portsOf k) == length (wireArgs k) | k <- meaningRegistry ]

-- ===== 意味原子のチェンバー定義 =====
--
-- 算術の原子はコモン公用語のチェンバーそのものである。原始文字は新しく作らず、
-- counter_plane に積み上げた演算（DagArith.addS / alignDepth / negateS、
-- CCS の Dyad 積）への参照を使う。だから Speech の発音符号も、
-- SparseTensor の三次元疎テンソルも、Ideogram の表意語もそのまま適用できる。
--
-- 残りは §55 の boundary atom である。定数の物質化、path separation、
-- address space への転送、外部環境への報告は言語の中の演算ではなく境界であり、
-- チェンバーを持たない。音節名だけは同じ規則で振る。

atomChamber :: MKind -> Maybe Chamber
atomChamber k = case k of
  MAdd  -> one [PtDyad, PtDyad] primAddD [PtDyad]
  MMul  -> one [PtDyad, PtDyad] primMul  [PtDyad]
  MNeg  -> one [PtDyad]         primNegD [PtDyad]
  MLtBr -> one [PtDyad, PtDyad] primLeqD [PtBit]   -- 判定部分。分離は境界
  _     -> Nothing
  where
    one gin a gout = cnf (Chamber MInf 0 gin [Layer [(0, a)]] gout)

-- 原子の中身を走らせる。走るのは counter_plane に積み上げた演算そのものである
evalAtom :: MKind -> [Value] -> Maybe [Value]
evalAtom k vs = case atomChamber k of
  Just c  -> evalChamber c vs
  Nothing -> Nothing

-- 表意語。語の意味は CNF(C)、可搬表現は ser(C)（01_意味対象と表意語 §1）
atomWord :: MKind -> Maybe Ig.Word
atomWord k = case atomChamber k of
  Just c  -> Ig.mkWord c
  Nothing -> Nothing

-- 発音。チェンバーを持つ原子は E_speech が決める。境界原子は
-- レジストリの正準番号から同じ規則で出す（06 §2 と §16.2）
atomUtterance :: MKind -> Sp.Utterance
atomUtterance k = case atomChamber k of
  Just c  -> Sp.encode c
  Nothing -> [kindName k]

-- ===== logical file unit（式 32.6）=====

data FileKind = FMeaning | FEntry | FInterface | FRefinement | FProof | FProfile
  deriving (Eq, Ord, Show, Enum)

kindIdx :: FileKind -> Int
kindIdx = fromEnum

type Item = (Int, String, [Int])   -- (位置, 音節名, 引数列)

-- 𝔉 = (k, ν, D, S, Γ⁻, Γ⁺, μ, d)。物理 filename は意味に現れない（定理 32.1）
data Unit = Unit
  { uKind   :: FileKind
  , uIdent  :: Integer     -- ν: canonical content から出す（式 32.8）
  , uDeps   :: [Integer]   -- D: 依存 identity
  , uGin    :: Int         -- Γ⁻ のワイヤ本数
  , uGout   :: Int         -- Γ⁺ のワイヤ本数
  , uMu     :: Mu          -- μ: 記憶深度
  , uDep    :: Int         -- d: 作図深度
  , uLayers :: [[Item]]    -- S: 最大平行層
  } deriving (Eq, Show)

-- 衝突耐性のある content identity（式 32.8 の H）。
-- 多項式 rolling hash。衝突を検出したらより長い identity へ広げる
contentIdent :: FileKind -> String -> Integer
contentIdent k s = foldl step (toInteger (kindIdx k) * mBase + 7) s `mod` mMod
  where
    mBase = 1000003
    mMod  = 2305843009213693951   -- 2^61 - 1

step :: Integer -> Char -> Integer
step acc ch = (acc * 1000003 + toInteger (fromEnum ch)) `mod` 2305843009213693951

mkUnit :: FileKind -> Mu -> Int -> Int -> Int -> [[Item]] -> Unit
mkUnit k mu dp gi go ls = Unit k ident [] gi go mu dp ls
  where
    ident = contentIdent k body
    body  = joinWith ";" [ muS mu, show dp, show gi, show go, uLayersS ls ]

-- ===== 三次元疎テンソル E と復元 D（§4、定理 4.1）=====
--
-- E: unit → S(k,q,r)=Atom。k は unit 内の横位置（ここでは 0 固定）、
-- q は同一深度での frontier 位置、r は因果深度。
-- D: r 昇順、q 昇順に並べ直すと層が戻る。

tensorEntries :: Unit -> [(Int, Int, Int, String, [Int])]
tensorEntries u =
  [ (0, q, r, nm, as)
  | (r, l) <- zip [0 ..] (uLayers u)
  , (q, nm, as) <- l ]

restoreFromTensor :: FileKind -> Mu -> Int -> Int -> Int
                  -> [(Int, Int, Int, String, [Int])] -> Unit
restoreFromTensor fk mu dp gi go entries = mkUnit fk mu dp gi go layers
  where
    -- 同じ r の左右順序は入力区間の左端 q で一意に決まる（定理 4.1 の議論）
    keyed   = sort [ ((r, q), (q, nm, as)) | (_, q, r, nm, as) <- entries ]
    layers  = groupByR (map fst keyed) (map snd keyed)

-- 原子のチェンバーについての可逆性（02 定理 6.1）。E と D は SparseTensor 側の
-- 実装をそのまま使う。assembler が自前で持つのは unit 一段だけである
atomTensorOk :: MKind -> Bool
atomTensorOk k = case atomChamber k of
  Nothing -> True         -- 境界原子はチェンバーを持たない
  Just c  ->
    ST.restore (chMu c) (chDep c) (chIn c) (chOut c) (ST.entries c) == Just c

-- 発音符号の可逆性（06 §2）。E_speech / D_speech も Speech 側の実装を使う
atomSpeechOk :: MKind -> Bool
atomSpeechOk k = case atomChamber k of
  Nothing -> True
  Just c  ->
    Sp.decode (chMu c) (chDep c) (chIn c) (chOut c) (Sp.encode c) == Just c

-- 多モーダルの読み（05 §1）。text / glyph / image / audio のどれで読んでも
-- 戻り先は同じ CNF になる。判定は Multimodal.roundTrips がそのまま行う
atomModalOk :: MKind -> Bool
atomModalOk k = case atomChamber k of
  Nothing -> True
  Just c  -> Mm.roundTrips c

-- 人間向けの二つの読み。表示は意味を作らないので、どちらも同じ語を指す
atomReadings :: MKind -> Maybe (String, String)
atomReadings k = case atomChamber k of
  Just c  -> Just (Mm.fText c, Mm.fGlyph c)
  Nothing -> Nothing

-- ===== 整形式検査（§54）=====
--
-- 境界の型はワイヤ本数として持つ。原子箱ごとに三つを見る:
--   引数の本数が arityOf と一致する
--   ワイヤ参照が先行する「値を出す箱」を指す
--   label が箱の範囲（末尾の一つ先まで）に収まる
--
-- label が末尾の一つ先を指すのは停止位置であり、正しい。自分より前を指すのは
-- Ω 閉包（§18）であり、これも正しい。

wellFormedUnit :: Unit -> Either String ()
wellFormedUnit u = go 0 items
  where
    items = concat (uLayers u)
    n = length items
    produces j = case drop j items of
      ((_, nm, _) : _) -> case kindByName nm of
        Just k  -> snd (portsOf k) > 0
        Nothing -> False
      [] -> False
    go _ []                    = Right ()
    go i ((_, nm, as) : rest)  = case kindByName nm of
      Nothing -> Left (at i ++ "未登録の意味原子: " ++ nm)
      Just k
        | length as /= arityOf k ->
            Left (at i ++ nm ++ " の引数は " ++ show (arityOf k)
                  ++ " 本のはずが " ++ show (length as) ++ " 本)")
        | not (null badWire) ->
            Left (at i ++ "ワイヤ参照が先行する値を指していない: " ++ show badWire)
        | not (null badLbl) ->
            Left (at i ++ "label が箱の範囲を外れている: " ++ show badLbl)
        | otherwise -> go (i + 1) rest
        where
          arg p = case drop p as of
            (v : _) -> v
            []      -> negate 1
          badWire = [ arg p | p <- wireArgs k
                            , not (arg p < i && arg p >= 0 && produces (arg p)) ]
          badLbl  = [ arg p | p <- labelArgs k, arg p < 0 || arg p > n ]
    at i = "box " ++ show i ++ ": "

-- ===== 採用語彙 V（06 §17）=====
--
-- 基準割当ては原子ごとの E_speech である。頻度の高い意味には、基準より短い列を
-- 機械的に割り当てられる。選択は正準順の走査なので決定的であり（命題 17.5）、
-- 意味は変わらない（命題 17.6）。

-- 観測レコード。意味 program の中での出現回数を数える（17.7）
atomFreq :: Unit -> [Ab.FreqRec]
atomFreq u = [ (c, countOf k) | k <- meaningRegistry, Just c <- [atomChamber k] ]
  where
    countOf k = length [ () | l <- uLayers u, (_, nm, _) <- l, nm == kindName k ]

-- 聴取チャネルと三つの閾値は Speech 側の実測値を使う
adoptedVocab :: Unit -> [(Chamber, Sp.Utterance)]
adoptedVocab u =
  Ab.selectVocab Sp.syllabicChannel (1, 1) (1, 3) (atomFreq u)

-- 採用表を通した発音。表に載らない意味は基準列のまま残る（17.2 の V^ext）
utterAdopted :: Unit -> [Phone]
utterAdopted u =
  concat [ concatMap phonesOf l ++ [phoneOfIdx idxBoundary] | l <- uLayers u ]
  where
    table = adoptedVocab u
    phonesOf (_, nm, _) = case kindByName nm of
      Just k -> case atomChamber k of
        Just c  -> Ab.extCol table c
        Nothing -> [kindName k]
      Nothing -> [phoneOfIdx idxSilent]

-- 隣り合う同じ r をまとめる。keyed が (r,q) 昇順なので一度の走査で足りる
groupByR :: [(Int, Int)] -> [Item] -> [[Item]]
groupByR []             _        = []
groupByR ((r, _) : ks)  (x : xs) =
  let sameN = length (takeWhile' (\(r', _) -> r' == r) ks)
  in (x : take sameN xs) : groupByR (drop sameN ks) (drop sameN xs)
groupByR _              []       = []

takeWhile' :: (a -> Bool) -> [a] -> [a]
takeWhile' _ []       = []
takeWhile' p (x : xs) = if p x then x : takeWhile' p xs else []

-- ===== 直列化 =====
--
-- 書式（7 欄）: kind ; ident ; deps ; gin+gout ; mu ; dep ; layers
--   deps   = 整数の , 区切り
--   layers = layer の / 区切り、layer = item の , 区切り
--   item   = 位置 ~ 音節名 [ ~ 引数の + 区切り ]

serUnit :: Unit -> String
serUnit u = joinWith ";"
  [ show (kindIdx (uKind u))
  , show (uIdent u)
  , joinWith "," (map show (uDeps u))
  , joinWith "+" [show (uGin u), show (uGout u)]
  , muS (uMu u)
  , show (uDep u)
  , uLayersS (uLayers u) ]

uLayersS :: [[Item]] -> String
uLayersS ls = joinWith "/" (map uLayerS ls)

uLayerS :: [Item] -> String
uLayerS l = joinWith "," (map uItemS l)

uItemS :: Item -> String
uItemS (p, nm, as) = show p ++ "~" ++ nm ++ case as of
  [] -> ""
  _  -> "~" ++ joinWith "+" (map show as)

parseUnit :: String -> Maybe Unit
parseUnit s = case splitOnC ';' s of
  [kdS, idS, depS, bdS, muS', dpS, lyS] ->
    case (readInt kdS, readInteger idS, splitOnC '+' bdS, muP muS', readInt dpS) of
      (Just kd, Just ident, [giS, goS], Just mu, Just dp)
        | 0 <= kd && kd <= 5 ->
            case (readInt giS, readInt goS, uLayersP lyS) of
              (Just gi, Just go, Just ls) ->
                Just (Unit (toEnum kd) ident deps gi go mu dp ls)
              _ -> Nothing
      _ -> Nothing
  _ -> Nothing
  where
    deps = case splitOnC ';' s of
      (_ : _ : d : _) -> [ v | dS <- splitOnC ',' d, Just v <- [readInteger dS] ]
      _               -> []

uLayersP :: String -> Maybe [[Item]]
uLayersP "" = Just []
uLayersP s  = seqM (map uLayerP (splitOnC '/' s))

uLayerP :: String -> Maybe [Item]
uLayerP "" = Just []
uLayerP s  = seqM (map uItemP (splitOnC ',' s))

uItemP :: String -> Maybe Item
uItemP it = case splitOnC '~' it of
  [pS, nm]     -> withPos pS nm []
  [pS, nm, aS] -> case seqM (map readInt (splitOnC '+' aS)) of
    Just as -> withPos pS nm as
    Nothing -> Nothing
  _            -> Nothing
  where
    withPos pS nm as = case readInt pS of
      Just p  -> Just (p, nm, as)
      Nothing -> Nothing

seqM :: [Maybe a] -> Maybe [a]
seqM []             = Just []
seqM (Nothing : _)  = Nothing
seqM (Just x : xs)  = case seqM xs of
  Just ys -> Just (x : ys)
  Nothing -> Nothing

readInt :: String -> Maybe Int
readInt s = case reads s of
  [(v, "")] -> Just v
  _         -> Nothing

readInteger :: String -> Maybe Integer
readInteger s = case reads s of
  [(v, "")] -> Just v
  _         -> Nothing

-- 人間向け表示。音節名を層ごとに連結する。引数は十進のまま出す
renderUnit :: Unit -> String
renderUnit u =
  joinWith "." [ concat [ nm ++ argTxt as | (_, nm, as) <- l ] | l <- uLayers u ]
  where
    argTxt [] = ""
    argTxt as = "(" ++ joinWith "," (map show as) ++ ")"

-- 発音列。原子ごとの発音を並べ、層の切れ目に予約音節を置く（06 §2）。
-- 算術原子の発音は Speech.encode がチェンバーから決める
utterUnit :: Unit -> [Phone]
utterUnit u = concat [ concatMap phonesOf l ++ [phoneOfIdx idxBoundary] | l <- uLayers u ]
  where
    phonesOf (_, nm, _) = case kindByName nm of
      Just k  -> atomUtterance k
      Nothing -> [phoneOfIdx idxSilent]


-- ===== source を書くための行構成（10 章 §3）=====
--
-- 箱の番号 = 行の番号 = 出力ワイヤの番号。ラベルは行に付ける名前であり、
-- 値の参照も分岐先も同じ名前で書く。番号を手で数えない。
-- 引数関数がラベル解決を受け取るので、前方参照も後方参照も同じ形になる。

data Line = Line
  { lnLabel :: String
  , lnAtom  :: MKind
  , lnArgs  :: (String -> Int) -> [Int]
  }

mkLine :: String -> MKind -> ((String -> Int) -> [Int]) -> Line
mkLine = Line

-- 値を出さない箱。ラベルを持たない
anon :: MKind -> ((String -> Int) -> [Int]) -> Line
anon = Line ""

-- 未定義のラベルは行数を返す。それは image の終端であり、実行はそこで止まる
resolveOf :: [Line] -> String -> Int
resolveOf ls s = case [ i | (i, l) <- zip [0 ..] ls, lnLabel l == s ] of
  (i : _) -> i
  []      -> length ls

-- 一行を一層に置く。逐次実行の意味 program はこの形になる
linesToUnit :: FileKind -> Mu -> Int -> [Line] -> Unit
linesToUnit fk mu dp ls =
  mkUnit fk mu dp 0 0 [ [(0, kindName (lnAtom l), lnArgs l r)] | l <- ls ]
  where r = resolveOf ls

-- ===== 原子箱ごとの行 =====

lCst :: String -> Int -> Line
lCst nm x = mkLine nm MCst (\_ -> [x, 0])

-- 分子 x と深度 d。値は x / 2^d（01 章 式 1.1）
lCstD :: String -> Int -> Int -> Line
lCstD nm x d = mkLine nm MCst (\_ -> [x, d])

lAdd, lMul :: String -> String -> String -> Line
lAdd nm a b = mkLine nm MAdd (\r -> [r a, r b])
lMul nm a b = mkLine nm MMul (\r -> [r a, r b])

lNeg :: String -> String -> Line
lNeg nm a = mkLine nm MNeg (\r -> [r a])

lLoad :: String -> String -> Line
lLoad nm a = mkLine nm MLoad (\r -> [r a])

lStore :: String -> String -> Line
lStore a v = anon MStore (\r -> [r a, r v])

lEqBr, lLtBr :: String -> String -> String -> Line
lEqBr a b l = anon MEqBr (\r -> [r a, r b, r l])
lLtBr a b l = anon MLtBr (\r -> [r a, r b, r l])

lBr :: String -> Line
lBr l = anon MBr (\r -> [r l])

lOk, lKo :: String -> Line
lOk nm = mkLine nm MOk (\_ -> [])
lKo nm = mkLine nm MKo (\_ -> [])

-- 一 byte を外へ出す。値は下位 8 bit を採る（10 章 §2）
lPut :: String -> Line
lPut a = anon MPut (\r -> [r a])

-- ===== よく出る組 =====

-- 作業領域の語番号 i へ即値 v を書く三行
stAt :: String -> Int -> Int -> [Line]
stAt tag i v =
  [ mkLine (tag ++ "a") MCst (\_ -> [i, 0])
  , mkLine (tag ++ "v") MCst (\_ -> [v, 0])
  , lStore (tag ++ "a") (tag ++ "v") ]
