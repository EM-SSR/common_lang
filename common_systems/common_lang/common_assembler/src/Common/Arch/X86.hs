{-# LANGUAGE NoImplicitPrelude #-}
module Common.Arch.X86 where

import CounterConstraints
import Common.Core.Pipe
import Common.Core.Dyad

-- ===== x86-64 architecture package（docs/common-compiler/arch/04）=====
-- doc: casm.x86.form casm.x86.enc casm.x86.sem casm.x86.image
--
-- 𝔄_Intel64 = 𝔄_x86-64 ⊕ F_Intel、𝔄_AMD64 = 𝔄_x86-64 ⊕ F_AMD（式 36.1、36.2）。
-- 本 package は基礎 package の subtarget であり、feature refinement は空である。
--
-- decode context は mode を含む（§36）。mode は二つ:
--   p32  multiboot が渡してくる 32 bit protected mode。long mode へ入るまで
--   l64  far jump のあとの 64 bit mode。意味 program の本体はここで走る
--
-- 可変長なので Enc_A は関係である。canonical encoding を各 form に一つ選ぶ。

targetName :: String
targetName = "x86_64"

-- ===== state =====
--
-- Σ = registers × memory × rip × 述語 × events。実行位相は一枚。
-- control register と MSR は本 subtarget の architecture-visible state に入れない。
-- bootstrap の CR/MSR 命令は rip を進めるだけになる（04 章 式 2.2）。
-- 完全 package はこの subtarget の上位として別に登録する。

data Machine = Machine
  { mRegs   :: [Integer]              -- rax..r15（16 本）
  , mMem    :: [(Integer, Integer)]
  , mRip    :: Integer
  , mFlagZ  :: Bool
  , mFlagLt :: Bool
  , mEvents :: [Integer]              -- 報告 port へ出た値を意味へ戻したもの
  , mOut    :: [Int]                  -- UART の送信 port へ出た byte（04 章 §8.2）
  , mDlab   :: Bool                   -- LCR の divisor latch。立つ間 0x3F8 は分周比
  } deriving (Eq, Show)

loadBase :: Integer
loadBase = 0x00100000

wordWidth :: Int
wordWidth = 64

-- 作業領域。identity map（0〜1 GB）の内側で image と重ならない位置
workBase :: Integer
workBase = 0x00200000

initMachine :: Integer -> Machine
initMachine entry = Machine (replicate 16 0) [] entry False False [] [] False

-- ===== instruction 𝓘_J =====

data Form
  -- p32: bootstrap
  = FCli
  | FLgdt !Int            -- 0F 01 15 disp32（絶対 address）
  | FMovEaxI !Int         -- B8 id
  | FMovEcxI !Int         -- B9 id
  | FOrEaxI !Int          -- 0D id
  | FMovToCr !Int         -- 0F 22 /r   cr ← eax
  | FMovFromCr !Int       -- 0F 20 /r   eax ← cr
  | FRdmsr                -- 0F 32
  | FWrmsr                -- 0F 30
  | FLjmp !Int !Int       -- EA off32 sel16
  -- l64: 本体
  | FMovRI !Int !Integer  -- REX.W B8+rd io64
  | FMovRR !Int !Int      -- REX.W 8B /r  mod=11   dst ← src
  | FAddRR !Int !Int      -- REX.W 01 /r  mod=11   dst += src
  | FSubRR !Int !Int      -- REX.W 29 /r
  | FImulRR !Int !Int     -- REX.W 0F AF /r
  | FShlRI !Int !Int      -- REX.W C1 /4 ib
  | FSarRI !Int !Int      -- REX.W C1 /7 ib
  | FCmpRR !Int !Int      -- REX.W 39 /r
  | FJe !Int              -- 0F 84 rel32
  | FJl !Int              -- 0F 8C rel32
  | FJmp !Int             -- E9 rel32
  | FLoad !Int !Int       -- REX.W 8B /r  mod=01 disp8=0   dst ← [addr]
  | FStore !Int !Int      -- REX.W 89 /r  mod=01 disp8=0   [addr] ← src
  | FMovDxI !Int          -- 66 BA iw
  | FMovAlI !Int          -- B0 ib
  | FMovAxI !Int          -- 66 B8 iw
  | FOutB                 -- EE
  | FOutW                 -- 66 EF
  | FInB                  -- EC        al <- in8(dx)
  | FTestAlI !Int         -- A8 ib     ZF <- (al & ib) = 0
  | FHlt                  -- F4
  -- l64: hosted 呼び出し規約（18 章 §1）。REX.B は r >= 8 のときだけ置く
  | FPush !Int            -- 50+r
  | FPop !Int             -- 58+r
  | FRet                  -- C3
  -- 語割付けの覆い（19 §6）。基底 R15 からの disp32 で作業領域を直に指す
  | FLoadD !Int !Int      -- REX.W 8B /r mod=10 disp32   dst <- [r15 + d]
  | FStoreD !Int !Int     -- REX.W 89 /r mod=10 disp32   [r15 + d] <- src
  | FNegR !Int            -- REX.W F7 /3
  | FNop                  -- 90。4 byte の演算枠を埋める
  deriving (Eq, Ord, Show)

-- mode ごとの form 集合。式 (51.1)、(40.1) の検査対象
formsP32 :: [Form]
formsP32 =
  [ FCli, FRdmsr, FWrmsr ]
  ++ [ FLgdt a | a <- [0x107020, 0] ]
  ++ [ FMovEaxI v | v <- [0x104000, 0] ]
  ++ [ FMovEcxI v | v <- [0xC0000080, 1] ]
  ++ [ FOrEaxI v | v <- [0x20, 0x100, 0x80000000] ]
  ++ [ FMovToCr c | c <- [0, 3, 4] ]
  ++ [ FMovFromCr c | c <- [0, 4] ]
  ++ [ FLjmp o 0x08 | o <- [0x10005B, 0] ]

formsL64 :: [Form]
formsL64 =
  [ FMovRI r v | r <- [0, 3, 8, 15], v <- [0, 42, -1, 4294967296] ]
  ++ [ FMovRR d s | d <- [0, 3, 9], s <- [1, 7, 15] ]
  ++ [ FAddRR d s | d <- [0, 3, 9], s <- [1, 7, 15] ]
  ++ [ FSubRR d s | d <- [0, 3, 9], s <- [1, 7, 15] ]
  ++ [ FImulRR d s | d <- [0, 3, 9], s <- [1, 7, 15] ]
  ++ [ FShlRI d n | d <- [0, 3, 11], n <- [1, 11, 63] ]
  ++ [ FSarRI d n | d <- [0, 3, 11], n <- [1, 11, 63] ]
  ++ [ FCmpRR a b | a <- [0, 3, 9], b <- [1, 7, 15] ]
  ++ [ FJe o | o <- [0, 16, -16] ]
  ++ [ FJl o | o <- [0, 16, -16] ]
  ++ [ FJmp o | o <- [0, 16, -16] ]
  ++ [ FLoad d a | d <- [0, 3, 9], a <- [3, 6, 13] ]
  ++ [ FStore a s | a <- [3, 6, 13], s <- [0, 7, 15] ]
  ++ [ FMovDxI v | v <- [0x604, 0xF4, 0x3F8, 0x3FD] ]
  ++ [ FMovAlI v | v <- [0, 20, 1, 3, 0x80] ]
  ++ [ FMovAxI v | v <- [0x2000] ]
  ++ [ FOutB, FOutW, FInB, FHlt ]
  ++ [ FTestAlI v | v <- [0x20, 0x80] ]
  ++ [ FLoadD d v | d <- [0, 1], v <- [0, 512, 65536] ]
  ++ [ FStoreD s v | s <- [0, 1], v <- [0, 512, 65536] ]
  ++ [ FNegR r | r <- [0, 1] ]
  ++ [ FNop ]
  ++ [ FPush r | r <- [0, 3, 5, 13, 15] ]
  ++ [ FPop r | r <- [0, 3, 5, 13, 15] ]
  ++ [ FRet ]

-- ===== encoding =====

-- REX.W 固定。R が reg field、B が rm field と opcode 埋め込み register を伸ばす
rex :: Int -> Int -> Int
rex rg rm = 0x48 .|. shiftL (rg `div` 8) 2 .|. (rm `div` 8)

modRM :: Int -> Int -> Int -> Int
modRM md rg rm = shiftL md 6 .|. shiftL (rg `mod` 8) 3 .|. (rm `mod` 8)

enc :: Form -> [Int]
enc fm = case fm of
  FCli          -> [0xFA]
  FLgdt a       -> [0x0F, 0x01, 0x15] ++ le32 a
  FMovEaxI v    -> [0xB8] ++ le32 v
  FMovEcxI v    -> [0xB9] ++ le32 v
  FOrEaxI v     -> [0x0D] ++ le32 v
  FMovToCr c    -> [0x0F, 0x22, modRM 3 c 0]
  FMovFromCr c  -> [0x0F, 0x20, modRM 3 c 0]
  FRdmsr        -> [0x0F, 0x32]
  FWrmsr        -> [0x0F, 0x30]
  FLjmp o s     -> [0xEA] ++ le32 o ++ le16 s
  FMovRI r v    -> [rex 0 r, 0xB8 + (r `mod` 8)] ++ qwordBytes v
  FMovRR d s    -> [rex d s, 0x8B, modRM 3 d s]
  FAddRR d s    -> [rex s d, 0x01, modRM 3 s d]
  FSubRR d s    -> [rex s d, 0x29, modRM 3 s d]
  FImulRR d s   -> [rex d s, 0x0F, 0xAF, modRM 3 d s]
  FShlRI d n    -> [rex 0 d, 0xC1, modRM 3 4 d, n .&. 0x3F]
  FSarRI d n    -> [rex 0 d, 0xC1, modRM 3 7 d, n .&. 0x3F]
  FCmpRR a b    -> [rex b a, 0x39, modRM 3 b a]
  FJe o         -> [0x0F, 0x84] ++ le32 o
  FJl o         -> [0x0F, 0x8C] ++ le32 o
  FJmp o        -> [0xE9] ++ le32 o
  -- mod=01、disp8=0。mod=00 では rm&7 = 5 が RIP 相対になるので使わない
  FLoad d a     -> [rex d a, 0x8B, modRM 1 d a, 0]
  FStore a s    -> [rex s a, 0x89, modRM 1 s a, 0]
  FMovDxI v     -> [0x66, 0xBA] ++ le16 v
  FMovAlI v     -> [0xB0, v .&. 0xFF]
  FMovAxI v     -> [0x66, 0xB8] ++ le16 v
  FOutB         -> [0xEE]
  FOutW         -> [0x66, 0xEF]
  FInB          -> [0xEC]
  FTestAlI v    -> [0xA8, v .&. 0xFF]
  FHlt          -> [0xF4]
  FPush r       -> [ 0x41 | r >= 8 ] ++ [0x50 + (r `mod` 8)]
  FPop r        -> [ 0x41 | r >= 8 ] ++ [0x58 + (r `mod` 8)]
  FRet          -> [0xC3]
  FLoadD d v    -> [rex d 15, 0x8B, modRM 2 d 15] ++ le32 v
  FStoreD sr v  -> [rex sr 15, 0x89, modRM 2 sr 15] ++ le32 v
  FNegR r       -> [rex 0 r, 0xF7, modRM 3 3 r]
  FNop          -> [0x90]

lenOf :: Form -> Int
lenOf = length . enc

-- ===== decoding =====
--
-- 消費した byte 数も返す（式 3.1）。mode で表を切り替える

dec :: Bool -> [Int] -> Maybe (Form, Int)
dec is64 bs = if is64 then decL64 bs else decP32 bs

decP32 :: [Int] -> Maybe (Form, Int)
decP32 bs = case bs of
  (0xFA : _)                     -> Just (FCli, 1)
  (0x0F : 0x01 : 0x15 : r)       -> Just (FLgdt (rd32 r), 7)
  (0x0F : 0x22 : m : _)          -> Just (FMovToCr (regOf m), 3)
  (0x0F : 0x20 : m : _)          -> Just (FMovFromCr (regOf m), 3)
  (0x0F : 0x32 : _)              -> Just (FRdmsr, 2)
  (0x0F : 0x30 : _)              -> Just (FWrmsr, 2)
  (0xB8 : r)                     -> Just (FMovEaxI (rd32 r), 5)
  (0xB9 : r)                     -> Just (FMovEcxI (rd32 r), 5)
  (0x0D : r)                     -> Just (FOrEaxI (rd32 r), 5)
  (0xEA : r)                     -> Just (FLjmp (rd32 r) (rd16 (drop 4 r)), 7)
  _                              -> Nothing
  where regOf m = shiftR m 3 .&. 7

decL64 :: [Int] -> Maybe (Form, Int)
decL64 bs = case bs of
  (0x66 : 0xBA : r)   -> Just (FMovDxI (rd16 r), 4)
  (0x66 : 0xB8 : r)   -> Just (FMovAxI (rd16 r), 4)
  (0x66 : 0xEF : _)   -> Just (FOutW, 2)
  (0xB0 : v : _)      -> Just (FMovAlI v, 2)
  (0xEE : _)          -> Just (FOutB, 1)
  (0xEC : _)          -> Just (FInB, 1)
  (0xA8 : v : _)      -> Just (FTestAlI v, 2)
  (0xF4 : _)          -> Just (FHlt, 1)
  (0xC3 : _)          -> Just (FRet, 1)
  (0x90 : _)          -> Just (FNop, 1)
  (p : _)
    | p >= 0x50 && p <= 0x57 -> Just (FPush (p - 0x50), 1)
    | p >= 0x58 && p <= 0x5F -> Just (FPop (p - 0x58), 1)
  (0xE9 : r)          -> Just (FJmp (sext32 (rd32 r)), 5)
  (0x0F : 0x84 : r)   -> Just (FJe (sext32 (rd32 r)), 6)
  (0x0F : 0x8C : r)   -> Just (FJl (sext32 (rd32 r)), 6)
  (p : rest)
    | p >= 0x40 && p <= 0x4F -> withRex p rest
  _ -> Nothing
  where
    withRex p rest = case rest of
      (op : more)
        | op >= 0xB8 && op <= 0xBF ->
            Just (FMovRI (bBit p * 8 + (op - 0xB8)) (rdQ more), 10)
      (op : _)
        | op >= 0x50 && op <= 0x57 -> Just (FPush (bBit p * 8 + (op - 0x50)), 2)
        | op >= 0x58 && op <= 0x5F -> Just (FPop (bBit p * 8 + (op - 0x58)), 2)
      (0x8B : m : more)
        | md m == 3 -> Just (FMovRR (rg p m) (rm p m), 3)
        | md m == 2 -> Just (FLoadD (rg p m) (rd32 more), 7)
        | md m == 1 -> Just (FLoad (rg p m) (rm p m), 4 + 0 * length more)
      (0x89 : m : more)
        | md m == 2 -> Just (FStoreD (rg p m) (rd32 more), 7)
        | md m == 1 -> Just (FStore (rm p m) (rg p m), 4)
      (0x01 : m : _) | md m == 3 -> Just (FAddRR (rm p m) (rg p m), 3)
      (0x29 : m : _) | md m == 3 -> Just (FSubRR (rm p m) (rg p m), 3)
      (0x39 : m : _) | md m == 3 -> Just (FCmpRR (rm p m) (rg p m), 3)
      (0x0F : 0xAF : m : _) | md m == 3 -> Just (FImulRR (rg p m) (rm p m), 4)
      (0xF7 : m : _) | md m == 3 && ext m == 3 -> Just (FNegR (rm p m), 3)
      (0xC1 : m : n : _)
        | md m == 3 && ext m == 4 -> Just (FShlRI (rm p m) n, 4)
        | md m == 3 && ext m == 7 -> Just (FSarRI (rm p m) n, 4)
      _ -> Nothing
    md m  = shiftR m 6 .&. 3
    ext m = shiftR m 3 .&. 7
    rBit q = shiftR q 2 .&. 1
    bBit q = q .&. 1
    rg q m = rBit q * 8 + (shiftR m 3 .&. 7)
    rm q m = bBit q * 8 + (m .&. 7)

rd32 :: [Int] -> Int
rd32 r = case r of
  (a : b : c : d : _) -> a + 256 * b + 65536 * c + 16777216 * d
  _                   -> 0

rd16 :: [Int] -> Int
rd16 r = case r of
  (a : b : _) -> a + 256 * b
  _           -> 0

rdQ :: [Int] -> Integer
rdQ r = sum [ toInteger v * shiftL 1 (8 * k) | (k, v) <- zip [0 ..] (take 8 r) ]
      - (if length r >= 8 && nth7 r >= 128 then shiftL 1 64 else 0)
  where nth7 xs = case drop 7 xs of
          (v : _) -> v
          []      -> 0

sext32 :: Int -> Int
sext32 v = if v >= 2147483648 then v - 4294967296 else v

-- ===== memory =====

memPut :: Integer -> Integer -> [(Integer, Integer)] -> [(Integer, Integer)]
memPut a v ms = (a, v) : [ p | p@(a', _) <- ms, a' /= a ]

memAt :: [(Integer, Integer)] -> Integer -> Integer
memAt ms a = case [ v | (a', v) <- ms, a' == a ] of
  (v : _) -> v
  []      -> 0

regAt :: [Integer] -> Int -> Integer
regAt rs r = case drop r rs of
  (v : _) -> v
  []      -> 0

setReg :: Int -> Integer -> [Integer] -> [Integer]
setReg r v rs
  | r < 0 || r > 15 = rs
  | otherwise       = take r rs ++ [v] ++ drop (r + 1) rs

w64 :: Integer -> Integer
w64 v = if h >= 9223372036854775808 then h - 18446744073709551616 else h
  where h = v `mod` 18446744073709551616

-- ===== semantics δ =====
--
-- 報告用の port 書き込みは、意味の側の値（0 = 成功、42 = 失敗）へ戻して
-- event trace に積む。port 番号と生の値は target の interface 規約であって
-- 意味ではない（§32.4）

portAcpi, portDebug :: Integer
portAcpi = 0x604
portDebug = 0x0F4

-- 16550 UART の COM1（04 章 §8.2）。実機でも QEMU でも同じ番地になる
portTx, portIer, portLcr, portLsr :: Integer
portTx  = 0x3F8      -- 送受信データ / 分周比の下位
portIer = 0x3F9      -- 割込み許可 / 分周比の上位
portLcr = 0x3FB      -- 行制御
portLsr = 0x3FD      -- 行状態。bit5 が送信ホールドの空き

applyForm :: Form -> Machine -> Maybe Machine
applyForm fm m = case fm of
  FCli          -> next
  FLgdt _       -> next
  FRdmsr        -> next
  FWrmsr        -> next
  FMovToCr _    -> next
  FMovFromCr _  -> ok 0 0        -- CR は Σ に無いので、読みは宣言値 0 を返す
  FMovEaxI v    -> ok 0 (toInteger v)
  FMovEcxI v    -> ok 1 (toInteger v)
  FOrEaxI v     -> ok 0 (regAt rg 0 .|. toInteger v)
  FLjmp o _     -> Just m { mRip = toInteger o }
  FMovRI r v    -> ok r v
  FMovRR d s    -> ok d (regAt rg s)
  FAddRR d s    -> ok d (regAt rg d + regAt rg s)
  FSubRR d s    -> ok d (regAt rg d - regAt rg s)
  FImulRR d s   -> ok d (regAt rg d * regAt rg s)
  FShlRI d n    -> ok d (shiftL (regAt rg d) n)
  FSarRI d n    -> ok d (shiftR (regAt rg d) n)
  FCmpRR a b    -> let v = regAt rg a - regAt rg b
                   in Just m { mFlagZ = v == 0, mFlagLt = v < 0, mRip = adv }
  FJe o         -> br (mFlagZ m) o
  FJl o         -> br (mFlagLt m) o
  FJmp o        -> Just m { mRip = adv + toInteger o }
  FLoad d a     -> ok d (memAt (mMem m) (regAt rg a))
  FStore a s    -> Just m { mMem = memPut (regAt rg a) (regAt rg s) (mMem m)
                          , mRip = adv }
  FMovDxI v     -> ok 2 (toInteger v)
  FMovAlI v     -> ok 0 (toInteger v)
  FMovAxI v     -> ok 0 (toInteger v)
  FOutB         -> out
  FOutW         -> out
  -- 行状態の読み。送信ホールドは常に空いているとみなす。実機で取りこぼす分は
  -- image 側の待ちループが吸収するので、その待ちは符号に残したままにする
  FInB          -> ok 0 (if regAt rg 2 == portLsr then 0x20 else 0)
  FTestAlI v    -> Just m { mFlagZ = (regAt rg 0 `mod` 256) .&. toInteger v == 0
                          , mRip = adv }
  FHlt          -> Just m { mRip = adv }
  -- stack は 𝓜 の一部になる。RSP は register 4（18 章 §2）
  FPush r       -> let sp = w64 (regAt rg 4 - 8)
                   in Just m { mRegs = setReg 4 sp rg
                             , mMem  = memPut sp (regAt rg r) (mMem m)
                             , mRip  = adv }
  FPop r        -> let sp = regAt rg 4
                   in Just m { mRegs = setReg 4 (w64 (sp + 8))
                                              (setReg r (memAt (mMem m) sp) rg)
                             , mRip  = adv }
  -- 戻り先が image の外なら runImage の表引きが外れて実行が終わる
  FLoadD d v    -> ok d (memAt (mMem m) (regAt rg 15 + toInteger v))
  FStoreD sr v  -> Just m { mMem = memPut (regAt rg 15 + toInteger v) (regAt rg sr) (mMem m)
                          , mRip = adv }
  FNegR r       -> ok r (negate (regAt rg r))
  FNop          -> next
  FRet          -> let sp = regAt rg 4
                   in Just m { mRegs = setReg 4 (w64 (sp + 8)) rg
                             , mRip  = memAt (mMem m) sp }
  where
    rg  = mRegs m
    adv = mRip m + toInteger (lenOf fm)
    next = Just m { mRip = adv }
    ok r v = Just m { mRegs = setReg r (w64 v) rg, mRip = adv }
    br c o = Just m { mRip = if c then adv + toInteger o else adv }
    -- port ごとに行き先が違う。報告は実行を閉じ、UART は byte を積むだけになる
    out =
      let p  = regAt rg 2
          al = regAt rg 0 `mod` 256
      in if p == portAcpi
           then Just m { mEvents = mEvents m ++ [0], mRip = adv }
         else if p == portDebug
           then Just m { mEvents = mEvents m ++ [42], mRip = adv }
         else if p == portLcr
           then Just m { mDlab = al >= 0x80, mRip = adv }
         else if p == portTx && not (mDlab m)
           then Just m { mOut = mOut m ++ [fromInteger al], mRip = adv }
         else next          -- 分周比の書き込みと割込み許可。状態を持たない

-- 可変長なので rip から form を引く表を先に作る
-- simulator の歩数上限。意味 program の箱数に比例して伸びるので、
-- core 意味論の既定（10^6 歩）と同じ桁を取る（14 章 §5）
simSteps :: Int
simSteps = 4000000

runImage :: Int -> Machine -> [(Integer, Form)] -> Machine
runImage steps m tbl
  | steps <= 0             = m
  | not (null (mEvents m)) = m
  | otherwise = case lookup (mRip m) tbl of
      Nothing -> m
      Just f  -> case applyForm f m of
        Just m' -> runImage (steps - 1) m' tbl
        Nothing -> m

-- ===== abi =====
--
-- RSP(4), R12 は ModRM で SIB を意味するので pool から外す。
-- RAX, RCX, RDX は疑似命令の scratch に残す

pool :: [Int]
pool = [3, 5, 6, 7, 8, 9, 10, 11, 13, 14]

scratchA, scratchB :: Int
scratchA = 0    -- RAX
scratchB = 1    -- RCX

baseReg :: Int
baseReg = 15    -- R15。作業領域の基底

wordShift :: Int
wordShift = 3


-- ===== 完全性（式 51.1、51.3、51.4）=====
--
-- 51.1 / 51.4: 全 form に意味が定義されている。適用条件 U_i を満たす状態を
--              form ごとに与え、そこで delta が値を持つことを見る
-- 51.3:        全 form に符号がある。符号の byte 長が lenOf と一致する

domainOf :: Form -> Machine
domainOf _ = initMachine loadBase

semTotal :: Bool
semTotal = all (\f -> applyForm f (domainOf f) /= Nothing) allForms

encTotal :: Bool
encTotal = all (\f -> lenOf f > 0 && length (enc f) == lenOf f) allForms

-- ===== image layout（04 章 §5）=====

hdrLen, bootOff, pml4Off, pdptOff, pdOff, gdtOff, gdtrOff, imgLen :: Int
hdrLen  = 32
bootOff = 32
pml4Off = 0x40000
pdptOff = 0x41000
pdOff   = 0x42000
gdtOff  = 0x43000
gdtrOff = 0x43020
imgLen  = 0x43030

mbMagic, mbFlags, mbChecksum :: Int
mbMagic    = 0x1BADB002
mbFlags    = 0x00010000          -- bit 16: address field が有効
mbChecksum = 0xE4514FFE          -- magic + flags + checksum ≡ 0 (mod 2^32)

-- ===== atlas =====

-- 報告の実現だけが subtarget ごとに変わる（04 章 §4 は I/O port、18 章 §4 は返り値）。
-- 残りの箱の覆いは共通なので、報告の form 列を引数に取る
covOpWith :: ([Form], [Form]) -> [(Int, Int)] -> (Int, Op) -> ([Form], [(Int, Int)])
covOpWith (okCov, koCov) al (_, o) = case o of
  OMat w x     -> ([FMovRI (rg w) x], [])
  OMul w u v   -> ([FMovRR scratchA (rg u), FImulRR scratchA (rg v)
                   , FMovRR (rg w) scratchA], [])
  ONeg w u     -> ([FMovRI scratchA 0, FSubRR scratchA (rg u)
                   , FMovRR (rg w) scratchA], [])
  OLoad w i    -> (addrOf i ++ [FLoad (rg w) scratchA], [])
  OStore i u   -> (addrOf i ++ [FStore scratchA (rg u)], [])
  OJmp l       -> ([FJmp 0], [(l, 0)])
  OAdd w u v   ->
    let fu = intoScratch scratchA u
        fv = intoScratch scratchB v
    in (fu ++ fv ++ [FMovRR (rg w) scratchA, FAddRR (rg w) scratchB], [])
  OEq u v l    -> cmp FJe u v l
  OLt u v l    -> cmp FJl u v l
  OPut u       -> (putCov (rg u), [])
  OOk          -> (okCov, [])
  OKo          -> (koCov, [])
  where
    rg = lookUpA al
    addrOf i = [ FMovRR scratchA (rg i), FShlRI scratchA wordShift
               , FAddRR scratchA baseReg ]
    -- 加算と比較は破壊的なので、必ず scratch へ写してから使う
    intoScratch sc (w, s)
      | s <= 0    = [FMovRR sc (rg w)]
      | otherwise = [FMovRR sc (rg w), FShlRI sc s]
    cmp mk u v l =
      let fu = intoScratch scratchA u
          fv = intoScratch scratchB v
          n = length fu + length fv
      in (fu ++ fv ++ [FCmpRR scratchA scratchB, mk 0], [(l, n + 1)])

-- UART の初期化（04 章 式 8.4）。分周比 1 で 115200 baud、LCR = 0x03 で 8N1。
-- Put を使う program の本体の先頭にだけ置く。使わない image の byte は動かない
uartInit :: [Form]
uartInit =
  [ FMovDxI 0x3F9, FMovAlI 0x00, FOutB       -- 割込みを止める
  , FMovDxI 0x3FB, FMovAlI 0x80, FOutB       -- DLAB を立てる
  , FMovDxI 0x3F8, FMovAlI 0x01, FOutB       -- 分周比 下位 = 1
  , FMovDxI 0x3F9, FMovAlI 0x00, FOutB       -- 分周比 上位 = 0
  , FMovDxI 0x3FB, FMovAlI 0x03, FOutB ]     -- DLAB を下ろし 8N1

-- Put の局所片（04 章 式 8.5）。送信ホールドが空くまで待ってから書く。
-- 待ちの後退分岐は覆いの中で閉じるので label を取らない。変位は
--   -(len FInB + len FTestAlI + len FJe) = -(1 + 2 + 6) = -9
putCov :: Int -> [Form]
putCov r =
  [ FMovDxI 0x3FD
  , FInB, FTestAlI 0x20, FJe (negate 9)
  , FMovRR scratchA r, FMovDxI 0x3F8, FOutB ]

-- 報告のあとは HLT で止め、さらに自己参照分岐で閉じる（§18）
reportOk, reportKo :: [Form]
reportOk = [FMovDxI 0x604, FMovAxI 0x2000, FOutW, FHlt, FJmp (negate 5)]
reportKo = [FMovDxI 0x0F4, FMovAlI 20, FOutB, FHlt, FJmp (negate 5)]

covOp :: [(Int, Int)] -> (Int, Op) -> ([Form], [(Int, Int)])
covOp = covOpWith (reportOk, reportKo)

setBr :: Form -> Int -> Form
setBr f d = case f of
  FJe _  -> FJe (d - lenOf f)
  FJl _  -> FJl (d - lenOf f)
  FJmp _ -> FJmp (d - lenOf f)
  other  -> other

-- ===== bootstrap（04 章 式 6.1）=====
--
-- 全 form が固定長なので、長さは第一パスで確定する。
-- entry の直後に置き、末尾の far jump で 64 bit の本体へ渡す

bootstrap :: Int -> [Form]
bootstrap bodyOff =
  [ FCli
  , FLgdt (fromIntegral loadBase + gdtrOff)
  , FMovEaxI (fromIntegral loadBase + pml4Off), FMovToCr 3
  , FMovFromCr 4, FOrEaxI 0x20, FMovToCr 4              -- CR4.PAE
  , FMovEcxI 0xC0000080, FRdmsr, FOrEaxI 0x100, FWrmsr  -- EFER.LME
  , FMovFromCr 0, FOrEaxI 0x80000000, FMovToCr 0        -- CR0.PG
  , FLjmp bodyOff 0x08 ]

bootLen :: Int
bootLen = sum (map lenOf (bootstrap 0))

-- ===== image =====

multibootHeader :: [Int]
multibootHeader =
  le32 mbMagic ++ le32 mbFlags ++ le32 mbChecksum
  ++ le32 (fromIntegral loadBase)          -- header_addr
  ++ le32 (fromIntegral loadBase)          -- load_addr
  ++ le32 0                                -- load_end_addr: ファイル全体
  ++ le32 0                                -- bss_end_addr
  ++ le32 (fromIntegral loadBase + bootOff)

-- identity map（2 MB page で 0〜1 GB）。bit0 present、bit1 writable、bit7 page size
tablePml4, tablePdpt, tablePd :: [Int]
tablePml4 = qwordBytes (loadBase + toInteger pdptOff + 3) ++ replicate (4096 - 8) 0
tablePdpt = qwordBytes (loadBase + toInteger pdOff + 3) ++ replicate (4096 - 8) 0
tablePd   = concat [ qwordBytes (toInteger k * 2097152 + 0x83) | k <- [0 .. 511 :: Int] ]

-- null / 64 bit code（L=1）/ data
gdt :: [Int]
gdt = [0, 0, 0, 0, 0, 0, 0, 0]
   ++ [0, 0, 0, 0, 0, 0x9A, 0x20, 0]
   ++ [0, 0, 0, 0, 0, 0x92, 0x00, 0]

gdtr :: [Int]
gdtr = le16 23 ++ le32 (fromIntegral loadBase + gdtOff)

padTo :: Int -> [Int] -> [Int]
padTo n bs = bs ++ replicate (n - length bs) 0

image :: [Form] -> [Form] -> [Int]
image boot body =
  padTo imgLen
    ( padTo pml4Off (multibootHeader ++ concatMap enc boot ++ concatMap enc body)
      ++ tablePml4 ++ tablePdpt ++ tablePd
      ++ padTo (gdtrOff - gdtOff) gdt ++ gdtr )

-- ===== build =====

build :: [(Int, MBox)] -> Built
build boxes = case allocRegs pool boxes of
  Left why -> failedBuild targetName why
  Right al -> case checkWidth wordWidth ops of
    Just why -> failedBuild targetName why
    Nothing
      | codeEnd > pml4Off -> failedBuild targetName "code overruns the table area"
      | otherwise -> Built targetName img (mEvents fin)
                             (relWork workBase 8 (mMem fin)) (mOut fin) False "" certs
    where
      ops  = lowerOps boxes
      covs = [ covOp al o | o <- ops ]
      bodyOff = fromIntegral loadBase + bootOff + bootLen
      boot = bootstrap bodyOff
      -- 本体は image 上の bootOff + bootLen から始まる。assemble の offset は
      -- 本体の先頭を 0 とするので、絶対 address へ直すのは表を作るときだけ
      -- UART は本体の先頭で開く。bootstrap は 32 bit mode の表しか復号しないので、
      -- 初期化を p32 側へ置くと式 51.2 の読み返しが割れる
      pro = [FMovRI baseReg workBase] ++ (if usesPut boxes then uartInit else [])
      (body, _) = assemble lenOf setBr pro covs
      codeEnd = bootOff + bootLen + sum (map lenOf body)
      img = image boot body
      -- rip → form の表。bootstrap と本体を連結した順に byte を数える
      addrTbl = go (loadBase + toInteger bootOff) (boot ++ body)
      go _ []       = []
      go a (f : fs) = (a, f) : go (a + toInteger (lenOf f)) fs
      fin = runImage simSteps (initMachine (loadBase + toInteger bootOff)) addrTbl
      certs =
        [ ( "40.1", "r", hexBs (concatMap enc allForms)
                       , hexBs (concatMap enc (roundTrip allForms)) )
        , ( "51.2", "n", showForms (boot ++ body)
                       , showForms (decodeRegion boot body) )
        , ( "30.4", "n", hexBs img, hexBs (padTo imgLen img) )
        , ( "5.1",  "n", show (mbMagic + mbFlags + mbChecksum), show (shiftL (1 :: Int) 32) )
        , ( "51.1", "n", show semTotal, show True )
        , ( "51.3", "n", show encTotal, show True )
        ]

allForms :: [Form]
allForms = formsP32 ++ formsL64

-- p32 の form は p32 の表で、l64 の form は l64 の表で往復させる
roundTrip :: [Form] -> [Form]
roundTrip fs = [ rt (isL64 f) f | f <- fs ]
  where
    isL64 f = elem f formsL64
    rt m f = case dec m (enc f) of
      Just (g, n) | n == lenOf f -> g
      _                          -> f

-- code 区間だけを decode する。data 区間は image rule に属する（03 章 §4）
decodeRegion :: [Form] -> [Form] -> [Form]
decodeRegion boot body =
  decRun False (concatMap enc boot) ++ decRun True (concatMap enc body)

decRun :: Bool -> [Int] -> [Form]
decRun _ [] = []
decRun m bs = case dec m bs of
  Just (f, n) | n > 0 -> f : decRun m (drop n bs)
  _                   -> []

showForms :: [Form] -> String
showForms fs = concat [ show f | f <- fs ]

hexBs :: [Int] -> String
hexBs bs = concat [ [dig (b `div` 16), dig (b `mod` 16)] | b <- bs ]
  where dig n = case drop n "0123456789ABCDEF" of
          (c : _) -> c
          []      -> '?'
