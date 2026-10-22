{-# LANGUAGE NoImplicitPrelude #-}
module Common.Core.Pipe where

import CounterConstraints
import Common.Lang.NL
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS

-- ===== target 非依存の pipeline core（仕様 §42、§52）=====
-- doc: casm.pipe.built casm.pipe.link casm.pipe.alloc
-- 参照: docs/common-compiler/core/03
--
-- 意味プログラムは全 target 共通の MBox 列へ正規化される。
-- architecture package はこれを自分の atlas で覆い、自分の image rule で pack する。
-- core に target 名は現れない（定理 52.1）。target 名は package が返す data である。

-- ===== 意味箱 =====
--
-- 箱の番号がそのまま出力ワイヤの番号になる。引数は先行する箱の番号を指す。

data MBox
  = BCst Integer Int      -- 分子 x と深度 δ。値 = x / 2^δ
  | BAdd Int Int
  | BMul Int Int
  | BNeg Int
  | BEqBr Int Int Int     -- u = v なら label へ分離（§16）
  | BLtBr Int Int Int     -- u < v なら label へ分離
  | BBr Int               -- 無条件分離。後退参照が Ω 閉包そのものになる（§18）
  -- 作業領域は語の並びである。番号で指すので、語の byte 幅は意味に現れない。
  -- 基底 address と刻み幅は architecture package が持つ（§32.2）
  | BLoad Int             -- w ← work[i]
  | BStore Int Int        -- work[i] ← u
  | BOk
  | BKo
  | BPut Int              -- 一 byte を外へ出す。報告と違い実行を閉じない（§32.4）
  deriving (Eq, Show)

-- unit の層列を意味箱の列へ復元する。名前は意味レジストリで解決する。
-- 先に §54 の整形式検査を通す。引数の本数や参照先が壊れた unit は
-- ここで止め、Cover へ渡さない
mboxes :: Unit -> Either String [(Int, MBox)]
mboxes u = case wellFormedUnit u of
  Left e  -> Left e
  Right _ -> go 0 (concat (uLayers u))
  where
    go _ [] = Right []
    go i ((_, nm, as) : rest) = case resolve nm as of
      Nothing -> Left ("box " ++ show i ++ ": 意味原子を解決できない: " ++ nm)
      Just b  -> case go (i + 1) rest of
        Right bs -> Right ((i, b) : bs)
        Left e   -> Left e
    resolve nm as = case kindByName nm of
      Just MCst   | (x : d : _) <- as -> Just (BCst (toInteger x) d)
      Just MCst   | (x : _)     <- as -> Just (BCst (toInteger x) 0)
      Just MAdd   | (x : y : _) <- as -> Just (BAdd x y)
      Just MMul   | (x : y : _) <- as -> Just (BMul x y)
      Just MNeg   | (x : _)     <- as -> Just (BNeg x)
      Just MEqBr  | (x : y : l : _) <- as -> Just (BEqBr x y l)
      Just MLtBr  | (x : y : l : _) <- as -> Just (BLtBr x y l)
      Just MBr    | (l : _)     <- as -> Just (BBr l)
      Just MLoad  | (a : _)     <- as -> Just (BLoad a)
      Just MStore | (a : x : _) <- as -> Just (BStore a x)
      Just MOk    -> Just BOk
      Just MKo    -> Just BKo
      Just MPut   | (x : _)     <- as -> Just (BPut x)
      _           -> Nothing

nOuts :: MBox -> Int
nOuts b = case b of
  BCst _ _ -> 1
  BAdd _ _ -> 1
  BMul _ _ -> 1
  BNeg _   -> 1
  BLoad _  -> 1
  _        -> 0

boxArgs :: MBox -> [Int]
boxArgs b = case b of
  BAdd x y    -> [x, y]
  BMul x y    -> [x, y]
  BNeg x      -> [x]
  BEqBr x y _ -> [x, y]
  BLtBr x y _ -> [x, y]
  BLoad a     -> [a]
  BStore a x  -> [a, x]
  BPut x      -> [x]
  _           -> []

-- ===== 制御流れ（§18 の閉包）=====
--
-- 反復は原子ではない。label が自分より小さい箱を指したとき、その分離がそのまま
-- Ω 閉包になる（10 章 §2 末、§5 式 5.3）。後続関係だけを明示すれば足りる。
-- 生存区間を「定義から最後の使用まで」で近似できないのは、この後退辺のためになる。

succOf :: Int -> Int -> MBox -> [Int]
succOf n i b = [ s | s <- raw, 0 <= s && s < n ]
  where
    raw = case b of
      BBr l       -> [l]
      BEqBr _ _ l -> [i + 1, l]
      BLtBr _ _ l -> [i + 1, l]
      BOk         -> []
      BKo         -> []
      _           -> [i + 1]

-- live-out の最小不動点。
--   out(i) = ⋃_{s ∈ succ(i)} in(s)
--   in(i)  = args(b_i) ∪ (out(i) \ def(b_i))
-- 単調なので有限集合上の反復は必ず止まる。
--
-- 集合は IntSet、添字引きは IntMap で持つ。list の union と drop で書くと
-- 一巡が箱数の二乗、反復まで数えると三乗になり、千箱で compile が実行より
-- 重くなる。後退データフローなので箱を降順に走ると、一巡で後続の in が
-- 先に決まり、反復回数はループの深さ程度で収まる
liveOut :: [(Int, MBox)] -> [[Int]]
liveOut boxes = [ IS.toAscList (IM.findWithDefault IS.empty i fixed) | (i, _) <- boxes ]
  where
    n     = length boxes
    bmap  = IM.fromList boxes
    succs = IM.fromList [ (i, succOf n i b) | (i, b) <- boxes ]
    order = reverse (map fst boxes)
    fixed = loop (n + 1) IM.empty
    loop k cur
      | k <= (0 :: Int) = cur
      | next == cur     = cur
      | otherwise       = loop (k - 1) next
      where next = foldl step cur order
    step m i = IM.insert i (IS.unions [ inOf m s | s <- IM.findWithDefault [] i succs ]) m
    inOf m i = case IM.lookup i bmap of
      Nothing -> IS.empty
      Just b  ->
        let o  = IM.findWithDefault IS.empty i m
            o' = if nOuts b > 0 then IS.delete i o else o
        in IS.union (IS.fromList (boxArgs b)) o'

-- ===== 最大平行層（02 §2、Common-Lang/2 定理2.1）=====
-- doc: tensor3d layer.nf casm.schedule
--
-- 因果深度を前駆関係から導く。
--
--   h(v) = 0                          Pred(v) = ∅
--   h(v) = 1 + max_{u∈Pred(v)} h(u)   その他
--
-- 最大平行層では v ∈ Λ_r ⟺ h(v) = r になる。同じ層の箱は互いに依存しないので、
-- どの順に走らせても、同時に走らせても同じ値を出す。逐次に並ぶのは CPU の都合で
-- あって、意味の側の順序ではない。
--
-- 層に入れる箱は、作業領域を書き換えないものに限る。
--
--   分岐    次に読む箱を選ぶ操作で、値を作らない。制御の切れ目になる
--   Store   作業領域を書き換える。前後の Load と順序を持つので区切りになる
--   Ok/Ko   外部への報告。並べ替えられない
--
-- Load は区切りにしない。読むだけなので、Store を挟まない限り互いに独立であり、
-- 同じ作業領域の上でどの順に読んでも同じ値が出る。番地が別の Load どうしはもちろん、
-- 同じ番地でも値が同じなので並べ替えてよい。番地が前の Load の出力から来る場合は
-- 因果深度がその依存を捉える。
--
-- Load を区切りにすると層の幅が 2 前後まで下がる。実測では eratosthenes が
-- 層 66・最大幅 2 になり、並列に走らせる余地がほとんど残らなかった。
--
-- だから層分解は「作業領域を書き換えない箱の連なり」の中で閉じる。

pureBox :: MBox -> Bool
pureBox b = case b of
  BCst _ _ -> True
  BAdd _ _ -> True
  BMul _ _ -> True
  BNeg _   -> True
  BLoad _  -> True
  _        -> False

-- 連なりへの切り分け。区切りの箱は単独の連なりになる
pureRuns :: [(Int, MBox)] -> [[(Int, MBox)]]
pureRuns [] = []
pureRuns (x@(_, b) : rest)
  | pureBox b = let (run, more) = span (pureBox . snd) (x : rest)
                in run : pureRuns more
  | otherwise = [x] : pureRuns rest

-- 連なりの中の因果深度。外のワイヤは既に決まっているので深度 0 とみなす。
--
-- 連なりの中では箱の引数が必ず先行する箱を指すので、番号順に積むだけで深度が決まる。
-- ds を ds 自身で定義する結び目は使えない。Data.IntMap.Strict が値を強制するので、
-- 組み立て中の表を引くと <<loop>> で止まる。
causalDepths :: [(Int, MBox)] -> IM.IntMap Int
causalDepths = foldl step IM.empty
  where
    step m (i, b) = IM.insert i (dOf m b) m
    dOf m b = case [ 1 + d | a <- boxArgs b, Just d <- [IM.lookup a m] ] of
      [] -> 0
      xs -> maximum xs

-- 層。深度の昇順に、同じ深度の箱番号を並べる
causalLayers :: [(Int, MBox)] -> [[Int]]
causalLayers run =
  [ [ i | (i, d) <- IM.toAscList ds, d == r ] | r <- [0 .. hMax] ]
  where
    ds   = causalDepths run
    hMax = foldr max (negate 1) (IM.elems ds)

-- 全体の層の並び。連なりは自分の層へ、区切りは一箱の層になる
scheduleLayers :: [(Int, MBox)] -> [[Int]]
scheduleLayers boxes = concatMap ofRun (pureRuns boxes)
  where
    ofRun run@((_, b) : _)
      | pureBox b = causalLayers run
      | otherwise = [map fst run]
    ofRun [] = []

-- 層の幅。式 21.2 の配置 κ_A が要る本数になる
layerWidths :: [(Int, MBox)] -> [Int]
layerWidths = map length . scheduleLayers

unionL :: [Int] -> [Int] -> [Int]
unionL xs ys = xs ++ [ y | y <- ys, notElem y xs ]

unionAll :: [[Int]] -> [Int]
unionAll = foldr unionL []

-- ===== Allocate λ_A（式 13.1、13.2）=====
--
-- 干渉: ある箱で同時に生きている二本は同じ landmark を共有しない。
-- 昇順の貪欲彩色なので、同じ入力からは常に同じ割当てが出る（式 46.1）。

allocRegs :: [Int] -> [(Int, MBox)] -> Either String [(Int, Int)]
allocRegs pool boxes = go wires IM.empty []
  where
    outs = liveOut boxes
    -- 干渉集合の族。定義した箱の出力も、その時点の live-out と衝突する
    cliques = [ if nOuts b > 0 then IS.insert i s else s
              | ((i, b), o) <- zip boxes outs, let s = IS.fromList o ]
    wires = [ i | (i, b) <- boxes, nOuts b > 0 ]
    -- 隣接表を一度だけ組む。clique を走査し直すと箱数の三乗になる。
    -- clique の大きさは landmark 数で抑えられるので、辺は箱数に比例する
    adj = IM.fromListWith IS.union
            [ (a, IS.delete a c) | c <- cliques, a <- IS.toList c ]
    go [] _ acc = Right (reverse acc)
    go (w : ws) col acc =
      let taken = [ r | v <- IS.toList (IM.findWithDefault IS.empty w adj)
                      , Just r <- [IM.lookup v col] ]
      in case [ r | r <- pool, notElem r taken ] of
           (r : _) -> go ws (IM.insert w r col) ((w, r) : acc)
           []      -> Left ("landmark pool exhausted at wire " ++ show w)

-- 割当ての引き。部分適用で表を一度だけ組むので、覆いの中で何度引いても
-- 箱数に比例しない。where 束縛 rg = lookUpA al がその形になる
lookUpA :: [(Int, Int)] -> Int -> Int
lookUpA alloc = \w -> IM.findWithDefault 0 w m
  where m = IM.fromList alloc

-- ===== Link（§29）=====
--
-- 箱ごとの被覆は自分の byte 位置を知らない。分岐は「label と、その箱の中で
-- 何番目の form か」の対で印を残し、全体を並べてから変位を埋める（式 29.2、29.3）。
-- 変位を埋めても form の byte 長が変わらないことが前提になる。可変長 target では
-- 分岐に固定長の相対符号だけを使う。
--
--   assemble lenOf setBr プロローグ [(局所片, [(label, 局所 form 番号)])]
--     → (全 form 列, 箱ごとの先頭 byte offset 表)
--
-- offset 表は長さ n+1 で、末尾要素は image の終端を指す。範囲外の label は
-- そこへ落ちるので、実行は停止する。

assemble :: (f -> Int) -> (f -> Int -> f) -> [f]
         -> [([f], [(Int, Int)])] -> ([f], [Int])
assemble lenOf setBr pro covs = (patched, offs)
  where
    proLen  = sum (map lenOf pro)
    sizes   = [ sum (map lenOf fs) | (fs, _) <- covs ]
    offs    = scanl (+) proLen sizes
    starts  = scanl (+) (length pro) [ length fs | (fs, _) <- covs ]
    allF    = pro ++ concatMap fst covs
    byteOf  = scanl (+) 0 (map lenOf allF)
    endOff  = proLen + sum sizes
    relsG   = [ (l, s + li) | ((_, rs), s) <- zip covs starts, (l, li) <- rs ]
    patched = foldl patch allF relsG
    patch fs (l, fi) =
      let tgt = nthOr endOff l offs
          src = nthOr 0 fi byteOf
      in [ if k == fi then setBr f (tgt - src) else f | (k, f) <- zip [0 ..] fs ]

nthOr :: a -> Int -> [a] -> a
nthOr d k xs
  | k < 0     = d
  | otherwise = case drop k xs of
      (x : _) -> x
      []      -> d

-- ===== Pack（§30）=====

packImage :: [Word32] -> [Int]
packImage = concatMap wordBytes

wordBytes :: Word32 -> [Int]
wordBytes w = [ fromIntegral ((w `shiftR` s) .&. 0xFF) | s <- [0, 8, 16, 24] ]

unpackImage :: [Int] -> [Word32]
unpackImage [] = []
unpackImage bs = takeW bs : unpackImage (drop 4 bs)
  where
    takeW (a : b : c : d : _) =
      fromIntegral a .|. shiftL (fromIntegral b) 8
        .|. shiftL (fromIntegral c) 16 .|. shiftL (fromIntegral d) 24
    takeW _ = 0

-- 64 bit 語の little endian 展開。パラメータブロックと page table に使う
qwordBytes :: Integer -> [Int]
qwordBytes v =
  [ fromIntegral ((v `shiftR` s) .&. 0xFF) | s <- [0, 8, 16, 24, 32, 40, 48, 56] ]

le32 :: Int -> [Int]
le32 v = [ (v `div` p) `mod` 256 | p <- [1, 256, 65536, 16777216] ]

le16 :: Int -> [Int]
le16 v = [ v `mod` 256, (v `div` 256) `mod` 256 ]

-- ===== build の返り値（docs/common-compiler/core/03 式 2.1）=====

-- certificate の素材 (τ, κ, ℓ, r)。κ は "n" / "r" / "c"。
-- ProofObj への組み立ては Common.Core.Proof が行う。package は文字列だけを作る
type Cert = (String, String, String, String)

data Built = Built
  { btName   :: String       -- package が持つ target 名。core の型には現れない
  , btImage  :: [Int]        -- Pack_T の出力
  , btObserv :: [Integer]    -- simulator の観測 ⟦X_T⟧_T
  , btWork   :: [(Integer, Integer)]
                             -- 作業領域の (base からの offset, 値)。
                             -- 絶対 address は target ごとに違うので相対で返す
  , btOut    :: [Int]        -- Put が外へ出した byte 列（03 章 §7）
  , btOnlySim :: Bool       -- 観測を内蔵 simulator でしか取れない（07 §5）。
                            -- 外部の実行台がある package では False になり、
                            -- 式 (43.2) の観測は実際に走らせた返り値から取る
  , btNote   :: String       -- 実現不能のときの理由（§50）。空なら成功
  , btCerts  :: [Cert]       -- verify 区分が出した certificate
  } deriving (Eq, Show)

-- 実現不能で止まったときの返り値
failedBuild :: String -> String -> Built
failedBuild nm why = Built nm [] [] [] [] False why []

-- 覆えない原子を Cover の前に見つける（式 50.3 の Fact_{A,μ}(C_P) = ∅）。
-- 局所片を持たない package はここで止める。素通しさせると、意味 program が
-- 出したはずの byte が黙って消える
usesPut :: [(Int, MBox)] -> Bool
usesPut boxes = or [ True | (_, BPut _) <- boxes ]

noPutWhy :: String
noPutWhy = "to (Put) を覆う局所片が無い（式 50.3）"

-- memory 像を作業領域の語番号の表へ写す。
-- 語の byte 幅は package が持つので、外から見える表は番号だけになる
relWork :: Integer -> Integer -> [(Integer, Integer)] -> [(Integer, Integer)]
relWork b stride ms =
  sort [ ((a - b) `div` stride, v) | (a, v) <- ms, a >= b, (a - b) `mod` stride == 0 ]
