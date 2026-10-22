{-# LANGUAGE NoImplicitPrelude #-}
module Common.Arch.RV64 where

import CounterConstraints
import Common.Core.Pipe
import Common.Core.Dyad

-- ===== riscv64 architecture package（docs/common-compiler/arch/06）=====
-- doc: casm.rv64.state casm.rv64.enc casm.rv64.abi casm.rv64.image casm.rv64.atlas
--
-- 九区分（式 33.1）を節で分ける。
--   state / instruction / encoding / semantics / memory / atlas / abi / image / verify
--
-- subtarget J = { LUI, ADDI, SLLI, SRAI, ADD, SUB, MUL, SW, SD, LD, BEQ, BLT, JAL }
-- MUL は M 拡張。QEMU virt の既定 CPU（rv64gc）が持つ。

targetName :: String
targetName = "riscv64"

-- ===== state =====
--
-- Σ = registers × memory × pc × events。実行位相は一枚（|𝒳| = 1）。
-- x0 は常に 0（静的制約 𝒦_A）

data Machine = Machine
  { mRegs   :: [Integer]              -- x0..x31
  , mMem    :: [(Integer, Integer)]   -- address → 語
  , mPc     :: Integer
  , mEvents :: [Integer]              -- sifive_test へ書かれた値
  } deriving (Eq, Show)

loadBase :: Integer
loadBase = 0x80000000

initMachine :: Machine
initMachine = Machine (replicate 32 0) [] loadBase []

wordWidth :: Int
wordWidth = 64

-- ===== instruction 𝓘_J =====

data Form
  = FLui  !Int !Int          -- rd, imm20（符号なし 20 bit）
  | FAddi !Int !Int !Int     -- rd, rs1, imm12
  | FSlli !Int !Int !Int     -- rd, rs1, shamt6
  | FSrai !Int !Int !Int
  | FAdd  !Int !Int !Int
  | FSub  !Int !Int !Int
  | FMul  !Int !Int !Int
  | FSw   !Int !Int !Int     -- rs2, rs1, imm12   mem[rs1+imm] ← rs2（32 bit）
  | FSd   !Int !Int !Int     -- 同上（64 bit）
  | FLd   !Int !Int !Int     -- rd, rs1, imm12
  | FBeq  !Int !Int !Int     -- rs1, rs2, offBytes
  | FBlt  !Int !Int !Int
  | FJal  !Int !Int          -- rd, offBytes
  deriving (Eq, Ord, Show)

-- 式 (51.1) と (40.1) の検査対象。境界値と符号の両側を含める
forms :: [Form]
forms =
  [ FLui r i     | r <- [1, 5, 6], i <- [0x10, 0xFFFFF] ]
  ++ [ FAddi r a i | r <- [1, 5], a <- [0, 1], i <- [0, 2047, -2048] ]
  ++ [ FSlli r a n | r <- [1, 5], a <- [1, 6], n <- [0, 11, 32, 63] ]
  ++ [ FSrai r a n | r <- [1, 5], a <- [1, 6], n <- [1, 32, 63] ]
  ++ [ FAdd r a b  | r <- [1, 5], a <- [1, 6], b <- [0, 5] ]
  ++ [ FSub r a b  | r <- [1, 5], a <- [0, 6], b <- [1, 5] ]
  ++ [ FMul r a b  | r <- [1, 5], a <- [1, 6], b <- [2, 5] ]
  ++ [ FSw b a i   | b <- [1, 5], a <- [5, 6], i <- [0, 100, -4] ]
  ++ [ FSd b a i   | b <- [1, 5], a <- [5, 6], i <- [0, 96, -8] ]
  ++ [ FLd r a i   | r <- [1, 5], a <- [5, 6], i <- [0, 96, -8] ]
  ++ [ FBeq a b o  | a <- [1, 0], b <- [5, 0], o <- [8, -8, 4094] ]
  ++ [ FBlt a b o  | a <- [1, 0], b <- [5, 0], o <- [8, -8, 4094] ]
  ++ [ FJal r o    | r <- [0, 1], o <- [8, -8, 1048574] ]

lenOf :: Form -> Int
lenOf _ = 4

-- ===== encoding =====
--
-- 一命令一符号。canonical encoding（定理 24.1）は関数へ退化する

enc :: Form -> Word32
enc fm = case fm of
  FLui rd i     -> uType i rd 0x37
  FAddi rd a i  -> iType i a 0x0 rd 0x13
  FSlli rd a n  -> iType (n .&. 0x3F) a 0x1 rd 0x13
  FSrai rd a n  -> iType (0x400 .|. (n .&. 0x3F)) a 0x5 rd 0x13
  FAdd rd a b   -> rType 0x00 b a 0x0 rd 0x33
  FSub rd a b   -> rType 0x20 b a 0x0 rd 0x33
  FMul rd a b   -> rType 0x01 b a 0x0 rd 0x33
  FSw b a i     -> sType i b a 0x2 0x23
  FSd b a i     -> sType i b a 0x3 0x23
  FLd rd a i    -> iType i a 0x3 rd 0x03
  FBeq a b o    -> bType o b a 0x0 0x63
  FBlt a b o    -> bType o b a 0x4 0x63
  FJal rd o     -> jType o rd 0x6F

rType :: Int -> Int -> Int -> Int -> Int -> Int -> Word32
rType f7 rs2 rs1 f3 rd op =
  fi (shiftL f7 25 .|. shiftL rs2 20 .|. shiftL rs1 15 .|. shiftL f3 12
       .|. shiftL rd 7 .|. op)

iType :: Int -> Int -> Int -> Int -> Int -> Word32
iType imm rs1 f3 rd op =
  fi (shiftL (imm .&. 0xFFF) 20 .|. shiftL rs1 15 .|. shiftL f3 12
       .|. shiftL rd 7 .|. op)

-- S 型は即値を imm[11:5] と imm[4:0] に割る
sType :: Int -> Int -> Int -> Int -> Int -> Word32
sType imm rs2 rs1 f3 op =
  fi ( shiftL ((imm `div` 32) .&. 0x7F) 25 .|. shiftL rs2 20 .|. shiftL rs1 15
       .|. shiftL f3 12 .|. shiftL (imm .&. 0x1F) 7 .|. op )

-- B 型: inst[31]=imm[12]、inst[30:25]=imm[10:5]、inst[11:8]=imm[4:1]、inst[7]=imm[11]
bType :: Int -> Int -> Int -> Int -> Int -> Word32
bType off rs2 rs1 f3 op =
  fi ( shiftL ((off `div` 4096) .&. 0x1) 31
       .|. shiftL ((off `div` 32) .&. 0x3F) 25
       .|. shiftL rs2 20 .|. shiftL rs1 15 .|. shiftL f3 12
       .|. shiftL ((off `div` 2) .&. 0xF) 8
       .|. shiftL ((off `div` 2048) .&. 0x1) 7
       .|. op )

uType :: Int -> Int -> Int -> Word32
uType imm rd op = fi (shiftL (imm .&. 0xFFFFF) 12 .|. shiftL rd 7 .|. op)

-- J 型: inst[31]=imm[20]、inst[30:21]=imm[10:1]、inst[20]=imm[11]、inst[19:12]=imm[19:12]
jType :: Int -> Int -> Int -> Word32
jType off rd op =
  fi ( shiftL ((off `div` 1048576) .&. 0x1) 31
       .|. shiftL ((off `div` 2) .&. 0x3FF) 21
       .|. shiftL ((off `div` 2048) .&. 0x1) 20
       .|. shiftL ((off `div` 4096) .&. 0xFF) 12
       .|. shiftL rd 7 .|. op )

fi :: Int -> Word32
fi = fromIntegral

dec :: Word32 -> Maybe Form
dec w = case w .&. 0x7F of
  0x37 -> Just (FLui (rd w) (hi20 w))
  0x13 -> case f3w w of
    0x0 -> Just (FAddi (rd w) (rs1 w) (sext12 (iImm w)))
    0x1 | iImm w `div` 64 == 0    -> Just (FSlli (rd w) (rs1 w) (iImm w .&. 0x3F))
    0x5 | iImm w `div` 64 == 0x10 -> Just (FSrai (rd w) (rs1 w) (iImm w .&. 0x3F))
    _   -> Nothing
  0x33 | f3w w == 0 -> case f7 w of
    0x00 -> Just (FAdd (rd w) (rs1 w) (rs2 w))
    0x20 -> Just (FSub (rd w) (rs1 w) (rs2 w))
    0x01 -> Just (FMul (rd w) (rs1 w) (rs2 w))
    _    -> Nothing
  0x23 -> case f3w w of
    0x2 -> Just (FSw (rs2 w) (rs1 w) (sext12 (sImm w)))
    0x3 -> Just (FSd (rs2 w) (rs1 w) (sext12 (sImm w)))
    _   -> Nothing
  0x03 | f3w w == 0x3 -> Just (FLd (rd w) (rs1 w) (sext12 (iImm w)))
  0x63 -> case f3w w of
    0x0 -> Just (FBeq (rs1 w) (rs2 w) (sext13 (bOff w)))
    0x4 -> Just (FBlt (rs1 w) (rs2 w) (sext13 (bOff w)))
    _   -> Nothing
  0x6F -> Just (FJal (rd w) (sext21 (jOff w)))
  _    -> Nothing
  where
    bOff ww = fromIntegral ((ww `shiftR` 31) .&. 0x1) * 4096
            + fromIntegral ((ww `shiftR` 25) .&. 0x3F) * 32
            + fromIntegral ((ww `shiftR` 7) .&. 0x1) * 2048
            + fromIntegral ((ww `shiftR` 8) .&. 0xF) * 2
    jOff ww = fromIntegral ((ww `shiftR` 31) .&. 0x1) * 1048576
            + fromIntegral ((ww `shiftR` 12) .&. 0xFF) * 4096
            + fromIntegral ((ww `shiftR` 20) .&. 0x1) * 2048
            + fromIntegral ((ww `shiftR` 21) .&. 0x3FF) * 2
    sImm ww = fromIntegral ((ww `shiftR` 25) .&. 0x7F) * 32
            + fromIntegral ((ww `shiftR` 7) .&. 0x1F)
    hi20 ww = fromIntegral ((ww `shiftR` 12) .&. 0xFFFFF)
    f7 ww   = fromIntegral ((ww `shiftR` 25) .&. 0x7F) :: Int
    f3w ww  = fromIntegral ((ww `shiftR` 12) .&. 0x7) :: Int
    rd ww   = fromIntegral ((ww `shiftR` 7) .&. 0x1F)
    rs1 ww  = fromIntegral ((ww `shiftR` 15) .&. 0x1F)
    rs2 ww  = fromIntegral ((ww `shiftR` 20) .&. 0x1F)
    iImm ww = fromIntegral ((ww `shiftR` 20) .&. 0xFFF)

sext12, sext13, sext21 :: Int -> Int
sext12 v = if v >= 2048 then v - 4096 else v
sext13 v = if v >= 4096 then v - 8192 else v
sext21 v = if v >= 1048576 then v - 2097152 else v

-- ===== memory =====

sifiveTest :: Integer
sifiveTest = 0x100000

memPut :: Integer -> Integer -> [(Integer, Integer)] -> [(Integer, Integer)]
memPut a v ms = (a, v) : [ p | p@(a', _) <- ms, a' /= a ]

memAt :: [(Integer, Integer)] -> Integer -> Integer
memAt ms a = case [ v | (a', v) <- ms, a' == a ] of
  (v : _) -> v
  []      -> 0

setReg :: Int -> Integer -> [Integer] -> [Integer]
setReg r v rs
  | r <= 0    = rs
  | otherwise = take r rs ++ [v] ++ drop (r + 1) rs

regAt :: [Integer] -> Int -> Integer
regAt rs r
  | r <= 0    = 0
  | otherwise = case drop r rs of
      (v : _) -> v
      []      -> 0

-- ===== semantics δ（式 8.1 の決定的特殊形）=====

applyForm :: Form -> Machine -> Maybe Machine
applyForm fm m = case fm of
  FLui rd i     -> ok rd (sext32 (toInteger i * 4096))
  FAddi rd a i  -> ok rd (regAt rg a + toInteger i)
  FSlli rd a n  -> ok rd (shiftL (regAt rg a) n)
  FSrai rd a n  -> ok rd (shiftR (regAt rg a) n)
  FAdd rd a b   -> ok rd (regAt rg a + regAt rg b)
  FSub rd a b   -> ok rd (regAt rg a - regAt rg b)
  FMul rd a b   -> ok rd (regAt rg a * regAt rg b)
  FLd rd a i    -> ok rd (memAt (mMem m) (regAt rg a + toInteger i))
  FSw b a i     -> st (regAt rg a + toInteger i) (mask32 (regAt rg b))
  FSd b a i     -> st (regAt rg a + toInteger i) (regAt rg b)
  FBeq a b o    -> br (regAt rg a == regAt rg b) o
  FBlt a b o    -> br (regAt rg a < regAt rg b) o
  FJal rd o     -> Just m { mRegs = setReg rd (mPc m + 4) rg
                          , mPc = mPc m + toInteger o }
  where
    rg = mRegs m
    ok r v = Just m { mRegs = setReg r (w64 v) rg, mPc = mPc m + 4 }
    st a v = Just m { mMem = memPut a v (mMem m), mPc = mPc m + 4
                    , mEvents = mEvents m ++ [ v | a == sifiveTest ] }
    br c o = Just m { mPc = mPc m + toInteger (if c then o else 4) }

-- 64 bit の巻き戻し。register 幅を超えた値は符号付きで折り返す
w64 :: Integer -> Integer
w64 v = if h >= 9223372036854775808 then h - 18446744073709551616 else h
  where h = v `mod` 18446744073709551616

mask32 :: Integer -> Integer
mask32 v = v `mod` 4294967296

sext32 :: Integer -> Integer
sext32 v = if v >= 2147483648 then v - 4294967296 else v

-- pc 主導の実行（式 43.2 の観測）。反復上限は暴走の検出用であり、
-- 意味としては停止ループが回り続けるのが正しい
-- simulator の歩数上限。意味 program の箱数に比例して伸びるので、
-- core 意味論の既定（10^6 歩）と同じ桁を取る（14 章 §5）
simSteps :: Int
simSteps = 4000000

runImage :: Int -> Machine -> [Form] -> Machine
runImage steps m fs
  | steps <= 0             = m
  | not (null (mEvents m)) = m
  | otherwise = case idx of
      Nothing -> m
      Just k  -> case drop k fs of
        (f : _) -> case applyForm f m of
          Just m' -> runImage (steps - 1) m' fs
          Nothing -> m
        [] -> m
  where
    d = mPc m - loadBase
    idx | d >= 0 && d `mod` 4 == 0 && d `div` 4 < toInteger (length fs)
            = Just (fromIntegral (d `div` 4))
        | otherwise = Nothing

-- ===== abi =====

pool :: [Int]
pool = [5 .. 26]

scratchA, scratchB :: Int
scratchA = 28
scratchB = 29

-- 作業領域の基底を持つ register。プロローグで一度だけ置く。
-- 語番号から address を作る刻み幅もここで決まる（意味には現れない）
baseReg :: Int
baseReg = 27

wordShift :: Int
wordShift = 3            -- 語は 8 byte

passValue, failValue :: Integer
passValue = 0x5555
failValue = 42 * 65536 + 0x3333

-- 作業領域の基底。RAM の先頭から 1 MB 先。image と重ならない
workBase :: Integer
workBase = 0x80100000

-- 意味の側の観測へ戻す（§32.4 の interface realization の逆）。
-- 0 = 成功、42 = 失敗。この正規化で全 target の観測が比較できるようになる
observe :: [Integer] -> [Integer]
observe = map back
  where
    back v | v == passValue = 0
           | otherwise      = v `div` 65536

-- ===== atlas（Cover）=====

-- 整数の物質化（06 章 式 5.1）。12 bit、32 bit、それ以上の三段
liSeq :: Int -> Integer -> [Form]
liSeq w k
  | -2048 <= k && k <= 2047 = [FAddi w 0 (fromIntegral k)]
  | -2147483648 <= k && k <= 2147483647 =
      let q  = (k + 2048) `div` 4096
          hi = fromIntegral (q .&. 0xFFFFF)
          lo = fromIntegral (k - q * 4096)
      in if lo == 0 then [FLui w hi] else [FLui w hi, FAddi w w lo]
  | otherwise =
      -- 11 bit ずつ上位から積む。剰余を非負に取るので ADDI の符号拡張を避けられる
      let q = k `div` 2048
          r = k - q * 2048
      in liSeq w q ++ [FSlli w w 11] ++ [FAddi w w (fromIntegral r)]

covOp :: [(Int, Int)] -> (Int, Op) -> ([Form], [(Int, Int)])
covOp al (_, o) = case o of
  OMat w x     -> (liSeq (rg w) x, [])
  OMul w u v   -> ([FMul (rg w) (rg u) (rg v)], [])
  ONeg w u     -> ([FSub (rg w) 0 (rg u)], [])
  -- 語番号 → address: (i << 3) + base
  OLoad w i    -> (addrOf i ++ [FLd (rg w) scratchA 0], [])
  OStore i u   -> (addrOf i ++ [FSd (rg u) scratchA 0], [])
  OJmp l       -> ([FJal 0 0], [(l, 0)])
  OAdd w u v   ->
    let (fu, ru) = shifted scratchA u
        (fv, rv) = shifted scratchB v
    in (fu ++ fv ++ [FAdd (rg w) ru rv], [])
  OEq u v l    -> cmp FBeq u v l
  OLt u v l    -> cmp FBlt u v l
  -- Put の局所片は無い。build が式 50.3 で先に止めるので、ここへは来ない
  OPut _       -> ([], [])
  OOk          -> (report passValue, [])
  OKo          -> (report failValue, [])
  where
    rg = lookUpA al
    addrOf i = [FSlli scratchA (rg i) wordShift, FAdd scratchA scratchA baseReg]
    -- 深度をそろえる左シフト。量が 0 なら局所片は空になる（01 章 式 4.1）
    shifted sc (w, s)
      | s <= 0    = ([], rg w)
      | otherwise = ([FSlli sc (rg w) s], sc)
    cmp mk u v l =
      let (fu, ru) = shifted scratchA u
          (fv, rv) = shifted scratchB v
      in (fu ++ fv ++ [mk ru rv 0], [(l, length fu + length fv)])
    -- 報告のあとは自己参照分岐で閉じる（§18）。素通しさせると、
    -- 外部環境が止めるまでの間に次の箱の局所片が走ってしまう
    report v = liSeq scratchA v ++ liSeq scratchB sifiveTest
               ++ [FSw scratchA scratchB 0, FJal 0 0]

setBr :: Form -> Int -> Form
setBr f d = case f of
  FBeq a b _ -> FBeq a b d
  FBlt a b _ -> FBlt a b d
  FJal r _   -> FJal r d
  other      -> other


-- ===== 完全性（式 51.1、51.3、51.4）=====
--
-- 51.1 / 51.4: 全 form に意味が定義されている。適用条件 U_i を満たす状態を
--              form ごとに与え、そこで delta が値を持つことを見る
-- 51.3:        全 form に符号がある。符号の byte 長が lenOf と一致する

domainOf :: Form -> Machine
domainOf _ = initMachine

semTotal :: Bool
semTotal = all (\f -> applyForm f (domainOf f) /= Nothing) forms

encTotal :: Bool
encTotal = all (\f -> lenOf f == 4 && length (wordBytes (enc f)) == lenOf f) forms

-- ===== image =====

image :: [Form] -> [Int]
image fs = packImage (map enc fs)

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
    Nothing  -> Built targetName img (observe (mEvents fin))
                       (relWork workBase 8 (mMem fin)) [] False "" certs
    where
      ops = lowerOps boxes
      pro = liSeq baseReg workBase
      (fs, _) = assemble lenOf setBr pro [ covOp al o | o <- ops ]
      img = image fs
      fin = runImage simSteps initMachine fs
      certs =
        [ ( "40.1", "r", hexOf (map enc forms), hexOf (map enc (roundTrip forms)) )
        , ( "51.2", "n", show (length fs), show (length (decodeAll img)) )
        , ( "30.4", "n", hexOf (unpackImage img), hexOf (map enc (decodeAll img)) )
        , ( "51.1", "n", show semTotal, show True )
        , ( "51.3", "n", show encTotal, show True )
        ]

-- 往復に失敗した form はそのまま残るので、certificate の差分でどれが壊れたか読める
roundTrip :: [Form] -> [Form]
roundTrip = map step'
  where step' f = case dec (enc f) of
          Just g  -> g
          Nothing -> f

decodeAll :: [Int] -> [Form]
decodeAll bs = [ f | w <- unpackImage bs, Just f <- [dec w] ]

hexOf :: [Word32] -> String
hexOf ws = concat [ hx (fromIntegral w :: Integer) | w <- ws ]
  where
    hx v = [ dig ((v `div` p) `mod` 16)
           | p <- [268435456, 16777216, 1048576, 65536, 4096, 256, 16, 1] ]
    dig n = case drop (fromIntegral n) "0123456789ABCDEF" of
      (c : _) -> c
      []      -> '?'
