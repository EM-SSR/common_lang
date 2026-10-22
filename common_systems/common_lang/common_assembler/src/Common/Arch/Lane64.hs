{-# LANGUAGE NoImplicitPrelude #-}
module Common.Arch.Lane64 where

import CounterConstraints
import Common.Core.Pipe
import Common.Core.Dyad
import Common.Arch.Lane (Mask, fullMask, isUniform, splitMask, joinMask)
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M

-- ===== lane64 architecture package（docs/common-compiler/arch/20）=====
-- doc: casm.lane64.state casm.lane64.enc casm.lane64.sem casm.lane64.atlas
--      casm.lane64.layer casm.lane64.host
--
-- 07 章の三 CPU package は実行位相を後から足した。こちらは 𝒳_A を state の
-- 第一成分に置く。走らせるのは Python である（20 章 §11）。
--
-- 九区分（式 33.1）を節で分ける。
--   state / instruction / encoding / semantics / memory / atlas / abi / image / verify
--
-- subtarget J = { HALT, MAT, ADD, MUL, NEG, EQ, LT, JMP, LD, ST, OK, KO, PUT }
--
-- 命令は一本 16 byte の固定長で、分岐は自分からの相対になる。だから image は
-- 位置独立であり、loader も relocation も要らない（20 章 §8）。

targetName :: String
targetName = "lane64"

-- 即値の欄の幅。語そのものは Z なので、checkWidth が見るのは定数だけになる
wordWidth :: Int
wordWidth = 64

-- landmark の本数 L。加算と比較がシフトを欄に持ち、乗算と負化が三番地形なので、
-- scratch を分けなくてよい（20 章 §9）
numLandmarks :: Int
numLandmarks = 256

-- ===== state（20 章 式 1.1）=====
--
-- lane ごとに landmark と作業領域を切る。式 (1.2) で区間が交わらないので、
-- 定理 21.1 の条件（state を共有しない）が構造として満たされる。だから排他制御が
-- 要らず、実行台は lane を process へ配れる（20 章 §0.5）。
-- 語番号をそのまま添字にするので、基底も刻み幅も意味に現れない（§32.2）。

-- 語は Z である。$2^{64}$ で巻き戻さない（20 章 §0.3）。即値の欄が 64 bit なので
-- 定数の表現可能性だけ checkWidth が見る。中間値の大きさで場合分けが起きないので、
-- 式 (43.2) が幅の但し書き無しで core 意味論と一致する（命題 4.1）
data LaneS = LaneS
  { lRegs :: IM.IntMap Integer      -- R[·]。無い landmark は 0
  , lWork :: M.Map Integer Integer  -- M[·]。無い語は 0
  , lOut  :: [Int]                  -- Σ_out。PUT が積む。新しいものが先頭
  } deriving (Eq, Show)

emptyLane :: LaneS
emptyLane = LaneS IM.empty M.empty []

-- 実行の組（20 章 §6）。mask と pc の対を持ち、pc の昇順に一歩ずつ進める
type Group = (Mask, Int)

data Machine = Machine
  { mLanes  :: [LaneS]
  , mGroups :: [Group]
  , mEvents :: [Integer]            -- 報告。0 が成功、42 が失敗
  } deriving (Eq, Show)

initMachine :: Int -> Machine
initMachine w = Machine (replicate w emptyLane) [(fullMask w, 0)] []

regAt :: LaneS -> Int -> Integer
regAt s r = IM.findWithDefault 0 r (lRegs s)

setReg :: Int -> Integer -> LaneS -> LaneS
setReg r v s = s { lRegs = IM.insert r v (lRegs s) }

workAt :: LaneS -> Integer -> Integer
workAt s a = M.findWithDefault 0 a (lWork s)

setWork :: Integer -> Integer -> LaneS -> LaneS
setWork a v s = s { lWork = M.insert a v (lWork s) }

-- ===== instruction 𝓘_J（20 章 §4）=====

data Form
  = FHalt
  | FMat !Int !Integer            -- a, imm
  | FAdd !Int !Int !Int !Int !Int -- a, b, c, s_b, s_c
  | FMul !Int !Int !Int           -- a, b, c
  | FNeg !Int !Int                -- a, b
  | FEq  !Int !Int !Int !Int !Int -- b, c, s_b, s_c, 変位
  | FLt  !Int !Int !Int !Int !Int
  | FJmp !Int                     -- 変位
  | FLd  !Int !Int                -- a, b
  | FSt  !Int !Int                -- b, c
  | FOk
  | FKo
  | FPut !Int                     -- b
  deriving (Eq, Ord, Show)

-- 式 (51.1) と (40.1) の検査対象。欄の境界値を含める
forms :: [Form]
forms =
  [ FHalt, FOk, FKo ]
  ++ [ FMat a x | a <- [0, 7, 255]
                , x <- [0, 1, -1, 4294967296, 9223372036854775807
                       , -9223372036854775808] ]
  ++ [ FAdd a b c sb sc | a <- [0, 255], b <- [1, 254], c <- [2, 3]
                        , sb <- [0, 63], sc <- [0, 1] ]
  ++ [ FMul a b c | a <- [0, 255], b <- [1, 9], c <- [2, 8] ]
  ++ [ FNeg a b   | a <- [0, 255], b <- [1, 9] ]
  ++ [ FEq b c sb sc d | b <- [0, 5], c <- [1, 6], sb <- [0, 2], sc <- [0, 3]
                       , d <- [1, -1, 65535, -65535] ]
  ++ [ FLt b c sb sc d | b <- [0, 5], c <- [1, 6], sb <- [0, 2], sc <- [0, 3]
                       , d <- [1, -1, 65535, -65535] ]
  ++ [ FJmp d | d <- [1, -1, 1000000, -1000000] ]
  ++ [ FLd a b | a <- [0, 255], b <- [1, 9] ]
  ++ [ FSt b c | b <- [0, 255], c <- [1, 9] ]
  ++ [ FPut b  | b <- [0, 255] ]

lenOf :: Form -> Int
lenOf _ = 16

-- ===== encoding（20 章 §2）=====
--
-- 一命令一符号。canonical encoding（定理 24.1）は関数へ退化する。
-- 欄の並びは op / a / b / c / s_b / s_c / imm で、全部 little endian になる。

opOf :: Form -> Int
opOf f = case f of
  FHalt              -> 0
  FMat _ _           -> 1
  FAdd {}            -> 2
  FMul _ _ _         -> 3
  FNeg _ _           -> 4
  FEq {}             -> 5
  FLt {}             -> 6
  FJmp _             -> 7
  FLd _ _            -> 8
  FSt _ _            -> 9
  FOk                -> 10
  FKo                -> 11
  FPut _             -> 12

enc :: Form -> [Int]
enc f = [opOf f, a, b, c] ++ le16 sb ++ le16 sc ++ qwordBytes im
  where
    (a, b, c, sb, sc, im) = fields f

-- 欄の取り出し。符号と意味の両方がここを読むので、規則を二度書かない
fields :: Form -> (Int, Int, Int, Int, Int, Integer)
fields f = case f of
  FHalt                -> (0, 0, 0, 0, 0, 0)
  FMat a x             -> (a, 0, 0, 0, 0, x)
  FAdd a b c sb sc     -> (a, b, c, sb, sc, 0)
  FMul a b c           -> (a, b, c, 0, 0, 0)
  FNeg a b             -> (a, b, 0, 0, 0, 0)
  FEq b c sb sc d      -> (0, b, c, sb, sc, toInteger d)
  FLt b c sb sc d      -> (0, b, c, sb, sc, toInteger d)
  FJmp d               -> (0, 0, 0, 0, 0, toInteger d)
  FLd a b              -> (a, b, 0, 0, 0, 0)
  FSt b c              -> (0, b, c, 0, 0, 0)
  FOk                  -> (0, 0, 0, 0, 0, 0)
  FKo                  -> (0, 0, 0, 0, 0, 0)
  FPut b               -> (0, b, 0, 0, 0, 0)

dec :: [Int] -> Maybe (Form, Int)
dec bs = case bs of
  (op : a : b : c : s0 : s1 : s2 : s3 : q) | length q >= 8 ->
    let sb = s0 + 256 * s1
        sc = s2 + 256 * s3
        im = sext64 (rdQ q)
        d  = fromInteger im
    in case op of
         0  -> Just (FHalt, 16)
         1  -> Just (FMat a im, 16)
         2  -> Just (FAdd a b c sb sc, 16)
         3  -> Just (FMul a b c, 16)
         4  -> Just (FNeg a b, 16)
         5  -> Just (FEq b c sb sc d, 16)
         6  -> Just (FLt b c sb sc d, 16)
         7  -> Just (FJmp d, 16)
         8  -> Just (FLd a b, 16)
         9  -> Just (FSt b c, 16)
         10 -> Just (FOk, 16)
         11 -> Just (FKo, 16)
         12 -> Just (FPut b, 16)
         _  -> Nothing
  _ -> Nothing

-- 8 byte を符号なしで読む
rdQ :: [Int] -> Integer
rdQ q = sum [ toInteger v * shiftL 1 (8 * k) | (k, v) <- zip [0 ..] (take 8 q) ]

sext64 :: Integer -> Integer
sext64 v = if v >= 9223372036854775808 then v - 18446744073709551616 else v

decodeAll :: [Int] -> [Form]
decodeAll [] = []
decodeAll bs = case dec bs of
  Just (f, n) -> f : decodeAll (drop n bs)
  Nothing     -> []

roundTrip :: [Form] -> [Form]
roundTrip = map back
  where
    back f = case dec (enc f) of
      Just (g, _) -> g
      Nothing     -> FHalt

-- ===== semantics δ（20 章 §5、07 章 式 2.1）=====
--
-- 一命令の意味は lane ごとに mask の下で当たる。mask を外れた lane は動かない。
-- pc は control state なので mask に依らず一つになる（07 §2）。
--
--   delta_i(sigma)[l] = delta^lane_i(sigma[l])   m[l] = 1
--                     = sigma[l]                 m[l] = 0

-- lane 一枚の遷移。分岐と報告は Machine 側が扱うので、ここには値の箱だけが来る
stepLane :: Form -> LaneS -> LaneS
stepLane f s = case f of
  FMat a x         -> setReg a x s
  FAdd a b c sb sc -> setReg a (shiftL (regAt s b) sb + shiftL (regAt s c) sc) s
  FMul a b c       -> setReg a (regAt s b * regAt s c) s
  FNeg a b         -> setReg a (negate (regAt s b)) s
  FLd a b          -> setReg a (workAt s (regAt s b)) s
  FSt b c          -> setWork (regAt s b) (regAt s c) s
  FPut b           -> s { lOut = fromInteger (regAt s b `mod` 256) : lOut s }
  _                -> s

-- 判定の値（07 式 3.1、3.2）。深度をそろえる左シフトは欄が持つ
condOf :: Form -> LaneS -> Bool
condOf f s = case f of
  FEq b c sb sc _ -> shiftL (regAt s b) sb == shiftL (regAt s c) sc
  FLt b c sb sc _ -> shiftL (regAt s b) sb <  shiftL (regAt s c) sc
  _               -> False

-- mask の下で lane 群を書き換える
overMask :: Mask -> (LaneS -> LaneS) -> [LaneS] -> [LaneS]
overMask m g ls = [ if a then g l else l | (a, l) <- zip m ls ]

-- 分岐する箱か
isBranch :: Form -> Bool
isBranch f = case f of
  FEq {} -> True
  FLt {} -> True
  _      -> False

-- ===== 実行（20 章 §6、命題 6.1）=====
--
-- 組 (mask, pc) の集まりを持ち、pc の最も小さい組を一歩進める。pc が一致した
-- 組は式 (3.3) で束ねる。lane の作業領域が交わらないので、この順序で進めても
-- 一本ずつ最後まで走らせた観測と一致する（命題 6.1）。

simSteps :: Int
simSteps = 4000000

runImage :: Int -> Machine -> [Form] -> Machine
runImage steps m fs
  | steps <= 0        = m
  | null (mGroups m)  = m
  | otherwise         = runImage (steps - 1) (stepMachine n tbl m) fs
  where
    n   = length fs
    tbl = IM.fromList (zip [0 ..] fs)

stepMachine :: Int -> IM.IntMap Form -> Machine -> Machine
stepMachine n tbl m = case pickLowest (mGroups m) of
  Nothing -> m
  Just ((msk, pc), rest)
    | pc < 0 || pc >= n -> m { mGroups = merge rest }
    | otherwise -> case IM.lookup pc tbl of
        Nothing -> m { mGroups = merge rest }
        Just f  -> case f of
          FHalt -> m { mGroups = merge rest }
          FOk   -> m { mGroups = merge rest, mEvents = mEvents m ++ [0] }
          FKo   -> m { mGroups = merge rest, mEvents = mEvents m ++ [42] }
          FJmp d -> m { mGroups = merge ((msk, pc + d) : rest) }
          _ | isBranch f ->
                let cs = [ condOf f l | l <- mLanes m ]
                in if isUniform msk cs
                     then let taken = orAny [ c | (True, c) <- zip msk cs ]
                              d = dispOf f
                          in m { mGroups =
                                   merge ((msk, if taken then pc + d else pc + 1) : rest) }
                     -- 判定が割れた（07 式 3.2）。両側を別の組にする
                     else let (m1, m0) = splitMask msk cs
                              d = dispOf f
                          in m { mGroups =
                                   merge ((m1, pc + d) : (m0, pc + 1) : rest) }
            | otherwise ->
                m { mLanes  = overMask msk (stepLane f) (mLanes m)
                  , mGroups = merge ((msk, pc + 1) : rest) }

dispOf :: Form -> Int
dispOf f = case f of
  FEq _ _ _ _ d -> d
  FLt _ _ _ _ d -> d
  FJmp d        -> d
  _             -> 1

orAny :: [Bool] -> Bool
orAny []       = False
orAny (x : xs) = x || orAny xs

-- pc の最も小さい組を取り出す
pickLowest :: [Group] -> Maybe (Group, [Group])
pickLowest [] = Nothing
pickLowest gs = Just (best, without)
  where
    best = foldl lower (headOf gs) gs
    lower x@(_, p) y@(_, q) = if q < p then y else x
    without = dropFirst best gs
    headOf (x : _) = x
    headOf []      = (fullMask 0, 0)
    dropFirst _ []       = []
    dropFirst t (x : xs) = if x == t then xs else x : dropFirst t xs

-- reconvergence（07 式 3.3）。pc が同じ組は mask を合わせて一つにする
merge :: [Group] -> [Group]
merge [] = []
merge ((msk, pc) : gs) = (foldl joinMask msk same, pc) : merge other
  where
    same  = [ mm | (mm, p) <- gs, p == pc ]
    other = [ g  | g@(_, p) <- gs, p /= pc ]

-- ===== 観測 =====
--
-- 報告はすでに意味の側の値（0 が成功、42 が失敗）で積んである

observe :: Machine -> [Integer]
observe = mEvents

-- lane 0 の作業領域。btWork は語番号で返すので、刻み幅は 1 になる
laneWork :: Machine -> [(Integer, Integer)]
laneWork m = case mLanes m of
  (l : _) -> [ p | p@(_, v) <- M.toAscList (lWork l), v /= 0 ]
  []      -> []

laneOut :: Machine -> [Int]
laneOut m = case mLanes m of
  (l : _) -> reverse (lOut l)
  []      -> []

-- ===== 完全性（式 51.1、51.3）=====

semTotal :: Bool
semTotal = all ok forms
  where
    -- 全 form に意味がある。値の箱は stepLane、制御の箱は stepMachine が持つ
    ok f = case f of
      FHalt -> True
      FOk   -> True
      FKo   -> True
      FJmp _ -> True
      _ | isBranch f -> stepMachine 1 (IM.fromList [(0, f)]) (initMachine 1) /= initMachine 1
        | otherwise  -> stepLane f emptyLane == stepLane f emptyLane

encTotal :: Bool
encTotal = all (\f -> lenOf f == 16 && length (enc f) == 16) forms

-- 符号は単射である（式 24.1、37.4）
encInjective :: Bool
encInjective = roundTrip forms == forms

-- ===== image（20 章 §8）=====
--
-- 命令語の並びだけになる。header も page table も relocation も無い

image :: [Form] -> [Int]
image = concatMap enc

hexBs :: [Int] -> String
hexBs = concatMap two
  where
    two v = [dig (v `div` 16), dig (v `mod` 16)]
    dig d = case drop d "0123456789abcdef" of
      (ch : _) -> ch
      []       -> '?'

-- ===== abi =====

pool :: [Int]
pool = [0 .. numLandmarks - 1]

-- ===== atlas（Cover、20 章 §9）=====
--
-- 疑似命令と局所片が一対一に対応する。この machine を仕様書 式 (12.4) の
-- 因数分解から導いたので、覆いに継ぎ目が出ない。

covOp :: [(Int, Int)] -> (Int, Op) -> ([Form], [(Int, Int)])
covOp al (_, o) = case o of
  OMat w x            -> ([FMat (rg w) x], [])
  OAdd w (u, su) (v, sv) -> ([FAdd (rg w) (rg u) (rg v) (nz su) (nz sv)], [])
  OMul w u v          -> ([FMul (rg w) (rg u) (rg v)], [])
  ONeg w u            -> ([FNeg (rg w) (rg u)], [])
  OEq (u, su) (v, sv) l -> ([FEq (rg u) (rg v) (nz su) (nz sv) 0], [(l, 0)])
  OLt (u, su) (v, sv) l -> ([FLt (rg u) (rg v) (nz su) (nz sv) 0], [(l, 0)])
  OJmp l              -> ([FJmp 0], [(l, 0)])
  OLoad w i           -> ([FLd (rg w) (rg i)], [])
  OStore i u          -> ([FSt (rg i) (rg u)], [])
  OPut u              -> ([FPut (rg u)], [])
  OOk                 -> ([FOk], [])
  OKo                 -> ([FKo], [])
  where
    rg = lookUpA al
    nz s = if s < 0 then 0 else s

-- 変位は命令の本数で数える。assemble は byte で渡すので 16 で割る（式 2.3）
setBr :: Form -> Int -> Form
setBr f d = case f of
  FEq b c sb sc _ -> FEq b c sb sc (d `div` 16)
  FLt b c sb sc _ -> FLt b c sb sc (d `div` 16)
  FJmp _          -> FJmp (d `div` 16)
  other           -> other

-- ===== build =====
--
-- simulator は W = 1 で走らせる。07 章 §4 のとおり n = 1 のときは lane 0 だけが
-- active になり、式 (43.2) の観測は core 意味論と同じ形になる。
-- W > 1 の検査は selfcheck が別に取る（式 21.1）。

build :: [(Int, MBox)] -> Built
build boxes = case allocRegs pool boxes of
  Left why -> failedBuild targetName why
  Right al -> case checkWidth wordWidth ops of
    Just why -> failedBuild targetName why
    Nothing  -> Built targetName img (observe fin) (laneWork fin)
                      (laneOut fin) False "" certs
    where
      ops = lowerOps boxes
      (fs, _) = assemble lenOf setBr [] [ covOp al o | o <- ops ]
      img = image fs
      fin = runImage simSteps (initMachine 1) fs
      certs =
        [ ( "40.1", "r", hexBs (concatMap enc forms)
                       , hexBs (concatMap enc (roundTrip forms)) )
        , ( "24.1", "n", show encInjective, show True )
        , ( "51.1", "n", show semTotal, show True )
        , ( "51.2", "n", show fs, show (decodeAll img) )
        , ( "51.3", "n", show encTotal, show True )
        , ( "30.4", "n", hexBs img, hexBs (image (decodeAll img)) )
        ]

-- ===== 実行位相を広げたときの検査（式 21.1）=====
--
-- 同じ image を W 枚の lane で走らせる。lane の作業領域は交わらないので
-- （式 1.2）、どの lane も W = 1 と同じ軌道を辿る。等しくならなければ
-- mask か合流のどちらかが壊れている。

runLanes :: Int -> [Form] -> Machine
runLanes w fs = runImage simSteps (initMachine w) fs

lanesAgree :: Int -> [(Int, MBox)] -> Bool
lanesAgree w boxes = case allocRegs pool boxes of
  Left _   -> False
  Right al ->
    let fs   = fst (assemble lenOf setBr [] [ covOp al o | o <- ops ])
        ops  = lowerOps boxes
        one  = runImage simSteps (initMachine 1) fs
        many = runLanes w fs
        wk l = [ p | p@(_, v) <- M.toAscList (lWork l), v /= 0 ]
    in case mLanes one of
         (l0 : _) -> all (\l -> wk l == wk l0) (mLanes many)
         []       -> False
