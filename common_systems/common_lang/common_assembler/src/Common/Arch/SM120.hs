{-# LANGUAGE NoImplicitPrelude #-}
module Common.Arch.SM120 where

import CounterConstraints
import Common.Core.Pipe
import Common.Core.Dyad
import Common.Arch.Lane

-- ===== NVIDIA sm_120 native architecture package（docs/common-compiler/arch/09）=====
-- doc: casm.sm120.state casm.sm120.enc casm.sm120.op casm.sm120.sem casm.sm120.atlas
--
-- 𝔄_PTX ≠ 𝔄_sm120（式 37.1）。本 package は native 側であり、PTX を経由しない。
--
-- 符号は nvdisasm（CUDA 12.8、--binary SM120）を oracle にして確定させた。
-- opcode も field 位置も分岐の変位式も、宣言値ではなく観測値である。
--
-- J = { MOV(imm), MOV(reg), IADD3, IMAD(reg), IMAD(imm), ISETP, BRA, LDS, STS, EXIT }
--
-- shift 命令は要らない。深度そろえも語番号から address を作るのも、
-- IMAD の即値倍で書ける。命令の種類を減らすほど verify が軽くなる。

targetName :: String
targetName = "sm_120"

warpW :: Int
warpW = 32

wordWidth :: Int
wordWidth = 32

rZ, pT :: Int
rZ = 255      -- 読み 0、書き捨て
pT = 7        -- 常に真

-- 語番号 → LDS byte address の倍率。語は 4 byte
wordScale :: Integer
wordScale = 4

-- ===== state（式 1.1、式 37.2）=====

data Machine = Machine
  { mRegs   :: [[Integer]]           -- R0..R31、各 lane ぶん
  , mPreds  :: [[Bool]]              -- P0..P6
  , mMask   :: Mask                  -- 𝒳_120
  , mLds    :: [(Integer, Integer)]  -- byte address → 32 bit 語
  , mPc     :: Integer
  , mEvents :: [Integer]
  } deriving (Eq, Show)

nReg, nPred :: Int
nReg = 32
nPred = 7

initMachine :: Machine
initMachine = Machine (replicate nReg (replicate warpW 0))
                      (replicate nPred (replicate warpW False))
                      (fullMask warpW) [] 0 []

-- ===== instruction 𝓘_J =====

data Form
  = FMovI  !Int !Integer        -- MOV Rd, imm32
  | FMovR  !Int !Int            -- MOV Rd, Rs
  | FIadd  !Int !Int !Int       -- IADD3 Rd, PT, PT, Ra, Rb, RZ
  | FImadR !Int !Int !Int       -- IMAD Rd, Ra, Rb, RZ
  | FImadI !Int !Int !Integer   -- IMAD Rd, Ra, imm32, RZ
  | FIsetp !Int !Int !Int       -- ISETP.<cmp>.AND P0, PT, Ra, Rb, PT
  | FBra   !Int !Int            -- 述語 p、byte 変位（pc_next 基準）
  | FLds   !Int !Int            -- LDS Rd, [Ra]
  | FSts   !Int !Int            -- STS [Ra], Rb
  | FExit
  deriving (Eq, Ord, Show)

-- 比較の種別は上位語 hi[15:12] に入る。観測値: LT = 1、EQ = 2、NE = 5、GE = 6
cmpLT, cmpEQ :: Int
cmpLT = 1
cmpEQ = 2

forms :: [Form]
forms =
  [ FMovI d x | d <- [0, 4, 31], x <- [0, 42, 0x12345678] ]
  ++ [ FMovR d s | d <- [0, 4], s <- [5, 31] ]
  ++ [ FIadd d a b | d <- [4, 5], a <- [4, 6], b <- [5, 7] ]
  ++ [ FImadR d a b | d <- [4, 5], a <- [4, 6], b <- [5, 7] ]
  ++ [ FImadI d a x | d <- [4, 5], a <- [4, 6], x <- [1, 4, negate 1] ]
  ++ [ FIsetp c a b | c <- [cmpLT, cmpEQ], a <- [4, 6], b <- [5, 7] ]
  ++ [ FBra p o | p <- [0, pT], o <- [0, 64, negate 64] ]
  ++ [ FLds d a | d <- [4, 5], a <- [6, 7] ]
  ++ [ FSts a s | a <- [6, 7], s <- [4, 5] ]
  ++ [ FExit ]

lenOf :: Form -> Int
lenOf _ = 16

-- ===== opcode（nvdisasm SM120 の観測値）=====
--
-- 下位 12 bit のうち [8:0] が演算、[11:9] が operand class になっている。
-- register 形が 0x2__、即値形が 0x8__ で、差は 0x600 に固定される。

opMovI, opMovR, opIaddR, opImadR, opImadI, opIsetpR, opBra, opLds, opSts, opExit :: Int
opMovI   = 0x802
opMovR   = 0x202
opIaddR  = 0x210
opImadR  = 0x224
opImadI  = 0x824
opIsetpR = 0x20C
opBra    = 0x947
opLds    = 0x984
opSts    = 0x388
opExit   = 0x94D

opTable :: [Int]
opTable = [ opMovI, opMovR, opIaddR, opImadR, opImadI
          , opIsetpR, opBra, opLds, opSts, opExit ]

opInjective :: Bool
opInjective =
  and [ a /= b | (i, a) <- zip [0 :: Int ..] opTable
               , (j, b) <- zip [0 :: Int ..] opTable, i /= j ]

-- ===== encoding =====
--
--   lo[11:0]  opcode          lo[15:12] 述語（bit3 が否定、bits[2:0] が番号）
--   lo[23:16] 目的 register    lo[31:24] source A
--   lo[63:32] source B または即値
--   hi[7:0]   source C        hi[15:12] 比較の種別
--   hi[63:41] 制御 bit（scheduling。δ には効かない）
--
-- 制御 bit は保守的な観測値で固定する。並べ替えをしないので、
-- 依存の待ちは最大にしておけばよい。

ctlSafe :: Integer
ctlSafe = 0x000FE20000000000

mkI :: Int -> Int -> Int -> Int -> Integer -> Integer -> (Integer, Integer)
mkI op prd dst srcA field hiLow = (lo, hi)
  where
    lo = toInteger op
       + shiftL (toInteger prd) 12
       + shiftL (toInteger dst) 16
       + shiftL (toInteger srcA) 24
       + shiftL (field `mod` 4294967296) 32
    hi = ctlSafe + hiLow

-- 分岐の変位。D = disp / 4 を 40 bit 符号付きで持ち、
-- 低 8 bit が lo[23:16]、高 32 bit が lo[63:32] へ入る
braFields :: Int -> (Int, Integer)
braFields disp = (fromIntegral (d .&. 0xFF), shiftR d 8 .&. 0xFFFFFFFF)
  where d = (toInteger disp `div` 4) .&. 0xFFFFFFFFFF

encPair :: Form -> (Integer, Integer)
encPair fm = case fm of
  FMovI d x     -> mkI opMovI pT d rZ x 0x0F00
  FMovR d s     -> mkI opMovR pT d rZ (toInteger s) 0x0F00
  FIadd d a b   -> mkI opIaddR pT d a (toInteger b) (0x07FFE000 + toInteger rZ)
  FImadR d a b  -> mkI opImadR pT d a (toInteger b) (0x078E0200 + toInteger rZ)
  FImadI d a x  -> mkI opImadI pT d a x (0x078E0200 + toInteger rZ)
  FIsetp c a b  -> mkI opIsetpR pT 0 a (toInteger b)
                       (0x03F00000 + shiftL (toInteger c) 12 + 0x0270)
  FLds d a      -> mkI opLds pT d a 0 0x0800
  FSts a s      -> mkI opSts pT 0 a (toInteger s) 0x0800
  FExit         -> mkI opExit pT 0 0 0 0x03800000
  FBra p o      -> (lo, hi)
    where
      (lo8, hi32) = braFields o
      lo = toInteger opBra + shiftL (toInteger p) 12
           + shiftL (toInteger lo8) 16 + shiftL hi32 32
      hi = 0x000FC00003800000

enc :: Form -> [Int]
enc f = qwordBytes lo ++ qwordBytes hi
  where (lo, hi) = encPair f

dec :: [Int] -> Maybe (Form, Int)
dec bs
  | length bs < 16 = Nothing
  | op == opMovI   = Just (FMovI dst (sext32 field), 16)
  | op == opMovR   = Just (FMovR dst (fromIntegral field), 16)
  | op == opIaddR  = Just (FIadd dst srcA (fromIntegral field), 16)
  | op == opImadR  = Just (FImadR dst srcA (fromIntegral field), 16)
  | op == opImadI  = Just (FImadI dst srcA (sext32 field), 16)
  | op == opIsetpR = Just (FIsetp cmpv srcA (fromIntegral field), 16)
  | op == opLds    = Just (FLds dst srcA, 16)
  | op == opSts    = Just (FSts srcA (fromIntegral field), 16)
  | op == opExit   = Just (FExit, 16)
  | op == opBra    = Just (FBra prd (fromIntegral (4 * sext40 dfield)), 16)
  | otherwise      = Nothing
  where
    lo    = rdQ bs
    hi    = rdQ (drop 8 bs)
    op    = fromIntegral (lo .&. 0xFFF)
    prd   = fromIntegral (shiftR lo 12 .&. 0xF)
    dst   = fromIntegral (shiftR lo 16 .&. 0xFF)
    srcA  = fromIntegral (shiftR lo 24 .&. 0xFF)
    field = shiftR lo 32 .&. 0xFFFFFFFF
    cmpv  = fromIntegral (shiftR hi 12 .&. 0xF)
    dfield = shiftL (shiftR lo 32 .&. 0xFFFFFFFF) 8
             .|. (shiftR lo 16 .&. 0xFF)

rdQ :: [Int] -> Integer
rdQ r = sum [ toInteger v * shiftL 1 (8 * k) | (k, v) <- zip [0 ..] (take 8 r) ]

sext32 :: Integer -> Integer
sext32 v = if v >= 2147483648 then v - 4294967296 else v

sext40 :: Integer -> Integer
sext40 v = if v >= 549755813888 then v - 1099511627776 else v

-- ===== semantics（式 4.1〜4.4、07 章 式 2.1）=====

rAt :: [[Integer]] -> Int -> [Integer]
rAt rs r
  | r == rZ   = replicate warpW 0
  | otherwise = case drop r rs of
      (v : _) -> v
      []      -> replicate warpW 0

rSet :: Int -> [Integer] -> [[Integer]] -> [[Integer]]
rSet r v rs
  | r < 0 || r >= nReg = rs
  | otherwise          = take r rs ++ [v] ++ drop (r + 1) rs

pAt :: [[Bool]] -> Int -> [Bool]
pAt ps p
  | p == pT   = replicate warpW True
  | otherwise = case drop (p .&. 7) ps of
      (v : _) -> v
      []      -> replicate warpW False

pSet :: Int -> [Bool] -> [[Bool]] -> [[Bool]]
pSet p v ps
  | p < 0 || p >= nPred = ps
  | otherwise           = take p ps ++ [v] ++ drop (p + 1) ps

w32 :: Integer -> Integer
w32 v = if h >= 2147483648 then h - 4294967296 else h
  where h = v `mod` 4294967296

ldsAt :: [(Integer, Integer)] -> Integer -> Integer
ldsAt ms a = case [ v | (a', v) <- ms, a' == a ] of
  (v : _) -> v
  []      -> 0

ldsPut :: Integer -> Integer -> [(Integer, Integer)] -> [(Integer, Integer)]
ldsPut a v ms = (a, v) : [ p | p@(a', _) <- ms, a' /= a ]

applyForm :: Form -> Machine -> Maybe Machine
applyForm fm m = case fm of
  FMovI d x     -> wr d (replicate warpW (w32 x))
  FMovR d s     -> wr d (rAt rg s)
  FIadd d a b   -> wr d (z2 (rAt rg a) (rAt rg b) (+))
  FImadR d a b  -> wr d (z2 (rAt rg a) (rAt rg b) (*))
  FImadI d a x  -> wr d [ w32 (v * x) | v <- rAt rg a ]
  FIsetp c a b  -> pr 0 [ cmpOf c x y | (x, y) <- zip (rAt rg a) (rAt rg b) ]
  FLds d a      -> wr d [ ldsAt (mLds m) x | x <- rAt rg a ]
  FSts a s      ->
    let pairs = [ (x, y) | (True, (x, y)) <- zip (mMask m) (zip (rAt rg a) (rAt rg s)) ]
    in Just m { mLds = foldl (\acc (x, y) -> ldsPut x y acc) (mLds m) pairs
              , mPc = adv }
  -- 述語が真の lane が一つでもあれば分岐する。本実装の判定は uniform なので
  -- mask は動かない。割れる source を書いたときに 07 章 式 (3.2) が選ばれる
  FBra p o      -> Just m { mPc = if anyActive p then adv + toInteger o else adv }
  -- 終了。lane 0 の R0 が観測になる（09 章 式 5.1、5.2）
  FExit         -> Just m { mEvents = mEvents m ++ [lane0 (rAt rg 0)], mPc = adv }
  where
    rg  = mRegs m
    adv = mPc m + 16
    wr d v = Just m { mRegs = rSet d (maskedWrite (mMask m) (rAt rg d) v) rg
                    , mPc = adv }
    pr p v = Just m { mPreds = pSet p (maskedWrite (mMask m) (pAt (mPreds m) p) v)
                                      (mPreds m)
                    , mPc = adv }
    -- 述語の bit3 が否定を表す
    anyActive p =
      let raw = pAt (mPreds m) (p .&. 7)
          val = if p .&. 8 /= 0 then map not raw else raw
      in or [ b | (True, b) <- zip (mMask m) val ]
    cmpOf c x y
      | c == cmpLT = x < y
      | c == cmpEQ = x == y
      | otherwise  = False
    z2 xs ys f = [ w32 (f x y) | (x, y) <- zip xs ys ]
    lane0 xs = case xs of
      (v : _) -> v
      []      -> 0

-- simulator の歩数上限。意味 program の箱数に比例して伸びるので、
-- core 意味論の既定（10^6 歩）と同じ桁を取る（14 章 §5）
simSteps :: Int
simSteps = 4000000

runImage :: Int -> Machine -> [(Integer, Form)] -> Machine
runImage steps m tbl
  | steps <= 0             = m
  | not (null (mEvents m)) = m
  | otherwise = case lookup (mPc m) tbl of
      Nothing -> m
      Just f  -> case applyForm f m of
        Just m' -> runImage (steps - 1) m' tbl
        Nothing -> m

-- ===== abi =====
--
-- R0 は報告の受け皿。R1..R3 は疑似命令の scratch

pool :: [Int]
pool = [4 .. 31]

scratchA, scratchB, scratchAddr :: Int
scratchA = 1
scratchB = 2
scratchAddr = 3

okCode, koCode :: Integer
okCode = 0
koCode = 42

-- ===== atlas =====

covOp :: [(Int, Int)] -> (Int, Op) -> ([Form], [(Int, Int)])
covOp al (_, o) = case o of
  OMat w x     -> ([FMovI (rg w) x], [])
  OMul w u v   -> ([FImadR (rg w) (rg u) (rg v)], [])
  -- 符号反転の専用命令を J に入れない。IMAD の即値 −1 で作る
  ONeg w u     -> ([FImadI (rg w) (rg u) (negate 1)], [])
  OJmp l       -> ([FBra pT 0], [(l, 0)])
  -- 語番号 → LDS address: i · 4
  OLoad w i    -> ([ FImadI scratchAddr (rg i) wordScale
                   , FLds (rg w) scratchAddr ], [])
  OStore i u   -> ([ FImadI scratchAddr (rg i) wordScale
                   , FSts scratchAddr (rg u) ], [])
  OAdd w u v   ->
    let (fu, ru) = shifted scratchA u
        (fv, rv) = shifted scratchB v
    in (fu ++ fv ++ [FIadd (rg w) ru rv], [])
  OEq u v l    -> cmp cmpEQ u v l
  OLt u v l    -> cmp cmpLT u v l
  -- Put の局所片は無い。build が式 50.3 で先に止めるので、ここへは来ない
  OPut _       -> ([], [])
  OOk          -> ([FMovI 0 okCode, FExit], [])
  OKo          -> ([FMovI 0 koCode, FExit], [])
  where
    rg = lookUpA al
    -- 深度そろえは 2^s 倍。shift 命令を持たずに済む
    shifted sc (w, s)
      | s <= 0    = ([], rg w)
      | otherwise = ([FImadI sc (rg w) (shiftL 1 s)], sc)
    cmp c u v l =
      let (fu, ru) = shifted scratchA u
          (fv, rv) = shifted scratchB v
          n = length fu + length fv
      in (fu ++ fv ++ [FIsetp c ru rv, FBra 0 0], [(l, n + 1)])

-- 変位は byte 単位で、基準は次の命令
setBr :: Form -> Int -> Form
setBr f d = case f of
  FBra p _ -> FBra p (d - 16)
  other    -> other

-- ===== 完全性（式 51.1、51.3、51.4）=====

domainOf :: Form -> Machine
domainOf _ = initMachine

semTotal :: Bool
semTotal = all (\f -> applyForm f (domainOf f) /= Nothing) forms

encTotal :: Bool
encTotal = all (\f -> lenOf f == 16 && length (enc f) == 16) forms

-- ===== image =====
--
-- cubin container は本 subtarget の対象外。式 (37.3) のうち B_120 までを出す

image :: [Form] -> [Int]
image = concatMap enc

-- ===== build =====

build :: [(Int, MBox)] -> Built
build boxes
  | usesPut boxes = failedBuild targetName noPutWhy
  | otherwise     = buildOk boxes

buildOk :: [(Int, MBox)] -> Built
buildOk boxes = case allocRegs pool boxes of
  Left why -> failedBuild targetName why
  Right al -> case checkWidth wordWidth ops of
    Just why -> failedBuild targetName why
    Nothing  -> Built targetName img (mEvents fin) work [] True "" certs
    where
      ops = lowerOps boxes
      (fs, _) = assemble lenOf setBr [] [ covOp al o | o <- ops ]
      img = image fs
      addrTbl = go 0 fs
      go _ []        = []
      go a (f : fs') = (a, f) : go (a + 16) fs'
      fin = runImage simSteps initMachine addrTbl
      work = relWork 0 wordScale (mLds fin)
      certs =
        [ ( "40.1", "r", hexBs (concatMap enc forms)
                       , hexBs (concatMap enc (roundTrip forms)) )
        , ( "37.4", "n", show opInjective, show True )
        , ( "51.1", "n", show semTotal, show True )
        , ( "51.2", "n", concatMap show fs, concatMap show (decRun img) )
        , ( "51.3", "n", show encTotal, show True )
        , ( "30.4", "n", hexBs img, hexBs (image (decRun img)) )
        ]

roundTrip :: [Form] -> [Form]
roundTrip = map rt
  where rt f = case dec (enc f) of
          Just (g, n) | n == 16 -> g
          _                     -> f

decRun :: [Int] -> [Form]
decRun [] = []
decRun bs = case dec bs of
  Just (f, n) | n > 0 -> f : decRun (drop n bs)
  _                   -> []

hexBs :: [Int] -> String
hexBs bs = concat [ [dig (b `div` 16), dig (b `mod` 16)] | b <- bs ]
  where dig n = case drop n "0123456789ABCDEF" of
          (c : _) -> c
          []      -> '?'
