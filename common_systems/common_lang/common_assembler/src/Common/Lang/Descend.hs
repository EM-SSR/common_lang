{-# LANGUAGE NoImplicitPrelude #-}
module Common.Lang.Descend where

import CounterConstraints
import CommonChamber
import CounterUnits (Op (..), UnitPoint (..))
import DagArith (QRat (..))
import Quantale (QCoeff (..), mulWord, invWord, applyWord, magOf)
import Common.Core.Pipe (MBox (..))
import Common.Core.Dyad (depthOfBox)
import qualified Data.IntMap.Strict as IM
import Data.List (partition, (!!))
import Control.Monad (foldM)

-- ===== 降下: チェンバー → Common Assembler の意味 program（16 §5）=====
-- doc: plain.descend descend.sound descend.beta chamber.reduce chamber.five
-- doc: node.missing node.impl agree member Q.quantale residual.adjoint
--
-- 平文は 47 生成元のチェンバーになる。実行は 11 原子へ降ろす。
--
--   Desc : Atom -> MBox*                                     式 (5.1)
--   ω    : (層, q) -> 箱番号                                  式 (5.2)
--
-- チェンバーでは接続を位置 q が決める（定理 2.2）ので、ω は frontier を
-- 左から数えるだけで作れる。ワイヤ名も label も要らない。
--
-- 席は三種で、型ごとの表現がどれかを選ぶ。
--
--   Dyad, Bit          W    実行時のワイヤ一本。深度は Common.Core.Dyad が持つ
--   Q                  JW   大きさ a/b と構成語の排他的な選択条件
--   Rational           QW   有理数 a/b の二本。b > 0
--   Trace, Point,      K    compile 時の値
--   Reflection, Noun
--
-- K が閉じるのは、この四型を出力に持つ生成元の入力型が同じ四型に収まり、
-- 根が trace / E / R_r / R_ij / node の五つの 0 引数箱になるからである。
-- Γ⁻ = I なので木の外に葉が無い。
--
-- 判定値の構成語は積・残差・上限を通して保持し、出口で整数へ符号化する。

data Slot
  = W Int          -- Dyad / Bit
  | QW Int Int     -- 有理数 a/b、b > 0
  | JW Int Int [(Int, ([Op], Int))] -- 大きさと、排他的な選択条件付きの構成語
  | NW QCoeff [Int] -- 影響対象の位置と実行時の実成分プロファイル
  | K Value        -- compile 時に決まる値
  deriving (Eq, Show)

type Wires = [Slot]

-- 積み上げ中の状態。箱は逆順に持ち、最後に反転する。深度表は箱を置くたびに伸ばす
data Acc = Acc
  { aBoxes :: [MBox]      -- 逆順
  , aNext  :: Int         -- 次に置く箱の番号
  , aDep   :: IM.IntMap Int
  , aLayers :: IM.IntMap Int
  }

emptyAcc :: Acc
emptyAcc = Acc [] 0 IM.empty IM.empty

push :: MBox -> Acc -> (Int, Acc)
push b (Acc bs n dm layers) = (n, Acc (b : bs) (n + 1) (IM.insert n (depthOfBox dm b) dm) layers)

depthOfWire :: Acc -> Int -> Int
depthOfWire acc w = IM.findWithDefault 0 w (aDep acc)

boxesOfAcc :: Acc -> [(Int, MBox)]
boxesOfAcc a = zip [0 ..] (reverse (aBoxes a))

-- ===== 箱を置く短縮形 =====

cstB :: Integer -> Int -> Acc -> (Int, Acc)
cstB x d = push (BCst x d)

addB, mulB :: Int -> Int -> Acc -> (Int, Acc)
addB u v = push (BAdd u v)
mulB u v = push (BMul u v)

negB :: Int -> Acc -> (Int, Acc)
negB u = push (BNeg u)

-- ===== Desc: 一箱の降下（16 §5 の表）=====
--
--   one  -> Cst(1,0)
--   ⊕    -> Add
--   ⊖    -> Neg
--   ⋆    -> Mul
--   β    -> Cst(1,0), Add, Cst(1,1), Mul          式 (5.6)
--   Δ    -> 空列（同じワイヤを二度使う）
--   !    -> 空列（ワイヤを落とす）
--   id   -> 空列
--
-- β の基準点は 1 になる（§5.1）。β(x) = (x+1)/2 であり、実装は
-- CounterComputeSystem.betaStep そのものになる。だから零を先に立てないと
-- 半分が作れない。この事実は降下の側では表に現れず、書き手の側に現れる。

descAtom :: Integer -> Atom -> Wires -> Acc -> Either String (Wires, Acc)
descAtom sw a ins0 acc0
  | POmega address body seed <- p = case mapM unK ins0 of
      Just inputs -> case evalPrim p inputs of
        Just values -> Right (map K values,acc0)
        Nothing -> Left "閉包本体に対応する有限評価の降下が未接続"
      Nothing
        | not (omegaWellFormed address body seed) -> Left "閉包の境界が一致しない"
        | omegaStateIndependent body -> do
            (initial,acc1) <- descEmbedded sw seed
              (if null (chIn seed) then [] else ins0) acc0
            descEmbedded sw body (ins0 ++ initial) acc1
        | Just base <- omegaBisectionBase body -> Right ([K base],acc0)
        | otherwise -> Left "閉包の実行時入力の降下が未接続"
  | PExt _ _ <- p = descAtom sw primMul ins0 acc0
  | PAcc _ _ <- p = descAtom sw primAddD ins0 acc0
  | PIdentity _ <- p, [u] <- ins0 = Right ([u],acc0)
  | PCopy _ <- p, [u] <- ins0 = Right ([u,u],acc0)
  | PDiscard _ <- p, [_] <- ins0 = Right ([],acc0)
  | PDupN <- p, [u] <- ins0 = Right ([u,u],acc0)
  | PDropN <- p, [_] <- ins0 = Right ([],acc0)
  | PWeight k <- p, [NW _ ps] <- ins0 = case drop k ps of
      (w:_) | k >= 0 -> Right ([W w],acc0)
      _ -> Left "影響プロファイルの目印番号が範囲外"
  | PNodeUnit op <- p, [NW x ps] <- ins0 = Right ([NW (applyWord [op] x) ps],acc0)
  | PRel ops <- p, [x,y] <- ins0 = case x of
      NW pos ps -> Right ([NW (applyWord (relWord ops) pos) ps,y],acc0)
      K (VNoun pos ps) -> Right ([K (VNoun (applyWord (relWord ops) pos) ps),y],acc0)
      _ -> Left "関係の入力が影響ノードでない"
  | PHomQ <- p, [x,y] <- ins0 = do
      (xs,acc1) <- profileJudges sw x acc0
      (ys,acc2) <- profileJudges sw y acc1
      if length xs /= length ys then Left "影響プロファイルの目印数が一致しない"
      else do
        (unit,acc3) <- resolve [PJudge] [K (VJudge (QRat 1 1) [] 1)] acc2
        foldM (\(out,acc4) (u,v) -> do
          (res,acc5) <- descAtom sw primResRJ [u,v] acc4
          case out ++ res of
            [a0,b0] -> selectJudge False sw a0 b0 acc5
            _ -> Left "到達度の境界が不正") (unit,acc3) (zip xs ys)
  | staticBox p = case mapM unK ins0 of
      Nothing -> Left ("静的な箱へ実行時のワイヤが来た: " ++ atomTag a)
      Just vs -> case evalPrim p vs of
        Nothing -> Left ("静的評価が閉じない: " ++ atomTag a)
        Just os -> Right (map K os, acc0)
  | otherwise = case resolve (fst (kindsOfPrim p)) ins0 acc0 of
      Left e           -> Left e
      Right (ins, acc) -> step ins acc
  where
    p = atomPrim a
    step ins acc = case (p, ins) of
      (PSupFamily n, xs) | n >= 0 && length xs == n -> do
        (zero,acc1) <- resolve [PJudge] [K (VJudge (QRat 0 1) [] 1)] acc
        foldM (\(out,a0) x -> descAtom sw primSupJ (out ++ [x]) a0) (zero,acc1) xs
      (PEqBranch target, [W u,W v]) ->
        let (_,a1) = push (BEqBr u v (negate (target+1))) acc in Right ([],a1)
      (PLtBranch target, [W u,W v]) ->
        let (_,a1) = push (BLtBr u v (negate (target+1))) acc in Right ([],a1)
      (PBranch target, []) ->
        let (_,a1) = push (BBr (negate (target+1))) acc in Right ([],a1)
      (PTransport images, xs) | validTransport images && length xs == length images ->
        case mapM wire xs of
          Nothing -> Left "影響の入力が二進有理数でない"
          Just ws ->
            let width = case images of (row:_) -> length row; [] -> 0
                component (out,a0) j =
                  let (zero,a1) = cstB 0 0 a0
                      term (total,a2) (w,row) =
                        let (n,d) = row !! j
                            (coefficient,a3) = cstB n d a2
                            (value,a4) = mulB coefficient w a3
                        in addB total value a4
                      (value,a5) = foldl term (zero,a1) (zip ws images)
                  in (out ++ [W value],a5)
            in Right (foldl component ([],acc) [0 .. width - 1])
      (PProfile n, xs) | n >= 0 && length xs == n -> case mapM wire xs of
        Just ws -> Right ([NW (QCoeff 1 0 [] 1) ws],acc)
        Nothing -> Left "影響プロファイルの入力が二進有理数でない"
      (PCstD n d, []) | d >= 0 ->
        let (w, acc1) = cstB n d acc in Right ([W w], acc1)
      (PIdentity _, [u]) -> Right ([u], acc)
      (PCopy _, [u]) -> Right ([u,u], acc)
      (PDiscard _, [_]) -> Right ([], acc)
      (PInvAt n d, [W u]) ->
        let du = depthOfWire acc u in
        if du <= d then Left "逆二分割の入力深度が基準点以下"
        else
          let (s, a1) = cstB sw 0 acc
              (_, a2) = push (BStore s u) a1
              (raw, a3) = push (BLoad s) a2
              (h, a4) = cstB 1 (du - 1) a3
              (x, a5) = mulB raw h a4
              (na, a6) = cstB (negate n) d a5
              (w, a7) = addB x na a6
          in Right ([W w], a7)
      (PBetaAt n d, [W u]) ->
        let (a, a1) = cstB n d acc
            (x, a2) = addB u a a1
            (h, a3) = cstB 1 1 a2
            (w, a4) = mulB x h a3
        in Right ([W w], a4)
      (PFixAt n d, [W _]) ->
        let (w, a1) = cstB n d acc in Right ([W w], a1)
      (PKoR, []) -> let (_, a1) = push BKo acc in Right ([], a1)
      (PPutW, [W u]) -> let (_, a1) = push (BPut u) acc in Right ([], a1)
      (PDivD, [W u, W v]) ->
        let (a, a1) = liftQ sw u acc
            (b, a2) = liftQ sw v a1
            ((n,d), a3) = divQ sw b a a2
            (zero, a4) = cstB 0 0 a3
            skip = aNext a4 + 3
            (_, a5) = push (BLtBr zero (fst b) skip) a4
            (_, a6) = push (BLtBr (fst b) zero skip) a5
            (_, a7) = push BKo a6
        in Right ([QW n d], a7)
      (POne, []) ->
        let (w, acc1) = cstB 1 0 acc in Right ([W w], acc1)
      (PAddD, [W u, W v]) ->
        let (w, acc1) = addB u v acc in Right ([W w], acc1)
      (PNegD, [W u]) ->
        let (w, acc1) = negB u acc in Right ([W w], acc1)
      (PMul, [W u, W v]) ->
        let (w, acc1) = mulB u v acc in Right ([W w], acc1)
      (PBeta, [W u]) ->
        -- β(x) = (x + 1) / 2。加算のあと 1/2 を掛ける
        let (o, acc1) = cstB 1 0 acc
            (s, acc2) = addB u o acc1
            (h, acc3) = cstB 1 1 acc2
            (w, acc4) = mulB s h acc3
        in Right ([W w], acc4)
      -- β⁻¹(x) = 2x − 1。像は深度 1 以上に限る（構成語 §4 の im β_a）。
      -- 深度を一段下げる道は Load しかないので、分子を語へ落としてから
      -- Cst(1, d−1) を掛けて置き直す
      (PBetaInv, [W u]) ->
        let d = depthOfWire acc u in
        if d < 1
          then Left "β⁻¹ の入力が像の外にある（深度 0）"
          else
            let (s,  acc1) = cstB sw 0 acc
                (_,  acc2) = push (BStore s u) acc1
                (n0, acc3) = push (BLoad s) acc2
                (k,  acc4) = cstB 1 (d - 1) acc3
                (t,  acc5) = mulB n0 k acc4
                (o,  acc6) = cstB 1 0 acc5
                (no, acc7) = negB o acc6
                (w,  acc8) = addB t no acc7
            in Right ([W w], acc8)
      -- Ω_a[β_a; x₀] = a。集積点は初期値に依らないので入力ワイヤは落ちる（16 式 5.8）
      (PFixL, [W _]) ->
        let (w, acc1) = cstB 1 0 acc in Right ([W w], acc1)
      -- β_a(x) = (x + a) / 2。16 式 (5.6) の Cst(1,0) が第二ワイヤに変わる（22 式 22.9）
      (PBisectD, [W u, W a0]) ->
        let (s, acc1) = addB u a0 acc
            (h, acc2) = cstB 1 1 acc1
            (w, acc3) = mulB s h acc2
        in Right ([W w], acc3)
      -- Ω_a[β_a; x₀] = a。箱を作らず第二ワイヤをそのまま返す（22 式 22.10）
      (PFixD, [W _, W a0]) -> Right ([W a0], acc)
      -- 作業領域と報告（16 §5.0）。番地も値もワイヤで来るので正準添字が要らない
      (PLoadW, [W i]) ->
        let (w, acc1) = push (BLoad i) acc in Right ([W w], acc1)
      (PStoreW, [W i, W u]) ->
        let (_, acc1) = push (BStore i u) acc in Right ([], acc1)
      (POkR, []) ->
        let (_, acc1) = push BOk acc in Right ([], acc1)
      -- 二値を作る八箱（16 §5.3 式 5.9）。値の join を memory しか持たないので、
      -- 既定値を退避語へ置き、path separation の片側で書き換えてから読み戻す
      (PLeqD, [W u, W v]) ->
        let (w, acc1) = bitSeq sw (Just v) u 0 acc in Right ([W w], acc1)
      (PFold, [W u]) ->
        let (w, acc1) = bitSeq sw Nothing u 1 acc in Right ([W w], acc1)
      -- 複製と廃棄は箱を作らない。ワイヤの世界では複製が無料であり、
      -- 廃棄はワイヤを落とすだけになる（仕様 §14 複製と移動を分ける）
      -- π は型を忘れるだけ。値は動かないので箱を作らない（16 §5 の表）
      (PPiF, [W u])   -> Right ([W u], acc)
      (PDupD, [W u])  -> Right ([W u, W u], acc)
      (PDropD, [_])   -> Right ([], acc)
      -- ===== 判定層（07 §6、圏論 定理 3.3、3.4）=====
      --
      --   (q ⇔ p) = ar(q,p) ⋆ ar(p,q)                        07 §6.2
      --   ar(a,c) = 1 (a = c = 0)、0 (a = 0 ≠ c)、min(1, c ⊘ a)
      (PAgr, [W u, W v]) ->
        let (q, acc1) = liftQ sw u acc
            (r, acc2) = liftQ sw v acc1
            ((n, d), acc3) = agreeB sw q r acc2
        in Right (judgeW n d ([],1) acc3)
      (PAgrU, [W u]) ->
        let (q, acc1) = liftQ sw u acc
            (o, acc2) = constQ 1 1 acc1
            ((n, d), acc3) = agreeB sw q o acc2
        in Right (judgeW n d ([],1) acc3)
      (PAgrZ, [W u]) ->
        let (q, acc1) = liftQ sw u acc
            (z, acc2) = constQ 0 1 acc1
            ((n, d), acc3) = agreeB sw q z acc2
        in Right (judgeW n d ([],1) acc3)
      (PMulJ, [JW a1 b1 w1, JW a2 b2 w2]) ->
        let (n, acc1) = mulB a1 a2 acc
            (d, acc2) = mulB b1 b2 acc1
            (ws, acc3) = combineWords mulWord w1 w2 acc2
        in Right ([JW n d ws], acc3)
      (PSupJ, [JW a1 b1 w1, JW a2 b2 w2]) ->
        selectJudge True sw (JW a1 b1 w1) (JW a2 b2 w2) acc
      -- ↘ は第一入力を、↙ は第二入力を residualQ の左に取る
      (PResRJ, [JW a1 b1 w1, JW a2 b2 w2]) ->
        let ((n, d), acc1) = residB sw (a1, b1) (a2, b2) acc
            (ws, acc2) = combineWords (\u v -> mulWord (invWord u) v) w1 w2 acc1
        in Right ([JW n d ws], acc2)
      (PResLJ, [JW a1 b1 w1, JW a2 b2 w2]) ->
        let ((n, d), acc1) = residB sw (a2, b2) (a1, b1) acc
            (ws, acc2) = combineWords (\u v -> mulWord u (invWord v)) w1 w2 acc1
        in Right ([JW n d ws], acc2)
      (PLeqJ, [JW a1 b1 _, JW a2 b2 _]) ->
        let (x, acc1) = mulB a1 b2 acc
            (y, acc2) = mulB a2 b1 acc1
            (w, acc3) = bitSeq sw (Just y) x 0 acc2
        in Right ([W w], acc3)
      -- 所属 φ∂∘π と二値化 Θ。どちらも大きさの正値だけを読む（07 §6.3）
      (PPhiJ, [JW n _ _])  -> Right (bitOf n acc)
      (PTheta, [JW n _ _]) -> Right (bitOf n acc)
      -- π は語を落とす。大きさは動かない
      (PPiJ, [JW n d _]) -> Right (judgeW n d ([],1) acc)
      -- 領域の関係（幾何 Index）。値は compile 時に決まる。Cst 一箱をこの位置で
      -- 開いて実行時のワイヤにする。開く位置を箱の位置へそろえると、
      -- commonc の側と箱の並びが一致する（19 式 5.1）
      (PRegionOp op, xs)
        | elem op ["contains", "overlaps", "adjacent", "path"] ->
            case mapM unK xs of
              Nothing -> Left ("領域の関係へ実行時のワイヤが来た: " ++ op)
              Just vs -> case evalPrim p vs of
                Just [VBit b] -> let (w, acc1) = cstB (toInteger b) 0 acc
                                 in Right ([W w], acc1)
                _ -> Left ("領域の関係が閉じない: " ++ op)
      _ -> Left ("降下の表に無い箱: " ++ atomTag a)
    bitOf n acc = let (w, acc1) = bitSeq sw Nothing n 1 acc in ([W w], acc1)
    wire (W w) = Just w
    wire _ = Nothing

-- 静的な四型（Trace, Point, Reflection, Noun）だけを触る箱。
-- 出力が Q になる G は入力が静的なので同じ扱いに入る
staticPort :: Port -> Bool
staticPort (PtReference _) = True
staticPort q = elem q [PtUnit, PtCoord, PtRefl, PNoun, PtChain, PtRegion,PtMono]

staticBox :: Prim -> Bool
staticBox (PWeight _) = True
staticBox p = case kindsOfPrim p of
  ([], []) -> False
  (is, os) -> all staticPort is && (all staticPort os || all (== PJudge) os)

unK :: Slot -> Maybe Value
unK (K v) = Just v
unK _     = Nothing

-- 入力の席を port の型へそろえる。静的な席が動く型の位置へ来たら Cst で開く
resolve :: [Port] -> Wires -> Acc -> Either String (Wires, Acc)
resolve ps ss acc0 = go ps ss [] acc0
  where
    go _ [] out acc = Right (reverse out, acc)
    go [] (s : rest) out acc = go [] rest (s : out) acc
    go (q : qs) (s : rest) out acc = case (q, s) of
      (PJudge, K (VJudge (QRat n d) ws sg)) ->
        let (x, acc1) = cstB n 0 acc
            (y, acc2) = cstB d 0 acc1
            (one, acc3) = cstB 1 0 acc2
        in go qs rest (JW x y [(one,(ws,sg))] : out) acc3
      (_, K (VDyad (n, d))) ->
        let (w, acc1) = cstB n d acc in go qs rest (W w : out) acc1
      (_, K (VBit b)) ->
        let (w, acc1) = cstB (toInteger b) 0 acc in go qs rest (W w : out) acc1
      _ -> go qs rest (s : out) acc

-- ===== 判定値の算術（大きさ a/b、b > 0）=====

judgeW :: Int -> Int -> ([Op], Int) -> Acc -> (Wires, Acc)
judgeW n d word acc =
  let (one, acc1) = cstB 1 0 acc in ([JW n d [(one,word)]], acc1)

profileJudges :: Integer -> Slot -> Acc -> Either String (Wires,Acc)
profileJudges sw (NW pos ps) acc
  | null ps = profileJudges sw (K (VNoun pos [])) acc
  | otherwise = Right (foldl lift ([],acc) ps)
  where
    lift (out,a) w =
      let ((n,d),a1) = liftQ sw w a
          (v,a2) = judgeW n d ([],1) a1
      in (out ++ v,a2)
profileJudges _ (K (VNoun pos ps)) acc =
  let coeffs = if null ps then [pos] else ps
      judge q = K (VJudge (magOf q) (qWord q) (qSign q))
  in resolve (replicate (length coeffs) PJudge) (map judge coeffs) acc
profileJudges _ _ _ = Left "到達度の入力が影響ノードでない"

-- Both lattice operations carry the selected construction word; ties forget
-- the word only when the two words differ, matching Quantale.meetJudge/joinJudge.
selectJudge :: Bool -> Integer -> Slot -> Slot -> Acc -> Either String (Wires,Acc)
selectJudge upper sw (JW a1 b1 w1) (JW a2 b2 w2) acc =
  let (less, acc1) = ltQ sw (a1,b1) (a2,b2) acc
      (back, acc2) = ltQ sw (a2,b2) (a1,b1) acc1
      rightGate = if upper then less else back
      leftGate = if upper then back else less
      (n, acc3) = selB rightGate a2 a1 acc2
      (d, acc4) = selB rightGate b2 b1 acc3
      (eitherLess, acc5) = addB less back acc4
      (tie, acc6) = eqZeroB sw eitherLess acc5
      (left, acc7) = gateWords leftGate w1 acc6
      (right, acc8) = gateWords rightGate w2 acc7
      (equal, acc9) = combineWords (\u v -> if u == v then u else ([],1)) w1 w2 acc8
      (tied, accA) = gateWords tie equal acc9
      (ws, accB) = mergeWords (left ++ right ++ tied) accA
  in Right ([JW n d ws],accB)
selectJudge _ _ _ _ _ = Left "上限・下限の入力が判定値でない"

-- 各条件は 0/1、全条件の和は 1。同じ語の条件を加算してまとめる。
mergeWords :: [(Int, ([Op], Int))] -> Acc -> ([(Int, ([Op], Int))], Acc)
mergeWords [] acc = ([],acc)
mergeWords ((gate,word):rest) acc =
  let (same,other) = partition ((== word) . snd) rest
      (sumGate,acc1) = foldl (\(s,a) (g,_) -> addB s g a) (gate,acc) same
      (tailWords,acc2) = mergeWords other acc1
  in ((sumGate,word):tailWords,acc2)

gateWords :: Int -> [(Int, ([Op], Int))] -> Acc -> ([(Int, ([Op], Int))], Acc)
gateWords _ [] acc = ([],acc)
gateWords gate ((g,w):rest) acc =
  let (productGate,acc1) = mulB gate g acc
      (tailWords,acc2) = gateWords gate rest acc1
  in ((productGate,w):tailWords,acc2)

combineWords :: (([Op],Int) -> ([Op],Int) -> ([Op],Int))
             -> [(Int,([Op],Int))] -> [(Int,([Op],Int))] -> Acc
             -> ([(Int,([Op],Int))],Acc)
combineWords f xs ys acc =
  let (ws,acc1) = foldl step ([],acc) [(x,y) | x <- xs, y <- ys]
  in mergeWords ws acc1
  where
    step (out,a) ((g,u),(h,v)) =
      let (both,a1) = mulB g h a in ((both,f u v):out,a1)

projectWords :: (([Op],Int) -> Integer) -> [(Int,([Op],Int))] -> Acc -> (Int,Acc)
projectWords field ws acc =
  let (zero,acc1) = cstB 0 0 acc
  in foldl step (zero,acc1) ws
  where
    step (s,a) (gate,word) =
      let (v,a1) = cstB (field word) 0 a
          (term,a2) = mulB gate v a1
      in addB s term a2

constQ :: Integer -> Integer -> Acc -> ((Int, Int), Acc)
constQ n d acc0 =
  let (x, acc1) = cstB n 0 acc0
      (y, acc2) = cstB d 0 acc1
  in ((x, y), acc2)

-- Dyad ワイヤを判定値へ上げる。値 = 分子 / 2^d であり、深度は compile 時の事実
-- なので分母は定数になる。Load が深度を落とす唯一の箱になる
liftQ :: Integer -> Int -> Acc -> ((Int, Int), Acc)
liftQ sw u acc0 =
  let d = depthOfWire acc0 u
      (s, acc1) = cstB sw 0 acc0
      (_, acc2) = push (BStore s u) acc1
      (n, acc3) = push (BLoad s) acc2
      (b, acc4) = cstB (shiftL (1 :: Integer) d) 0 acc3
  in ((n, b), acc4)

-- [x < y]。判定値の成分はどれも深度 0 なので左シフトが出ない
ltB :: Integer -> Int -> Int -> Acc -> (Int, Acc)
ltB sw x y = bitSeq sw (Just x) y 1

-- [a = 0] = 1 − [a < 0] − [0 < a]
eqZeroB :: Integer -> Int -> Acc -> (Int, Acc)
eqZeroB sw a acc0 =
  let (z,  acc1) = cstB 0 0 acc0
      (lt, acc2) = ltB sw a z acc1
      (gt, acc3) = ltB sw z a acc2
      (o,  acc4) = cstB 1 0 acc3
      (m1, acc5) = negB lt acc4
      (m2, acc6) = negB gt acc5
      (t,  acc7) = addB o m1 acc6
      (r,  acc8) = addB t m2 acc7
  in (r, acc8)

-- sel(c, x, y) = c ⋆ x ⊕ (1 ⊖ c) ⋆ y（16 式 5.11）
selB :: Int -> Int -> Int -> Acc -> (Int, Acc)
selB c x y acc0 =
  let (t1, acc1) = mulB c x acc0
      (o,  acc2) = cstB 1 0 acc1
      (nc, acc3) = negB c acc2
      (ic, acc4) = addB o nc acc3
      (t2, acc5) = mulB ic y acc4
      (r,  acc6) = addB t1 t2 acc5
  in (r, acc6)

-- 分母を正へそろえる。qnorm の符号の側だけを写す
normQ :: Integer -> (Int, Int) -> Acc -> ((Int, Int), Acc)
normQ sw (a, b) acc0 =
  let (z,  acc1) = cstB 0 0 acc0
      (s,  acc2) = ltB sw b z acc1
      (na, acc3) = negB a acc2
      (nb, acc4) = negB b acc3
      (a2, acc5) = selB s na a acc4
      (b2, acc6) = selB s nb b acc5
  in ((a2, b2), acc6)

-- min(1, a/b)。b > 0 なので比較は分子と分母の大小になる
clamp1 :: Integer -> (Int, Int) -> Acc -> ((Int, Int), Acc)
clamp1 sw (a, b) acc0 =
  let (c,  acc1) = ltB sw b a acc0
      (o1, acc2) = cstB 1 0 acc1
      (o2, acc3) = cstB 1 0 acc2
      (a2, acc4) = selB c o1 a acc3
      (b2, acc5) = selB c o2 b acc4
  in ((a2, b2), acc5)

-- [x < y] を交差乗算で取る。分母はどちらも正
ltQ :: Integer -> (Int, Int) -> (Int, Int) -> Acc -> (Int, Acc)
ltQ sw (a1, b1) (a2, b2) acc0 =
  let (x, acc1) = mulB a1 b2 acc0
      (y, acc2) = mulB a2 b1 acc1
  in ltB sw x y acc2

-- c ⊘ a を正の分母で置く。a = 0 の側は選択で捨てるので、ここでは商が壊れてよい
divQ :: Integer -> (Int, Int) -> (Int, Int) -> Acc -> ((Int, Int), Acc)
divQ sw (an, ad) (cn, cd) acc0 =
  let (n0, acc1) = mulB cn ad acc0
      (d0, acc2) = mulB cd an acc1
  in normQ sw (n0, d0) acc2

-- residualQ a c = 1 (a = 0)、min(1, c ⊘ a)（圏論 定理 3.3）
residB :: Integer -> (Int, Int) -> (Int, Int) -> Acc -> ((Int, Int), Acc)
residB sw aa cc acc0 =
  let (r, acc1) = divQ sw aa cc acc0
      ((n2, d2), acc2) = clamp1 sw r acc1
      (z,  acc3) = eqZeroB sw (fst aa) acc2
      (o1, acc4) = cstB 1 0 acc3
      (o2, acc5) = cstB 1 0 acc4
      (n3, acc6) = selB z o1 n2 acc5
      (d3, acc7) = selB z o2 d2 acc6
  in ((n3, d3), acc7)

-- agreeResidual a c = 1 (a = c = 0)、0 (a = 0 ≠ c)、min(1, c ⊘ a)（07 §1）
agrResB :: Integer -> (Int, Int) -> (Int, Int) -> Acc -> ((Int, Int), Acc)
agrResB sw aa cc acc0 =
  let (r, acc1) = divQ sw aa cc acc0
      ((n2, d2), acc2) = clamp1 sw r acc1
      (za, acc3) = eqZeroB sw (fst aa) acc2
      (zc, acc4) = eqZeroB sw (fst cc) acc3
      (o1, acc5) = cstB 1 0 acc4
      (z0, acc6) = cstB 0 0 acc5
      (n3, acc7) = selB zc o1 z0 acc6
      (o2, acc8) = cstB 1 0 acc7
      (n4, acc9) = selB za n3 n2 acc8
      (d4, accA) = selB za o2 d2 acc9
  in ((n4, d4), accA)

-- (q ⇔ p) = ar(q,p) ⋆ ar(p,q)
agreeB :: Integer -> (Int, Int) -> (Int, Int) -> Acc -> ((Int, Int), Acc)
agreeB sw q r acc0 =
  let ((n1, d1), acc1) = agrResB sw q r acc0
      ((n2, d2), acc2) = agrResB sw r q acc1
      (n, acc3) = mulB n1 n2 acc2
      (d, acc4) = mulB d1 d2 acc3
  in ((n, d), acc4)

-- 退避語の下限。16 式 (5.10) の s = 31 をそのまま下限に採る。
-- 実際に使う語は descendWith が本文から決める
scratchWord :: Integer
scratchWord = 31

-- A < B なら既定 d が残り、そうでなければ 1 − d になる。
-- A を Nothing に取ると零の箱を A に使う（φ∂ の場合）
bitSeq :: Integer -> Maybe Int -> Int -> Integer -> Acc -> (Int, Acc)
bitSeq word mA b d acc0 = (w, acc8)
  where
    n0         = aNext acc0
    (z,  acc1) = push (BCst 0 0) acc0
    (sw, acc2) = push (BCst word 0) acc1
    (dv, acc3) = push (BCst d 0) acc2
    (_,  acc4) = push (BStore sw dv) acc3
    a          = case mA of
      Just x  -> x
      Nothing -> z
    (_,  acc5) = push (BLtBr a b (n0 + 7)) acc4
    (e,  acc6) = push (BCst (1 - d) 0) acc5
    (_,  acc7) = push (BStore sw e) acc6
    (w,  acc8) = push (BLoad sw) acc7

-- ===== 静的な席の実体化 =====
--
-- 出口境界に残った席は成分の順で Cst に開く。分岐語は無限二面体群
-- D∞ = ⟨i, j | i² = j² = e⟩ の元として二語で持つ。
--
--   i = (0,1)、 j = (1,1)
--   (m,ε)·(m',ε') = (m + (1−2ε)m', ε + ε' − 2εε')
--   |w| = |2m − ε|

dinf :: [Op] -> (Integer, Integer)
dinf = foldl step (0, 0)
  where
    step (m, e) o = case o of
      I -> (m, 1 - e)
      J -> (m + (1 - 2 * e), 1 - e)

matSlot :: Slot -> Acc -> Either String ([Int], Acc)
matSlot s acc = case s of
  W w    -> Right ([w], acc)
  QW a b -> Right ([a, b], acc)
  NW x ps -> do
    (position,acc1) <- matCoeff x acc
    let (count,acc2) = cstB (toInteger (length ps)) 0 acc1
        component (out,a) w =
          let (zero,a1) = cstB 0 0 a
              (one,a2) = cstB 1 0 a1
          in (out ++ [w,zero,zero,one],a2)
        (profile,acc3) = foldl component ([],acc2) ps
    Right (position ++ [count] ++ profile,acc3)
  JW a b ws ->
    let (m, acc1) = projectWords (\(w,_) -> fst (dinf w)) ws acc
        (e, acc2) = projectWords (\(w,_) -> snd (dinf w)) ws acc1
        (sg, acc3) = projectWords (toInteger . snd) ws acc2
    in Right ([a,b,m,e,sg], acc3)
  K v    -> matValue v acc

matValue :: Value -> Acc -> Either String ([Int], Acc)
matValue v acc0 = case v of
  VDyad (n, d) -> one n d
  VBit b       -> one (toInteger b) 0
  VRefl k      -> one (toInteger k) 0
  VMono k      -> one (toInteger k) 0
  VReference k -> one (toInteger k) 0
  VCoord (r, w, d) ->
    let (x, acc1) = cstB (toInteger r) d acc0
        (y, acc2) = cstB (toInteger w) d acc1
    in Right ([x, y], acc2)
  VRational (QRat n d) ->
    let (x, acc1) = cstB n 0 acc0
        (y, acc2) = cstB d 0 acc1
    in Right ([x, y], acc2)
  VJudge (QRat n d) ws sg ->
    let (m,e) = dinf ws in wordsValue [n,d,m,e,toInteger sg]
  VRegion es -> wordsValue (toInteger (length es) : map toInteger es)
  VChain cs -> wordsValue (toInteger (length cs) : concat
    [[toInteger n, toInteger (length vs)] ++ map toInteger vs | (n,vs) <- cs])
  VPt (UnitPoint w s c) ->
    let (m, e) = dinf w
        (p0, acc1) = cstB m 0 acc0
        (p1, acc2) = cstB e 0 acc1
        (p2, acc3) = cstB (toInteger s) 0 acc2
        (p3, acc4) = cstB (toInteger c) 0 acc3
    in Right ([p0, p1, p2, p3], acc4)
  VNoun x ps -> do
    (position,acc1) <- matCoeff x acc0
    let (count,acc2) = cstB (toInteger (length ps)) 0 acc1
        component (out,a) q = do
          (ws,a1) <- matCoeff q a
          Right (out ++ ws,a1)
    (profile,acc3) <- foldM component ([],acc2) ps
    Right (position ++ [count] ++ profile,acc3)
  where
    one n d = let (w, acc1) = cstB n d acc0 in Right ([w], acc1)
    wordsValue xs = Right (go xs [] acc0)
    go [] out acc = (reverse out, acc)
    go (x:xs) out acc = let (w, a1) = cstB x 0 acc in go xs (w:out) a1

matCoeff :: QCoeff -> Acc -> Either String ([Int],Acc)
matCoeff (QCoeff n d w s) acc =
  let (m,e) = dinf w
      (a,acc1) = cstB (toInteger n) d acc
      (b,acc2) = cstB m 0 acc1
      (c,acc3) = cstB e 0 acc2
      (sg,acc4) = cstB (toInteger s) 0 acc3
  in Right ([a,b,c,sg],acc4)

-- ===== 層を一つ降ろす =====
--
-- 層の箱は q 昇順に並んでいる。frontier の位置を左から進めながら、
-- 箱に覆われない位置はワイヤをそのまま次の層へ渡す。

-- ===== 閉包（構成語 §5.4、§5.5、§5.7）=====
--
-- 開きの層で本体の先頭箱番号と frontier を控え、閉じの層で単調フラグを一本受けて
-- 後退分岐を置く。フラグが 0 の間は本体へ戻る。
--
--   F : X ⊗ A -> A、  Ω_a[F] : X -> A                       §5.4
--   h_n ≤ h_{n+1}、   ⋁_n h_n = 1 で境界へ集積               §5.5
--   有限高さの単調反復は有限段で不動点になる                  04 定理 9.1
--
-- 状態は作業領域が持つ（Load / Store）。frontier は開きと閉じで同じでなければ
-- ならないので、繰り返しの間に持ち越す値をワイヤへ載せられない。MBox に phi が
-- 無いので、これが phi の要らない唯一の形になる。

type OmStack = [(Int, Wires)]

-- Embedded closed forms use the same atom lowering as ordinary chambers.
-- Control transfer needs its own layer-address scope and is handled separately.
descEmbedded :: Integer -> Chamber -> Wires -> Acc -> Either String (Wires, Acc)
descEmbedded sw c inputs acc
  | any control [atomPrim a | Layer es <- chLay c, (_,a) <- es] =
      Left "閉包の有限展開内に制御移動を置けない"
  | otherwise = go inputs acc (chLay c)
  where
    control p = case p of
      PEqBranch _ -> True
      PLtBranch _ -> True
      PBranch _ -> True
      POmOpen -> True
      POmClose -> True
      PLoadW -> True
      PStoreW -> True
      POkR -> True
      PKoR -> True
      PPutW -> True
      _ -> False
    go front st [] = Right (front,st)
    go front st (layer:rest) = do
      (next,(st',_)) <- descLayer sw 0 front layer (st,[])
      go next st' rest

descLayer :: Integer -> Int -> Wires -> Layer -> (Acc, OmStack)
          -> Either String (Wires, (Acc, OmStack))
descLayer sw r front (Layer xs) st0 = case xs of
  [(_, a)] | atomPrim a == POmOpen ->
    let (acc, om) = st0 in Right (front, (acc, (aNext acc, front) : om))
  [(pos, a)] | atomPrim a == POmClose -> case st0 of
    (_, [])                -> Left (at ++ "閉じに対応する開きが無い")
    (acc, (b0, saved) : om)
      | pos >= length front -> Left (at ++ "フラグのワイヤが frontier の外を指す")
      | rest /= saved       -> Left (at ++ "開きと閉じで frontier が違う（§5.7 状態型の一致）")
      | otherwise -> case drop pos front of
          (W h : _) ->
            let (z, acc1) = push (BCst 0 0) acc
                (_, acc2) = push (BEqBr h z b0) acc1
            in Right (rest, (acc2, om))
          _ -> Left (at ++ "フラグのワイヤが無い")
      where rest = take pos front ++ drop (pos + 1) front
  _ | any (isOm . snd) xs -> Left (at ++ "閉包の印は層に一つだけ置く")
    | otherwise -> go 0 [] st0 xs
  where
    at = "層 " ++ showI r ++ ": "
    isOm a = atomPrim a == POmOpen || atomPrim a == POmClose
    go cur outAcc st [] = Right (reverse outAcc ++ drop cur front, st)
    go cur outAcc (acc, om) ((pos, a) : rest)
      | pos < cur = Left (at ++ atomTag a ++ " の位置が戻っている（非正準層）")
      | otherwise =
          let skipped = take (pos - cur) (drop cur front)
              k       = length (fst (atomPorts a))
              ins     = take k (drop pos front)
          in if pos + k > length front
               then Left (at ++ atomTag a ++ " の入力が frontier を越える")
               else case descAtom sw a ins acc of
                 Left e -> Left (at ++ e)
                 Right (outs, acc') ->
                   go (pos + k) (reverse outs ++ reverse skipped ++ outAcc) (acc', om) rest

showI :: Int -> String
showI k = go (abs k) ""
  where
    go n s
      | n < 10    = digit n : s
      | otherwise = go (n `div` 10) (digit (n `mod` 10) : s)
    digit d = case drop d "0123456789" of
      (c : _) -> c
      []      -> '?'

-- ===== 文章全体の降下 =====
--
-- Γ⁻ = I なので frontier は空から始まる。最後に残った席が Γ⁺ になる。
-- 席を成分の語へ開いた番号を返すので、driver はそこを読めば値が取れる。

descend :: Integer -> Chamber -> Either String ([(Int, MBox)], [Int])
descend sw c
  | not (wellFormed c) = Left "チェンバーの型・境界が一致しない"
  | not (null (chIn c)) = Left "Γ⁻ が I でない。文章は何も受け取らずに始まる（16 §1.1）"
  | otherwise = case go 0 [] (emptyAcc, []) (chLay c) of
      Left e                   -> Left e
      Right (_, (_, _ : _))    -> Left "閉じていない閉包がある"
      Right (front, (acc, [])) -> case matAll front [] acc of
        Left e           -> Left e
        Right (out, acc') -> do
          boxes <- mapM (resolveTarget (aLayers acc')) (boxesOfAcc acc')
          Right (boxes, out)
  where
    go r front (acc,om) [] = Right (front, (acc {aLayers=IM.insert r (aNext acc) (aLayers acc)},om))
    go r front (acc,om) (l : ls) = case descLayer sw r front l
      (acc {aLayers=IM.insert r (aNext acc) (aLayers acc)},om) of
      Left e              -> Left e
      Right (front', st') -> go (r + 1) front' st' ls
    matAll [] out acc = Right (reverse out, acc)
    matAll (s : rest) out acc = case matSlot s acc of
      Left e           -> Left e
      Right (ws, acc') -> matAll rest (reverse ws ++ out) acc'

resolveTarget :: IM.IntMap Int -> (Int,MBox) -> Either String (Int,MBox)
resolveTarget layers (i,box) = case box of
  BEqBr u v t | t < 0 -> do target <- at t; Right (i,BEqBr u v target)
  BLtBr u v t | t < 0 -> do target <- at t; Right (i,BLtBr u v target)
  BBr t | t < 0 -> do target <- at t; Right (i,BBr target)
  _ -> Right (i,box)
  where at t = maybe (Left "分岐先の層が存在しない") Right (IM.lookup (negate t-1) layers)

-- 走らせる形にする。出力ワイヤを作業領域の語 0.. へ置き、成功を報告する。
-- core 意味論は停止位置で作業領域を返すので、driver はそこを読む（14 章 §4）。
--
-- 出口ワイヤの番号もそのまま返す。作業領域は分子だけを持つので（01 章、§32.2）、
-- 語を読んだだけでは深度が分からない。深度は compile 時の事実であり、
-- 読む側が Common.Core.Dyad.depthsOf でワイヤから引く
descendRunnable :: Chamber -> Either String ([(Int, MBox)], [Int])
descendRunnable c = case descendWith c of
  Left e             -> Left e
  Right (_, bs, out) -> Right (bs, out)

-- 退避語も返す。host は本文の語だけを触るので、どこが compiler の作業語かを
-- 知る必要がある
descendWith :: Chamber -> Either String (Integer, [(Int, MBox)], [Int])
descendWith c = case descend scratchWord c of
  Left e -> Left e
  Right (bs, out) ->
    let s = chooseScratch bs (length out) in
    case descend s c of
      Left e            -> Left e
      Right (bs', out') ->
        let acc0 = Acc (reverse (map snd bs')) (length bs') (depthTable bs') IM.empty
            acc1 = storeAll acc0 0 out'
            (_, acc2) = push BOk acc1
        in Right (s, boxesOfAcc acc2, out')
  where
    storeAll acc _ [] = acc
    storeAll acc i (w : ws) =
      let (a2, acc1) = push (BCst (toInteger i) 0) acc
          (_,  acc2) = push (BStore a2 w) acc1
      in storeAll acc2 (i + 1) ws

depthTable :: [(Int, MBox)] -> IM.IntMap Int
depthTable = foldl step IM.empty
  where step tbl (i, b) = IM.insert i (depthOfBox tbl b) tbl

-- ===== 退避語の選び方（16 §5.3）=====
--
-- 二値の八箱は既定値を語へ退避する。16 式 (5.10) は s = 31 を 13 §4 の走査区間から
-- 取っているが、その区間は compiler 自身の割付であって平文の予約ではない。
-- 平文は語 0 から出力を積み、host も低い語を使う（common_os/04 §4）。
-- だから退避語は本文の上へ置く。
--
--   S = 1 + max( 31, |Γ⁺| − 1, { 定数から畳める Load / Store の番地 } )
--
-- 一段目の降下は S を決めるためだけに走らせる。退避語は本文の番地へ流れないので、
-- 二段目の番地は一段目と同じになる。ワイヤの値から来る番地は畳めないので、
-- そこは書き手の責任として残る。

constFold :: [(Int, MBox)] -> [Maybe Integer]
constFold bs = vals
  where
    vals = map (val . snd) bs
    at i = case drop i vals of
      (v : _) -> v
      []      -> Nothing
    val (BCst x 0) = Just x
    val (BAdd u v) = both (+) (at u) (at v)
    val (BMul u v) = both (*) (at u) (at v)
    val (BNeg u)   = case at u of
      Just x  -> Just (negate x)
      Nothing -> Nothing
    val _          = Nothing
    both f (Just x) (Just y) = Just (f x y)
    both _ _       _         = Nothing

-- 定数から畳める番地だけを集める。八箱と liftQ が自分で置く退避語は数えない
knownAddrs :: [(Int, MBox)] -> [Integer]
knownAddrs bs = go (map snd bs)
  where
    boxes = map snd bs
    vals  = constFold bs
    at i = case drop i vals of
      (v : _) -> v
      []      -> Nothing
    ours i = case drop i boxes of
      (BCst x 0 : _) -> x == scratchWord
      _              -> False
    go []         = []
    go (b : rest) = case b of
      BLoad a    -> step a rest
      BStore a _ -> step a rest
      _          -> go rest
    step a rest
      | ours a    = go rest
      | otherwise = case at a of
          Just x  -> x : go rest
          Nothing -> go rest

chooseScratch :: [(Int, MBox)] -> Int -> Integer
chooseScratch bs nOut =
  1 + foldr max (toInteger nOut - 1) (scratchWord : knownAddrs bs)

-- 生成元が降下できるかを表を写さずに判定するための席。型ごとに根の値を置く
probeSlots :: Atom -> Wires
probeSlots a = map slotOf (fst (atomPorts a))
  where
    slotOf q = case q of
      PtUnit  -> K (VPt (UnitPoint [] 1 1))
      PtCoord -> K (VCoord (0, 0, 0))
      PtRefl  -> K (VRefl 0)
      PNoun   -> K (VNoun (QCoeff 1 0 [] 1) [])
      PJudge  -> K (VJudge (QRat 1 1) [] 1)
      _       -> W 0

-- ===== 定理 5.1 の検査 =====
--
--   [[C_P]]_chamber = pi_{Gamma+} ( [[Desc(C_P)]]_C )            式 (5.3)
--
-- 左辺は evalChamber、右辺は core 意味論で走らせた後の作業領域になる。
-- 二つの実装が独立していることが検査の値打ちなので、ここでは片方の結果を
-- もう片方から作らない。

-- 作業領域から出力境界を読む。語が持つのは分子だけなので、深度は呼び出し側が
-- 出口ワイヤから引いて渡す（01 章、§32.2）
worksOf :: [Int] -> [(Integer, (Integer, Int))] -> [(Integer, Int)]
worksOf ds work = [ (num (toInteger i), d) | (i, d) <- zip [0 :: Int ..] ds ]
  where
    num i = case lookup i work of
      Just (v, _) -> v
      Nothing     -> 0

-- チェンバーの値を同じ形へそろえる
dyadsOf :: [Value] -> Maybe [(Integer, Int)]
dyadsOf vs = go vs []
  where
    go [] acc = Just (reverse acc)
    go (VDyad d : rest) acc = go rest (d : acc)
    go _ _ = Nothing
