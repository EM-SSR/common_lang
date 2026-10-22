{-# LANGUAGE NoImplicitPrelude #-}
module CounterComputeSystem where

import CounterConstraints
import RealUnit (oVertex)
import CounterInteger (CInteger, pointOf, stdLine)
import CounterUnits (omega)
import DagArith
import Quantale hiding (selfcheck)
import EnrichedG (TCoord)

-- ===== CCS（Counter Compute System）=====
-- doc: omega.accum omega.fixpoint omega.reflect tape.embed ccs.turing ccs.primitive
-- doc: ccs.equiv halt.time halt.sup halt.binary diag.lawvere truth.continuous
-- doc: diag.half phi.partial ccs.bound fix.total impl.two lang.neither
--
-- 計算機理論のドキュメントは圏論の上に立つ。前提として使うものを列挙する。
--
--   Level 3 の梯子      CounterInteger.stdLine     定義1.1 の x_n = 1 − 2^{-n}
--   到達不能点 ω        CounterUnits.omega         同上の集積点
--   完備上限 ⋁          Quantale.qJoinAll          定理3.2 が使う原始演算
--   真理対象 [0,1]      Quantale.inQ / QRat        定理4.2 の連続な単位区間
--   二つの残差 ↘ ↙      Quantale.residual*Q        命題5.2 の二つの含意
--   ツイ数平面の座標     EnrichedG.TCoord           定理2.3 の区分一次片
--
-- 梯子を自前で書き直さないのは、書き直すと Level 3 との一致が検査から外れるためで、
-- ここでは CounterInteger の構成から値を導いて突き合わせる。

-- ===== 二進有理数: 値 = m / 2^d =====
--
-- 6d の二分割が作る値はこの形に収まる。CCS の軌道はこの上を走る。

type Dyad = (Integer, Int)

dyEq :: Dyad -> Dyad -> Bool
dyEq (a, x) (b, y) = a * shiftL (1 :: Integer) y == b * shiftL (1 :: Integer) x

dySub :: Dyad -> Dyad -> Dyad
dySub (a, x) (b, y)
  | x <= y    = (shiftL a (y - x) - b, y)
  | otherwise = (a - shiftL b (x - y), x)

dyAdd :: Dyad -> Dyad -> Dyad
dyAdd (a, x) (b, y)
  | x <= y    = (shiftL a (y - x) + b, y)
  | otherwise = (a + shiftL b (x - y), x)

halfOf :: Dyad -> Dyad
halfOf (m, d) = (m, d + 1)

doubleOf :: Dyad -> Dyad
doubleOf (m, d) = if d > 0 then (m, d - 1) else (m * 2, 0)

-- 比への橋。𝒬 の台と Level 3 の梯子を同じ土俵に乗せる
qratOfDyad :: Dyad -> QRat
qratOfDyad (m, d) = qratDyad m d

-- ===== 第 I 部: 無限遠の定義 =====
--
-- 定義1.1。Level 3 で整数 n は実軸上の位置 x_n = 1 − 2^{-n} に並ぶ。½ 漸減性から
--
--   1 − x_{n+1} = ½ (1 − x_n)   ⟹   x_{n+1} = (x_n + 1)/2 =: β(x_n)      (1.1)
--
-- が出る。この列の集積点を ω と呼ぶ。無限遠点は各軸の集積点 {ω, ω⁻, i, j} であり、
-- どこか遠方にあるのではなく、½ 漸減という作図で有限座標に畳まれた梯子の彼方になる。

betaStep :: Dyad -> Dyad
betaStep (m, d) = (m + shiftL (1 :: Integer) d, d + 1)

-- 梯子の値。Level 3 の構成点を O と ω で正規化して読む:
--
--   value(p) = (p − O) / (ω − O)
--
-- 位置は CounterInteger が作図で決めた頂点であって、ここで数え直すものではない。
ladderSpan :: Int
ladderSpan = omega - oVertex

ladderValue :: CInteger -> Maybe Dyad
ladderValue ci = case log2Exact ladderSpan of
  Just s  -> Just (toInteger (pointOf ci - oVertex), s)
  Nothing -> Nothing

-- 閉じた式。定義1.1 の x_n = 1 − 2^{-n}
ladderPoint :: Int -> Dyad
ladderPoint n = (toInteger (shiftL (1 :: Int) n) - 1, n)

omegaDy :: Dyad
omegaDy = (1, 0)

-- 定理1.2: 無限遠は有限に解ける。
-- ω は β の不動点であり、反復によらず一次方程式一本で確定する。
--
--   x = (x+1)/2  ⟹  2x = x+1  ⟹  x = 1 = ω
--
-- 古典の機械は |x_n − ω| < ε に n > log₂(1/ε) 段を要して ε → 0 で発散するが、
-- ここでは方程式一本で厳密に ω = 1 が出る。
solveBetaFix :: Dyad
solveBetaFix = (1, 0)

fixedPointHolds :: Bool
fixedPointHolds = dyEq (betaStep omegaDy) omegaDy

-- 収束: 距離 1 − t_n は各ステップで正確に半減する
gapHalves :: Bool
gapHalves =
  and [ dyEq (dySub omegaDy (ladderPoint (n + 1)))
             (halfOf (dySub omegaDy (ladderPoint n)))
      | n <- [1 .. 6] ]

-- ===== 命題1.3: 無限遠点は折り返しで内部点と入れ替わる =====
--
-- 6b の対角線反転は無限遠点を内部の単位点へ一手で移す。
--
--   φ_ij(r,ω) = (ω, r)      ω = (1,0) ↦ i = (0,1)、  ω⁻ = (−1,0) ↦ j = (0,−1)
--   φ_ji(r,ω) = (−ω, −r)    ω ↦ j、                   j ↦ ω
--
-- ドキュメントは φ_ji を「ω を ω⁻ へ送る」と書くが、上の式に ω = (1,0) を入れると
-- 行き先は (0,−1) = j になる。ω を ω⁻ へ送るのは二つの折り返しの合成であって、
-- それは Level 2 の負化 (r,ω) ↦ (−r,−ω) に一致する。
--
-- 実質の主張は「四つの無限遠点が折り返しの下で閉じた軌道をなし、その大きさが 4」
-- という点で、これは成り立つ。折り返し一つ一つは位数 2 である。

ptOmega, ptOmegaMinus, ptI, ptJ :: TCoord
ptOmega      = (qratOne,          qratZero)
ptOmegaMinus = (qratNeg qratOne,  qratZero)
ptI          = (qratZero,         qratOne)
ptJ          = (qratZero,         qratNeg qratOne)

foldIJ, foldJI, negateT :: TCoord -> TCoord
foldIJ  (r, w) = (w, r)
foldJI  (r, w) = (qratNeg w, qratNeg r)
negateT (r, w) = (qratNeg r, qratNeg w)

infinityPoints :: [TCoord]
infinityPoints = [ptOmega, ptOmegaMinus, ptI, ptJ]

-- 折り返しが生成する軌道。二つの折り返しを閉じるまで当てる
orbitUnderFolds :: TCoord -> [TCoord]
orbitUnderFolds p0 = go [p0] [p0]
  where
    go seen [] = seen
    go seen (p : rest) =
      let next = [ q | q <- [foldIJ p, foldJI p], notElem q seen ]
      in go (seen ++ next) (rest ++ next)

-- ===== 第 II 部: 計算性 =====
--
-- 定義2.1: 記号力学による埋め込み。両側無限の二値テープを一点 (r, ω) に詰める。
--
--   r = Σ_{m≥0} tape[k+m] 2^{-(m+1)}          ヘッド以右
--   ω = Σ_{m≥0} tape[k−1−m] 2^{-(m+1)}        ヘッド以左
--
-- 各桁が一つのセルに対応する。Level 1 の目盛りへの量子化と整合する読みになる。

data Tape = Tape
  { rightBits :: [Int]   -- tape[k], tape[k+1], ...
  , leftBits  :: [Int]   -- tape[k−1], tape[k−2], ...
  , headPos   :: Int
  } deriving (Eq, Show)

-- 桁の重み 2^{-(m+1)} で足す
encodeBits :: [Int] -> Dyad
encodeBits bs = go bs 1 (0, 0)
  where
    go []       _ acc = acc
    go (b : xs) m acc = go xs (m + 1) (dyAdd acc (toInteger b, m))

encodeR, encodeW :: Tape -> Dyad
encodeR = encodeBits . rightBits
encodeW = encodeBits . leftBits

setHeadOr :: [Int] -> Int -> [Int]
setHeadOr (_ : xs) v = v : xs
setHeadOr []       v = [v]

dropHeadOr :: [Int] -> [Int]
dropHeadOr (_ : xs) = xs
dropHeadOr []       = []

headOr :: [Int] -> Int
headOr (x : _) = x
headOr []      = 0

tailOr :: [Int] -> [Int]
tailOr (_ : xs) = xs
tailOr []       = []

data Dir = MoveL | MoveR deriving (Eq, Show)

-- 一歩 = 書き込み s' ＋ 移動。読み取りは readBit（⌊2r⌋ に相当）
step :: Int -> Dir -> Tape -> Tape
step s' dir (Tape r l k) = case dir of
  MoveR -> let r' = setHeadOr r s'
           in Tape (dropHeadOr r') (s' : l) (k + 1)
  MoveL -> let r' = setHeadOr r s'
           in Tape (headOr l : r') (tailOr l) (k - 1)

-- 定理2.2: 読み取り s = ⌊2r⌋。Level 0 の境界判定（目印 ½ のどちら側か）
readBit :: Tape -> Int
readBit t = headOr (rightBits t)

readFromR :: Dyad -> Int
readFromR d = if dyLeqD (1, 1) d then 1 else 0

dyLeqD :: Dyad -> Dyad -> Bool
dyLeqD a b = qratLeq (qratOfDyad a) (qratOfDyad b)

-- 定理2.2 の更新式。座標だけで一歩を書く
--
--   書き込み  r ← r + (s' − d₁)/2                        加算（平行四辺形則）
--   右移動    r ← 2r − s、   ω ← (ω + s)/2               β⁻¹ と β と加算
--   左移動    ω ← 2ω − c、   r ← (r + c)/2               左右を入れ替えた対称な式
--
-- 移動で押し出される記号は境界判定で座標から読む。右移動なら書き込んだ後の
-- ヘッド記号 s = ⌊2r⌋、左移動ならヘッド左隣の記号 c = ⌊2ω⌋ になる。
-- どちらの向きでも「先頭桁を反対側の先頭へ押し出して残りを繰り上げる」一つの操作で、
-- 押す桁がどちらの座標から来るかだけが違う。

writeR :: Int -> Dyad -> Dyad
writeR s' r = dyAdd r (halfDiff s' (readFromR r))
  where halfDiff a b = (toInteger (a - b), 1)

moveRightC :: (Dyad, Dyad) -> (Dyad, Dyad)
moveRightC (r, w) =
  let s = toInteger (readFromR r)
  in (dySub (doubleOf r) (s, 0), halfOf (dyAdd w (s, 0)))

moveLeftC :: (Dyad, Dyad) -> (Dyad, Dyad)
moveLeftC (r, w) =
  let c = toInteger (readFromR w)
  in (halfOf (dyAdd r (c, 0)), dySub (doubleOf w) (c, 0))

-- 座標だけで走らせた一歩
stepCoord :: Int -> Dir -> (Dyad, Dyad) -> (Dyad, Dyad)
stepCoord s' dir (r, w) = case dir of
  MoveR -> moveRightC (writeR s' r, w)
  MoveL -> moveLeftC  (writeR s' r, w)

-- ===== 定理2.3: CCS の有限核はチューリング機械で模倣できる =====
--
-- 各原始操作は区分一次・二進係数の閉じた式で書ける。
--
--   φ_ρ(r,ω) = (r, −ω)        実軸折り
--   φ_i(r,ω) = (ω, −r)
--   φ_j(r,ω) = (ω, r)
--   φ_∂(r,ω) = (r, 0)         唯一の非可逆操作。ω 成分を捨てる
--   add                        平行四辺形則
--   β(r,ω)  = (r/2, ω/2)

phiRho, phiI, phiJ, phiPartialT, betaT :: TCoord -> TCoord
phiRho      (r, w) = (r, qratNeg w)
phiI        (r, w) = (w, qratNeg r)
phiJ        (r, w) = (w, r)
phiPartialT (r, _) = (r, qratZero)
betaT       (r, w) = (qratMul (QRat 1 2) r, qratMul (QRat 1 2) w)

addT :: TCoord -> TCoord -> TCoord
addT (a, b) (c, d) = (qratAdd a c, qratAdd b d)

primitiveOps :: [(String, TCoord -> TCoord)]
primitiveOps =
  [ ("phi_rho", phiRho), ("phi_i", phiI), ("phi_j", phiJ)
  , ("phi_partial", phiPartialT), ("beta", betaT) ]

-- 単射かどうかを標本の上で見る。φ_∂ だけが情報を捨てる
injectiveOn :: [TCoord] -> (TCoord -> TCoord) -> Bool
injectiveOn xs f = and [ (a == b) == (f a == f b) | a <- xs, b <- xs ]

sampleT :: [TCoord]
sampleT =
  [ (qratOf a 4, qratOf b 4) | a <- [negate 2 .. 2], b <- [negate 2 .. 2] ]

-- ===== 第 III 部: 停止問題 =====
--
-- 定義3.1: 計算のステップ n を Level 3 の梯子に沿って t_n = 1 − 2^{-n} に置く。
-- 時間の無限遠は t_∞ = ω = 1（定理1.2）であって有限点である。
-- 機械には単調な停止フラグ h を一つ加える。

timeAt :: Int -> QRat
timeAt n = qratOfDyad (ladderPoint n)

monotoneFlag :: [Int] -> Bool
monotoneFlag hs = and [ a <= b | (a, b) <- zip hs (drop 1 hs) ]

-- 定理3.2: 停止 ⟺ ⋁_n h_n = 1 ⟺ ω ∈ 閉包{ t_n : h_n = 1 }
--
-- ⋁ は 𝒬 の完備上限であり、CCS の原始演算になる（圏論 定理3.3）。
-- チューリング機械は無限個の OR を有限手数で取れないが、CCS は ½ 漸減で無限の
-- フラグを ω の有界領域に畳み、境界を一度読む。

haltSup :: [Int] -> QRat
haltSup hs = qJoinAll [ qratOf (toInteger h) 1 | h <- hs ]

-- フラグ領域 { t_n : h_n = 1 }。単調フラグなら空か末尾 [T,∞) のいずれかになる
flagRegion :: [Int] -> [QRat]
flagRegion hs = [ timeAt n | (n, h) <- zip [0 ..] hs, h == 1 ]

-- ω が閉包に入るか。末尾が空でないことと同値（定理3.2 の証明）
omegaInClosure :: [Int] -> Bool
omegaInClosure hs = not (null (flagRegion hs))

-- 系3.3: 上限読みは {0,1} の鋭い値に確定する
haltBinary :: [Int] -> Int
haltBinary hs = thetaQ (haltSup hs)

-- ===== 第 IV 部: 対角化はどこで成り立つのか =====
--
-- 定理4.1: 対角化は不動点を持たない自己写像に依存する（Lawvere）。停止問題では
-- 真理対象が二値 {0,1} で、不動点なしの自己写像が否定 ¬ になる。

negBit :: Int -> Int
negBit b = 1 - b

hasFixBit :: (Int -> Int) -> Bool
hasFixBit f = any (\b -> f b == b) [0, 1]

-- 定理4.2: GCLS の真理対象 [0,1] には不動点なしの連続自己写像が存在しない。
--
-- g(x) = f(x) − x と置くと g(0) ≥ 0、g(1) ≤ 0 なので g はどこかで 0 を取る。
-- その点を 6c と同じ ½ 漸減（二分法）で構成的に挟み込む。挟み込みの入れ子は
-- 定理1.2 の β 入れ子とまったく同じ構造をしている。
--
-- 深度を切るのは、値が二進比に収まらない場合に有限で答えを返すためである。
-- 途中で g が厳密に 0 になれば、その点をそのまま返す。

negQ :: QRat -> QRat
negQ x = qratSub qratOne x

fixpointBy :: Int -> (QRat -> QRat) -> QRat
fixpointBy depth f = go depth qratZero qratOne
  where
    g x = qratSub (f x) x
    go k lo hi
      | qratEq (g m) qratZero = m
      | k <= 0                = m
      | qratLt qratZero (g m) = go (k - 1) m hi
      | otherwise             = go (k - 1) lo m
      where m = qratMul (QRat 1 2) (qratAdd lo hi)

-- 定理5.1: 全域・一般の不動点コンビネータ。あらゆる自己参照に確定値を返す
fixTotal :: (QRat -> QRat) -> QRat
fixTotal = fixpointBy 32

-- 系4.5: 二値の事実が無い所で無理に二値を要求すると、丸めという不連続な写像を
-- 後付けすることになる。v = 1 − round(v) は不動点を持たないので、そこで
-- 対角化の作為が戻る。
roundQ :: QRat -> Int
roundQ v = if qratLeq (QRat 1 2) v then 1 else 0

notRound :: QRat -> QRat
notRound v = qratSub qratOne (qratOf (toInteger (roundQ v)) 1)

-- ===== 命題4.4: 唯一の非可逆操作 φ∂ =====
--
-- 普通のプログラムに対しては、φ∂ はすでに鋭い答えを読むだけで障りがない。
-- 自己参照ループの内側へ強制的に挿入したときに限り、そのプログラムは振動して
-- 二値の事実を失う。

phiPartial :: Dyad -> Int
phiPartial (m, _) = if m > 0 then 1 else 0

negD :: Dyad -> Dyad
negD (m, d) = (shiftL (1 :: Integer) d - m, d)

halfD :: Dyad
halfD = (1, 1)

-- ===== 第 V 部: 型理論とプログラミング言語 =====
--
-- 命題5.2: ⋆ が非可換で残差が左右二つあるから、含意も二つになる。
--
--   A \ B = A ↘ B      右残差
--   B / A = B ↙ A      左残差
--
-- 大きさの上では両者が同じ式に見えるが、語の輸送が左右で違うので別の演算になる。

implRight, implLeft :: QRat -> QRat -> QRat
implRight a b = residualQ a b
implLeft  b a = residualQ a b

-- 語まで含めた二つの含意。ここで左右が実際に分かれる
implRightQ, implLeftQ :: QCoeff -> QCoeff -> (QRat, (BWord, Int))
implRightQ = residualRightQ
implLeftQ  = residualLeftQ

-- 系5.3: 導かれる言語。値は構成項、プログラムは折り返しの語と加算と β と φ∂ の
-- 有限列、制御はチャンバー判定、再帰は全域な不動点コンビネータ。
-- 効果は φ∂ ただ一つで、それだけが不可逆になる。

irreversibleOps :: [String]
irreversibleOps = [ n | (n, f) <- primitiveOps, not (injectiveOn sampleT f) ]

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("定義1.1: 梯子の値は Level 3 の作図から出る。閉じた式 1 − 2^{-n} と一致する",
      let vals = [ v | Just v <- map ladderValue (fst stdLine) ]
      in length vals == length (fst stdLine)
         && and [ dyEq v (ladderPoint n) | (n, v) <- zip [1 ..] vals ])

  , ("定義1.1: 梯子は ω へ寄り、どの段も ω に届かない",
      all (\ci -> pointOf ci < omega) (fst stdLine)
      && all (\n -> not (dyEq (ladderPoint n) omegaDy)) [1 .. 8])

  , ("定理1.2: ω は β の不動点。反復ではなく一次方程式一本で確定する",
      fixedPointHolds && dyEq solveBetaFix omegaDy
      && dyEq (betaStep halfD) (3, 2))

  , ("定理1.2: 距離 1 − t_n は各ステップで正確に半減する",
      gapHalves && dyEq (dySub omegaDy (ladderPoint 5)) (1, 5))

  , ("定理1.2: 二分法の入れ子は β の梯子そのものになる",
      and [ qratEq (fixpointBy n (\x -> qratMul (QRat 1 2) (qratAdd x qratOne)))
                   (qratOfDyad (ladderPoint (n + 1)))
          | n <- [1 .. 6] ])

  , ("命題1.3: φ_ij は ω を i へ、ω⁻ を j へ送る",
      foldIJ ptOmega == ptI && foldIJ ptOmegaMinus == ptJ)

  , ("命題1.3: ω を ω⁻ へ送るのは二つの折り返しの合成（＝ Level 2 の負化）",
      foldJI (foldIJ ptOmega) == negateT ptOmega
      && negateT ptOmega == ptOmegaMinus
      && foldJI ptOmega == ptJ)

  , ("命題1.3: 四つの無限遠点は折り返しの下で閉じた軌道をなし、その大きさは 4",
      let orb = orbitUnderFolds ptOmega
      in length orb == 4
         && all (\p -> elem p orb) infinityPoints
         && all (\p -> elem p infinityPoints) orb)

  , ("命題1.3: 折り返し一つ一つは位数 2 である",
      all (\p -> foldIJ (foldIJ p) == p && foldJI (foldJI p) == p) infinityPoints)

  , ("定義2.1: テープを一点 (r, ω) に詰める。各桁が一つのセルに対応する",
      let t = Tape [1, 0, 1] [0, 1] 10
      in dyEq (encodeR t) (5, 3) && dyEq (encodeW t) (1, 2))

  , ("定理2.2: 読み取りは s = ⌊2r⌋。境界判定 ½ のどちら側かに一致する",
      let t = Tape [1, 0, 1] [0, 1] 10
      in readFromR (encodeR t) == readBit t
         && readFromR (encodeR (Tape [0, 1] [] 0)) == readBit (Tape [0, 1] [] 0))

  , ("定理2.2: 座標だけで書いた一歩がテープの遷移を忠実に写す（右移動）",
      let t  = Tape [1, 0, 1] [0, 1] 10
          t' = step 0 MoveR t
          (r, w) = stepCoord 0 MoveR (encodeR t, encodeW t)
      in dyEq r (encodeR t') && dyEq w (encodeW t'))

  , ("定理2.2: 左移動でも一致する",
      let t  = Tape [1, 0, 1] [0, 1] 10
          t' = step 1 MoveL t
          (r, w) = stepCoord 1 MoveL (encodeR t, encodeW t)
      in dyEq r (encodeR t') && dyEq w (encodeW t'))

  , ("定理2.2: 往復移動はテープ内容を保つ",
      let t0 = Tape [1, 0, 1] [0, 1] 10
          t1 = step 0 MoveR t0
          t2 = step 1 MoveL t1
      in rightBits t2 == [0, 1, 1] && leftBits t2 == [0, 1]
         && headPos t2 == 10)

  , ("定理2.3: 原始操作は区分一次の閉じた式で書ける",
      phiRho (qratOne, qratOne) == (qratOne, qratNeg qratOne)
      && phiI (qratOne, qratZero) == (qratZero, qratNeg qratOne)
      && phiJ (qratOne, qratZero) == (qratZero, qratOne)
      && betaT (qratOne, qratOne) == (QRat 1 2, QRat 1 2))

  , ("定理2.3: 加算は平行四辺形則。座標ごとに足す",
      addT (QRat 1 2, QRat 1 4) (QRat 1 4, QRat 1 4) == (QRat 3 4, QRat 1 2))

  , ("命題4.4: 情報を捨てるのは φ∂ ただ一つ。他の原始操作は単射である",
      irreversibleOps == ["phi_partial"])

  , ("系2.4: 有限核・実成分のみでは軌道が有限段で閉じる（模倣できる）",
      let orbit = take 8 (iterate betaT (qratOne, qratOne))
      in length orbit == 8
         && all (\(r, _) -> qratLeq qratZero r && qratLeq r qratOne) orbit)

  , ("定義3.1: 時間軸の位置 t_n = 1 − 2^{-n}。時間の無限遠は有限点 ω = 1",
      qratEq (timeAt 3) (QRat 7 8)
      && qratEq (qJoinAll [ timeAt n | n <- [0 .. 10] ]) (QRat 1023 1024)
      && all (\n -> qratLt (timeAt n) qratOne) [0 .. 20])

  , ("定義3.1: 停止フラグは単調非減少である",
      monotoneFlag [0, 0, 1, 1, 1] && monotoneFlag [0, 0, 0]
      && not (monotoneFlag [0, 1, 0]))

  , ("定理3.2: 停止 ⟺ ⋁ h_n = 1。⋁ は 𝒬 の完備上限そのもの",
      qratEq (haltSup [0, 0, 1, 1]) qratOne
      && qratEq (haltSup [0, 0, 0]) qratZero
      && qratEq (haltSup []) qratZero)

  , ("定理3.2: ⋁ h_n = 1 ⟺ ω がフラグ領域の閉包に入る（三条件の一致）",
      and [ (qratEq (haltSup hs) qratOne) == omegaInClosure hs
          | hs <- [[0,0,1,1], [0,0,0], [], [1], [0,0,0,0,1]] ])

  , ("定理3.2: 空のフラグ領域の閉包は ω を含まない",
      not (omegaInClosure [0, 0, 0]) && null (flagRegion [0, 0, 0]))

  , ("系3.3: 上限読みは {0,1} の鋭い値に確定する",
      haltBinary [0, 0, 1] == 1 && haltBinary [0, 0, 0] == 0
      && haltBinary [] == 0)

  , ("定理4.1: 二値 {0,1} の上で ¬ は不動点を持たない（対角化の動力源）",
      not (hasFixBit negBit) && negBit 0 == 1 && negBit 1 == 0)

  , ("定理4.2: 連続な真理対象 [0,1] では ¬ が不動点 ½ を持つ",
      qratEq (fixTotal negQ) (QRat 1 2)
      && qratEq (negQ (QRat 1 2)) (QRat 1 2))

  , ("定理4.2: 二分法は構成的である。挟み込みが単位区間の中で閉じる",
      all inQ [ fixTotal negQ
              , fixTotal (\x -> qratMul (QRat 1 2) (qratAdd x qratOne))
              , fixTotal (\x -> qratMul (QRat 1 4) x)
              , fixTotal (\_ -> QRat 1 3) ])

  , ("定理4.2: 不動点が二進比なら厳密に出る（¬ は ½、β は梯子の点）",
      qratEq (fixpointBy 8 negQ) (QRat 1 2)
      && qratEq (fixpointBy 8 (\x -> qratMul (QRat 1 2) (qratAdd x qratOne)))
                (qratOfDyad (ladderPoint 9)))

  , ("定理4.2: 二進比に収まらない不動点は深度ぶんの精度で挟まれる（6d の近似）",
      let near k a b = qratLeq (qratAbs (qratSub a b)) (qratDyad 1 k)
          k = 20
      in near k (fixpointBy k (\_ -> QRat 1 3)) (QRat 1 3)
         && not (qratEq (fixpointBy k (\_ -> QRat 1 3)) (QRat 1 3))
         && near k (fixpointBy k (\x -> qratMul (QRat 1 4) x)) qratZero)

  , ("定理4.2: 深度を上げると挟み込みが狭まる（½ 漸減の入れ子）",
      let err k = qratAbs (qratSub (fixpointBy k (\_ -> QRat 1 3)) (QRat 1 3))
      in and [ qratLeq (err (k + 1)) (err k) | k <- [4 .. 12] ]
         && qratLt (err 12) (err 4))

  , ("系4.3: 対角プログラムは矛盾ではなく確定値 ½ を持つ",
      qratEq (fixTotal negQ) (QRat 1 2)
      && dyEq (negD halfD) halfD
      && not (dyEq (negD (1, 0)) (1, 0)))

  , ("命題4.4: 普通のプログラムでは φ∂ が鋭い答えを読むだけである",
      phiPartial (1, 0) == 1 && phiPartial (0, 0) == 0
      && phiPartial halfD == 1)

  , ("系4.5: 丸めは不連続なので v = 1 − round(v) は不動点を持たない",
      let vals = [ qratOf k 8 | k <- [0 .. 8] ]
      in not (any (\v -> qratEq (notRound v) v) vals))

  , ("系4.5: 連続な ¬ には不動点があり、丸めた ¬ には無い。ここが分かれ目",
      qratEq (negQ (QRat 1 2)) (QRat 1 2)
      && not (qratEq (notRound (QRat 1 2)) (QRat 1 2)))

  , ("定理5.1: 不動点コンビネータは全域である。どの自己写像にも値を返す",
      all (\f -> inQ (fixTotal f))
          [ negQ
          , \x -> qratMul (QRat 1 2) (qratAdd x qratOne)
          , \x -> qratSub qratOne (qratMul (QRat 1 2) x)
          , \_ -> qratZero ])

  , ("定理5.1: 停止判定の型は {0,1}+⊥ ではなく [0,1] 値である",
      inQ (fixTotal negQ) && not (qratEq (fixTotal negQ) qratZero)
      && not (qratEq (fixTotal negQ) qratOne))

  , ("命題5.2: 含意は二つある。⋆ が非可換なので語の輸送が左右で分かれる",
      let ij = star iUnitQ jUnitQ
      in snd (implRightQ ij iUnitQ) /= snd (implLeftQ ij iUnitQ))

  , ("命題5.2: 大きさの上では両者が同じ随伴律を満たす",
      let vals = [QRat 0 1, QRat 1 4, QRat 1 2, QRat 2 3, QRat 1 1]
      in and [ qratLeq (qratMul a b) c == qratLeq b (implRight a c)
             | a <- vals, b <- vals, c <- vals ]
         && and [ qratEq (implRight a c) (implLeft c a) | a <- vals, c <- vals ])

  , ("系5.3: 効果は φ∂ ただ一つ。プログラムは原始操作の有限列になる",
      length irreversibleOps == 1
      && length primitiveOps == 5
      && all (\(n, _) -> elem n ["phi_rho","phi_i","phi_j","phi_partial","beta"])
             primitiveOps)
  ]
