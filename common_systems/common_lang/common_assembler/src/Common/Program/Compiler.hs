{-# LANGUAGE NoImplicitPrelude #-}
module Common.Program.Compiler where

import CounterConstraints
import CommonChamber (Mu (..))
import Totality (FsmVerdict (..), decideFsm)
import Common.Lang.NL

-- ===== Common 言語 compiler（docs/common-compiler/program/11）=====
-- doc: casm.prog.sched casm.prog.mem casm.prog.algo
--
-- 縮約行列 M から正準スケジュールを作る。入力は行列の台、出力は命令列である。
--
--   Sched : M ↦ one ; (ext を D(M) の昇順で) ; (acc を supp(M) の順で) ; halt
--
-- chain(T) は T から最大元を順に外して ∅ へ降りる辞書式鎖であり、その逆順は
-- 要素の昇順列を前から一つずつ足していく列に一致する。だから入力側で T を
-- 昇順列として渡せば、bit mask の最大元抽出（＝除算）が要らなくなる。
--
-- SEEN による重複除去が |D(M)| を実現する。鎖が接頭辞を共有するとき ext は一度しか出ない。

-- ===== 作業領域の割付（語番号）=====
--
-- 語の byte 幅は architecture package が持つので、ここには現れない（§32.2）。

wPtr, wOut, wT, wJ, wU, wN :: Int
wPtr = 0     -- SUPP の現在位置
wOut = 1     -- OUT の現在位置
wT   = 2     -- 現在の T
wJ   = 3     -- 内側ループの進み
wU   = 4     -- 現在の u
wN   = 5     -- 現在の n

wSupp, wPow, wSeen, wOutBuf :: Int
wSupp   = 64
wPow    = 128
wSeen   = 144
wOutBuf = 256

-- ===== 入力の行列 =====
--
-- supp(M) = { (u=0, T={0,1}), (u=1, T={0,2}) }
-- 表の書式は  u, n, k_1 … k_n  の繰り返しで、u = −1 が終端になる

suppTable :: [Int]
suppTable = [ 0, 2, 0, 1
            , 1, 2, 0, 2
            , negate 1 ]

powTable :: [Int]
powTable = [1, 2, 4]

-- ===== 期待する正準スケジュール =====
--
-- 命令は一語に詰める。opcode は one = 0、ext = 1、acc = 2、halt = 3。
--
--   ext(b,T,k) ↦ 1000000 + b·10000 + T·100 + k
--   acc(u,T)   ↦ 2000000 + u·10000 + T·100
--
-- 十進の桁で分けるので、shift も mask も要らない。乗算と加算だけで組める。

expectedSchedule :: [Integer]
expectedSchedule =
  [ 0            -- one
  , 1010000      -- ext(b=1, T=0, k=0)      ∅ → {0}
  , 1020101      -- ext(b=2, T=1, k=1)      {0} → {0,1}
  , 2000300      -- acc(u=0, T=3)
  , 1040102      -- ext(b=4, T=1, k=2)      {0} → {0,2}   接頭辞 {0} は再利用
  , 2010500      -- acc(u=1, T=5)
  , 3000000      -- halt
  ]

-- C_sched(M) = |D(M)| + nnz(M)。D(M) = {∅,{0},{0,1},{0,2}}、nnz = 2
schedCost :: Int
schedCost = 4 + 2

-- ===== 停止性（04 §6 の有限状態判定）=====
--
-- 反復は Br の後退参照として持つ（§18 の閉包）。閉包が有限で閉じることは、
-- ループ変数の動きを有限状態系として読めば判定できる。判定は Totality の
-- decideFsm がそのまま行う。assembler 側に停止判定を書き足さない。

-- 内側ループ: j は 0 から一つずつ進み、j = n で外へ出る
innerHalts :: Int -> FsmVerdict
innerHalts n = decideFsm [0 .. n] (\j -> j + 1) [n] 0

-- 外側ループ: SUPP の位置は要素ごとに (2 + n) 語進み、終端の −1 で止まる
outerHalts :: FsmVerdict
outerHalts = decideFsm [0 .. terminator] nextEntry [terminator] 0
  where
    terminator = length suppTable - 1
    nextEntry i = i + 2 + at (i + 1)
    at j = case drop j suppTable of
      (v : _) -> v
      []      -> 0

-- ===== program =====
--
-- 定数はその場で作り直す。長く生かすと landmark が足りなくなる。

compilerLines :: [Line]
compilerLines =
  -- 冪表 POW[p] = 2^p
  concat [ stAt ("p" ++ show i) (wPow + i) v
         | (i, v) <- zip [0 :: Int ..] powTable ]

  -- 入力表 SUPP
  ++ concat [ stAt ("t" ++ show i) (wSupp + i) v
            | (i, v) <- zip [0 :: Int ..] suppTable ]

  -- SEEN[0] = 1。∅ は one が担うので ext を出さない
  ++ stAt "sn" wSeen 1

  -- 走査の初期値と、最初の one
  ++ stAt "q0" wPtr wSupp
  ++ stAt "q1" wOut wOutBuf
  ++ stAt "q2" wOutBuf 0
  ++ stAt "q3" wOut (wOutBuf + 1)

  -- ===== 外側ループ: supp(M) の各要素 =====
  ++ [ lCst  "Louter" wPtr
     , lLoad "p"  "Louter"
     , lLoad "u"  "p"
     , lCst  "m1" (negate 1)
     , lEqBr "u" "m1" "Ldone"          -- 終端なら halt を出しに行く
     , lCst  "e1" 1
     , lAdd  "p1" "p" "e1"
     , lLoad "n"  "p1"                 -- n ← 要素数
     , lAdd  "p2" "p1" "e1"            -- k 列の先頭
     , lCst  "cN" wN,  lStore "cN" "n"
     , lCst  "cU" wU,  lStore "cU" "u"
     , lCst  "z0" 0
     , lCst  "cT" wT,  lStore "cT" "z0"
     , lCst  "cJ" wJ,  lStore "cJ" "z0"
     , lStore "Louter" "p2" ]

  -- ===== 内側ループ: 鎖 ∅ ⊂ {k₁} ⊂ … ⊂ T を登る =====
  ++ [ lCst  "Linner" wJ
     , lLoad "jj" "Linner"
     , lCst  "cN2" wN
     , lLoad "nn" "cN2"
     , lLtBr "jj" "nn" "Lbody"
     , lBr   "Lacc" ]

  ++ [ lCst  "Lbody" wPtr
     , lLoad "pp" "Lbody"
     , lLoad "k"  "pp"                 -- k ← 次の要素
     , lCst  "e2" 1
     , lAdd  "pp2" "pp" "e2"
     , lStore "Lbody" "pp2"            -- 走査位置を進める
     , lAdd  "j2" "jj" "e2"
     , lCst  "cJ2" wJ, lStore "cJ2" "j2"
     , lCst  "cPow" wPow
     , lAdd  "pwk" "cPow" "k"
     , lLoad "bb" "pwk"                -- bb ← POW[k] = 2^k
     , lCst  "cT2" wT
     , lLoad "tt" "cT2"
     -- T ∩ {k} = ∅ なので T ∪ {k} の符号は T + 2^k に等しい
     , lAdd  "t2" "tt" "bb"
     , lStore "cT2" "t2"
     , lCst  "cSn" wSeen
     , lAdd  "sa2" "cSn" "t2"
     , lLoad "sv" "sa2"
     , lCst  "e3" 1
     , lEqBr "sv" "e3" "Lskip"         -- 構成済みなら ext を出さない

     -- ext(b=bb, T=tt, k) = 1000000 + bb·10000 + tt·100 + k
     , lCst  "cE4" 10000
     , lMul  "mA" "bb" "cE4"
     , lCst  "cE6" 1000000
     , lAdd  "sA" "cE6" "mA"
     , lCst  "cH" 100
     , lMul  "mB" "tt" "cH"
     , lAdd  "sB" "sA" "mB"
     , lAdd  "sC" "sB" "k"
     , lCst  "cO" wOut
     , lLoad "oo" "cO"
     , lStore "oo" "sC"
     , lCst  "e4" 1
     , lAdd  "oo2" "oo" "e4"
     , lStore "cO" "oo2"
     , lStore "sa2" "e4"               -- SEEN[T'] ← 1
     , mkLine "Lskip" MBr (\r -> [r "Linner"]) ]

  -- ===== acc を出して外側へ戻る =====
  -- acc(u,T) = 2000000 + u·10000 + T·100
  ++ [ lCst  "Lacc" wU
     , lLoad "uu" "Lacc"
     , lCst  "cT3" wT
     , lLoad "tt2" "cT3"
     , lCst  "cF4" 10000
     , lMul  "mC" "uu" "cF4"
     , lCst  "cF6" 2000000
     , lAdd  "sD" "cF6" "mC"
     , lCst  "cH2" 100
     , lMul  "mD" "tt2" "cH2"
     , lAdd  "sE" "sD" "mD"
     , lCst  "cO2" wOut
     , lLoad "oo3" "cO2"
     , lStore "oo3" "sE"
     , lCst  "e5" 1
     , lAdd  "oo4" "oo3" "e5"
     , lStore "cO2" "oo4"
     , lBr   "Louter" ]

  -- ===== halt を出して終わる =====
  ++ [ lCst  "Ldone" wOut
     , lLoad "oo5" "Ldone"
     , lCst  "hv" 3000000
     , lStore "oo5" "hv"
     , lOk   "Lend" ]

compilerUnit :: Unit
compilerUnit = linesToUnit FMeaning MInf 3 compilerLines

compilerEntry :: Unit
compilerEntry =
  (linesToUnit FEntry MInf 0 []) { uDeps = [uIdent compilerUnit] }

-- 作業領域の OUT 区間から、出力された命令列を読み出す。
-- 表は語番号で来るので、target の語幅に依らない
readSchedule :: [(Integer, Integer)] -> [Integer]
readSchedule work =
  [ at (toInteger wOutBuf + toInteger k)
  | k <- [0 .. length expectedSchedule - 1] ]
  where
    at i = case [ v | (i', v) <- work, i' == i ] of
      (v : _) -> v
      []      -> 0
