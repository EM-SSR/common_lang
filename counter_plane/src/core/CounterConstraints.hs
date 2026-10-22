{-# LANGUAGE NoImplicitPrelude #-}
module CounterConstraints (module X) where

-- doc: complex.matrix
-- この系のモジュールが import してよいのは CounterConstraints のみ。
-- 語彙はここで列挙したものに限られ、それ以外の識別子はコンパイルエラーになる。
-- 幾何的概念は CounterType（単体複体行列）からのみ演繹される。
-- Prelude の再エクスポートは記帳（簿記・検証コード）のための最小限であり、
-- 幾何的な概念（数体系・代算機構）は含まない。

import CounterType as X

import Prelude as X
  ( Bool (..)
  , Maybe (..)
  , Either (..)
  , Char, String
  , Eq (..), Ord (..), Show, show
  , Read, reads
  , Int, Integer
  , Num (..), Enum (..), Integral (..)
  , (.), ($), id, const, flip, uncurry, curry, fst, snd, fromIntegral
  , return, (>>)
  , not, otherwise, maybe, (&&), (||), even, odd, gcd
  , map, filter, foldr, foldl, concat, concatMap, reverse
  , length, null, all, any, and, or, elem, notElem, sum, iterate, span
  , head, tail, last, init, scanl, lookup, mapM_, mapM, sequence_, sequence
  , zip, zipWith, zipWith3, (++), repeat, replicate, take, drop
  , maximum, minimum
  )

import Data.Word as X (Word64, Word32)

import Data.Bits as X
  ( setBit, clearBit, testBit, complement, popCount, zeroBits, bit
  , shiftL, shiftR, (.&.), (.|.), xor
  )

import Data.List as X (sort)






