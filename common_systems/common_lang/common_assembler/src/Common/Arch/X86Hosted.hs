{-# LANGUAGE NoImplicitPrelude #-}
module Common.Arch.X86Hosted where

import CounterConstraints
import Common.Core.Pipe
import Common.Core.Dyad
-- form、符号、意味、simulator は 04 章の package から借りる。
-- 名前が重なる五つだけ隠して、この module 側の定義を使う
import Common.Arch.X86 hiding (build, covOp, image, pool, targetName)

-- ===== hosted x86-64 architecture package（docs/common-compiler/arch/18）=====
-- doc: casm.x86h.abi casm.x86h.image casm.x86h.lane
--
-- 04 章の package は freestanding で、multiboot loader が image を受け取る。
-- こちらは仕様 §49 の hosted 側になる。𝓔 = 𝓔_OS であり、interface chamber は
-- 「作業領域を host が渡す」の一つだけになる。
--
-- ISA は同じなので form も符号も意味も 04 章から借りる。変わるのは三点だけ:
--
--   1. 作業領域の基底が固定値でなく RDI から来る          （18 §3.2）
--   2. Ok / Ko が I/O port でなく RAX と RET になる        （18 §4.1）
--   3. image に multiboot header も page table も bootstrap も無い（18 §5）
--
-- 本体の form は rel32 分岐と register 相対の load/store しか使わないので、
-- image は位置独立になる。host は好きな address へ写して呼べる。

targetName :: String
targetName = "x86_64-hosted"

-- ===== abi（18 §3）=====
--
-- System V AMD64 の第一引数 RDI が作業領域の基底になる。だから RDI(7) は
-- landmark pool から外す。R15 は 04 章と同じく基底を持つ

pool :: [Int]
pool = [3, 5, 6, 8, 9, 10, 11, 13, 14]

-- callee-saved のうち pool と基底が触る五本（18 式 3.3）
saved :: [Int]
saved = [3, 5, 13, 14, 15]

argReg :: Int
argReg = 7      -- RDI

retReg :: Int
retReg = 0      -- RAX

-- ===== 報告（18 §4）=====
--
-- 退避した register を逆順に戻してから RET。RAX が 0 で成功、1 で失敗になる

reportCov :: Integer -> [Form]
reportCov code = [FMovRI retReg code] ++ [ FPop r | r <- reverse saved ] ++ [FRet]

covOp :: [(Int, Int)] -> (Int, Op) -> ([Form], [(Int, Int)])
covOp = covOpWith (reportCov 0, reportCov 1)

-- ===== prologue（18 式 5.1）=====
--
-- RSP の 16 byte 整列は要らない。本体はどの関数も呼ばない

prologue :: [Form]
prologue = [ FPush r | r <- saved ] ++ [ FMovRR baseReg argReg ]

-- ===== simulator の配置 =====
--
-- image は位置独立なので、観測に使う address は何でもよい。三つの区間が
-- 重ならないことだけが要る。戻り先は 0 に置く。表に無い address なので
-- runImage の表引きが外れ、そこで実行が終わる

simImage, simWork, simStack, simRet :: Integer
simImage = 0x00100000
simWork  = 0x00200000
simStack = 0x00300000
simRet   = 0

initHosted :: Machine
initHosted = Machine
  { mRegs   = setReg argReg simWork (setReg 4 simStack (replicate 16 0))
  , mMem    = [(simStack, simRet)]
  , mRip    = simImage
  , mFlagZ  = False
  , mFlagLt = False
  , mEvents = []
  -- hosted に UART は無い（18 章 §7.2）。Put を使う program は式 50.3 で止まる
  , mOut    = []
  , mDlab   = False
  }

-- ===== image（18 §5）=====
--
-- Pack は恒等になる。header も padding も無いので式 (30.4) は自明に成り立つ

image :: [Form] -> [Int]
image = concatMap enc

-- ===== build =====

-- 03 §6 の貪欲彩色は landmark の本数で頭を打つ。打ったら 19 §6 の語割付けへ
-- 落ちる。あちらは干渉グラフを組まないので、ワイヤの本数に上限が無い。
-- 代償は語の往復で、image は大きく遅くなる
build :: [(Int, MBox)] -> Built
build boxes
  | usesPut boxes = failedBuild targetName noPutWhy
  | otherwise     = buildOk boxes

buildOk :: [(Int, MBox)] -> Built
buildOk boxes = case allocRegs pool boxes of
  Left _   -> buildSpill boxes
  Right al -> case checkWidth wordWidth ops of
    Just why -> failedBuild targetName why
    Nothing  -> Built targetName img obs (relWork simWork 8 (mMem fin)) [] False "" certs
    where
      ops  = lowerOps boxes
      covs = [ covOp al o | o <- ops ]
      (body, _) = assemble lenOf setBr prologue covs
      img  = image body
      addrTbl = go simImage body
      go _ []       = []
      go a (f : fs) = (a, f) : go (a + toInteger (lenOf f)) fs
      fin = runImage simSteps initHosted addrTbl
      -- 復帰しなかった実行は観測を持たない。歩数切れと報告済みを分ける
      obs | mRip fin == simRet = [ if regAt (mRegs fin) retReg == 0 then 0 else 42 ]
          | otherwise          = []
      certs =
        [ ( "40.1", "r", hexBs (concatMap enc formsL64)
                       , hexBs (concatMap enc (roundTripL64 formsL64)) )
        , ( "51.2", "n", showForms body, showForms (decRun True img) )
        , ( "30.4", "n", hexBs img, hexBs (image body) )
        , ( "51.1", "n", show semTotal, show True )
        , ( "51.3", "n", show encTotal, show True )
        ]

-- ===== 語割付けの覆い（19 §6）=====
--
-- commonc は干渉グラフを組まない。全てのワイヤを語 64+w へ置き、RAX と RCX
-- だけを使う。同じ覆いをこちらでも組めば、二つの compiler の出力を byte 単位で
-- 比べられる（19 式 5.1）。
--
--   λ(w) = 語 64 + w、   disp(w) = 8 (64 + w) = 512 + 8w

dispOf :: Int -> Int
dispOf w = 512 + 8 * w

-- 一様形。33 byte 固定になる。シフト量 0 の局所片も出す。
-- 長さが箱の種類に依らないので、image の配置が一巡で決まる
uniOp :: Int -> Int -> Int -> Int -> Int -> [Form] -> [Form]
uniOp u su v sv w opF =
  [ FLoadD 0 (dispOf u), FShlRI 0 su
  , FLoadD 1 (dispOf v), FShlRI 1 sv ]
  ++ opF
  ++ [ FStoreD 0 (dispOf w) ]

covSpill :: (Int, Op) -> ([Form], [(Int, Int)])
covSpill (_, o) = case o of
  OMat w x            -> ([FMovRI retReg x, FStoreD retReg (dispOf w)], [])
  OAdd w (u, su) (v, sv) -> (uniOp u (mx su) v (mx sv) w [FAddRR 0 1, FNop], [])
  OMul w u v          -> (uniOp u 0 v 0 w [FImulRR 0 1], [])
  -- 第二入力は使わないので第一と同じにする。長さを一様形にそろえる
  ONeg w u            -> (uniOp u 0 u 0 w [FNegR 0, FNop], [])
  -- 語番号を 8 倍して基底へ足し、その番地へ書く
  OStore a u          -> ([ FLoadD 0 (dispOf a), FShlRI 0 3, FAddRR 0 baseReg
                          , FLoadD 1 (dispOf u), FStore 0 1 ], [])
  -- Put は hosted では要らない（18 章 §7.2）。出力は語配列に残り host が読む
  OPut _              -> ([], [])
  OOk                 -> (reportCov 0, [])
  OKo                 -> (reportCov 1, [])
  -- 語番号を 8 倍して基底へ足し、その番地から読む
  OLoad w a           -> ([ FLoadD 0 (dispOf a), FShlRI 0 3, FAddRR 0 baseReg
                          , FLoad 0 0, FStoreD 0 (dispOf w) ], [])
  -- 分岐は閉包の後退辺になる（16 §18）。比較の二本は深度をそろえてから読む
  OEq (u, su) (v, sv) l -> (cmpBr FJe u su v sv, [(l, 5)])
  OLt (u, su) (v, sv) l -> (cmpBr FJl u su v sv, [(l, 5)])
  OJmp l              -> ([FJmp 0], [(l, 0)])
  where
    mx s = if s < 0 then 0 else s
    cmpBr mk u su v sv =
      [ FLoadD 0 (dispOf u), FShlRI 0 (mx su)
      , FLoadD 1 (dispOf v), FShlRI 1 (mx sv)
      , FCmpRR 0 1, mk 0 ]

-- 語割付けの覆いを別名で持つ（§41 の subtarget）。ISA も image 規約も同じで、
-- 違うのは Allocate の λ_A だけになる。commonc と同じ覆いなので、この名前を
-- 選んだときだけ式 (5.1) の byte 一致が取れる（19 §6）
targetNameW :: String
targetNameW = "x86_64-hosted-w"

buildW :: [(Int, MBox)] -> Built
buildW bs = (buildSpill bs) { btName = targetNameW }

buildSpill :: [(Int, MBox)] -> Built
buildSpill boxes = case checkWidth wordWidth ops of
  Just why -> failedBuild targetName why
  Nothing  -> Built targetName img obs (relWork simWork 8 (mMem fin)) [] False "" certs
  where
    ops  = lowerOps boxes
    covs = [ covSpill o | o <- ops ]
    (body, _) = assemble lenOf setBr prologue covs
    img  = concatMap enc body
    addrTbl = go simImage body
    go _ []       = []
    go a (f : fs) = (a, f) : go (a + toInteger (lenOf f)) fs
    fin = runImage simSteps initHosted addrTbl
    obs | mRip fin == simRet = [ if regAt (mRegs fin) retReg == 0 then 0 else 42 ]
        | otherwise          = []
    certs =
      [ ( "51.2", "n", showForms body, showForms (decRun True img) )
      , ( "30.4", "n", hexBs img, hexBs (concatMap enc body) )
      ]

-- 本 subtarget は l64 の表しか使わない（18 式 1.1）
roundTripL64 :: [Form] -> [Form]
roundTripL64 fs = [ rt f | f <- fs ]
  where
    rt f = case dec True (enc f) of
      Just (g, n) | n == lenOf f -> g
      _                          -> f
