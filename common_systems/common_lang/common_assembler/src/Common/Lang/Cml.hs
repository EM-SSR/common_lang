module Common.Lang.Cml where

import CommonChamber
import Common.Lang.Construction (candidateSupremum)
import Data.Char (isDigit, isSpace)
import Data.List (sortOn, nubBy)
import Control.Monad (foldM, unless)

-- doc: cml.text cml.code cml.depth cml.addrfield ref.hash typing.rules
data Cml = Cml
  { cmlChamber :: Chamber
  , cmlDepth :: [Int]
  , cmlAddresses :: [Int]
  , cmlAtoms :: [(Int, Int, Int, [Int])]
  } deriving (Eq, Show)

type Ordinal = [Int]

-- trimOrdinal は CommonChamber が持つ。順序数の正準形は一箇所で決める。

addOrdinal :: Ordinal -> Ordinal -> Ordinal
addOrdinal a b = trimOrdinal (ordinalPlus a b)

omegaDepth :: Ordinal -> Ordinal
omegaDepth d = case trimOrdinal d of
  [] -> []
  ds -> replicate (length ds) 0 ++ [1]

maxOrdinal :: Ordinal -> Ordinal -> Ordinal
maxOrdinal = ordinalMax

primitiveDepth :: Prim -> Ordinal
primitiveDepth = primitiveGrade

constructionDepth :: Chamber -> Ordinal
constructionDepth = foldl addOrdinal [] . map layerDepth . chLay
  where layerDepth (Layer atoms) = foldl maxOrdinal [] [primitiveDepth (atomPrim a) | (_,a) <- atoms]

portCodes :: [(String, Port)]
portCodes = [("0",PtCoord),("1",PtUnit),("2",PtRefl),("3",PtDyad),
             ("4",PtBit),("5",PJudge),("6",PtMono),("7",PNoun),
             ("-2",PtRational),("-3",PtChain),("-4",PtRegion)]

readPort :: String -> Either String Port
readPort s = case portP s of
  Just p -> Right p
  Nothing -> case lookup s portCodes of
    Just p -> Right p
    Nothing -> case reads s of
      [(k,"")] | k >= 8 -> Right (PtReference (k-8))
      _ -> Left ("未知の型: " ++ s)

portCode :: Port -> Int
portCode (PtReference k) = 8+k
portCode p = read (fst (head [(s,q) | (s,q) <- portCodes, q == p]))

number :: String -> Either String Int
number s = case reads s of
  [(n, "")] -> Right n
  _ -> Left ("整数でない: " ++ s)

parameterNames :: [String]
parameterNames = ["cst", "identity", "copy", "discard", "beta-at", "inverse-at", "fix-at",
                  "simplex", "region", "intersection", "union", "exterior", "contains",
                  "overlaps", "adjacent", "inside", "outside", "path", "region-boundary",
                  "profile", "weight", "relation", "orbit", "transport",
                  "bisect-point", "close-bisection", "reflection", "sup-family", "candidates"]

generator :: Int -> [Int] -> Either String Atom
generator g args
  | g >= 0 && g < 38 = mkAtom (canonicalNames !! g) <$> canonical g args
  | g >= 38 && g < 38 + length sourceAtoms && null args = Right (snd (sourceAtoms !! (g-38)))
  | otherwise = case drop (g - 38 - length sourceAtoms) parameterNames of
      (name : _) | g >= 38 + length sourceAtoms -> mkAtom name <$> parameter name args
      _ -> Left ("生成元または引数が不正: " ++ show (g,args))
  where
    canonical 0 [n,d] | d >= 0 = Right (PCstD (toInteger n) d)
    canonical 1 [] = Right PAddD
    canonical 2 [] = Right PMul
    canonical 3 [] = Right PNegD
    canonical 4 [target] | target >= 0 = Right (PEqBranch target)
    canonical 5 [target] | target >= 0 = Right (PLtBranch target)
    canonical 6 [target] | target >= 0 = Right (PBranch target)
    canonical 7 [] = Right PLoadW
    canonical 8 [] = Right PStoreW
    canonical 9 [] = Right POkR
    canonical 10 [] = Right PKoR
    canonical 11 [] = Right PPutW
    canonical 12 [t] = PIdentity <$> readPort (show t)
    canonical 13 [t] = PCopy <$> readPort (show t)
    canonical 14 [t] = PDiscard <$> readPort (show t)
    canonical 16 [] = Right (atomPrim primI)
    canonical 17 [] = Right (atomPrim primJ)
    canonical 18 [] = Right PRhoM
    canonical 19 [] = Right PRhoP
    canonical 20 [k] | k >= 0 && k < 9 = Right (PBetaPoint k)
    canonical 21 [k] | k >= 0 && k < 9 = Right (PInversePoint k)
    canonical 22 [k] | k >= 0 && k < 8 = Right (PReflectPoint k)
    canonical 23 [] = Right PPhiJ
    canonical 24 [] = Right PBoundary
    canonical 25 [] = Right PMulJ
    canonical 26 [] = Right PSupJ
    canonical 27 [] = Right PResRJ
    canonical 28 [] = Right PResLJ
    canonical 29 [] = Right PPiJ
    canonical 30 [] = Right PTheta
    canonical 31 [] = Right PEndpoint
    canonical 32 [] = Right PAct
    canonical 33 [] = Right POne
    canonical 34 [k,t] | k >= 0 && t >= 0 = Right (PExt k t)
    canonical 35 [u,t] | u >= 0 && t >= 0 = Right (PAcc u t)
    canonical 36 [] = Right PFixL
    canonical 37 [] = Right PFold
    canonical code values = Left ("正準生成元の引数または降下が未対応: " ++ show (code,values))
    parameter "cst" [n,d] | d >= 0 = Right (PCstD (toInteger n) d)
    parameter "identity" [t] = PIdentity <$> readPort (show t)
    parameter "copy" [t] = PCopy <$> readPort (show t)
    parameter "discard" [t] = PDiscard <$> readPort (show t)
    parameter "beta-at" [n,d] | d >= 0 = Right (PBetaAt (toInteger n) d)
    parameter "inverse-at" [n,d] | d >= 0 = Right (PInvAt (toInteger n) d)
    parameter "fix-at" [n,d] | d >= 0 = Right (PFixAt (toInteger n) d)
    parameter "simplex" vs | all (\v -> v >= 0 && v < 64) vs = Right (PSimplex vs)
    parameter "region" es | all (\e -> e >= 0 && e < 64) es = Right (PRegion es)
    parameter "profile" [n] | n >= 0 = Right (PProfile n)
    parameter "weight" [k] | k >= 0 = Right (PWeight k)
    parameter "sup-family" [n] | n >= 0 = Right (PSupFamily n)
    parameter "bisect-point" [] = Right PBisectPoint
    parameter "close-bisection" [] = Right PFixPoint
    parameter "reflection" [k] | k >= 0 && k < 8 = Right (PReflection k)
    parameter "transport" (n:m:values) | n > 0 && m > 0 && length values == 2*n*m =
      let pairs (a:d:rest) = (toInteger a,d):pairs rest
          pairs _ = []
          rows [] = []
          rows xs = take m xs : rows (drop m xs)
          images = rows (pairs values)
      in if validTransport images then Right (PTransport images)
         else Left "目印の像の二分割深度が不正"
    parameter "relation" ops | all (`elem` [0,1]) ops = Right (PRel (map (\i -> if i == 0 then 'i' else 'j') ops))
    parameter "orbit" ops | all (`elem` [0,1]) ops = Right (POmW (map (\i -> if i == 0 then 'i' else 'j') ops))
    parameter "region-boundary" [] = Right (PRegionOp "boundary")
    parameter name [] | name `elem` ["intersection","union","exterior","contains","overlaps",
                                    "adjacent","inside","outside","path"] = Right (PRegionOp name)
    parameter name _ = Left (name ++ " の正準引数が不正")

generatorCode :: String -> Either String Int
generatorCode ('#' : s) = do
  k <- number s
  unless (k >= 0) (Left "参照番号は非負")
  Right (negate (k + 2))
generatorCode s = case lookup s names of
  Just g -> Right g
  Nothing -> number s
  where names = zip canonicalNames [0..]
                ++ [(phoneOfIdx (unitBase + i), i) | i <- [0 .. 37]]
                ++ zip (map fst sourceAtoms) [38..]
                ++ zip parameterNames [38 + length sourceAtoms ..]

canonicalNames :: [String]
canonicalNames = ["Cst","Add","Mul","Neg","EqBr","LtBr","Br","Load","Store","Ok","Ko","Put",
  "identity","copy","discard","Omega","i","j","rho-","rho+","beta","inverse","R","phi",
  "boundary","star","sup","resr","resl","pi","Theta","endpoint","act","one","ext","acc","fix","observe"]

sourceAtoms :: [(String,Atom)]
sourceAtoms = primitiveTable ++ extensionTable

-- References are indexed by expanded content, independent of spelling,
-- aliases, definition order, or padding in the ordinal field.
canonicalRefs :: [Cml] -> [Cml]
canonicalRefs = nubBy (\a b -> key a == key b) . sortOn key
  where
    key doc = (muS (chMu c), trimOrdinal (cmlDepth doc), chIn c,
               [[(q,atomPrim a) | (q,a) <- xs] | Layer xs <- chLay c],
               chOut c, cmlAddresses doc)
      where c = cmlChamber doc

readCml :: String -> Either String Cml
readCml = readCmlWith []

readCmlWith :: [Cml] -> String -> Either String Cml
readCmlWith refs text = do
  let rows = filter (not . null) (map (words . stripComment) (lines text))
      field n = case [xs | (k:xs) <- rows, k == n] of
        [xs] -> Right xs
        [] | n == "addr" -> Right []
        _ -> Left (n ++ " 欄は一つ必要")
      stripComment line = case break (== '#') line of
        (prefix,'#':suffix)
          | [r,q] <- words prefix
          , Right _ <- number r, Right _ <- number q
          , not (null prefix), isSpace (last prefix)
          , (digits,rest) <- span isDigit suffix, not (null digits)
          , null rest || isSpace (head rest) || head rest == '#' ->
              prefix ++ "#" ++ digits ++ takeWhile (/= '#') rest
        (prefix,_) -> prefix
  mu <- field "mu" >>= \xs -> case xs of
    [s] -> maybe (Left "mu が不正") Right (muP s)
    _ -> Left "mu の欄幅が不正"
  depth <- field "d" >>= mapM number
  unless (length depth >= 3 && all (>= 0) depth) (Left "d は非負の順序数係数を三つ以上指定する")
  gin <- field "in" >>= mapM readPort
  gout <- field "out" >>= mapM readPort
  addr <- field "addr" >>= mapM address
  atoms <- mapM atomRow [row | row@(k:_) <- rows, k `notElem` ["mu","d","in","out","addr"]]
  construct refs mu depth gin gout addr atoms
  where
    address s = maybe (number s) Right (lookup s (zip ["O","omega","omega-","i","j","p++","p-+","p+-","p--"] [0..]))
    atomRow (r:q:g:args) = (,,,) <$> number r <*> number q <*> generatorCode g <*> mapM number args
    atomRow _ = Left "原子箱は r q 生成元 引数 の順で指定する"

construct :: [Cml] -> Mu -> Ordinal -> [Port] -> [Port] -> [Int]
          -> [(Int,Int,Int,[Int])] -> Either String Cml
construct refs mu depth gin gout addr rawAtoms = do
  atoms <- mapM canonicalAtom rawAtoms
  unless (all (\(r,q,_,_) -> r >= 0 && q >= 0) atoms) (Left "層・位置は非負")
  unless (all (\a -> a >= 0 && a <= 8) addr) (Left "集積点番号が範囲外")
  unless (atoms == sortOn (\(r,q,_,_) -> (r,q)) atoms) (Left "箱は層・位置の昇順で指定する")
  let layers = if null atoms then [] else [filter (\(r,_,_,_) -> r == i) atoms | i <- [0 .. maximum [r | (r,_,_,_) <- atoms]]]
  rows <- mapM (mapM box) layers
  let closureAddresses = concat [snd (chamberGrade c) | row <- rows, (_,c,_) <- row]
  unless (null closureAddresses || addr == closureAddresses)
    (Left "閉包アドレス欄が本体の外側からの順序と一致しない")
  let starts = scanl (\offset xs -> offset + rowHeight xs) 0 rows
  relocated <- sequence [sequence
    [do c' <- relocate (if g <= -2 || isCandidates g then localTarget start c else sourceTarget starts) c
        Right (q,c',d)
    | ((_,_,g,_),(q,c,d)) <- zip row xs]
    | (row,xs,start) <- zip3 layers rows starts]
  (expanded,actualDepth) <- foldM expand ([],[]) relocated
  typedLayers <- specializeLayers gin expanded
  let c = withGrade depth addr (Chamber mu (length typedLayers) gin typedLayers gout)
  unless (wellFormed c) (Left "チェンバーの型・境界が一致しない")
  unless (trimOrdinal depth == trimOrdinal actualDepth) (Left ("作図深度が本体と異なる: " ++ show actualDepth))
  Right (Cml c depth addr atoms)
  where
    canonicalAtom entry@(r,q,g,args)
      | g < 0 = Right entry
      | g == 15 || isCandidates g = Right entry
      | otherwise = do
          a <- generator g args
          -- Context-polymorphic names must not widen a typed alias's domain.
          let matches = [k | k <- [0..37], k `notElem` [23,25,37], Right b <- [generator k args],
                             atomPrim a == atomPrim b]
          Right (r,q,case matches of k:_ -> k; [] -> g,args)
    specializeLayers _ [] = Right []
    specializeLayers front (Layer es:rest) = do
      let select (q,a) =
            let ports = drop q front
                p = case (atomTag a,atomPrim a,ports) of
                  ("star",PMulJ,PtDyad:PtDyad:_) -> PMul
                  ("phi",PPhiJ,PtDyad:_) -> PFold
                  ("phi",PPhiJ,PtCoord:_) -> PReadR
                  ("observe",PFold,PJudge:_) -> PPhiJ
                  ("observe",PFold,PtCoord:_) -> PReadR
                  _ -> atomPrim a
            in (q,a {atomPrim=p})
          layer = Layer (map select es)
      next <- maybe (Left "生成元の入力型・作用位置が境界と一致しない") Right (stepPorts front layer)
      (layer:) <$> specializeLayers next rest
    ordered = canonicalRefs refs
    isCandidates g = lookup "candidates"
      (zip parameterNames [38 + length sourceAtoms ..]) == Just g
    reference k
      | k < 0 = Left "正準参照は非負"
      | otherwise = case drop k ordered of
          c:_ -> Right c
          [] -> Left "正準参照が範囲外"
    box (_,q,g,f:xs) | isCandidates g = do
      predicate <- cmlChamber <$> reference f
      arguments <- mapM (fmap cmlChamber . reference) xs
      c <- candidateSupremum predicate arguments
      unless (chMu c == mu) (Left "候補族の記憶深度が外側と異なる")
      Right (q,c,fst (chamberGrade c))
    box (_,q,15,[address,f,x]) = do
      body <- reference f
      seed <- reference x
      let b = cmlChamber body
          s = cmlChamber seed
      unless (chMu b == mu && chMu s == mu && omegaWellFormed address b s)
        (Left "閉包の本体・初期値・状態型・集積点が整合しない")
      let p = POmega address b s
          (ins,outs) = kindsOfPrim p
          d = omegaDepth (cmlDepth body)
          addresses = address : (cmlAddresses body ++ cmlAddresses seed)
          c = withGrade d addresses (Chamber mu 1 ins [Layer [(0,mkAtom "Omega" p)]] outs)
      Right (q,c,d)
    box (_,q,g,args)
      | g <= -2 && null args = case drop (-g-2) ordered of
          (ref:_) -> Right (q, cmlChamber ref, cmlDepth ref)
          [] -> Left "正準参照が範囲外"
      | otherwise = do
          a <- generator g args
          let (ins,outs) = atomPorts a
              d = primitiveDepth (atomPrim a)
          Right (q, Chamber mu 1 ins [Layer [(0,a)]] outs, d)
    rowHeight xs = maximum (1 : [length (chLay c) | (_,c,_) <- xs])
    sourceTarget starts t
      | t >= 0 && t < length starts = Right (starts !! t)
      | otherwise = Left "分岐先のソース層が存在しない"
    localTarget start c t
      | t >= 0 && t <= length (chLay c) = Right (start+t)
      | otherwise = Left "参照内の分岐先が範囲外"
    relocate target c = do
      ls <- mapM (\(Layer es) -> Layer <$> mapM (\(q,a) -> do
        p <- case atomPrim a of
          PEqBranch t -> PEqBranch <$> target t
          PLtBranch t -> PLtBranch <$> target t
          PBranch t -> PBranch <$> target t
          p -> Right p
        Right (q,a {atomPrim=p})) es) (chLay c)
      Right c {chLay=ls}
    expand (done,d) xs = do
      unless (all (\(_,c,_) -> chMu c == mu) xs) (Left "参照先の mu が一致しない")
      _ <- foldM (\end (q,c,_) -> if q < end then Left "参照箱の入力区間が重なる"
                                  else Right (q + length (chIn c))) 0 xs
      ls <- mapM (expandStage xs) [0 .. rowHeight xs - 1]
      Right (done ++ ls, addOrdinal d (foldr maxOrdinal [] [v | (_,_,v) <- xs]))
    expandStage xs stage = Layer . snd <$> foldM place (0,[]) xs
      where
        place (shift,atoms0) (q,c,_) = do
          front <- maybe (Left "参照先の中間境界が不正") Right
                     (runPorts (chIn c) (take stage (chLay c)))
          let es = case drop stage (chLay c) of Layer ys:_ -> ys; [] -> []
          Right (shift + length front - length (chIn c),
                 atoms0 ++ [(q+shift+p,a) | (p,a) <- es])

codeCml :: Cml -> [Int]
codeCml doc = [muCode (chMu c)] ++ take (max 3 (length (cmlDepth doc))) (cmlDepth doc ++ repeat 0)
  ++ [length (chIn c),length (chOut c),length (cmlAddresses doc)]
  ++ map portCode (chIn c ++ chOut c) ++ cmlAddresses doc
  ++ concat [[r,q,g,length args] ++ args | (r,q,g,args) <- cmlAtoms doc] ++ [-1]
  where
    c = cmlChamber doc
    muCode m = case m of M0 -> 0; M1 -> 1; M2 -> 2; MInf -> 3

decodeCml :: [Cml] -> [Int] -> Either String Cml
decodeCml = decodeCmlDepth 3

decodeCmlDepth :: Int -> [Cml] -> [Int] -> Either String Cml
decodeCmlDepth width refs words0 = do
  unless (width >= 3) (Left "深度欄は三語以上必要")
  unless (length words0 >= width + 4) (Left "符号化ヘッダーが途中で終わる")
  let mu = head words0
      depth = take width (tail words0)
      header = drop (width + 1) words0
      ni = header !! 0
      no = header !! 1
      na = header !! 2
      rest = drop 3 header
  unless (mu >= 0 && mu <= 3 && all (>=0) (depth ++ [ni,no,na])) (Left "符号化ヘッダーが不正")
  unless (length rest >= ni+no+na) (Left "境界欄が途中で終わる")
  ports <- mapM (readPort . show) (take (ni+no) rest)
  atoms <- readAtoms (drop (ni+no+na) rest)
  construct refs ([M0,M1,M2,MInf] !! mu) depth (take ni ports) (drop ni ports)
    (take na (drop (ni+no) rest)) atoms
  where
    readAtoms [-1] = Right []
    readAtoms (r:q:g:n:xs) | r >= 0 && n >= 0 && length xs >= n =
      ((r,q,g,take n xs) :) <$> readAtoms (drop n xs)
    readAtoms _ = Left "原子箱の欄幅または終端が不正"
