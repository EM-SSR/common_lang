{-# LANGUAGE NoImplicitPrelude #-}
module Common.Arch.GFX1200 where

import CounterConstraints
import Common.Core.Pipe
import Common.Core.Dyad
import Common.Arch.Lane

-- ===== AMD gfx1200 architecture package（docs/common-compiler/arch/08）=====
-- doc: casm.gfx.state casm.gfx.enc casm.gfx.op casm.gfx.sem casm.gfx.atlas
--
-- 𝔄_gfx1200 = 𝔄_RDNA4 ⊕ F_gfx1200（式 38.1）。本 package はその subtarget。
--
-- 符号は llvm-mc（LLVM 22、-mcpu=gfx1200）を oracle にして一つずつ確認した。
-- OP 番号も field 位置も、宣言値ではなく観測値である。検査は build の
-- verify 区分で行い、外部 disassembler との突き合わせは tools が持つ。
--
-- 値は VGPR に置く。作業領域は LDS を使う。LDS の address は 32 bit の VGPR
-- 一本で足りるので、語番号から address を作るのに shift 一手で済む。

targetName :: String
targetName = "gfx1200"

waveW :: Int
waveW = 32                 -- wave32

wordWidth :: Int
wordWidth = 32

-- 語番号 → LDS byte address。語は 4 byte
wordShift :: Int
wordShift = 2

-- ===== state（式 1.1）=====
--
-- VGPR は式 (2.1) の mask の下で更新される。SGPR と SCC は uniform。
-- VCC は wave32 なので lane ごとの一 bit。LDS は lane ごとの address で引く

data Machine = Machine
  { mVgpr   :: [[Integer]]           -- v0..v31、各 lane ぶん
  , mSgpr   :: [Integer]             -- s0..s31
  , mVcc    :: [Bool]
  , mScc    :: Bool
  , mExec   :: Mask
  , mLds    :: [(Integer, Integer)]  -- byte address → 32 bit 語
  , mPc     :: Integer
  , mEvents :: [Integer]
  } deriving (Eq, Show)

nVgpr, nSgpr :: Int
nVgpr = 32
nSgpr = 32

initMachine :: Machine
initMachine = Machine (replicate nVgpr (replicate waveW 0))
                      (replicate nSgpr 0)
                      (replicate waveW False) False (fullMask waveW)
                      [] 0 []

-- ===== instruction 𝓘_J =====

data Form
  = FVMovI  !Int !Integer     -- v_mov_b32 vD, literal
  | FVMovR  !Int !Int         -- v_mov_b32 vD, vS
  | FVAdd   !Int !Int !Int    -- v_add_nc_u32 vD, vS0, vS1
  | FVSub   !Int !Int !Int    -- v_sub_nc_u32
  | FVMul   !Int !Int !Int    -- v_mul_lo_u32（VOP3）
  | FVShl   !Int !Int !Int    -- v_lshlrev_b32 vD, k, vS
  | FVAshr  !Int !Int !Int    -- v_ashrrev_i32 vD, k, vS
  | FVCmpEq !Int !Int         -- v_cmp_eq_u32 vcc, vS0, vS1
  | FVCmpLt !Int !Int         -- v_cmp_lt_i32 vcc, vS0, vS1
  | FDsLoad  !Int !Int        -- ds_load_b32 vD, vAddr
  | FDsStore !Int !Int        -- ds_store_b32 vAddr, vData
  | FWaitLgkm                 -- s_waitcnt lgkmcnt(0)
  | FCbrVcc !Int              -- s_cbranch_vccnz。変位は word 単位
  | FBranch !Int              -- s_branch
  | FReadLane !Int !Int       -- v_readfirstlane_b32 sD, vS
  | FEndPgm
  deriving (Eq, Ord, Show)

forms :: [Form]
forms =
  [ FVMovI d x | d <- [0, 4, 31], x <- [0, 42, 0x12345678] ]
  ++ [ FVMovR d s | d <- [0, 4], s <- [1, 5] ]
  ++ [ FVAdd d a b | d <- [0, 4], a <- [1, 5], b <- [2, 6] ]
  ++ [ FVSub d a b | d <- [0, 4], a <- [1, 5], b <- [2, 6] ]
  ++ [ FVMul d a b | d <- [0, 4], a <- [1, 5], b <- [2, 6] ]
  ++ [ FVShl d k a | d <- [0, 4], k <- [1, 2, 8], a <- [1, 5] ]
  ++ [ FVAshr d k a | d <- [0, 4], k <- [1, 2, 8], a <- [1, 5] ]
  ++ [ FVCmpEq a b | a <- [1, 5], b <- [2, 6] ]
  ++ [ FVCmpLt a b | a <- [1, 5], b <- [2, 6] ]
  ++ [ FDsLoad d a | d <- [0, 5], a <- [1, 7] ]
  ++ [ FDsStore a v | a <- [1, 7], v <- [0, 5] ]
  ++ [ FWaitLgkm ]
  ++ [ FCbrVcc o | o <- [1, -1, 100] ]
  ++ [ FBranch o | o <- [1, -1, 100] ]
  ++ [ FReadLane s v | s <- [0, 3], v <- [0, 4] ]
  ++ [ FEndPgm ]

lenOf :: Form -> Int
lenOf f = case f of
  FVMovI _ _  -> 8      -- literal が続く
  FVMul _ _ _ -> 8      -- VOP3
  FDsLoad _ _ -> 8
  FDsStore _ _ -> 8
  _           -> 4

-- ===== OP 番号（llvm-mc gfx1200 の観測値）=====

opSMov :: Int
opSMov = 0x00                  -- SOP1

opBranch, opCbrScc1, opCbrVcc, opWaitcnt, opEndpgm :: Int
opBranch  = 0x20               -- SOPP
opCbrScc1 = 0x22
opCbrVcc  = 0x24
opWaitcnt = 0x09
opEndpgm  = 0x30

opVMov, opVReadLane :: Int
opVMov      = 0x01             -- VOP1
opVReadLane = 0x02

opVAdd, opVSub, opVShl, opVAshr :: Int
opVAdd  = 0x25                 -- VOP2
opVSub  = 0x26
opVShl  = 0x18
opVAshr = 0x1A

opVCmpEq, opVCmpLt :: Int
opVCmpEq = 0x4A                -- VOPC
opVCmpLt = 0x41

-- VOP3 は [31:26] が符号種別、[25:16] が OP になる。base word を 0xD7 から
-- 取ると OP field と重なるので、種別は 0x35 << 26 で置く
vop3Base :: Int
vop3Base = shiftL 0x35 26      -- 0xD4000000

opVMul :: Int
opVMul = 0x32C                 -- VOP3。v_mul_lo_u32

-- lgkmcnt(0) の SIMM16。LDS の完了を待つ
simmLgkm :: Int
simmLgkm = 0xFC07

-- 同じ format の中で番号が重ならないこと。式 (37.4) の前提になる
opInjective :: Bool
opInjective = and
  [ distinct [opBranch, opCbrScc1, opCbrVcc, opWaitcnt, opEndpgm]
  , distinct [opVMov, opVReadLane]
  , distinct [opVAdd, opVSub, opVShl, opVAshr]
  , distinct [opVCmpEq, opVCmpLt] ]
  where
    distinct xs = and [ a /= b | (i, a) <- zip [0 :: Int ..] xs
                              , (j, b) <- zip [0 :: Int ..] xs, i /= j ]

-- ===== operand の符号 =====
--
-- SRC field は 9 bit。0..105 が SGPR、128 が 0、128+k が 1..64 の inline 定数、
-- 255 が後続の 32 bit literal、256+n が VGPR になる

srcInline :: Int -> Int
srcInline k
  | k == 0            = 128
  | k >= 1 && k <= 64 = 128 + k
  | otherwise         = 128

srcLiteral :: Int
srcLiteral = 255

srcVgpr :: Int -> Int
srcVgpr n = 256 + n

inlineValue :: Int -> Maybe Int
inlineValue v
  | v == 128             = Just 0
  | v >= 129 && v <= 192 = Just (v - 128)
  | otherwise            = Nothing

-- ===== encoding =====

sopp :: Int -> Int -> Int
sopp op simm = 0xBF800000 .|. shiftL op 16 .|. (simm .&. 0xFFFF)

vop1 :: Int -> Int -> Int -> Int
vop1 op vdst src0 = 0x7E000000 .|. shiftL vdst 17 .|. shiftL op 9 .|. src0

vop2 :: Int -> Int -> Int -> Int -> Int
vop2 op vdst vsrc1 src0 =
  shiftL op 25 .|. shiftL vdst 17 .|. shiftL vsrc1 9 .|. src0

vopc :: Int -> Int -> Int -> Int
vopc op vsrc1 src0 = 0x7C000000 .|. shiftL op 17 .|. shiftL vsrc1 9 .|. src0

enc :: Form -> [Int]
enc fm = case fm of
  FVMovI d x    -> le32 (vop1 opVMov d srcLiteral) ++ le32 (lo32 x)
  FVMovR d s    -> le32 (vop1 opVMov d (srcVgpr s))
  FVAdd d a b   -> le32 (vop2 opVAdd d b (srcVgpr a))
  FVSub d a b   -> le32 (vop2 opVSub d b (srcVgpr a))
  -- VOP3: word0 = 種別 | OP<<16 | VDST、word1 = SRC0 | SRC1<<9
  FVMul d a b   -> le32 (vop3Base .|. shiftL opVMul 16 .|. d)
                   ++ le32 (srcVgpr a .|. shiftL (srcVgpr b) 9)
  -- shift 量は src0（inline 定数）、値は vsrc1 に来る
  FVShl d k a   -> le32 (vop2 opVShl d a (srcInline k))
  FVAshr d k a  -> le32 (vop2 opVAshr d a (srcInline k))
  FVCmpEq a b   -> le32 (vopc opVCmpEq b (srcVgpr a))
  FVCmpLt a b   -> le32 (vopc opVCmpLt b (srcVgpr a))
  -- DS: dword0 = 0xD8D80000 | offset、dword1 = vAddr | vDst<<24
  FDsLoad d a   -> le32 0xD8D80000 ++ le32 (a .|. shiftL d 24)
  FDsStore a v  -> le32 0xD8340000 ++ le32 (a .|. shiftL v 8)
  FWaitLgkm     -> le32 (sopp opWaitcnt simmLgkm)
  FCbrVcc o     -> le32 (sopp opCbrVcc o)
  FBranch o     -> le32 (sopp opBranch o)
  FReadLane s v -> le32 (vop1 opVReadLane s (srcVgpr v))
  FEndPgm       -> le32 (sopp opEndpgm 0)

lo32 :: Integer -> Int
lo32 x = fromIntegral (x `mod` 4294967296)

-- ===== decoding =====

dec :: [Int] -> Maybe (Form, Int)
dec bs
  | length bs < 4 = Nothing
  | w == 0xD8D80000 && length bs >= 8 =
      Just (FDsLoad (shiftR w1 24 .&. 0xFF) (w1 .&. 0xFF), 8)
  | w == 0xD8340000 && length bs >= 8 =
      Just (FDsStore (w1 .&. 0xFF) (shiftR w1 8 .&. 0xFF), 8)
  | top6 == 0x35 && op10 == opVMul && length bs >= 8 =
      Just (FVMul (w .&. 0xFF) (w1 .&. 0x1FF - 256)
                  (shiftR w1 9 .&. 0x1FF - 256), 8)
  | top9 == 0x17F = case op7 of
      _ | op7 == opBranch  -> Just (FBranch (sext16 simm), 4)
        | op7 == opCbrVcc  -> Just (FCbrVcc (sext16 simm), 4)
        | op7 == opWaitcnt -> Just (FWaitLgkm, 4)
        | op7 == opEndpgm  -> Just (FEndPgm, 4)
      _ -> Nothing
  | top7 == 0x3F = case opV1 of
      _ | opV1 == opVMov && src0 == srcLiteral && length bs >= 8 ->
            Just (FVMovI vdst1 (sext32i (rd32 (drop 4 bs))), 8)
        | opV1 == opVMov && src0 >= 256 -> Just (FVMovR vdst1 (src0 - 256), 4)
        | opV1 == opVReadLane && src0 >= 256 ->
            Just (FReadLane vdst1 (src0 - 256), 4)
      _ -> Nothing
  | top7 == 0x3E = case opVc of
      _ | opVc == opVCmpEq && src0 >= 256 -> Just (FVCmpEq (src0 - 256) vsrc1, 4)
        | opVc == opVCmpLt && src0 >= 256 -> Just (FVCmpLt (src0 - 256) vsrc1, 4)
      _ -> Nothing
  | top1 == 0 = case opV2 of
      _ | opV2 == opVAdd && src0 >= 256 -> Just (FVAdd vdst1 (src0 - 256) vsrc1, 4)
        | opV2 == opVSub && src0 >= 256 -> Just (FVSub vdst1 (src0 - 256) vsrc1, 4)
        | opV2 == opVShl  -> shiftDec FVShl
        | opV2 == opVAshr -> shiftDec FVAshr
      _ -> Nothing
  | otherwise = Nothing
  where
    w     = rd32 bs
    w1    = rd32 (drop 4 bs)
    top9  = shiftR w 23 .&. 0x1FF
    top7  = shiftR w 25 .&. 0x7F
    top6  = shiftR w 26 .&. 0x3F
    top1  = shiftR w 31 .&. 0x1
    op7   = shiftR w 16 .&. 0x7F
    op10  = shiftR w 16 .&. 0x3FF
    opV1  = shiftR w 9 .&. 0xFF
    opV2  = shiftR w 25 .&. 0x3F
    opVc  = shiftR w 17 .&. 0xFF
    vdst1 = shiftR w 17 .&. 0xFF
    vsrc1 = shiftR w 9 .&. 0xFF
    src0  = w .&. 0x1FF
    simm  = w .&. 0xFFFF
    shiftDec mk = case inlineValue src0 of
      Just k  -> Just (mk vdst1 k vsrc1, 4)
      Nothing -> Nothing

rd32 :: [Int] -> Int
rd32 r = case r of
  (a : b : c : d : _) -> a + 256 * b + 65536 * c + 16777216 * d
  _                   -> 0

sext16 :: Int -> Int
sext16 v = if v >= 32768 then v - 65536 else v

-- literal field は 32 bit の bit pattern。値としては符号付きで読む
sext32i :: Int -> Integer
sext32i v = toInteger (if v >= 2147483648 then v - 4294967296 else v)

-- ===== semantics（07 章 式 2.1）=====

vAt :: [[Integer]] -> Int -> [Integer]
vAt vs r = case drop r vs of
  (v : _) -> v
  []      -> replicate waveW 0

vSet :: Int -> [Integer] -> [[Integer]] -> [[Integer]]
vSet r v vs
  | r < 0 || r >= nVgpr = vs
  | otherwise           = take r vs ++ [v] ++ drop (r + 1) vs

sSet :: Int -> Integer -> [Integer] -> [Integer]
sSet r v ss
  | r < 0 || r >= nSgpr = ss
  | otherwise           = take r ss ++ [v] ++ drop (r + 1) ss

sAt :: [Integer] -> Int -> Integer
sAt ss r = case drop r ss of
  (v : _) -> v
  []      -> 0

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
  FVMovI d x    -> wr d (replicate waveW (w32 x))
  FVMovR d s    -> wr d (vAt vr s)
  FVAdd d a b   -> wr d (z2 (vAt vr a) (vAt vr b) (+))
  FVSub d a b   -> wr d (z2 (vAt vr a) (vAt vr b) (-))
  FVMul d a b   -> wr d (z2 (vAt vr a) (vAt vr b) (*))
  FVShl d k a   -> wr d [ w32 (shiftL x k) | x <- vAt vr a ]
  FVAshr d k a  -> wr d [ w32 (shiftR x k) | x <- vAt vr a ]
  FVCmpEq a b   -> cc [ x == y | (x, y) <- zip (vAt vr a) (vAt vr b) ]
  FVCmpLt a b   -> cc [ x <  y | (x, y) <- zip (vAt vr a) (vAt vr b) ]
  FDsLoad d a   -> wr d [ ldsAt (mLds m) x | x <- vAt vr a ]
  -- 書き込みは active lane だけが行う
  FDsStore a v  ->
    let pairs = [ (x, y) | (True, (x, y)) <- zip (mExec m) (zip (vAt vr a) (vAt vr v)) ]
    in Just m { mLds = foldl (\acc (x, y) -> ldsPut x y acc) (mLds m) pairs
              , mPc = adv }
  FWaitLgkm     -> Just m { mPc = adv }
  FCbrVcc o     -> Just m { mPc = adv + (if anyVcc then toInteger o * 4 else 0) }
  FBranch o     -> Just m { mPc = adv + toInteger o * 4 }
  FReadLane s v -> Just m { mSgpr = sSet s (lane0 (vAt vr v)) (mSgpr m), mPc = adv }
  -- 終了。s0 の値が観測になる（08 章 式 6.1、6.2）
  FEndPgm       -> Just m { mEvents = mEvents m ++ [sAt (mSgpr m) 0], mPc = adv }
  where
    vr  = mVgpr m
    adv = mPc m + toInteger (lenOf fm)
    wr d v = Just m { mVgpr = vSet d (maskedWrite (mExec m) (vAt vr d) v) vr
                    , mPc = adv }
    cc v = Just m { mVcc = maskedWrite (mExec m) (mVcc m) v, mPc = adv }
    anyVcc = or [ b | (True, b) <- zip (mExec m) (mVcc m) ]
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
-- v0..v2 は疑似命令の scratch。v3 は語番号から作った LDS address。
-- 報告は v_readfirstlane_b32 で s0 へ移してから s_endpgm

pool :: [Int]
pool = [4 .. 31]

scratchA, scratchB, scratchAddr :: Int
scratchA = 0
scratchB = 1
scratchAddr = 3

okCode, koCode :: Integer
okCode = 0
koCode = 42

-- ===== atlas =====

covOp :: [(Int, Int)] -> (Int, Op) -> ([Form], [(Int, Int)])
covOp al (_, o) = case o of
  OMat w x     -> ([FVMovI (rg w) x], [])
  OMul w u v   -> ([FVMul (rg w) (rg u) (rg v)], [])
  ONeg w u     -> ([FVMovI scratchA 0, FVSub (rg w) scratchA (rg u)], [])
  OJmp l       -> ([FBranch 0], [(l, 0)])
  -- 語番号 → LDS address: i << 2
  OLoad w i    -> ([ FVShl scratchAddr wordShift (rg i)
                   , FDsLoad (rg w) scratchAddr, FWaitLgkm ], [])
  OStore i u   -> ([ FVShl scratchAddr wordShift (rg i)
                   , FDsStore scratchAddr (rg u), FWaitLgkm ], [])
  OAdd w u v   ->
    let (fu, ru) = shifted scratchA u
        (fv, rv) = shifted scratchB v
    in (fu ++ fv ++ [FVAdd (rg w) ru rv], [])
  OEq u v l    -> cmp FVCmpEq u v l
  OLt u v l    -> cmp FVCmpLt u v l
  -- Put の局所片は無い。build が式 50.3 で先に止めるので、ここへは来ない
  OPut _       -> ([], [])
  OOk          -> (report okCode, [])
  OKo          -> (report koCode, [])
  where
    rg = lookUpA al
    shifted sc (w, s)
      | s <= 0    = ([], rg w)
      | otherwise = ([FVShl sc s (rg w)], sc)
    cmp mk u v l =
      let (fu, ru) = shifted scratchA u
          (fv, rv) = shifted scratchB v
          n = length fu + length fv
      in (fu ++ fv ++ [mk ru rv, FCbrVcc 0], [(l, n + 1)])
    report v = [FVMovI scratchA v, FReadLane 0 scratchA, FEndPgm]

-- SIMM16 は word 単位で、基準は次の命令（式 8.1）
setBr :: Form -> Int -> Form
setBr f d = case f of
  FCbrVcc _ -> FCbrVcc ((d - 4) `div` 4)
  FBranch _ -> FBranch ((d - 4) `div` 4)
  other     -> other

-- ===== 完全性（式 51.1、51.3、51.4）=====

domainOf :: Form -> Machine
domainOf _ = initMachine

semTotal :: Bool
semTotal = all (\f -> applyForm f (domainOf f) /= Nothing) forms

encTotal :: Bool
encTotal = all (\f -> lenOf f > 0 && length (enc f) == lenOf f) forms

-- ===== image =====

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
      go a (f : fs') = (a, f) : go (a + toInteger (lenOf f)) fs'
      fin = runImage simSteps initMachine addrTbl
      -- LDS の byte address を語番号へ戻す
      work = relWork 0 (shiftL 1 wordShift) (mLds fin)
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
          Just (g, n) | n == lenOf f -> g
          _                          -> f

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
