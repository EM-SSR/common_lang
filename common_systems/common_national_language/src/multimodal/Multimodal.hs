{-# LANGUAGE NoImplicitPrelude #-}
module Multimodal where

import CounterConstraints
import CommonChamber

-- ===== 多モーダル文法（05_多モーダル文法.md）=====
-- doc: modal.share modal.invert image.grammar video.grammar
--
-- 各モーダルへの観測射 f_m:C→R_m と復元 p_m:R_m→C を
-- 単射な対として持ち、定理1.1（CNF 一致）を検証する。
--   R_text  : ser 文字列
--   R_glyph : 装飾文字列
--   R_image : 層ごとの領域 (位置, 幅, 概念文字)。画素データそのものではなく
--             「領域・∂・目印」を持つ文法対象である
--   R_audio : 層ごとの発音グループ（構文境界はグループ分割として保持）

-- ===== R_text =====

fText :: Chamber -> String
fText = ser

pText :: String -> Maybe Chamber
pText = parse

-- ===== R_glyph =====

fGlyph :: Chamber -> String
fGlyph c = "W[" ++ ser c ++ "]"

pGlyph :: String -> Maybe Chamber
pGlyph ('W' : '[' : rest) = stripEndG rest []
pGlyph s                  = parse s

stripEndG :: String -> String -> Maybe Chamber
stripEndG []         acc = parse (reverse acc)
stripEndG (']' : []) acc = parse (reverse acc)
stripEndG (c : cs)   acc = stripEndG cs (c : acc)

-- ===== R_image =====

-- 行 = 層（走査帯）、要素 = 領域 (位置 q, 幅, 概念文字)。
-- 幅は描画情報ではなくポート列から復元される値であるが、
-- 画像上の「領域の幅」としても観測できる（両者は一致する）
data Image = Image
  { imgMu  :: Mu
  , imgDep :: Int
  , imgIn  :: [Port]
  , imgRows :: [[(Int, Int, String)]]
  , imgOut :: [Port]
  }
  | GradedImage
  { imgMu :: Mu, imgDep :: Int, imgIn :: [Port]
  , imgRows :: [[(Int, Int, String)]], imgOut :: [Port]
  , imgOrdinal :: [Int], imgAddresses :: [Int]
  } deriving (Eq, Read, Show)

fImage :: Chamber -> Image
fImage c = case c of
  GradedChamber {} -> GradedImage (chMu c) (chDep c) (chIn c) rows (chOut c)
    (fst (chamberGrade c)) (snd (chamberGrade c))
  _ -> Image (chMu c) (chDep c) (chIn c) rows (chOut c)
  where
    rows =
      [ [(pos, widthOfAtom a, atomRepresentation a) | (pos, a) <- layerAtoms l]
      | l <- chLay c ]
    widthOfAtom a = length (fst (atomPorts a))

-- A parameterized atom or a local name is not recoverable from a registry tag.
-- Its finite typed construction belongs to the modality's retained meaning.
atomRepresentation :: Atom -> String
atomRepresentation a
  | lookupAtom (atomTag a) == Just a = atomTag a
  | otherwise = '@' : show a

atomFromRepresentation :: String -> Maybe Atom
atomFromRepresentation ('@':s) = case reads s of
  [(a,"")] -> Just a
  _ -> Nothing
atomFromRepresentation tag = lookupAtom tag

buildLayersImg :: [[(Int, Int, String)]] -> Maybe [Layer]
buildLayersImg rows = go rows []
  where
    go []     acc = Just (reverse acc)
    go (r : rest) acc = case rowToLayer r of
      Just l  -> go rest (l : acc)
      Nothing -> Nothing

rowToLayer :: [(Int, Int, String)] -> Maybe Layer
rowToLayer row = go row []
  where
    go [] acc = Just (Layer (reverse acc))
    go ((pos, w, tag) : rest) acc = case atomFromRepresentation tag of
      Just a
        | length (fst (atomPorts a)) == w -> go rest ((pos, a) : acc)
      _ -> Nothing

pImage :: Image -> Maybe Chamber
pImage img = case buildLayersImg (imgRows img) of
  Just ls
    | runPorts (imgIn img) ls == Just (imgOut img) ->
        let base = Chamber (imgMu img) (imgDep img) (imgIn img) ls (imgOut img)
            c = case img of
              GradedImage {} -> withGrade (imgOrdinal img) (imgAddresses img) base
              _ -> base
        in if wellFormed c then Just c else Nothing
  _ -> Nothing

-- ===== R_audio =====

-- グループ = 層（構文境界）。グループ内は frontier を走査し、
-- 隙間を無声音 "_" へ、箱を概念文字タグへ写す。
-- 恒等ワイヤのみの区間も意味をもつ音素列になる
data Audio = Audio
  { auMu  :: Mu
  , auDep :: Int
  , auIn  :: [Port]
  , auGroups :: [[String]]
  , auOut :: [Port]
  }
  | GradedAudio
  { auMu :: Mu, auDep :: Int, auIn :: [Port]
  , auGroups :: [[String]], auOut :: [Port]
  , auOrdinal :: [Int], auAddresses :: [Int]
  } deriving (Eq, Read, Show)

gapPhoneM :: String
gapPhoneM = "_"

fAudio :: Chamber -> Audio
fAudio c = case c of
  GradedChamber {} -> GradedAudio (chMu c) (chDep c) (chIn c) groups (chOut c)
    (fst (chamberGrade c)) (snd (chamberGrade c))
  _ -> Audio (chMu c) (chDep c) (chIn c) groups (chOut c)
  where
    groups = case portFrontierSeqM (chIn c) (chLay c) of
      Just (ins, _) -> zipWith layerGroup ins (chLay c)
      Nothing       -> []

layerGroup :: [Port] -> Layer -> [String]
layerGroup front (Layer xs) = go 0 xs
  where
    total = length front
    go cur []              = replicate (total - cur) gapPhoneM
    go cur ((pos, a) : rest) =
      replicate (pos - cur) gapPhoneM ++ atomRepresentation a : go (pos + widthOfAtom a) rest

widthOfAtom :: Atom -> Int
widthOfAtom a = length (fst (atomPorts a))

groupToLayerP :: [Port] -> [String] -> Maybe Layer
groupToLayerP front tags = go 0 [] tags
  where
    total = length front
    go cur acc [] | cur == total = Just (Layer (reverse acc))
                 | otherwise = Nothing
    go cur acc ("_" : rest) | cur < total = go (cur + 1) acc rest
                           | otherwise = Nothing
    go cur acc (tag : rest) = case atomFromRepresentation tag of
      Just a ->
        let k = widthOfAtom a
        in if cur + k > total
             then Nothing
             else go (cur + k) ((cur, a) : acc) rest
      Nothing -> Nothing

groupsToLayers :: [Port] -> [[String]] -> Maybe [Layer]
groupsToLayers gin gs = go gin gs []
  where
    go _ [] acc = Just (reverse acc)
    go f (g : rest) acc = case groupToLayerP f g of
      Just l  -> case portFrontierSeqM f [l] of
        Just (_, f') -> go f' rest (l : acc)
        Nothing      -> Nothing
      Nothing -> Nothing

pAudio :: Audio -> Maybe Chamber
pAudio au = case groupsToLayers (auIn au) (auGroups au) of
  Just ls
    | runPorts (auIn au) ls == Just (auOut au) ->
        let base = Chamber (auMu au) (auDep au) (auIn au) ls (auOut au)
            c = case au of
              GradedAudio {} -> withGrade (auOrdinal au) (auAddresses au) base
              _ -> base
        in if wellFormed c then Just c else Nothing
  _ -> Nothing

-- ===== R_video: initial construction, state transition, observation (§9) =====

data Video = Video
  { videoInitial :: Chamber
  , videoTransition :: Chamber
  , videoObservation :: Chamber
  } deriving (Eq, Read, Show)

videoWellFormed :: Video -> Bool
videoWellFormed (Video initial transition observation) =
  all wellFormed [initial,transition,observation]
  && null (chIn initial)
  && chMu initial == chMu transition && chMu initial == chMu observation
  && chOut initial == chIn transition
  && chIn transition == chOut transition
  && chIn observation == chOut initial

-- A finite presentation requests its frame count explicitly. The model retains
-- F and R, so producing a presentation does not replace temporal identity by a
-- list of unrelated images. The first frame observes X_0.
videoFrames :: Int -> Video -> Maybe [[Value]]
videoFrames count video
  | count < 0 || not (videoWellFormed video) = Nothing
  | count == 0 = Just []
  | otherwise = case evalChamber (videoInitial video) [] of
      Just initial -> frames count initial
      Nothing -> Nothing
  where
    frames n state = case evalChamber (videoObservation video) state of
      Nothing -> Nothing
      Just frame
        | n == 1 -> Just [frame]
        | otherwise -> case evalChamber (videoTransition video) state of
            Nothing -> Nothing
            Just next -> case frames (n-1) next of
              Just rest -> Just (frame:rest)
              Nothing -> Nothing

renderVideoModel :: Video -> String
renderVideoModel = show

parseVideoModel :: String -> Maybe Video
parseVideoModel source = case reads source of
  [(video,"")] | videoWellFormed video -> Just video
  _ -> Nothing

-- ===== 画素レベルの有限関数と領域文法（§2/§3）=====

type Cell = (Int, Int)

-- 有限関数としての画像: 座標 → 色成分（未定義座標は 0）
type ImgFn = [(Cell, Int)]

-- Finite video data retains every time/pixel sample, independently of whether
-- the temporal model above admits a smaller representation.
type VideoFn = [((Int, Int, Int), Int)]

videoPixelAt :: VideoFn -> (Int, Int, Int) -> Int
videoPixelAt video position = case lookup position video of
  Just value -> value
  Nothing -> 0

videoFrameAt :: Int -> VideoFn -> ImgFn
videoFrameAt time video = [((x,y),value) | ((t,x,y),value) <- video, t == time]

pixelAt :: ImgFn -> Cell -> Int
pixelAt img c = case lookup c img of
  Just v  -> v
  Nothing -> 0

-- 領域 G の境界 ∂G: 領域に属するセルのうち、4 近傍に非所属セルを持つもの
regionBoundary :: [Cell] -> [Cell]
regionBoundary cells = filter hasOutsideNeighbor cells
  where
    neighbors (x, y) = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    hasOutsideNeighbor c = any (`notElem` cells) (neighbors c)

-- 相対アドレス: 目印（基準点）からの差分。絶対座標に依存しない
relativeAddress :: Cell -> Cell -> (Int, Int)
relativeAddress origin c = (fst c - fst origin, snd c - snd origin)

-- ===== ドキュメント主張の実行可能証明 =====

sampleA, sampleB, sampleAB :: Chamber
sampleA = Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]
sampleB = Chamber MInf 0 [PtDyad] [Layer [(0, primBeta)], Layer [(0, primFold)]] [PtBit]
sampleAB = Chamber MInf 0 [PtCoord, PtCoord]
             [Layer [(0, primAdd)], Layer [(0, primCId)]]
             [PtCoord]

roundTrips :: Chamber -> Bool
roundTrips c =
  cnfEqM (pText (fText c)) c
  && cnfEqM (pGlyph (fGlyph c)) c
  && cnfEqM (pImage (fImage c)) c
  && cnfEqM (pAudio (fAudio c)) c

cnfEqM :: Maybe Chamber -> Chamber -> Bool
cnfEqM mc c = case mc of
  Just c' -> c' == c
  Nothing -> False

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("定理1.1: レジストリの全原子が四モーダルで往復する",
      all (\a -> let (gin, gout) = atomPorts a
                 in case cnf (Chamber (if atomPrim a == PDupN then M1 else MInf) 0 gin [Layer [(0, a)]] gout) of
                      Just c  -> roundTrips c
                      Nothing -> False)
          [ a | (_, a) <- primitiveTable ])
  , ("定理1.1: 四モーダル全てが同じ CNF へ復元する",
      roundTrips sampleA && roundTrips sampleB && roundTrips sampleAB)
  , ("定理1.1: モーダル間で CNF が一致する（image ↔ audio）",
      let i1 = pImage (fImage sampleAB)
          a1 = pAudio (fAudio sampleAB)
      in i1 /= Nothing && i1 == a1)
  , ("単射性: 異なるチェンバーは異なる画像へ観測される",
      fImage sampleA /= fImage sampleB
      && fImage sampleAB /= fImage sampleA)
  , ("単射性(負検証): 画像の概念文字を一つ破壊すると復元が壊れるか別物になる",
      let Image mu d gi rows go_ = fImage sampleAB
          corruptedRows = case rows of
            (r : rest) -> case r of
              ((q, w, _) : more) -> ((q, w, "cow") : more) : rest
              []                 -> [] : rest
            [] -> []
          corrupted = Image mu d gi corruptedRows go_
      in pImage corrupted /= Just sampleAB)
  , ("非可換表示: 発音グループの順序を入れ替えると別の意味になる",
      let Audio mu d gi gs go_ = fAudio sampleAB
          swapped = Audio mu d gi (reverse gs) go_
      in swapped /= fAudio sampleAB && pAudio swapped /= Just sampleAB)
  , ("§3: 領域の境界 ∂G — 塗りつぶし正方形の境界は周縁 8 セル",
      let square = [(x, y) | x <- [0 .. 2], y <- [0 .. 2]]
          bd = regionBoundary square
      in length bd == 8 && notElem (1, 1) bd)
  , ("§3: 相対アドレスは平行移動で不変である（絶対座標に依存しない）",
      let profs1 = [ relativeAddress (0, 0) c | c <- [(1, 1), (2, 1)] ]
          profs2 = [ relativeAddress (10, 10) c | c <- [(11, 11), (12, 11)] ]
      in profs1 == profs2)
  , ("§10: ⊗ と ; は同じ語から異なる CNF を生む",
      let t = tensorC sampleA sampleA
          s = seqC sampleA sampleA
      in t /= s)
  ]

emptyImage :: Image
emptyImage = Image M0 0 [] [] []


