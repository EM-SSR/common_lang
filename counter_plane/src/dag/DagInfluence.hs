{-# LANGUAGE NoImplicitPrelude #-}
module DagInfluence where

import CounterConstraints
import RealUnit
import CounterInteger (pointOf, stdLine)
import DagPlane
import DagArith

-- ===== 影響関数と整合条件（4章）=====
-- doc: influence.w influence.convex influence.boundary influence.unbounded
-- doc: coherence.star morphism.T
--
-- 4章は五つを順に置く。この module は同じ順で持つ。
--
--   定義1   幾何図形 G と目印集合 L
--   定義2   影響関数 w : L × G → ℝ。ℝ は Level 1 の「開半直線への境界操作の出力」
--   定義3   幾何的性質が w の制約を決める
--     証明3.1  凸性        → Σ_ℓ w(ℓ,x) = 1、w ≥ 0     （タレス比の帰納構成）
--     証明3.2  方向付き境界 → w ∈ {−1,0,1}、∂² = 0
--     証明3.3  非有界      → 制約なし
--   定義5   幾何的射と遷移係数 T_f(ℓ₁,ℓ₂) = w₂(ℓ₂, f(ℓ₁))
--     証明5.1  整合条件 (⋆) の幾何的必然性
--
-- w の値は QRat（3章のタレス比）である。座標の分子 SCoord とは別物で、
-- 座標は二進、比は一般の有理数になる。

-- ===== 定義1: 幾何図形と目印 =====
--
-- 目印の本数 n+1 と、図形がどの幾何的性質を持つかだけが w の制約を決める。
-- 図形の中身（頂点番号や辺の並び）は制約に効かないので、ここでは持たない。
-- 効くのは「凸か、方向付き境界か、非有界か」の三択である（定義3）。

data Regime
  = RConvex      -- 凸領域。目印はその頂点集合
  | RBoundary    -- 方向付き境界構造。目印は一つ下の次元の単体
  | RUnbounded   -- 非有界。目印は軸方向
  deriving (Eq, Show)

data GObj = GObj
  { gRegime :: Regime
  , gRank   :: Int        -- 目印の本数 |L|
  } deriving (Eq, Show)

-- ===== 定義2: 影響プロファイル =====
--
-- x̂ = (w(ℓ₀,x), w(ℓ₁,x), …, w(ℓₙ,x))。長さは |L| に等しい。

type Profile = [QRat]

profileRank :: Profile -> Int
profileRank = length

qsum :: [QRat] -> QRat
qsum = foldr qratAdd qratZero

-- ===== 定義3: 幾何的性質が制約を決める =====
--
-- 4章末尾の表をそのまま実行形にしたもの。
--
--   凸性（有界）    Σ_ℓ w(ℓ,x) = 1、w ≥ 0     タレス比構成、6c の拘束
--   方向付き境界    w ∈ {−1,0,1}、∂² = 0      隣接・含まれる、ℝ³ 制約1
--   非有界          制約なし                   ω の非対称性、∂-境界なし

constraintsHold :: GObj -> Profile -> Bool
constraintsHold g ws = length ws == gRank g && case gRegime g of
  RConvex    -> qratEq (qsum ws) qratOne && all (qratLeq qratZero) ws
  RBoundary  -> all inc11 ws
  RUnbounded -> True

inc11 :: QRat -> Bool
inc11 w = qratEq w qratZero || qratEq w qratOne || qratEq w (qratNeg qratOne)

-- ===== 証明3.1: 凸性 → 分配制約と非負性 =====
--
-- 目印 ℓ₀ と内部点 x を取り、ℓ₀ から x へ向かう道を G の内部で延長する。
-- 凸性により、この道は ℓ₀ を含まない対面 F₀ とちょうど一点 y で交わって止まる。
-- そこで読むタレス比が第一の影響になる。
--
--   w(ℓ₀, x) = |xy| / |ℓ₀ y|                                   (3.1a)
--
-- 残りの影響 1 − w(ℓ₀,x) は丸ごと y へ渡り、F₀ は残りの頂点 ℓ₁,…,ℓₙ が張る
-- 凸領域だから、y に対して同じ操作を帰納的に適用できる。
--
-- したがって点は「作図の比の列」そのものとして持てる。座標系は要らない。
-- 比 r_k ∈ [0,1] は段 k の対面上で読んだタレス比である。

newtype Descent = Descent { descentRatios :: [QRat] } deriving (Eq, Show)

-- 比の列が作図として成立する条件。各段の比が閉区間 [0,1] に収まること。
-- 証明3.1 の「x は ℓ₀ と y の間の道上に含まれる」がこの範囲を与える
descentOK :: Descent -> Bool
descentOK (Descent rs) = all inUnit rs
  where inUnit r = qratLeq qratZero r && qratLeq r qratOne

-- 帰納構成の展開。段ごとに残りの影響を比で切り、最後の目印へ残りを渡す。
--
--   w(ℓ₀,x) = r₀
--   w(ℓ_k,x) = r_k · Π_{m<k} (1 − r_m)          (1 ≤ k < n)
--   w(ℓ_n,x) =        Π_{m<n} (1 − r_m)
--
-- 総和が 1 になるのは各段で「切った分」と「残り」に分けているからで、
-- 足し合わせると隣り合う項が打ち消し合って 1 だけが残る。
-- 非負性は各 r_k ∈ [0,1] から出る。
profileOfDescent :: Descent -> Profile
profileOfDescent (Descent rs) = go rs qratOne
  where
    go []       rest = [rest]
    go (r : xs) rest = qratMul rest r : go xs (qratMul rest (qratSub qratOne r))

-- ===== 命題1.4（圏論 第I部）の構成的な中身 =====
--
-- 逆向き。プロファイルから比の列を復元する。
--
--   r_k = w(ℓ_k,x) ⊘ (1 − Σ_{m<k} w(ℓ_m,x))
--
-- 内点では分母が正なので r_k は一意に決まり、プロファイルが点を一意に定める。
-- 面の上（途中で残りが 0 になる点）では、以降の道が ℓ に重なって比が読めない。
-- 幾何としては「点は既に定まっている」ので、末尾は 0 へ正準化する。
descentOfProfile :: Profile -> Maybe Descent
descentOfProfile ws
  | null ws                              = Nothing
  | not (all (qratLeq qratZero) ws)      = Nothing
  | not (qratEq (qsum ws) qratOne)       = Nothing
  | otherwise                            = Just (Descent (go (initOf ws) qratOne))
  where
    go []       _    = []
    go (w : xs) rest = case qratDiv w rest of
      Just r  -> r : go xs (qratSub rest w)
      Nothing -> qratZero : go xs rest      -- 残りが 0。以降は面の上にある

initOf :: [a] -> [a]
initOf []       = []
initOf [_]      = []
initOf (x : xs) = x : initOf xs

-- 6c との接続。T₁ = (O, i, ij) の重心座標は共通分母 2^depth に対する分子三つで
-- 持たれている（DagPlane.CellPt）。これを比へ持ち上げると、証明3.1 の
-- 帰納構成が返すプロファイルと一致する。
profileOfCellPt :: CellPt -> Profile
profileOfCellPt (CellPt _ (a, b, c) d) =
  [ qratDyad (toInteger a) d
  , qratDyad (toInteger b) d
  , qratDyad (toInteger c) d ]

-- ===== 証明3.2: 方向付き境界構造 → 符号付き整数制約と冪零性 =====
--
-- 単体複体では目印を (n−1)-単体に取る。影響は「σ_{n−1} が σ_n の境界に
-- 符号付きで含まれるか、含まれないか」の三択しかない。
--
--   w(σ_{n−1,i}, σ_{n,j}) = inc(σ_{n−1,i}, σ_{n,j}) ∈ {−1, 0, 1}
--
-- 冪零性 ∂² = 0 は ℝ³ の制約1（閉じた曲面には境界がない）から来る。
-- 係数の相殺はその幾何的事実の表現に過ぎない。
--
-- 凸性との違いは非負性に出る。総和では分けられない: n-単体の境界は面が n+1 枚で
-- 符号が交代するので、n が偶数のとき和はちょうど 1 になり、凸性の拘束と
-- 見分けがつかない。2-単体（面 3 枚、+1 −1 +1）がその場合にあたる。

boundaryProfile :: Simplex -> [Simplex] -> Profile
boundaryProfile sigma faces =
  [ qratOf (toInteger k) 1 | k <- incRow sigma faces ]

-- ===== 証明3.3: 非有界 → 無制約 =====
--
-- 証明3.1 の核心は「道を延長すると ∂G の反対側の面にぶつかる」だった。
-- H⁺ では ω 側に整数点が無い（Level 4 の非対称性）ので、その面が存在しない。
-- 制約を導いた幾何的根拠が最初から無く、w(e_j,x) = x_j に何も課されない。
--
-- 実行形では「構成済みの H⁺ の ∂ が端点を一つしか返さない」ことがそれにあたる。
-- 有界な道は両端を返すので、ここで区別がつく。

boundedEnds :: Region -> Int
boundedEnds = length . boundaryRegion

-- 構成済み H⁺（O から hi まで）。ω 側の端は未構成なので ∂ は O だけを返す
halfPlusConstructed :: Int -> Region
halfPlusConstructed = halfPlus

-- 非有界図形の影響は座標そのもの。持ち上げるだけで制約を課さない
unboundedProfile :: [QRat] -> Profile
unboundedProfile = id

-- ===== 定義5: 幾何的射と遷移係数 =====
--
-- 射 f は「各目印の像がどこに立つか」で決まる。像は G₂ の点だから、
-- G₂ のプロファイルとして書ける。遷移係数はそれをそのまま並べたものになる。
--
--   T_f(ℓ₁, ℓ₂) = w₂(ℓ₂, f(ℓ₁))                                (定義5)
--
-- 成分は一般に 0/1 ではない。目印が目印へ落ちる射だけが δ になる（定理2.3）。

newtype GMor = GMor { morRows :: [Profile] } deriving (Eq, Show)

-- 行 = 出発側の目印 ℓ₁、列 = 行先の目印 ℓ₂
transOf :: GMor -> [Profile]
transOf = morRows

-- 目印を目印へ写す射。像は行先目印に立つ点なので、プロファイルは δ になる
vertexMor :: Int -> Int -> (Int -> Int) -> GMor
vertexMor n m f = GMor [ [ if f v == w then qratOne else qratZero
                         | w <- [0 .. m - 1] ]
                       | v <- [0 .. n - 1] ]

identityMor :: Int -> GMor
identityMor n = vertexMor n n id

-- ===== 証明5.1: 整合条件 (⋆) =====
--
-- 凸図形では任意の点が目印のタレス比による結合として書ける。
--
--   x = Σ_{ℓ₁} w₁(ℓ₁,x) · ℓ₁
--
-- f が道構造を保つならこの表現に f を適用でき、G₂ の影響関数で展開して
--
--   w₂(ℓ₂, f(x)) = Σ_{ℓ₁} T_f(ℓ₁,ℓ₂) ⋆ w₁(ℓ₁,x)                (⋆)
--
-- を得る。⋆ は 3章のタレス乗算、和は 3章の加算（平行四辺形則）。
-- 実成分どうしなら可換なので和の順序は問わない。

starApply :: Profile -> GMor -> Profile
starApply x (GMor rows) =
  [ qsum (zipWith qratMul x col) | col <- colsOf rows ]

colsOf :: [Profile] -> [Profile]
colsOf []   = []
colsOf rows = foldr (zipWith (:)) (replicate (widthOf rows) []) rows
  where
    widthOf (r : _) = length r
    widthOf []      = 0

-- ===== 定理2.2 の大きさ版: (2.1) の ⋆-行列積 =====
--
--   T_{g∘f}(ℓ₁,ℓ₃) = Σ_{ℓ₂} T_g(ℓ₂,ℓ₃) ⋆ T_f(ℓ₁,ℓ₂)             (2.1)
--
-- 行優先で持つので、合成は「f の行に g を掛ける」形になる。
-- 分岐語（型）を運ぶ非可換版は Quantale / GclsCategory が持つ。ここは大きさだけ。

composeMor :: GMor -> GMor -> GMor
composeMor f g = GMor [ starApply row g | row <- morRows f ]

-- 射が凸図形の間の射であること。各行が G₂ のプロファイルになっている
-- ＝ 行和が 1 で非負。この性質が (2.1) で閉じることが圏の成立を支える
convexMor :: GMor -> Bool
convexMor (GMor rows) =
  and [ qratEq (qsum r) qratOne && all (qratLeq qratZero) r | r <- rows ]

-- ===== 鎖写像（証明3.2 の射版）=====

type VertMap = Int -> Int

transMatrix :: [Int] -> [Int] -> VertMap -> [[Int]]
transMatrix src dst f =
  [ [ if f v == w then 1 else 0 | w <- dst ] | v <- src ]

matComp :: [[Int]] -> [[Int]] -> [[Int]]
matComp a b =
  let bt = foldr (zipWith (:)) (repeat []) b
  in [ [ sum (zipWith (*) r c) | c <- bt ] | r <- a ]

mapVertices :: VertMap -> Simplex -> Simplex
mapVertices f (Simplex a) = simplex [f p | p <- [0 .. 63], testBit a p]

-- 頂点像の列を昇順へ整列する置換の符号（反転数の偶奇）
permSign :: [Int] -> Int
permSign xs = if even (countInv xs) then 1 else negate 1

countInv :: [Int] -> Int
countInv []     = 0
countInv (a : rest) =
  length [b | b <- rest, b < a] + countInv rest

-- f♯σ: 頂点写像に向き補正（置換符号）を掛けた鎖像。
-- 向き補正なしでは f♯∂ = ∂f♯ が壊れる（頂点順が保存されないため）
chainImage :: VertMap -> Simplex -> (Int, Simplex)
chainImage f sg = (permSign (map f (vertices sg)), mapVertices f sg)

fSharpBoundary :: VertMap -> Simplex -> [(Int, Simplex)]
fSharpBoundary f sg =
  [ (c * s, t) | (c, tau) <- boundary sg, let (s, t) = chainImage f tau ]

sortS :: [(Int, Simplex)] -> [(Int, Simplex)]
sortS = sort

-- ===== 標本 =====

swapMap :: VertMap
swapMap p
  | p == pI   = pJ
  | p == pJ   = pI
  | p == pIJ  = pJI
  | p == pJI  = pIJ
  | p == pNIJ = pNJI
  | p == pNJI = pNIJ
  | otherwise = p

vertsP :: [Int]
vertsP = [pO, pOne, pI, pJ, pIJ, pJI, pNIJ, pNJI]

-- T₁ 上の点。6c の三分割比 (λ_ij, λ_i, λ_O) をそのまま持つ
t1Obj :: GObj
t1Obj = GObj RConvex 3

-- x = (a, b) = (1/4, 3/4) の重心座標。λ_ij = 1/4、λ_i = 1/2、λ_O = 1/4
sampleCell :: CellPt
sampleCell = mkT1Pt 1 3 2

-- 目印を内点へ落とす射。成分が 0/1 に収まらない例になる。
--   ℓ₀ ↦ T₁ の重心寄りの点、ℓ₁ ↦ 辺の中点、ℓ₂ ↦ 目印 ℓ₂ そのもの
mixedMor :: GMor
mixedMor = GMor
  [ [ QRat 1 2, QRat 1 3, QRat 1 6 ]
  , [ QRat 1 4, QRat 1 4, QRat 1 2 ]
  , [ qratZero, qratZero, qratOne  ] ]

mixedMor2 :: GMor
mixedMor2 = GMor
  [ [ QRat 1 5, QRat 3 5, QRat 1 5 ]
  , [ QRat 1 2, qratZero, QRat 1 2 ]
  , [ QRat 1 3, QRat 1 3, QRat 1 3 ] ]

mixedMor3 :: GMor
mixedMor3 = GMor
  [ [ QRat 2 7, QRat 4 7, QRat 1 7 ]
  , [ qratOne,  qratZero, qratZero ]
  , [ QRat 1 6, QRat 1 2, QRat 1 3 ] ]

-- 非有界の標本。制約が課されないので和が 1 にも非負にもならない
unboundedSample :: Profile
unboundedSample = unboundedProfile [QRat 5 2, qratNeg (QRat 1 3), QRat 7 1]

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("定義2: プロファイルの長さは目印の本数に等しい",
      profileRank (profileOfCellPt sampleCell) == gRank t1Obj)

  , ("証明3.1: 帰納構成が分配制約 Σ w = 1 と非負性を与える",
      let ds = [ Descent [QRat 1 4, QRat 2 3]
               , Descent [QRat 1 2, QRat 1 2]
               , Descent [qratZero,  QRat 3 5]
               , Descent [qratOne,   QRat 1 2] ]
      in all (\d -> descentOK d && constraintsHold t1Obj (profileOfDescent d)) ds)

  , ("証明3.1: 段ごとの比が「切った分」と「残り」に分かれ、隣り合う項が打ち消し合う",
      profileOfDescent (Descent [QRat 1 4, QRat 2 3])
        == [QRat 1 4, QRat 1 2, QRat 1 4])

  , ("証明3.1: 比が [0,1] を外れると作図として成立しない",
      not (descentOK (Descent [QRat 3 2]))
      && not (descentOK (Descent [qratNeg (QRat 1 4)])))

  , ("6c との一致: T₁ の重心座標は帰納構成の出力と同じプロファイルになる",
      profileOfCellPt sampleCell == profileOfDescent (Descent [QRat 1 4, QRat 2 3]))

  , ("命題1.4: プロファイルから比の列が一意に戻る（内点では分母が正）",
      let d = Descent [QRat 1 4, QRat 2 3]
      in descentOfProfile (profileOfDescent d) == Just d)

  , ("命題1.4: 面の上では末尾の比が読めないので 0 へ正準化する",
      descentOfProfile [qratOne, qratZero, qratZero]
        == Just (Descent [qratOne, qratZero]))

  , ("命題1.4: プロファイルが一致するとき、かつそのときだけ同じ点",
      let p = profileOfDescent (Descent [QRat 1 4, QRat 2 3])
          q = profileOfDescent (Descent [QRat 1 4, QRat 1 3])
      in p /= q && descentOfProfile p /= descentOfProfile q)

  , ("命題1.4: 拘束を破る割り当ては点にならない",
      descentOfProfile [QRat 1 2, QRat 1 2, QRat 1 2] == Nothing
      && descentOfProfile [QRat 3 2, qratNeg (QRat 1 2)] == Nothing)

  , ("証明3.2: 単体複体の影響は inc ∈ {−1,0,1} に限られる",
      let g = GObj RBoundary (length facesP)
      in all (\c -> constraintsHold g (boundaryProfile c facesP)) cellsP)

  , ("証明3.2: 冪零性 ∂² = 0（閉じた曲面には境界がない）",
      all d2Zero cellsP)

  , ("証明3.2: 境界構造には非負性が課されない（−1 の成分が実際に立つ）",
      let row = boundaryProfile q1 facesP
      in not (all (qratLeq qratZero) row)
         && not (constraintsHold (GObj RConvex (length facesP)) row))

  , ("証明3.3: 有界な道は両端を返す。証明3.1 が使う「対面」はこの端点である",
      boundedEnds (region [oVertex + 1 .. oVertex + 4]) == 2)

  , ("証明3.3: H⁺ は構成済み側の端点 O しか出さない（反対側の面が無い）",
      boundaryOutput (halfPlusConstructed (oVertex + 5))
        == Just (RealNum oVertex (negate 1)))

  , ("証明3.3: ω はどの有限深度の構成点でもない。延長しても対面へ届かない",
      all (\ci -> pointOf ci < snd stdLine) (fst stdLine))

  , ("証明3.3: 非有界では制約が課されない（和が 1 でも非負でもない値を許す）",
      constraintsHold (GObj RUnbounded 3) unboundedSample
      && not (constraintsHold (GObj RConvex 3) unboundedSample))

  , ("定義5: 遷移係数は像のプロファイルそのもの。成分は 0/1 に限られない",
      convexMor mixedMor
      && not (all (\r -> all (\w -> inc11 w) r) (morRows mixedMor)))

  , ("定理2.3: 目印を目印へ写す射だけが δ になる",
      morRows (identityMor 3)
        == [ [qratOne, qratZero, qratZero]
           , [qratZero, qratOne, qratZero]
           , [qratZero, qratZero, qratOne] ])

  , ("定理2.3: δ は (2.1) の両側単位元である（分数成分の射でも）",
      composeMor (identityMor 3) mixedMor == mixedMor
      && composeMor mixedMor (identityMor 3) == mixedMor)

  , ("証明5.1: (⋆) の像は G₂ の点になる（行和 1・非負が保たれる）",
      let x = profileOfCellPt sampleCell
      in constraintsHold t1Obj (starApply x mixedMor)
         && descentOfProfile (starApply x mixedMor) /= Nothing)

  , ("証明5.1: 目印の像を読むと (⋆) は T_f の行そのものを返す",
      and [ starApply e mixedMor == row
          | (e, row) <- zip (morRows (identityMor 3)) (morRows mixedMor) ])

  , ("証明5.1: 頂点写像では (⋆) がプロファイルの並べ替えに一致する",
      let f v = case v of { 0 -> 2; 1 -> 0; _ -> 1 }
          x   = [QRat 1 4, QRat 1 2, QRat 1 4]
          byRelabel = [ qsum [ w | (v, w) <- zip [0 ..] x, f v == u ] | u <- [0, 1, 2] ]
      in starApply x (vertexMor 3 3 f) == byRelabel)

  , ("定理2.2: (2.1) は結合的である — 分数成分の射三つで確かめる",
      composeMor (composeMor mixedMor mixedMor2) mixedMor3
        == composeMor mixedMor (composeMor mixedMor2 mixedMor3))

  , ("定理2.2: 合成は凸性を保つ（行和 1・非負が (2.1) で閉じる）",
      convexMor (composeMor mixedMor mixedMor2)
      && convexMor (composeMor (composeMor mixedMor mixedMor2) mixedMor3))

  , ("定理2.2: (⋆) は合成と可換する — w₂(ℓ,g(f(x))) は二通りに読める",
      let x = profileOfCellPt sampleCell
      in starApply (starApply x mixedMor) mixedMor2
           == starApply x (composeMor mixedMor mixedMor2))

  , ("鎖写像条件: f♯(∂σ) = ∂(f♯σ)（向き補正込み）",
      and [ sortS (fSharpBoundary swapMap c)
              == sortS (boundary (snd (chainImage swapMap c)))
          | c <- cellsP ])

  , ("鎖写像は冪零性を保存する: ∂²(f♯σ) = 0",
      all (d2Zero . mapVertices swapMap) cellsP)

  , ("整合条件の整数版: T_{g∘f} = T_g · T_f（置換行列の場合）",
      matComp (transMatrix vertsP vertsP swapMap)
              (transMatrix vertsP vertsP swapMap)
          == transMatrix vertsP vertsP id)
  ]
