{-# LANGUAGE NoImplicitPrelude #-}
module ConstructCalculus where

import CounterConstraints
import CounterUnits (Op (..))
import DagArith
import Quantale hiding (selfcheck)
import EnrichedG hiding (selfcheck)

-- ===== 構成計算 𝒞 と有向ストリング図（圏論 第IV部）=====
-- doc: calc.C coord.unfaithful string.diagram fig.compose fig.ij_ne_ji no.braiding
--
--   定義4.1  構成計算 𝒞
--   定理4.2  座標写像は忠実でない
--   定義4.3  有向ストリング図の標準的記法
--   図4.A    合成律 (2.1)
--   図4.B    ij ≠ ji
--   図4.C    簡約 i² = −1、j² = +1
--   図4.D    Eckmann–Hilton の不成立（交差の不在）
--
-- 第IV部の主題は「座標は加算的な最終値しか運ばない。忠実な記述は構成の順序を
-- 保持する有向ストリング図である」という一点になる。だから座標写像を先に作り、
-- それが忠実でないことを示してから、図の側を立てる。

-- ===== 定義4.1: 構成計算 𝒞 =====
--
-- 生成元
--
--   Σ = { 1, ρ（実軸境界操作）, i（ω 境界操作）, j（ω⁻ 境界操作）, β（6d 二分割）}
--
-- 上の自由モノイドを、幾何的実現可能性で割った商が 𝒞 である。関係は等式ではなく
-- 有向の書き換え規則になる。
--
--   i i ⇒ ρ⁻¹      (i² = −1)
--   j j ⇒ ρ⁺¹      (j² = +1)
--   i j ⇏ j i
--
-- 最後の非合流性——ij と ji が別の正規形を持つこと——が 𝒞 の核心であり、
-- 「経路を忘れない」という原理を構文の側で述べたものになる。

data Gen
  = GUnit          -- 1
  | GRho Int       -- ρ^{±1}。実軸境界操作。指数は +1 か −1
  | GI             -- ω 境界操作
  | GJ             -- ω⁻ 境界操作
  | GBeta          -- 6d 二分割
  deriving (Eq, Ord, Read, Show)

type Term = [Gen]

-- 書き換えの一歩。左から見て最初に当たる規則を一つだけ適用する。
--
-- ρ の指数は行き先の半平面を指す。図4.C のとおり ρ⁺¹ は H⁺ へ戻る操作、
-- つまり実軸上の +1 であり単位元になる。ρ⁻¹ が H⁻ へ送る操作、つまり −1 になる。
-- したがって指数は {+1, −1} の乗法群であって、加法ではない。
--
--   1 は消える            単位元
--   ρ⁺¹ も消える          +1 は実軸上の単位元
--   ρ^a ρ^b ⇒ ρ^{ab}     符号の合成
--   i i ⇒ ρ⁻¹            i² = −1
--   j j ⇒ ρ⁺¹            j² = +1。続けて単位として消える
--
-- ρ は実軸上の量なので i / j / β を越えて前へ寄せる。これは 3章 の
-- 「実スケールはタレス構成で分配される」に対応する。
stepRW :: Term -> Maybe Term
stepRW t = case t of
  (GUnit : rest)                 -> Just rest
  (GRho a : GRho b : rest)       -> Just (GRho (a * b) : rest)
  (GRho a : rest)
    | a >= 0                     -> Just rest
    | a /= negate 1              -> Just (GRho (negate 1) : rest)
  (GI : GI : rest)               -> Just (GRho (negate 1) : rest)
  (GJ : GJ : rest)               -> Just (GRho 1 : rest)
  (GI : GRho a : rest)           -> Just (GRho a : GI : rest)
  (GJ : GRho a : rest)           -> Just (GRho a : GJ : rest)
  (GBeta : GRho a : rest)        -> Just (GRho a : GBeta : rest)
  (x : rest)                     -> case stepRW rest of
    Just rest' -> Just (x : rest')
    Nothing    -> Nothing
  []                             -> Nothing

-- 正規形。上限を置くのは、書き換えが止まることを別に証明するまでの用心である。
-- 実際には各歩で「語長が減る」か「ρ が左へ一つ寄る」かのどちらかが起きるので、
-- 語長と ρ の位置の組を辞書順で見ると狭義に減り、有限段で止まる。
normalizeC :: Term -> Term
normalizeC = go rwBound
  where
    rwBound = 256 :: Int
    go k t
      | k <= 0    = t
      | otherwise = case stepRW t of
          Just t' -> go (k - 1) t'
          Nothing -> t

-- 正規形かどうか
isNormalC :: Term -> Bool
isNormalC t = stepRW t == Nothing

-- 分岐語との橋。𝒞 の語から i / j だけを読むと Quantale の snf に一致する
bWordOf :: Term -> BWord
bWordOf t = [ op | g <- t, Just op <- [toOp g] ]
  where
    toOp GI = Just I
    toOp GJ = Just J
    toOp _  = Nothing

-- ρ の総指数。符号がここに集まる。指数は乗法群なので積で畳む
rhoOf :: Term -> Int
rhoOf t = foldr step 1 t
  where
    step (GRho a) acc = a * acc
    step _        acc = acc

-- ===== 定理4.2: 座標写像は忠実でない =====
--
-- 意味論 ⟦·⟧ : 𝒞 → 𝒯 は構成項にその到達点を割り当てる。⟦ij⟧ = (+1,+1)、
-- ⟦ji⟧ = (+1,−1)。この写像は全射だが単射でない。
--
-- 反例は 3章 の減算表にある。
--
--   −(b·i)   座標 (0,−b)   (−i)² = −1   ω の H⁺ 稠密境界操作を反転
--    b·j     座標 (0,−b)    j²  = +1    ω⁻ の H⁻ 稠密境界操作
--
-- 座標が一致するのに自乗が違う。⟦·⟧ が忠実なら自乗も座標から復元できるはずだが
-- 復元できない。よって非単射。

semC :: Term -> Maybe TCoord
semC t = case coordOfWord (fst (snfWord (bWordOf t))) of
  Just (x, y) ->
    let s = rhoOf t * snd (snfWord (bWordOf t))
    in Just (scaleBy' s x, scaleBy' s y)
  Nothing -> Nothing
  where
    scaleBy' s v = if s < 0 then qratNeg v else v

-- 𝒞 の項を 𝒬 の元へ送る。大きさは 1、語と符号だけが動く
qvalOfTerm :: QRat -> Term -> QVal
qvalOfTerm m t =
  let (w, s) = snfWord (bWordOf t)
      sgn    = s * rhoOf t
  in qvNorm [(w, applySign sgn m)]

-- 反例の二項。b は大きさで、ここでは 1/2 を取る
negIterm, jTerm :: Term
negIterm = [GRho (negate 1), GI]   -- −(b·i)
jTerm    = [GJ]                    -- b·j

-- ===== 定義4.3: 有向ストリング図 =====
--
-- Joyal–Street の図式計算に従う。
--
--   ワイヤ            対象でラベルされる。ここでは本数だけを見る
--   箱                射でラベルされ、下辺に入力列、上辺に出力列を持つ
--   鉛直の積み重ね     合成 ∘
--   水平の並置        テンソル積 ⊗
--   箱のないワイヤ     恒等射 id
--   ワイヤのない空白   単位対象 I（本数 0 の恒等射）
--
-- 健全性・完全性により、図の表す射は境界を固定する平面アイソトピーで不変になる。
-- 𝔾 の基底は非対称（定理3.1）なので交差を生成元に持たず、図は厳密に平面内で
-- アイソトピーを取る。したがって
--
--   積み重ねた箱の鉛直順序   射の不変量
--   平行ワイヤの左右順序     射の不変量
--
-- になる。

data Box = Box
  { boxName :: String
  , boxIn   :: Int
  , boxOut  :: Int
  } deriving (Eq, Ord, Show)

data Diagram
  = DBox Box
  | DId Int              -- n 本の恒等ワイヤ。DId 0 が単位対象 I
  | DSeq Diagram Diagram -- 鉛直に積む（下が第一引数）
  | DTen Diagram Diagram -- 水平に並べる（左が第一引数）
  deriving (Eq, Show)

domD, codD :: Diagram -> Maybe Int
domD d = case d of
  DBox b   -> Just (boxIn b)
  DId n    -> Just n
  DSeq a b -> case (codD a, domD b) of
    (Just x, Just y) | x == y -> domD a
    _                         -> Nothing
  DTen a b -> addM (domD a) (domD b)

codD d = case d of
  DBox b   -> Just (boxOut b)
  DId n    -> Just n
  DSeq a b -> case (codD a, domD b) of
    (Just x, Just y) | x == y -> codD b
    _                         -> Nothing
  DTen a b -> addM (codD a) (codD b)

addM :: Maybe Int -> Maybe Int -> Maybe Int
addM (Just x) (Just y) = Just (x + y)
addM _        _        = Nothing

wellTyped :: Diagram -> Bool
wellTyped d = domD d /= Nothing && codD d /= Nothing

-- ===== 平面アイソトピーの不変量 =====
--
-- 図が表す射を、箱どうしの接続と平面上の左右順序だけで持つ。箱を上下に滑らせても
-- 接続も左右順序も変わらないので、この形はアイソトピーで不変になる。逆に、
-- 鉛直に積んだ二つの箱を入れ替えると接続が変わるので、区別が残る。
--
-- ワイヤは「境界の第 k 本」か「箱 b の第 k 出力」のどちらか。

data Wire = WIn Int | WOut Int Int deriving (Eq, Ord, Show)

data Node = Node
  { ndBox  :: Box
  , ndArgs :: [Wire]
  , ndPos  :: Int     -- 生成時の平面上の左端位置。左右の順序はこれで決まる
  } deriving (Eq, Ord, Show)

data Built = Built
  { bNodes :: [Node]
  , bOut   :: [Wire]
  } deriving (Eq, Show)

-- 図をたどってワイヤの接続を組む。offset が平面上の左端位置になる
buildD :: Diagram -> Maybe Built
buildD d = case domD d of
  Nothing -> Nothing
  Just n  -> case go d 0 (map WIn [0 .. n - 1]) [] of
    Just (outs, ns) -> Just (canonical (Built ns outs))
    Nothing         -> Nothing
  where
    go dg off front acc = case dg of
      DId k | length front == k -> Just (front, acc)
            | otherwise         -> Nothing
      DBox b
        | length front == boxIn b ->
            let k = length acc
            in Just ([ WOut k p | p <- [0 .. boxOut b - 1] ]
                    , acc ++ [Node b front off])
        | otherwise -> Nothing
      DSeq a c -> case go a off front acc of
        Just (mid, acc') -> go c off mid acc'
        Nothing          -> Nothing
      DTen a c -> case domD a of
        Nothing -> Nothing
        Just na
          | length front < na -> Nothing
          | otherwise -> case go a off (take na front) acc of
              Nothing -> Nothing
              Just (oa, acc') -> case go c (off + na) (drop na front) acc' of
                Nothing -> Nothing
                Just (oc, acc'') -> Just (oa ++ oc, acc'')

-- 正準形。箱を（因果深度, 平面上の左端位置）の昇順へ並べ替え、番号を振り直す。
--
--   h(v) = 0                          Pred(v) = ∅
--   h(v) = 1 + max_{u∈Pred(v)} h(u)   その他
--
-- これが 02章 §2 の最大平行層そのものになる。平面アイソトピーで箱を上下に
-- 滑らせても因果深度は動かないので、この並びは不変量である。
canonical :: Built -> Built
canonical (Built ns outs) = Built ns' (map remap outs)
  where
    depths = depthsOf ns
    keyed  = sort (zipWith3 (\k nd dp -> (dp, ndPos nd, k)) [0 :: Int ..] ns depths)
    order  = [ k | (_, _, k) <- keyed ]
    newOf k = indexIn k order
    ns'    = [ (nodeAt k ns) { ndArgs = map remap (ndArgs (nodeAt k ns)) } | k <- order ]
    remap (WOut b p) = WOut (newOf b) p
    remap w          = w

nodeAt :: Int -> [Node] -> Node
nodeAt _ [x]      = x
nodeAt 0 (x : _)  = x
nodeAt k (_ : xs) = nodeAt (k - 1) xs
nodeAt _ []       = Node (Box "" 0 0) [] 0

indexIn :: Int -> [Int] -> Int
indexIn x xs = go 0 xs
  where
    go k (y : ys) = if x == y then k else go (k + 1) ys
    go k []       = k

-- 因果深度。引数が全て境界なら 0、そうでなければ前駆の最大 + 1
depthsOf :: [Node] -> [Int]
depthsOf ns = ds
  where
    ds = [ dOf nd | nd <- ns ]
    dOf nd = case [ 1 + pick b | WOut b _ <- ndArgs nd ] of
      [] -> 0
      xs -> maximum xs
    pick b = nthOr 0 b ds

nthOr :: Int -> Int -> [Int] -> Int
nthOr dflt _ []       = dflt
nthOr _    0 (x : _)  = x
nthOr dflt k (_ : xs) = nthOr dflt (k - 1) xs

-- 平面アイソトピー。正準形が一致することと同値
isotopic :: Diagram -> Diagram -> Bool
isotopic a b = case (buildD a, buildD b) of
  (Just x, Just y) -> x == y
  _                -> False

-- ===== 𝒞 の生成元を箱として置く（定義4.3 末尾）=====

boxOfGen :: Gen -> Box
boxOfGen g = case g of
  GUnit  -> Box "1"    1 1
  GRho a -> Box (if a < 0 then "rho-" else "rho+") 1 1
  GI     -> Box "i"    1 1
  GJ     -> Box "j"    1 1
  GBeta  -> Box "beta" 1 1

-- 語を鉛直に積んだ図。左の生成元が下に来る
diagOfTerm :: Term -> Diagram
diagOfTerm = foldl step (DId 1)
  where step acc g = DSeq acc (DBox (boxOfGen g))

-- ===== 標本 =====

bf, bg, bh :: Box
bf = Box "Tf" 1 1
bg = Box "Tg" 1 1
bh = Box "Th" 1 1

bA, bB :: Box
bA = Box "A" 1 1
bB = Box "B" 1 1

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("定義4.1: i i ⇒ ρ⁻¹、j j ⇒ ρ⁺¹ が書き換えとして走る",
      normalizeC [GI, GI] == [GRho (negate 1)]
      && normalizeC [GJ, GJ] == []
      && normalizeC [GI, GI, GI, GI] == [])

  , ("定義4.1: ρ の指数は乗法群 {+1,−1}。ρ⁺¹ は単位として消える",
      normalizeC [GRho 1] == []
      && normalizeC [GRho (negate 1), GRho (negate 1)] == []
      && normalizeC [GRho (negate 1)] == [GRho (negate 1)])

  , ("定義4.1: 書き換えは有限段で止まり、正規形に達する",
      all (isNormalC . normalizeC)
          [ [GI,GI,GJ], [GJ,GJ,GI,GI], [GI,GJ,GI,GJ]
          , [GUnit,GI,GUnit], [GBeta,GI,GI], [GRho 1, GRho (negate 1), GI] ])

  , ("定義4.1: 1 は消える。ρ⁰ も消える（幾何的実現可能性で割った商）",
      normalizeC [GUnit, GI, GUnit] == [GI]
      && normalizeC [GRho 0, GJ] == [GJ])

  , ("定義4.1: ρ は実軸上の量なので i / j を越えて前へ寄る",
      normalizeC [GI, GRho (negate 1)] == [GRho (negate 1), GI])

  , ("定義4.1: 臨界対 ij / ji は解消しない。別の正規形を持つ",
      normalizeC [GI, GJ] /= normalizeC [GJ, GI]
      && normalizeC [GI, GJ] == [GI, GJ]
      && normalizeC [GJ, GI] == [GJ, GI])

  , ("定義4.1: 𝒞 の語から i / j を読むと Quantale の snf に一致する",
      and [ fst (snfWord (bWordOf t)) == fst (snfWord (bWordOf (normalizeC t)))
          | t <- [[GI,GI,GJ], [GJ,GJ,GI], [GI,GJ], [GJ,GI], [GI,GI,GI]] ])

  , ("意味論: ⟦ij⟧ = (+1,+1)、⟦ji⟧ = (+1,−1)",
      semC [GI, GJ] == Just (qratOne, qratOne)
      && semC [GJ, GI] == Just (qratOne, qratNeg qratOne))

  , ("意味論: ⟦i⟧ = (0,+1)、⟦j⟧ = (0,−1)、⟦1⟧ = (+1,0)",
      semC [GI] == Just (qratZero, qratOne)
      && semC [GJ] == Just (qratZero, qratNeg qratOne)
      && semC [] == Just (qratOne, qratZero))

  , ("定理4.2: ⟦·⟧ は単射でない — −(b·i) と b·j の座標が一致する",
      semC negIterm == semC jTerm
      && semC negIterm == Just (qratZero, qratNeg qratOne))

  , ("定理4.2: それでも自乗は違う — (−i)² = −1、j² = +1",
      let sq t = semC (normalizeC (t ++ t))
      in sq negIterm == Just (qratNeg qratOne, qratZero)
         && sq jTerm == Just (qratOne, qratZero)
         && sq negIterm /= sq jTerm)

  , ("定理4.2: 構成項としては別物である。𝒬 の元でも分かれる",
      negIterm /= jTerm
      && qvalOfTerm (QRat 1 2) negIterm /= qvalOfTerm (QRat 1 2) jTerm)

  , ("定理4.2: 座標代数は加算的な最終値までしか運ばない",
      semC negIterm == semC jTerm
      && normalizeC negIterm /= normalizeC jTerm)

  , ("定義4.3: 図の型検査。合成は cod と dom が合うときだけ成立する",
      wellTyped (DSeq (DBox bf) (DBox bg))
      && not (wellTyped (DSeq (DBox (Box "p" 1 2)) (DBox (Box "q" 1 1))))
      && domD (DTen (DBox bf) (DBox bg)) == Just 2)

  , ("定義4.3: 箱のないワイヤが恒等射。ワイヤのない空白が単位対象 I",
      isotopic (DSeq (DId 1) (DBox bf)) (DBox bf)
      && isotopic (DSeq (DBox bf) (DId 1)) (DBox bf)
      && isotopic (DTen (DBox bf) (DId 0)) (DBox bf)
      && isotopic (DTen (DId 0) (DBox bf)) (DBox bf))

  , ("図4.A: 合成は箱を鉛直に積むこと。積み方の括弧は射を変えない",
      isotopic (DSeq (DSeq (DBox bf) (DBox bg)) (DBox bh))
               (DSeq (DBox bf) (DSeq (DBox bg) (DBox bh))))

  , ("図4.A: 中間ワイヤをどの順に評価しても同じ射になる（定理2.2 の図式版）",
      isotopic (DTen (DSeq (DBox bf) (DBox bg)) (DId 1))
               (DSeq (DTen (DBox bf) (DId 1)) (DTen (DBox bg) (DId 1))))

  , ("定義4.3: 並置の括弧も射を変えない（厳密モノイダル）",
      isotopic (DTen (DTen (DBox bf) (DBox bg)) (DBox bh))
               (DTen (DBox bf) (DTen (DBox bg) (DBox bh))))

  , ("定義4.3: 交換律。並置した箱は上下に滑らせても同じ射を表す",
      isotopic (DTen (DBox bA) (DBox bB))
               (DSeq (DTen (DBox bA) (DId 1)) (DTen (DId 1) (DBox bB)))
      && isotopic (DTen (DBox bA) (DBox bB))
                  (DSeq (DTen (DId 1) (DBox bB)) (DTen (DBox bA) (DId 1))))

  , ("図4.B: ij ≠ ji — 鉛直に積んだ箱の順序は射の不変量である",
      not (isotopic (DSeq (DBox (boxOfGen GI)) (DBox (boxOfGen GJ)))
                    (DSeq (DBox (boxOfGen GJ)) (DBox (boxOfGen GI)))))

  , ("図4.B: 図式の区別に意味論が忠実に対応する",
      semC [GI, GJ] /= semC [GJ, GI])

  , ("図4.C: 同じ箱を二つ積むと簡約される。i の二積みが ρ⁻¹ へ落ちる",
      normalizeC [GI, GI] == [GRho (negate 1)]
      && diagOfTerm (normalizeC [GI, GI]) == DSeq (DId 1) (DBox (boxOfGen (GRho (negate 1))))
      && diagOfTerm (normalizeC [GJ, GJ]) == DId 1)

  , ("図4.C: 臨界対 ij / ji は書き換えでは解消しない",
      isNormalC [GI, GJ] && isNormalC [GJ, GI]
      && normalizeC [GI, GJ] /= normalizeC [GJ, GI])

  , ("図4.D: 交差は生成元に無い。並べた二箱を入れ替える図が描けない",
      not (isotopic (DTen (DBox bA) (DBox bB)) (DTen (DBox bB) (DBox bA))))

  , ("図4.D: 平行ワイヤの左右順序が射の不変量なので、入れ替えは別の射になる",
      let l = buildD (DTen (DBox bA) (DBox bB))
          r = buildD (DTen (DBox bB) (DBox bA))
      in l /= r && l /= Nothing && r /= Nothing)

  , ("図4.D: Eckmann–Hilton が発動しない。交換律まではあるが交差が無い",
      isotopic (DTen (DBox bA) (DBox bB))
               (DSeq (DTen (DBox bA) (DId 1)) (DTen (DId 1) (DBox bB)))
      && not (isotopic (DTen (DBox bA) (DBox bB)) (DTen (DBox bB) (DBox bA))))

  , ("正準形は最大平行層である。因果深度が同じ箱は同じ層に並ぶ",
      case buildD (DTen (DBox bA) (DBox bB)) of
        Just (Built ns _) -> depthsOf ns == [0, 0]
        Nothing           -> False)

  , ("正準形: 鉛直に積むと因果深度が上がる",
      case buildD (DSeq (DBox bA) (DBox bB)) of
        Just (Built ns _) -> depthsOf ns == [0, 1]
        Nothing           -> False)
  ]
