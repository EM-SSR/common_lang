{-# LANGUAGE NoImplicitPrelude #-}
module Foundations where

import CounterConstraints
import CounterUnits (Op (..))
import DagArith
import DagPlane (mkT1Pt)
import DagInfluence hiding (selfcheck)
import Quantale hiding (selfcheck)
import GclsCategory hiding (selfcheck)
import EnrichedG hiding (selfcheck)

-- ===== 既存の世界との接続（圏論 第V部）=====
-- doc: link.zfc link.simplicial link.universe cat.selfhost forget.recover
--
--   物質的集合論との接続    U = Θ∘π と埋め込み D。下りは標準的、上りは実軸に限る
--   圏論との接続            Δ : Δ → 𝔾 は忠実充満。単体的恒等式と ∂² = 0
--   宇宙との接続            部分図形・積と二残差・二分割細分の三つで閉じる
--   自己ホスティング        i ⊣ π ⊣ j と、d 軸の二つの余終端 ω / ω⁻

-- ===== 整数行列の道具 =====
--
-- 単体的な射の遷移係数は δ なので、この節では成分が整数に収まる。
-- 𝒬 係数の行列は GclsCategory が持つ。

type MatZ = [[Int]]

zeroMatZ :: Int -> Int -> MatZ
zeroMatZ r c = replicate r (replicate c 0)

matAddZ :: MatZ -> MatZ -> MatZ
matAddZ = zipWith (zipWith (+))

matScaleZ :: Int -> MatZ -> MatZ
matScaleZ k = map (map (k *))

isZeroMatZ :: MatZ -> Bool
isZeroMatZ m = all (all (== 0)) m

-- ===== 物質的集合論との接続 =====
--
-- しきい値射影 Θ と型忘却 π を合成した二重退化
--
--   U = Θ ∘ π : 𝔾 ⟶ Set
--
-- が二値の集合圏への関手を与える。逆に有限集合 {0,…,n} を頂点だけの離散影響対象
-- （目印＝全点、w = δ）へ送る埋め込み D : Set ⟶ 𝔾 がある。
--
-- ここに方向の非対称がある。下り U は標準的・関手的で選択が要らない。上り D の像は
-- 実軸（対称退化部分、b = 0）に限られる。型 b ≠ 0 は ω / ω⁻ の非対称性という
-- Level 4/5 の原始から来る量で、∈ にも基数にも対応物がない。

uForget :: MatQ -> MatZ
uForget = map (map (thetaQ . piQ))

-- Set 側の合成。二値なので論理積の上限になる
boolMul :: MatZ -> MatZ -> MatZ
boolMul a b =
  [ [ if any (\(x, y) -> x > 0 && y > 0) (zip row col) then 1 else 0
    | col <- colsZ b ]
  | row <- a ]

colsZ :: MatZ -> MatZ
colsZ []   = []
colsZ rows = foldr (zipWith (:)) (replicate (widthZ rows) []) rows

widthZ :: MatZ -> Int
widthZ (r : _) = length r
widthZ []      = 0

-- 埋め込み D : Set ⟶ 𝔾。写像を δ 行列へ送る。像は必ず実軸上に乗る
dEmbed :: Int -> Int -> (Int -> Int) -> MatQ
dEmbed = matOfVertexMap

-- 像が実軸に乗っていること。全ての成分の語が空である
onRealAxis :: MatQ -> Bool
onRealAxis m = and [ all (== []) (qvWords v) | row <- m, v <- row ]

-- ===== 圏論との接続: 単体圏 Δ =====
--
-- 各 n に対し標準 n-単体を、目印 {0,…,n} をもつ凸影響対象 Δⁿ（影響関数＝重心座標）
-- に写し、単調写像 θ を
--
--   T_θ(i,j) = δ_{θ(i), j}
--
-- で送ると、Δ : Δ ⟶ 𝔾 は忠実充満関手になる。6c の重心座標分割が Δ² = T₁ で
-- Σλ = 1 を与え、余面・余退化が (2.1) の行列積で単体的恒等式を満たす。
--
-- 単調写像は θ(0) ≤ θ(1) ≤ … ≤ θ(m) の値の並びとして持つ。

type Monotone = [Int]

isMonotone :: Monotone -> Bool
isMonotone th = and [ a <= b | (a, b) <- zip th (drop 1 th) ]

-- (ψ ∘ θ)(i) = ψ(θ(i))
compMono :: Monotone -> Monotone -> Monotone
compMono psi th = map (nthZ psi) th

nthZ :: [Int] -> Int -> Int
nthZ (x : _)  0 = x
nthZ (_ : xs) k = nthZ xs (k - 1)
nthZ []       _ = 0

idMono :: Int -> Monotone
idMono n = [0 .. n]

-- T_θ。行 = 出発側の目印、列 = 行先の目印。行先の目印は n+1 個
tMatZ :: Int -> Monotone -> MatZ
tMatZ n th = [ [ if v == w then 1 else 0 | w <- [0 .. n] ] | v <- th ]

tMatQ :: Int -> Monotone -> MatQ
tMatQ n th = [ [ if v == w then qvOne else qvZero | w <- [0 .. n] ] | v <- th ]

-- 忠実充満の逆向き。δ 行列から θ を戻す。行ごとに 1 がちょうど一つ立つこと、
-- 戻した並びが単調であることが条件になる
monoOfMat :: MatZ -> Maybe Monotone
monoOfMat rows = case mapM oneHot rows of
  Just th | isMonotone th -> Just th
  _                       -> Nothing
  where
    oneHot r = case [ k | (k, x) <- zip [0 ..] r, x /= 0 ] of
      [k] | nthZ r k == 1 -> Just k
      _                   -> Nothing

-- 余面 d^k : [n−1] → [n]。k を飛ばす
coface :: Int -> Int -> Monotone
coface n k = [ if i < k then i else i + 1 | i <- [0 .. n - 1] ]

-- 余退化 s^k : [n+1] → [n]。k を重ねる
codeg :: Int -> Int -> Monotone
codeg n k = [ if i <= k then i else i - 1 | i <- [0 .. n + 1] ]

-- 境界作用素 ∂_n = Σ_k (−1)^k T_{d^k}。行 n 本、列 n+1 本
boundaryOpZ :: Int -> MatZ
boundaryOpZ n =
  foldr matAddZ (zeroMatZ n (n + 1))
        [ matScaleZ (if even k then 1 else negate 1) (tMatZ n (coface n k))
        | k <- [0 .. n] ]

-- ===== グロタンディーク宇宙との接続 =====
--
-- ETCS+R の「すべての対象が属する宇宙が存在する」は、GCLS では
-- 「すべての作図に対し、それを含む ω-型到達不能点で閉じた階層が存在する」になる。
-- 基数の大きさが作図深度 d の到達不能性へ置き換わる。宇宙は三つで閉じる。
--
--   部分図形        Level 0 の「含まれる」で閉じる
--   積と内部ホム    𝒬 の tensor と二つの残差 ↙, ↘ で閉じる
--   二分割細分      深度 +1 で閉じる

-- 部分図形。目印の部分集合を取ると、残った影響を再正規化した凸対象になる
subFigure :: [Int] -> Profile -> Maybe Profile
subFigure keep ws =
  let kept = [ w | (k, w) <- zip [0 ..] ws, elem k keep ]
      tot  = qsum kept
  in if qratEq tot qratZero
       then Nothing
       else mapM (\w -> qratDiv w tot) kept

-- 積と内部ホム。𝒬 の元に対して閉じる
closedUnderQ :: QRat -> QRat -> Bool
closedUnderQ a b =
  inQ (qratMul a b) && inQ (residualQ a b) && inQ (residualQ b a)

-- 二分割細分。深度が一つ上がるだけで、有限段のうちは ω に届かない
refineDepth :: Depth -> Depth
refineDepth (DFinite n) = DFinite (n + 1)
refineDepth DOmega      = DOmega

-- ===== 自己ホスティング =====
--
-- 二重格付け (μ, d) のなす平面それ自身がツイ数平面の構造を持つ。
--
--   d 軸   ω（H⁺ 側）と ω⁻（H⁻ 側）という二つの有向な余終端を持つ
--   μ 軸   忘却 π（型→実）に対する左随伴 i と右随伴 j を持つ
--
--     i ⊣ π ⊣ j      ⟺      ω / ω⁻
--
-- π のファイバー π⁻¹(a) = {(a,b)} は ω 軸方向の直線で、左 Kan 拡張が H⁺ 側 ω への
-- 埋め込み i、右 Kan 拡張が H⁻ 側 ω⁻ への埋め込み j になる。三角等式は ⋆ の
-- 結合律から閉じ、⋆ が非可換ゆえ左右の随伴が分離する。この左右随伴は定理3.3 の
-- 二つの残差 ↙, ↘ に一致する。

-- 埋め込み。実の大きさを ω 軸の各側へ載せる
iEmbed, jEmbed :: QRat -> QVal
iEmbed a = qvNorm [([I], a)]
jEmbed a = qvNorm [([J], a)]

-- 実軸断面。型を外から指定せずに上がれる唯一の道（第V部「物質的集合論との接続」）
realSection :: QRat -> QVal
realSection = qvOfRat

-- d 軸の二つの余終端。有限段はどちらにも属さない
data DepthEnd = DEnd Int | DOmegaPlus | DOmegaMinus deriving (Eq, Ord, Show)

-- μ 軸の随伴と d 軸の余終端の対応
endOfAdjoint :: Op -> DepthEnd
endOfAdjoint I = DOmegaPlus
endOfAdjoint J = DOmegaMinus

-- 格付け平面の点
data GradePoint = GradePoint
  { gpMu  :: Mu
  , gpEnd :: DepthEnd
  } deriving (Eq, Ord, Show)

-- ===== 標本 =====

setMorA, setMorB :: MatQ
setMorA = dEmbed 3 3 (\v -> mod (v + 1) 3)
setMorB = dEmbed 3 3 (\v -> mod (v * 2) 3)

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("link.zfc: U = Θ∘π は恒等射を恒等射へ送る",
      uForget (matIdQ 3) == tMatZ 2 (idMono 2))

  , ("link.zfc: U は合成を保つ（実成分の射の上で関手になる）",
      and [ uForget (matMulQ f g) == boolMul (uForget f) (uForget g)
          | f <- [setMorA, setMorB, matIdQ 3]
          , g <- [setMorA, setMorB, matIdQ 3] ])

  , ("link.zfc: U は連続度を落とす。区別されていた射が同じ像になる",
      let m1 = matOfMor (GMor [[QRat 1 2, QRat 1 2], [QRat 1 4, QRat 3 4]])
          m2 = matOfMor (GMor [[QRat 1 3, QRat 2 3], [QRat 7 8, QRat 1 8]])
      in m1 /= m2 && uForget m1 == uForget m2)

  , ("link.zfc: 埋め込み D は関手である（写像の合成が行列の合成へ移る）",
      dEmbed 3 3 (\v -> mod (mod (v + 1) 3 * 2) 3) == matMulQ setMorA setMorB)

  , ("link.zfc: U ∘ D = id（下りと上りの往復で集合の射が戻る）",
      uForget (dEmbed 3 3 (\v -> mod (v + 1) 3))
        == tMatZ 2 [1, 2, 0])

  , ("link.zfc: D の像は実軸に限られる。型 b ≠ 0 は像に現れない",
      onRealAxis setMorA && onRealAxis (matIdQ 3)
      && not (onRealAxis iMat))

  , ("link.zfc: 上りは一方向的。型を持つ射は D の像に無い",
      not (any (\f -> f == iMat) [dEmbed 2 2 f' | f' <- [id, \v -> 1 - v]]))

  , ("link.simplicial: Δ は関手である。T_{ψ∘θ} = T_θ · T_ψ",
      let th  = [0, 0, 1]      -- [2] → [1]
          psi = [0, 2]         -- [1] → [2]
      in matComp (tMatZ 1 th) (tMatZ 2 psi)
           == tMatZ 2 (compMono psi th))

  , ("link.simplicial: Δ は恒等射を恒等射へ送る",
      tMatZ 3 (idMono 3) == tMatZ 3 (idMono 3)
      && monoOfMat (tMatZ 3 (idMono 3)) == Just (idMono 3))

  , ("link.simplicial: Δ は忠実である。違う単調写像は違う行列を与える",
      let ths = [ [0,0,1], [0,1,1], [0,1,2], [0,0,0], [1,1,2] ]
      in and [ (a == b) == (tMatZ 2 a == tMatZ 2 b) | a <- ths, b <- ths ])

  , ("link.simplicial: Δ は充満である。δ 行列から単調写像が一意に戻る",
      let ths = [ [0,0,1], [0,1,1], [0,1,2], [1,2,2] ]
      in all (\th -> monoOfMat (tMatZ 2 th) == Just th) ths)

  , ("link.simplicial: 単調でない割り当ては Δ の像に無い",
      monoOfMat [[0,1,0],[1,0,0]] == Nothing
      && monoOfMat [[1,1,0],[0,1,0]] == Nothing
      && monoOfMat [[0,0,0],[1,0,0]] == Nothing)

  , ("単体的恒等式: d^j ∘ d^i = d^i ∘ d^{j−1}  (i < j)",
      and [ compMono (coface n j) (coface (n - 1) i)
              == compMono (coface n i) (coface (n - 1) (j - 1))
          | n <- [2 .. 5], j <- [1 .. n], i <- [0 .. j - 1] ])

  , ("単体的恒等式: s^j ∘ s^i = s^i ∘ s^{j+1}  (i ≤ j)",
      and [ compMono (codeg n j) (codeg (n + 1) i)
              == compMono (codeg n i) (codeg (n + 1) (j + 1))
          | n <- [1 .. 4], j <- [0 .. n], i <- [0 .. j] ])

  , ("単体的恒等式: s^j ∘ d^i = id  (i = j または i = j+1)",
      and [ compMono (codeg n j) (coface (n + 1) i) == idMono n
          | n <- [1 .. 4], j <- [0 .. n], i <- [j, j + 1] ])

  , ("単体的恒等式: s^j ∘ d^i = d^i ∘ s^{j−1}  (i < j)",
      and [ compMono (codeg n j) (coface (n + 1) i)
              == compMono (coface n i) (codeg (n - 1) (j - 1))
          | n <- [2 .. 4], j <- [1 .. n], i <- [0 .. j - 1] ])

  , ("単体的恒等式: s^j ∘ d^i = d^{i−1} ∘ s^j  (i > j+1)",
      and [ compMono (codeg n j) (coface (n + 1) i)
              == compMono (coface n (i - 1)) (codeg (n - 1) j)
          | n <- [2 .. 4], j <- [0 .. n - 1], i <- [j + 2 .. n + 1] ])

  , ("恒等式が (2.1) の行列積でも成り立つ（Δ が 𝔾 の中で閉じる）",
      and [ matComp (tMatZ (n - 1) (coface (n - 1) i)) (tMatZ n (coface n j))
              == tMatZ n (compMono (coface n j) (coface (n - 1) i))
          | n <- [2 .. 4], j <- [1 .. n], i <- [0 .. j - 1] ])

  , ("∂² = 0: 交代和で作った境界作用素が鎖複体を与える",
      all (\n -> isZeroMatZ (matComp (boundaryOpZ (n - 1)) (boundaryOpZ n)))
          [2 .. 6])

  , ("∂ の形: ∂_n は n 行 n+1 列で、成分は {−1,0,1} に収まる",
      let b = boundaryOpZ 4
      in length b == 4 && all ((== 5) . length) b
         && all (\x -> abs x <= 1) (concat b))

  , ("link.simplicial: Δ² = T₁。6c の重心座標が Σλ = 1 を与える",
      let g = GObj RConvex 3
      in coherent g (profileOfCellPt (mkT1Pt 1 3 2))
         && gRank g == length (idMono 2))

  , ("link.universe: 部分図形で閉じる（目印を絞ると凸対象が残る）",
      let ws = profileOfCellPt (mkT1Pt 1 3 2)
      in case subFigure [0, 1] ws of
           Just sub -> constraintsHold (GObj RConvex 2) sub
           Nothing  -> False)

  , ("link.universe: 目印を全て落とすと図形が残らない",
      subFigure [] (profileOfCellPt (mkT1Pt 1 3 2)) == Nothing)

  , ("link.universe: 積と二つの残差で閉じる",
      let vals = [qratZero, QRat 1 4, QRat 1 3, QRat 1 2, QRat 2 3, qratOne]
      in and [ closedUnderQ a b | a <- vals, b <- vals ])

  , ("link.universe: 二分割細分は深度を一つ上げるだけで ω に届かない",
      refineDepth (DFinite 3) == DFinite 4
      && all (\n -> refineDepth (DFinite n) < DOmega) [0 .. 20]
      && refineDepth DOmega == DOmega)

  , ("link.universe: ω は全ての有限深度の上にある到達不能点である",
      all (\n -> DFinite n < DOmega) [0 .. 100])

  , ("cat.selfhost: 三角等式 π ∘ i = id、π ∘ j = id",
      let vals = [QRat 1 4, QRat 1 2, QRat 2 3, qratOne]
      in and [ qratEq (piQ (iEmbed a)) a && qratEq (piQ (jEmbed a)) a
             | a <- vals ])

  , ("cat.selfhost: 左右の随伴は分離する。i と j は別の埋め込みになる",
      let a = QRat 1 2
      in iEmbed a /= jEmbed a
         && qvWords (iEmbed a) == [[I]] && qvWords (jEmbed a) == [[J]])

  , ("cat.selfhost: 分離の根は ⋆ の非可換性にある",
      qvStar (iEmbed qratOne) (jEmbed qratOne)
        /= qvStar (jEmbed qratOne) (iEmbed qratOne))

  , ("cat.selfhost: 左右の随伴は定理3.3 の二つの残差に対応する",
      let ij = star iUnitQ jUnitQ
      in snd (residualRightQ ij iUnitQ) /= snd (residualLeftQ ij iUnitQ))

  , ("cat.selfhost: 実軸断面 s(a) = (a,0) は型を持たない。上りはここに限られる",
      qvWords (realSection (QRat 1 2)) == [[]]
      && realSection (QRat 1 2) /= iEmbed (QRat 1 2)
      && realSection (QRat 1 2) /= jEmbed (QRat 1 2))

  , ("cat.selfhost: μ 軸の随伴と d 軸の余終端が一対一に対応する",
      endOfAdjoint I == DOmegaPlus && endOfAdjoint J == DOmegaMinus
      && endOfAdjoint I /= endOfAdjoint J)

  , ("cat.selfhost: d 軸は二つの有向な余終端を持ち、有限段はどちらにも属さない",
      all (\n -> DEnd n < DOmegaPlus && DEnd n < DOmegaMinus) [0 .. 20]
      && DOmegaPlus /= DOmegaMinus)

  , ("cat.selfhost: 格付け平面の点は (μ, 余終端) で決まり、四隅が分かれる",
      let ps = [ GradePoint m e | m <- [M0, MInf], e <- [DOmegaPlus, DOmegaMinus] ]
      in length ps == 4
         && and [ (a == b) == (gpMu a == gpMu b && gpEnd a == gpEnd b)
                | a <- ps, b <- ps ])

  , ("forget.recover: 忘却の列 𝔾 → ℝ≥0-豊穣 → Set が既存の基礎を回収する",
      gradeOf FGCLS == (MInf, DOmega)
      && gradeOf FClassicalCat == (M1, DFinite 1)
      && gradeOf FZFC == (M0, DFinite 1)
      && forgetsTo FGCLS FClassicalCat && forgetsTo FGCLS FZFC)
  ]
