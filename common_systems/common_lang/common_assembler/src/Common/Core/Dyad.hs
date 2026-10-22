{-# LANGUAGE NoImplicitPrelude #-}
module Common.Core.Dyad where

import CounterConstraints
import CounterComputeSystem (Dyad)
import DagArith (SCoord, Ratio2 (..), addS, alignDepth, negateS, multiplyThales,
                 divideThales, asScale, scaleBy)
import Common.Core.Pipe
import qualified Data.IntMap.Strict as IM

-- ===== 二進有理定数と深度（docs/common-compiler/core/01）=====
-- doc: casm.dyad.depth casm.dyad.mat casm.dyad.limit casm.dyad.div
--
-- 値の型は counter_plane のものをそのまま使う。
--   Dyad   = (分子, 深度)          CounterComputeSystem
--   SCoord = (x, y, 深度)          DagArith。実軸上なら y = 0
-- 四則の規則も DagArith が決める。ここが独自に定義するのは
-- 「深度を build 時の型として持ち、分子だけを register に載せる」という写像だけである。
--
--   Cst(x,δ) : δ
--   u ⊕ v    : max(δu, δv)      alignDepth
--   u ⊗ v    : δu + δv          multiplyThales
--   −u       : δu               negateS
--
-- 固定小数点にすると乗算で 2^φ の割り算が入り、丸めが出る。深度を型に置けば
-- どの段にも除算が現れず、値は Z[1/2] の中に留まる（01 章 定理 2.5）。

-- 実軸上の値として Dyad と SCoord を行き来する。ω 成分は使わない
onAxis :: Dyad -> SCoord
onAxis (n, d) = (fromInteger n, 0, d)

fromAxis :: SCoord -> Dyad
fromAxis (x, _, d) = (toInteger x, d)

-- 深度環境 Δ。箱の番号が出力ワイヤの番号なので、表は箱と一対一になる。
-- 引数は必ず先行する箱を指すから、自己参照の遅延評価で一回の走査に畳める
-- 引数は必ず先行する箱を指すので、箱の昇順に一度畳めば閉じる。
-- assoc list の lookup で書くと箱数の二乗になる
depthsOf :: [(Int, MBox)] -> IM.IntMap Int
depthsOf boxes = foldl step IM.empty boxes
  where step tbl (i, b) = IM.insert i (depthOfBox tbl b) tbl

-- 箱ひとつぶんの規則。降下（Common.Lang.Descend）が積み上げ中の表を引くので、
-- depthsOf と同じ式をここから両方が参照する
depthOfBox :: IM.IntMap Int -> MBox -> Int
depthOfBox tbl b = case b of
  BCst _ d -> d
  -- alignDepth が返す深度をそのまま採る（規則を書き写さない）
  BAdd u v -> depthOfPair (at u) (at v)
  -- multiplyThales の深度成分。二進比の積は指数が加算される
  BMul u v -> at u + at v
  BNeg u   -> depthOf1 (at u)
  BLoad _  -> 0        -- memory の語は分子そのもの（深度 0）
  _        -> 0
  where at w = IM.findWithDefault 0 w tbl

-- DagArith.alignDepth が決める共通深度
depthOfPair :: Int -> Int -> Int
depthOfPair da db = d
  where ((_, _, d), _) = alignDepth (1, 0, da) (1, 0, db)

-- DagArith.negateS は深度を変えない。その事実をここで参照する
depthOf1 :: Int -> Int
depthOf1 da = d
  where (_, _, d) = negateS (1, 0, da)

depthAt :: IM.IntMap Int -> Int -> Int
depthAt tbl w = IM.findWithDefault 0 w tbl

-- ===== 疑似命令（01 章 §3）=====
--
-- package はこの列を自分の atlas で覆う。深度の計算は全て core 側で済んでいる。
-- (wire, shift) の shift が 0 なら、その左シフトの局所片は空になる。

type Shifted = (Int, Int)     -- (ワイヤ番号, 左シフト量)

data Op
  = OMat   Int Integer        -- w ← x（分子の物質化）
  | OAdd   Int Shifted Shifted
  | OMul   Int Int Int
  | ONeg   Int Int
  | OEq    Shifted Shifted Int  -- u = v なら label へ
  | OLt    Shifted Shifted Int
  | OJmp   Int
  | OLoad  Int Int
  | OStore Int Int
  | OOk
  | OKo
  | OPut  Int                 -- 一 byte を外へ出す（03 章 §7、04 章 §8.2）
  deriving (Eq, Show)

-- 意味箱を疑似命令へ落とす。深度をそろえる左シフトはここで決まる（01 章 式 4.1）。
-- 反復は命令を増やさない。§18 の「通常の loop branch が適切なら back-edge を持つ
-- control chamber へ写す」がそのまま当たり、後退 label の条件分離が back-edge になる。
lowerOps :: [(Int, MBox)] -> [(Int, Op)]
lowerOps boxes = [ (i, op i b) | (i, b) <- boxes ]
  where
    ds = depthsOf boxes
    d w = depthAt ds w
    align w t = (w, t - d w)
    op i b = case b of
      BCst x _    -> OMat i x
      BAdd u v    -> let t = depthOfPair (d u) (d v)
                     in OAdd i (align u t) (align v t)
      BMul u v    -> OMul i u v
      BNeg u      -> ONeg i u
      BEqBr u v l -> let t = depthOfPair (d u) (d v)
                     in OEq (align u t) (align v t) l
      BLtBr u v l -> let t = depthOfPair (d u) (d v)
                     in OLt (align u t) (align v t) l
      BBr l       -> OJmp l
      BLoad a     -> OLoad i a
      BStore a u  -> OStore a u
      BOk         -> OOk
      BKo         -> OKo
      BPut u      -> OPut u

-- ===== 意味の側の値（式 43.2 の ⟦C_P⟧）=====
--
-- 意味箱の列を DagArith の上で直接評価する。machine simulator の観測と
-- この値が一致することが compiler correctness の内容になる。
-- 分岐から先は追わず、算術の部分だけを見る

valuesOf :: [(Int, MBox)] -> [(Int, Dyad)]
valuesOf boxes = IM.toAscList (foldl step IM.empty boxes)
  where
    step tbl (i, b) = IM.insert i (vOf tbl b) tbl
    at tbl w = IM.findWithDefault (0, 0) w tbl
    vOf tbl b = case b of
      BCst x d -> (x, d)
      BAdd u v -> fromAxis (addS (onAxis (at tbl u)) (onAxis (at tbl v)))
      BMul u v -> mulAxis (at tbl u) (at tbl v)
      BNeg u   -> fromAxis (negateS (onAxis (at tbl u)))
      _        -> (0, 0)

-- タレス積。大きさは比の積、深度は指数の和（DagArith.multiplyThales）
mulAxis :: Dyad -> Dyad -> Dyad
mulAxis (a, da) (b, db) =
  case asScale (multiplyThales (Ratio a' 1) (Ratio b' 1)) of
    Just (n, _) -> (toInteger n, da + db)
    Nothing     -> (0, 0)
  where
    a' = fromInteger a
    b' = fromInteger b

-- ===== 表現可能性（01 章 式 5.1）=====
--
-- register 幅に載らない分子は近似せずに build を止める（§50 の「表現できない」）

fitsWidth :: Int -> Integer -> Bool
fitsWidth w x = negate lim <= x && x < lim
  where lim = shiftL (1 :: Integer) (w - 1)

checkWidth :: Int -> [(Int, Op)] -> Maybe String
checkWidth w ops = case [ x | (_, OMat _ x) <- ops, not (fitsWidth w x) ] of
  (x : _) -> Just ("constant does not fit in " ++ show w ++ " bits: " ++ show x)
  []      -> Nothing

-- ===== タレス比の materialize（01 章 §6）=====
--
-- 商が二進比 n/2^s へ正規化できるときだけ定数になる。判定は DagArith が持つ。
-- 1/3 のような商は Cst の引数になれない。除算命令を意味原始にはしない

asDyadic :: Integer -> Integer -> Maybe (Integer, Int)
asDyadic n dn = case asScale (divideThales (fromInteger n) (fromInteger dn)) of
  Just (q, s) -> Just (toInteger q, s)
  Nothing     -> Nothing

-- 二進比を値へ適用する。scaleBy がその写像そのもの
applyScale :: (Int, Int) -> Dyad -> Dyad
applyScale s v = fromAxis (scaleBy s (onAxis v))
