{-# LANGUAGE NoImplicitPrelude #-}
module Common.Program.Arith where

import CounterConstraints
import CommonChamber (Mu (..))
import Common.Lang.NL

-- ===== 分数を含む算術の意味 program（docs/common-compiler/program/11）=====
-- doc: casm.prog.arith casm.dyad.depth
--
-- 意味レジストリの原子だけで書く。mnemonic も register 名も現れない。
-- 目的はツイ数幾何の定数 x / 2^δ が machine の上でそのまま計算できることを示すこと。
--
--   a = 3/2、 b = 1/4
--   s = a ⊕ b = 7/4        深度をそろえてから足す（01 章 式 4.1）
--   m = s ⊗ 2 = 7/2        深度は加算される。丸めは入らない
--   n = −m    = −7/2
--   n = e ?   → 成功報告 / 失敗報告
--
-- e の分子を変えると失敗経路へ落ちる。両方の image を build して、
-- QEMU の終了コードが 0 と 42 に分かれることを確かめる。

-- 期待値の分子（深度 2）。−14 で成功、それ以外で失敗
arithLines :: Int -> [Line]
arithLines expect =
  [ lCstD "a" 3 1            -- 3/2   分子 3、深度 1
  , lCstD "b" 1 2            -- 1/4   分子 1、深度 2
  , lAdd  "s" "a" "b"        -- 7/4   深度 max(1,2) = 2。a を 1 段左へ寄せる
  , lCst  "two" 2            -- 2     深度 0
  , lMul  "m" "s" "two"      -- 7/2   深度 2 + 0 = 2、分子 14
  , lNeg  "n" "m"            -- −7/2  深度 2、分子 −14
  , lCstD "e" expect 2
  , lEqBr "n" "e" "ok"
  , lBr   "ko"
  , lOk   "ok"
  , lKo   "ko"
  ]

arithUnit :: Int -> Unit
arithUnit expect = linesToUnit FMeaning MInf 2 (arithLines expect)

passExpect, failExpect :: Int
passExpect = negate 14
failExpect = negate 13

-- entry unit（式 32.9）。新しい計算を持たず、meaning unit を外部 entry として開く
arithEntry :: Int -> Unit
arithEntry expect =
  (linesToUnit FEntry MInf 0 []) { uDeps = [uIdent (arithUnit expect)] }
