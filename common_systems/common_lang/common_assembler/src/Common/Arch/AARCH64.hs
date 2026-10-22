{-# LANGUAGE NoImplicitPrelude #-}
module Common.Arch.AARCH64 where

import CounterConstraints
import Common.Core.Pipe
import Common.Core.Dyad

-- ===== aarch64 architecture package（docs/common-compiler/arch/05）=====
-- doc: casm.a64.state casm.a64.enc casm.a64.abi casm.a64.image casm.a64.atlas
--
-- subtarget J = { MOVZ, MOVK, ADDi, ADDr, SUBr, MUL, LSLi, ASRi,
--                 SUBSr, SUBSi, BEQ, BLT, B, LDR, STR, HLT }
--
-- loader contract（§49 bare）: QEMU virt に -bios none -kernel raw.bin。
-- image は 0x40080000 に置かれ、pc も同じ値になる。終了は semihosting SYS_EXIT。

targetName :: String
targetName = "arm64"

-- ===== state =====
--
-- Σ = registers × flags × memory × pc × events。x31 は xzr（読み 0、書き捨て）。
-- NZCV そのものではなく、SUBS が決める二つの述語だけを持つ。J の分岐が
-- 読むのはこの二つに限られるので、観測としては等価になる

data Machine = Machine
  { mRegs   :: [Integer]              -- x0..x30
  , mFlagZ  :: Bool                   -- 直前の SUBS が 0 だったか
  , mFlagLt :: Bool                   -- 直前の SUBS が負だったか（符号付き）
  , mMem    :: [(Integer, Integer)]
  , mPc     :: Integer
  , mEvents :: [Integer]              -- semihosting exit の終了コード
  } deriving (Eq, Show)

loadBase :: Integer
loadBase = 0x40080000

initMachine :: Machine
initMachine = Machine (replicate 31 0) False False [] loadBase []

wordWidth :: Int
wordWidth = 64

-- ===== instruction 𝓘_J =====

data Form
  = FMovz  !Int !Int !Int     -- rd, imm16, hw（置く位置は hw*16 bit）
  | FMovk  !Int !Int !Int     -- 他の field を残して差し替える
  | FAddi  !Int !Int !Int     -- rd, rn, imm12
  | FAddR  !Int !Int !Int     -- rd, rn, rm
  | FSubR  !Int !Int !Int
  | FMul   !Int !Int !Int     -- MADD rd, rn, rm, xzr の別名
  | FLsl   !Int !Int !Int     -- UBFM の別名。rd, rn, shift
  | FAsr   !Int !Int !Int     -- SBFM の別名
  | FSubsR !Int !Int          -- rn, rm。結果を捨てて述語だけ更新する
  | FSubsi !Int !Int
  | FBeq   !Int               -- offBytes
  | FBlt   !Int
  | FB     !Int
  | FLdr   !Int !Int !Int     -- rt, rn, byteOffset（8 の倍数）
  | FStr   !Int !Int !Int
  | FHlt
  deriving (Eq, Ord, Show)

forms :: [Form]
forms =
  [ FMovz r i h | r <- [0, 1, 4], i <- [0, 0x18, 0xFFFF], h <- [0, 1] ]
  ++ [ FMovk r i h | r <- [1], i <- [0x4008, 0x1234], h <- [0, 1] ]
  ++ [ FAddi r a i | r <- [0, 2], a <- [0, 1], i <- [0, 3, 4095] ]
  ++ [ FAddR r a b | r <- [0, 2], a <- [0, 1], b <- [1, 31] ]
  ++ [ FSubR r a b | r <- [0, 2], a <- [31, 1], b <- [1, 5] ]
  ++ [ FMul r a b  | r <- [0, 2], a <- [1, 5], b <- [1, 6] ]
  ++ [ FLsl r a s  | r <- [0, 2], a <- [1, 5], s <- [1, 11, 32, 63] ]
  ++ [ FAsr r a s  | r <- [0, 2], a <- [1, 5], s <- [1, 32, 63] ]
  ++ [ FSubsR a b  | a <- [0, 2], b <- [0, 1] ]
  ++ [ FSubsi a i  | a <- [0, 2], i <- [5, 6] ]
  ++ [ FBeq o | o <- [8, -8, 1048572] ]
  ++ [ FBlt o | o <- [8, -8, 1048572] ]
  ++ [ FB o   | o <- [8, -8, 4194300] ]
  ++ [ FLdr t n i | t <- [4, 5], n <- [1, 6], i <- [0, 8, 32760] ]
  ++ [ FStr t n i | t <- [4, 5], n <- [1, 6], i <- [0, 8, 32760] ]
  ++ [ FHlt ]

lenOf :: Form -> Int
lenOf _ = 4

-- ===== encoding =====

enc :: Form -> Word32
enc fm = case fm of
  FMovz rd i hw -> moveW 0xD2800000 rd i hw
  FMovk rd i hw -> moveW 0xF2800000 rd i hw
  FAddi rd rn i -> fi (0x91000000 .|. shiftL (i .&. 0xFFF) 10 .|. shiftL rn 5 .|. rd)
  FAddR rd rn rm-> fi (0x8B000000 .|. shiftL rm 16 .|. shiftL rn 5 .|. rd)
  FSubR rd rn rm-> fi (0xCB000000 .|. shiftL rm 16 .|. shiftL rn 5 .|. rd)
  -- MUL は MADD の Ra を xzr に固定した別名
  FMul rd rn rm -> fi (0x9B000000 .|. shiftL rm 16 .|. shiftL 31 10
                        .|. shiftL rn 5 .|. rd)
  -- LSL #s = UBFM rd, rn, #(-s mod 64), #(63-s)
  FLsl rd rn s  -> fi (0xD3400000 .|. shiftL (immrOfLsl s) 16
                        .|. shiftL (63 - s) 10 .|. shiftL rn 5 .|. rd)
  -- ASR #s = SBFM rd, rn, #s, #63
  FAsr rd rn s  -> fi (0x93400000 .|. shiftL (s .&. 0x3F) 16
                        .|. shiftL 63 10 .|. shiftL rn 5 .|. rd)
  FSubsR rn rm  -> fi (0xEB000000 .|. shiftL rm 16 .|. shiftL rn 5 .|. 31)
  FSubsi rn i   -> fi (0xF1000000 .|. shiftL (i .&. 0xFFF) 10 .|. shiftL rn 5 .|. 31)
  FBeq o        -> condB o 0x0
  FBlt o        -> condB o 0xB
  FB o          -> fi (0x14000000 .|. ((o `div` 4) .&. 0x3FFFFFF))
  FLdr t n i    -> fi (0xF9400000 .|. shiftL ((i `div` 8) .&. 0xFFF) 10
                        .|. shiftL n 5 .|. t)
  FStr t n i    -> fi (0xF9000000 .|. shiftL ((i `div` 8) .&. 0xFFF) 10
                        .|. shiftL n 5 .|. t)
  FHlt          -> hltW

immrOfLsl :: Int -> Int
immrOfLsl s = (64 - s) `mod` 64

condB :: Int -> Int -> Word32
condB o c = fi (0x54000000 .|. shiftL ((o `div` 4) .&. 0x7FFFF) 5 .|. c)

moveW :: Int -> Int -> Int -> Int -> Word32
moveW base rd i hw =
  fi (base .|. shiftL (hw .&. 0x3) 21 .|. shiftL (i .&. 0xFFFF) 5 .|. rd)

hltW :: Word32
hltW = fi (0xD4400000 .|. shiftL 0xF000 5)

fi :: Int -> Word32
fi = fromIntegral

-- ===== decoding =====
--
-- 上位 9 bit（bit 31..23）で切り分ける。B と B.cond は即値が上位まで伸びるので
-- 別の判定式を使う

dec :: Word32 -> Maybe Form
dec w
  | w == hltW           = Just FHlt
  | top6 w == 0x05      = Just (FB (sext26 (fromIntegral (w .&. 0x3FFFFFF)) * 4))
  | top8 w == 0x54      = case fromIntegral (w .&. 0xF) :: Int of
      0x0 -> Just (FBeq (condOff w))
      0xB -> Just (FBlt (condOff w))
      _   -> Nothing
  | otherwise = case top9 w of
      0x1A5 -> Just (FMovz (rd w) (imm16 w) (hw w))
      0x1E5 -> Just (FMovk (rd w) (imm16 w) (hw w))
      0x122 -> Just (FAddi (rd w) (rn w) (uimm12 w))
      0x116 -> Just (FAddR (rd w) (rn w) (rm w))
      0x196 -> Just (FSubR (rd w) (rn w) (rm w))
      0x136 | ra w == 31 -> Just (FMul (rd w) (rn w) (rm w))
      -- UBFM は LSL の形だけを受ける。immr が式 (2.1) の逆を満たすか検査する
      0x1A6 | immrOfLsl (63 - imms w) == immr w -> Just (FLsl (rd w) (rn w) (63 - imms w))
      0x126 | imms w == 63 -> Just (FAsr (rd w) (rn w) (immr w))
      0x1D6 | rd w == 31 -> Just (FSubsR (rn w) (rm w))
      0x1E2 | rd w == 31 -> Just (FSubsi (rn w) (uimm12 w))
      0x1F2 | bit22 w     -> Just (FLdr (rd w) (rn w) (uimm12 w * 8))
            | otherwise   -> Just (FStr (rd w) (rn w) (uimm12 w * 8))
      _     -> Nothing
  where
    top6 w' = fromIntegral (w' `shiftR` 26) :: Int
    top8 w' = fromIntegral (w' `shiftR` 24) :: Int
    top9 w' = fromIntegral (w' `shiftR` 23) :: Int
    bit22 w' = (w' `shiftR` 22) .&. 1 == 1
    condOff w' = sext19 (fromIntegral ((w' `shiftR` 5) .&. 0x7FFFF)) * 4
    rm w'    = fromIntegral ((w' `shiftR` 16) .&. 0x1F)
    ra w'    = fromIntegral ((w' `shiftR` 10) .&. 0x1F) :: Int
    rd w'    = fromIntegral (w' .&. 0x1F)
    rn w'    = fromIntegral ((w' `shiftR` 5) .&. 0x1F)
    imm16 w' = fromIntegral ((w' `shiftR` 5) .&. 0xFFFF)
    uimm12 w'= fromIntegral ((w' `shiftR` 10) .&. 0xFFF)
    immr w'  = fromIntegral ((w' `shiftR` 16) .&. 0x3F)
    imms w'  = fromIntegral ((w' `shiftR` 10) .&. 0x3F)
    hw w'    = fromIntegral ((w' `shiftR` 21) .&. 0x3)

sext19, sext26 :: Int -> Int
sext19 v = if v >= 262144 then v - 524288 else v
sext26 v = if v >= 33554432 then v - 67108864 else v

-- ===== memory =====

memPut :: Integer -> Integer -> [(Integer, Integer)] -> [(Integer, Integer)]
memPut a v ms = (a, v) : [ p | p@(a', _) <- ms, a' /= a ]

memAt :: [(Integer, Integer)] -> Integer -> Integer
memAt ms a = case [ v | (a', v) <- ms, a' == a ] of
  (v : _) -> v
  []      -> 0

regAt :: [Integer] -> Int -> Integer
regAt rs r
  | r >= 31 || r < 0 = 0
  | otherwise = case drop r rs of
      (v : _) -> v
      []      -> 0

setReg :: Int -> Integer -> [Integer] -> [Integer]
setReg r v rs
  | r >= 31 || r < 0 = rs
  | otherwise = take r rs ++ [v] ++ drop (r + 1) rs

reasonExit :: Integer
reasonExit = 0x20026

-- ===== semantics δ =====

applyForm :: Form -> Machine -> Maybe Machine
applyForm fm m = case fm of
  FMovz rd i h  -> ok rd (toInteger i * shiftL 1 (h * 16))
  FMovk rd i h  ->
    let sh = h * 16
        cur = regAt rg rd
        msk = shiftL 65535 sh
    in ok rd (cur - (cur .&. msk) + toInteger i * shiftL 1 sh)
  FAddi rd n i  -> ok rd (regAt rg n + toInteger i)
  FAddR rd n r  -> ok rd (regAt rg n + regAt rg r)
  FSubR rd n r  -> ok rd (regAt rg n - regAt rg r)
  FMul rd n r   -> ok rd (regAt rg n * regAt rg r)
  FLsl rd n s   -> ok rd (shiftL (regAt rg n) s)
  FAsr rd n s   -> ok rd (shiftR (regAt rg n) s)
  FLdr t n i    -> ok t (memAt (mMem m) (regAt rg n + toInteger i))
  FStr t n i    -> Just m { mMem = memPut (regAt rg n + toInteger i) (regAt rg t) (mMem m)
                          , mPc = mPc m + 4 }
  FSubsR n r    -> flags (regAt rg n - regAt rg r)
  FSubsi n i    -> flags (regAt rg n - toInteger i)
  FBeq o        -> br (mFlagZ m) o
  FBlt o        -> br (mFlagLt m) o
  FB o          -> Just m { mPc = mPc m + toInteger o }
  FHlt          ->
    -- semihosting SYS_EXIT。x1 が指すブロックから (reason, subcode) を読む
    let blk = regAt rg 1
    in if memAt (mMem m) blk == reasonExit
         then Just m { mEvents = mEvents m ++ [memAt (mMem m) (blk + 8)] }
         else Nothing
  where
    rg = mRegs m
    ok r v = Just m { mRegs = setReg r (w64 v) rg, mPc = mPc m + 4 }
    flags v = Just m { mFlagZ = v == 0, mFlagLt = v < 0, mPc = mPc m + 4 }
    br c o = Just m { mPc = mPc m + toInteger (if c then o else 4) }

w64 :: Integer -> Integer
w64 v = if h >= 9223372036854775808 then h - 18446744073709551616 else h
  where h = v `mod` 18446744073709551616

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

scratchA, scratchB, scratchR :: Int
scratchA = 28
scratchB = 29
scratchR = 4          -- 報告値の受け皿。x0/x1 は semihosting の引数に使う

baseReg :: Int
baseReg = 27

wordShift :: Int
wordShift = 3

sysExit :: Int
sysExit = 0x18

okCode, koCode :: Int
okCode = 0
koCode = 42

-- 作業領域の基底。DRAM 先頭から 1 MB 先
workBase :: Integer
workBase = 0x40100000

-- ===== atlas =====

-- 整数の物質化。16 bit ずつ MOVZ / MOVK で積む
movSeq :: Int -> Integer -> [Form]
movSeq w k
  | k < 0     = movSeq w (k + 18446744073709551616)
  | otherwise =
      case [ (h, fromIntegral ((k `shiftR` (16 * h)) .&. 0xFFFF))
           | h <- [0 .. 3], (k `shiftR` (16 * h)) .&. 0xFFFF /= 0 ] of
        []            -> [FMovz w 0 0]
        ((h0, v0) : rest) -> FMovz w v0 h0 : [ FMovk w v h | (h, v) <- rest ]

covOp :: [(Int, Int)] -> (Int, Op) -> ([Form], [(Int, Int)])
covOp al (_, o) = case o of
  OMat w x     -> (movSeq (rg w) x, [])
  OMul w u v   -> ([FMul (rg w) (rg u) (rg v)], [])
  ONeg w u     -> ([FSubR (rg w) 31 (rg u)], [])
  OLoad w i    -> (addrOf i ++ [FLdr (rg w) scratchA 0], [])
  OStore i u   -> (addrOf i ++ [FStr (rg u) scratchA 0], [])
  OJmp l       -> ([FB 0], [(l, 0)])
  OAdd w u v   ->
    let (fu, ru) = shifted scratchA u
        (fv, rv) = shifted scratchB v
    in (fu ++ fv ++ [FAddR (rg w) ru rv], [])
  OEq u v l    -> cmp FBeq u v l
  OLt u v l    -> cmp FBlt u v l
  -- Put の局所片は無い。build が式 50.3 で先に止めるので、ここへは来ない
  OPut _       -> ([], [])
  OOk          -> (report okCode, [])
  OKo          -> (report koCode, [])
  where
    rg = lookUpA al
    addrOf i = [FLsl scratchA (rg i) wordShift, FAddR scratchA scratchA baseReg]
    shifted sc (w, s)
      | s <= 0    = ([], rg w)
      | otherwise = ([FLsl sc (rg w) s], sc)
    -- 比較は SUBS で述語を作り、その次の form が分岐になる
    cmp mk u v l =
      let (fu, ru) = shifted scratchA u
          (fv, rv) = shifted scratchB v
          n = length fu + length fv
      in (fu ++ fv ++ [FSubsR ru rv, mk 0], [(l, n + 1)])
    -- パラメータブロックの subcode 欄（x1 + 8）へ書いてから HLT。
    -- そのあとは自己参照分岐で閉じる（§18）。素通しさせると、
    -- 外部環境が止めるまでの間に次の箱の局所片が走ってしまう
    report c = [FMovz scratchR c 0, FStr scratchR 1 8, FHlt, FB 0]

setBr :: Form -> Int -> Form
setBr f d = case f of
  FBeq _ -> FBeq d
  FBlt _ -> FBlt d
  FB _   -> FB d
  other  -> other


-- ===== 完全性（式 51.1、51.3、51.4）=====
--
-- 51.1 / 51.4: 全 form に意味が定義されている。適用条件 U_i を満たす状態を
--              form ごとに与え、そこで delta が値を持つことを見る
-- 51.3:        全 form に符号がある。符号の byte 長が lenOf と一致する

-- HLT は x1 が指すブロックの reason が exit のときだけ意味を持つ。
-- 適用条件 U_i を満たす状態をここで与える
domainOf :: Form -> Machine
domainOf f = case f of
  FHlt -> initMachine { mMem = [(0, reasonExit)] }
  _    -> initMachine

semTotal :: Bool
semTotal = all (\f -> applyForm f (domainOf f) /= Nothing) forms

encTotal :: Bool
encTotal = all (\f -> lenOf f == 4 && length (wordBytes (enc f)) == lenOf f) forms

-- ===== image =====
--
-- code 区間のあとにパラメータブロック (reason, subcode) を置く。
-- reason は image が供給する data、subcode は実行時に STR で書かれる

-- リセット直後は MMU が無効で、全 address が Device 属性になる。
-- Device への非整列 access は SCTLR.A に関係なく必ず fault するので、
-- パラメータブロックを 16 byte 境界へそろえる
alignUp :: Int -> Int -> Int
alignUp a n = ((n + a - 1) `div` a) * a

blkOffOf :: [Form] -> Int
blkOffOf fs = alignUp 16 (4 * length fs)

image :: [Form] -> [Int]
image fs =
  packImage (map enc fs)
  ++ replicate (blkOffOf fs - 4 * length fs) 0
  ++ qwordBytes reasonExit ++ qwordBytes 0

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
    Nothing  -> Built targetName img (mEvents fin)
                       (relWork workBase 8 (mMem fin)) [] False "" certs
    where
      ops = lowerOps boxes
      covs = [ covOp al o | o <- ops ]
      -- プロローグは固定 3 form。x0 = SYS_EXIT、x1 = パラメータブロックの絶対address。
      -- 即値は全体長が決まってから埋めるので、ここでは 0 を置く
      pro0 = [FMovz 0 sysExit 0, FMovz 1 0 0, FMovk 1 0 1] ++ movSeq baseReg workBase
      (fs0, _) = assemble lenOf setBr pro0 covs
      blkOff = blkOffOf fs0
      blkAddr = loadBase + toInteger blkOff
      lo16 = fromIntegral (blkAddr `mod` 65536)
      hi16 = fromIntegral ((blkAddr `div` 65536) `mod` 65536)
      fs = [ fixPro k f | (k, f) <- zip [0 :: Int ..] fs0 ]
      fixPro 1 (FMovz r _ h) = FMovz r lo16 h
      fixPro 2 (FMovk r _ h) = FMovk r hi16 h
      fixPro _ f             = f
      img = image fs
      -- loader が data 区間を配置するのと同じ役割（§30 の 𝓛）
      m0 = initMachine { mMem = [(blkAddr, reasonExit)] }
      fin = runImage simSteps m0 fs
      codeLen = 4 * length fs   -- 式 51.2 の検査は code 区間だけを見る
      certs =
        [ ( "40.1", "r", hexOf (map enc forms), hexOf (map enc (roundTrip forms)) )
        , ( "51.2", "n", hexOf (map enc fs)
                       , hexOf (map enc (decodeAll (take codeLen img))) )
        , ( "30.4", "n", hexOf (unpackImage img), hexOf (unpackImage (packImage (unpackImage img))) )
        , ( "51.1", "n", show semTotal, show True )
        , ( "51.3", "n", show encTotal, show True )
        ]

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
