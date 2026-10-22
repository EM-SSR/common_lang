{-# LANGUAGE NoImplicitPrelude #-}
module Common.Core.Eval where

import CounterConstraints
import CounterComputeSystem (Dyad)
import Common.Core.Pipe
import Common.Core.Dyad (onAxis, fromAxis, depthOfPair, mulAxis)
import DagArith (addS, negateS)
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M

-- ===== core 意味論 ⟦P⟧_C（14 章）=====
-- doc: core.state core.align core.step core.observe core.total core.values core.driver
--
-- 仕様書 式 (43.2) の右辺。architecture package を一つも使わずに意味 program を
-- 走らせる。左辺 ⟦X_T⟧_T は package の simulator が出すので、この二つを比べると
-- compiler correctness が core だけで確かめられる。
--
--   Σ_C = (c, V, W, o, e)
--     c  次に読む箱の番号。c = n が停止位置
--     V  ワイヤ値。箱の番号が出力ワイヤの番号になる
--     W  作業領域。語番号で引く（§32.2）。語の byte 幅も深度もここに現れない
--     o  外部環境への報告（§32.4）。実行を閉じる
--     e  外部環境への byte 列（03 章 §7）。Put が積む。実行を閉じない
--
-- 値は二進有理数 ⟨分子, 深度⟩。深度は build 時の型なので register には載らない。

-- ===== 語番号で引く表 =====
--
-- 平衡木を値正格で持つ。自前の二分探索木では二つの問題が出る。
--
--   平衡しない   語番号は 0 から順に伸びることが多く、その並びを入れると木が
--                一列に伸びてしまい、引きが語数に比例する
--   値が遅延する 同じ語を何度も書き換えると thunk が積み上がる。20M 歩の
--                program で常駐が 2GB を越えていた
--
-- どちらも containers の Data.Map.Strict が持っている性質で足りる。

type Mem = M.Map Integer Dyad

emptyMem :: Mem
emptyMem = M.empty

memGet :: Mem -> Integer -> Dyad
memGet m key = M.findWithDefault (0, 0) key m

memPut :: Integer -> Dyad -> Mem -> Mem
memPut = M.insert

-- 語番号の昇順。非零の語だけを外へ出すのは呼び出し側の仕事
memList :: Mem -> [(Integer, Dyad)]
memList = M.toAscList

-- ===== 外部報告 =====

data Report = RNone | ROk | RKo deriving (Eq, Show)

-- ===== 状態 =====

data CoreState = CoreState
  { csPc   :: Int
  , csWire :: Mem      -- 箱の番号を語番号として使う
  , csWork :: Mem
  , csRep  :: Report
  , csOut  :: [Int]    -- Put が出した byte。新しいものが先頭に積む
  }

initState :: CoreState
initState = CoreState 0 emptyMem emptyMem RNone []

-- ===== 一段の遷移 δ_C（14 章 §3）=====
--
-- 深度をそろえるのは加算と二つの比較だけ。乗算は深度を足し、負化は変えない。
-- 語番号は分子だけを読む（式 3.1）。作業領域は語の並びであって
-- 二進有理数の格子ではない。

-- 箱の引き。番号で引く表を一度だけ組む。リストを毎歩なめると箱数 × 歩数になり、
-- 千箱の program では compile より実行が重くなる
type BoxTab = IM.IntMap MBox

boxTable :: [(Int, MBox)] -> BoxTab
boxTable = IM.fromList

step :: Int -> BoxTab -> CoreState -> CoreState
step n tbl st = case IM.lookup (csPc st) tbl of
  Nothing -> st { csPc = n }
  Just b  -> case b of
    BCst x d    -> put (x, d)
    BAdd u v    -> put (fromAxis (addS (onAxis (rd u)) (onAxis (rd v))))
    BMul u v    -> put (mulAxis (rd u) (rd v))
    BNeg u      -> put (fromAxis (negateS (onAxis (rd u))))
    BEqBr u v l -> let (x, y, _) = align2 (rd u) (rd v)
                   in jump (if x == y then l else csPc st + 1)
    BLtBr u v l -> let (x, y, _) = align2 (rd u) (rd v)
                   in jump (if x <  y then l else csPc st + 1)
    BBr l       -> jump l
    BLoad a     -> put (memGet (csWork st) (addrOf (rd a)))
    BStore a u  -> st { csPc  = csPc st + 1
                      , csWork = memPut (addrOf (rd a)) (wordOf (rd u)) (csWork st) }
    BOk         -> st { csPc = n, csRep = ROk }
    BKo         -> st { csPc = n, csRep = RKo }
    BPut u      -> st { csPc = csPc st + 1
                      , csOut = putByte (rd u) : csOut st }
  where
    rd w = memGet (csWire st) (toInteger w)
    put v = st { csPc = csPc st + 1
               , csWire = memPut (toInteger (csPc st)) v (csWire st) }
    -- 範囲外の label は停止位置へ落ちる。書き間違いと停止の意図を分けるのは
    -- driver の仕事であり（12 章 §3）、core は停止として扱う
    jump l = st { csPc = if l < 0 || l > n then n else l }

-- 語番号は分子。深度は語番号に現れない
addrOf :: Dyad -> Integer
addrOf (x, _) = x

-- 作業領域が持つのは分子だけになる。深度は build 時の型であって register にも
-- 語にも載らない（01 章、§32.2）。Common.Core.Dyad.depthsOf も Load の深度を
-- 0 と宣言している。ここで深度を持たせると core だけが machine と違う値を返し、
-- 式 (43.2) が破れる
wordOf :: Dyad -> Dyad
wordOf (x, _) = (x, 0)

-- Put が出す byte。値を整数として読み、範囲外は下位 8 bit を採る（10 章 §2）
putByte :: Dyad -> Int
putByte (x, d) = fromInteger ((x `div` shiftL 1 d) `mod` 256)

-- DagArith.alignDepth と同じ深度へ寄せる（式 2.1）
align2 :: Dyad -> Dyad -> (Integer, Integer, Int)
align2 (a, da) (b, db) = (a * shiftL 1 (t - da), b * shiftL 1 (t - db), t)
  where t = depthOfPair da db

-- ===== 実行 =====
--
-- 停止性が示されていない program のために歩数上限 S を取る。上限で切れた場合は
-- 値ではなく誤りの報告になる（14 章 §5）。

data Outcome
  = Closed Report [(Integer, Dyad)] [Int]
    -- ^ (外部報告, 非零の作業領域, Put が出した byte 列)
  | Unclosed Int                      -- 上限 S で閉じなかった
  deriving (Eq, Show)

runCore :: Int -> [(Int, MBox)] -> Outcome
runCore budget boxes = go budget initState
  where
    n   = length boxes
    tbl = boxTable boxes
    go k st
      | csPc st >= n = closedAt st
      | k <= 0       = Unclosed budget
      | otherwise    = go (k - 1) (step n tbl st)

-- 停止位置での観測。作業領域は非零の語だけ、byte 列は出した順に戻す
closedAt :: CoreState -> Outcome
closedAt st =
  Closed (csRep st) (nonZero (memList (csWork st))) (reverse (csOut st))

-- ===== 層並列の実行（02 §1、Common-Lang/2 定理2.1）=====
--
-- 同じ層の箱は互いに依存しないので、同時に走らせても同じ値を出す。だから PC を
-- 一つずつ進める代わりに、連なりへ入ったら層ごとにまとめて走らせる。
--
--   PC が連なりの中にある そこから末尾までの層をまとめて走らせ、PC をその次へ置く
--   PC が区切りにある     一箱だけ走らせる（分岐・作業領域・報告）
--
-- 逐次版と同じ値を出す。連なりの中の箱は値を作るだけで、作業領域も報告も触らず、
-- 同じ層の箱は互いのワイヤを読まないからである。driver の --run が毎回
-- 両方を走らせて突き合わせる。
--
-- 逐次に並んでいたのは CPU の都合であって、意味の側の順序ではない。

runCorePar :: Int -> [(Int, MBox)] -> Outcome
runCorePar budget boxes = go budget initState
  where
    n    = length boxes
    tbl  = boxTable boxes
    -- 連なりの途中へ分岐で入ることがあるので、各位置から末尾までを登録する
    runs = IM.fromList
      [ (i, drop j run)
      | run <- pureRuns boxes
      , isPureRun run
      , (j, (i, _)) <- zip [0 ..] run ]
    isPureRun ((_, b) : _) = pureBox b
    isPureRun []           = False
    go k st
      | csPc st >= n = closedAt st
      | k <= 0       = Unclosed budget
      | otherwise    = case IM.lookup (csPc st) runs of
          Just run -> go (k - length run) (runPure tbl run st)
          Nothing  -> go (k - 1) (step n tbl st)

-- 連なりを層ごとに走らせる。層の中の箱は互いに依存しないので、値を作ってから表へ入れる
runPure :: BoxTab -> [(Int, MBox)] -> CoreState -> CoreState
runPure tbl run st =
  st { csPc = lastOf run + 1, csWire = foldl layer (csWire st) (causalLayers run) }
  where
    layer wm is =
      let vals = [ (i, evalPure wm (csWork st) (IM.findWithDefault BKo i tbl)) | i <- is ]
      in foldl (\m (i, v) -> memPut (toInteger i) v m) wm vals

lastOf :: [(Int, MBox)] -> Int
lastOf xs = foldl (\acc (i, _) -> max acc i) (negate 1) xs

-- 作業領域を書き換えない箱。Load は読むだけなので、連なりの間ずっと同じ
-- 作業領域を見る。Store が来たらそこで連なりが切れる
evalPure :: Mem -> Mem -> MBox -> Dyad
evalPure wm work b = case b of
  BCst x d -> (x, d)
  BAdd u v -> fromAxis (addS (onAxis (rd u)) (onAxis (rd v)))
  BMul u v -> mulAxis (rd u) (rd v)
  BNeg u   -> fromAxis (negateS (onAxis (rd u)))
  BLoad a  -> memGet work (addrOf (rd a))
  _        -> (0, 0)
  where rd w = memGet wm (toInteger w)

nonZero :: [(Integer, Dyad)] -> [(Integer, Dyad)]
nonZero xs = [ p | p@(_, (v, _)) <- xs, v /= 0 ]

defaultBudget :: Int
defaultBudget = 1000000

-- 到達したワイヤ値も見たいときの入口。デバッグ用であって観測ではない
runCoreWires :: Int -> [(Int, MBox)] -> Maybe [(Integer, Dyad)]
runCoreWires budget boxes = go budget initState
  where
    n   = length boxes
    tbl = boxTable boxes
    go k st
      | csPc st >= n = Just (memList (csWire st))
      | k <= 0       = Nothing
      | otherwise    = go (k - 1) (step n tbl st)

-- ===== 作業領域の読み出し =====
--
-- 語番号 base から len 語を並べる。program が書いた表をそのまま読む用途に使う

sliceWork :: [(Integer, Dyad)] -> Integer -> Int -> [Integer]
sliceWork work base len =
  [ at (base + toInteger k) | k <- [0 .. len - 1] ]
  where
    at i = case [ v | (i', (v, _)) <- work, i' == i ] of
      (v : _) -> v
      []      -> 0
