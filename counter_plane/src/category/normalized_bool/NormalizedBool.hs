{-# LANGUAGE NoImplicitPrelude #-}
module NormalizedBool where

import CounterConstraints
import DagArith
import DagInfluence hiding (selfcheck)
import Quantale hiding (selfcheck)

-- ===== 論理関数の一意正規形 =====
-- doc: bit.geometry cube.W logic.as.morphism anf.unique zeta.mobius
-- doc: unique.ground anf.binary anf.summary
--
--   §1  1ビットを幾何として置く          w(ℓ₁,x) = x、w(ℓ₀,x) = 1 − x
--   §2  nビットを積として置く            W_S(x) = Π_k (S_k x_k + (1−S_k)(1−x_k))
--   §3  論理関数を射として読む            T_f(ℓ_S, ℓ₁) = f(S)、(⋆) が補間式を渡す
--   §4  実係数の正規形とその一意性        ゼータ Z の三角性とメビウス M
--   §5  含まれると境界が一意性を支える     Level 0 の「含まれる」と ∂² = 0
--   §6  二値への畳み込みと代数標準形      a_T = c_T mod 2
--
-- 正規形は幾何の側から強制される。立方体のどの頂点に出力値を立てるかを決めれば、
-- 内部への補間は影響関数で一意に決まり、二値への畳み込みで ANF が一意に決まる。
-- 途中に設計の自由はない。

-- ===== 部分集合 = ビットマスク =====
--
-- 単項式 x^T の番号 T は「どの入力の影響の道を一緒に保持したか」という部分集合で、
-- 部分集合どうしの包含が Level 0 の「含まれる」にあたる。

type Sub = Int

subsetsN :: Int -> [Sub]
subsetsN n = [0 .. shiftL (1 :: Int) n - 1]

-- T ⊆ R
isSub :: Sub -> Sub -> Bool
isSub t r = t .&. r == t

-- 頂点 𝟏_R の座標。成分が R の指示ベクトルになる
vertexPt :: Int -> Sub -> [QRat]
vertexPt n r = [ if testBit r k then qratOne else qratZero | k <- [0 .. n - 1] ]

-- ===== §1: 1ビットを幾何として置く =====
--
-- 1ビットは Level 1 の開区間を 1-単体に取り、両端に目印 ℓ₀, ℓ₁ を置いたもの。
-- 区間の中の点 x が各目印から受ける影響は 6c のタレス比をそのまま当てて
--
--   w(ℓ₁, x) = x,      w(ℓ₀, x) = 1 − x
--
-- になる。証明3.1 の凸性の拘束がそのまま効いて和は 1、どちらも負にならない。
-- 鋭いビット値は Θ で取り出す。ビット 1 は ℓ₁ に座る点の像、0 は ℓ₀ の像になる。

bitInfluence :: QRat -> Profile
bitInfluence x = [qratSub qratOne x, x]

bitObj :: GObj
bitObj = GObj RConvex 2

-- Θ: 連続な区間を二つの端点へ送る（μ:1→0 の最後の一段）
sharpBit :: QRat -> Int
sharpBit = thetaQ

-- ===== §2: nビットを積として置く =====
--
--   W_S(x) = Π_{k=1}^{n} ( S_k x_k + (1−S_k)(1−x_k) )
--
-- 各因子は軸 k について「S_k = 1 なら x_k、S_k = 0 なら 1 − x_k」を選んだもので、
-- 1-単体の影響を掛け合わせた形になる。掛け算を選ぶのは、立方体の中で内部点に届く道が
-- 各軸方向の道に分かれ、独立な方向に沿って影響が積み重なるからで、
-- 「乗算は経路を保持する」が影響を軸ごとの寄与の積として残す形になっている。

cubeObj :: Int -> GObj
cubeObj n = GObj RConvex (shiftL (1 :: Int) n)

cubeW :: Sub -> [QRat] -> QRat
cubeW s xs = foldr qratMul qratOne
  [ if testBit s k then x else qratSub qratOne x | (k, x) <- zip [0 ..] xs ]

-- 立方体の内部点の影響プロファイル。頂点 2^n 個ぶんの成分を持つ
cubeProfile :: Int -> [QRat] -> Profile
cubeProfile n xs = [ cubeW s xs | s <- subsetsN n ]

-- 性質1: W_S(𝟏_R) = [S = R]。恒等射の遷移係数 δ が頂点上で満たす形と重なる
propVertex :: Int -> Bool
propVertex n =
  and [ qratEq (cubeW s (vertexPt n r)) (if s == r then qratOne else qratZero)
      | s <- subsetsN n, r <- subsetsN n ]

-- 性質2: Σ_S W_S(x) = 1。証明3.1 の凸性の拘束が立方体でも成り立つ
propSum :: Int -> [QRat] -> Bool
propSum n xs = qratEq (qsum (cubeProfile n xs)) qratOne

-- 性質3: 各軸について一次。W_S は x_k について
--
--   W_S(x) = (1 − x_k) · W_S|_{x_k = 0} + x_k · W_S|_{x_k = 1}
--
-- と書ける。だから W_S は多重線形の式になる
setAt :: Int -> QRat -> [QRat] -> [QRat]
setAt k v xs = [ if i == k then v else x | (i, x) <- zip [0 ..] xs ]

propMultilinear :: Int -> [QRat] -> Bool
propMultilinear n xs =
  and [ qratEq (cubeW s xs)
                (qratAdd (qratMul (qratSub qratOne xk) (cubeW s (setAt k qratZero xs)))
                         (qratMul xk (cubeW s (setAt k qratOne xs))))
      | s <- subsetsN n, k <- [0 .. n - 1]
      , let xk = nthQ k xs ]

nthQ :: Int -> [QRat] -> QRat
nthQ 0 (x : _)  = x
nthQ k (_ : xs) = nthQ (k - 1) xs
nthQ _ []       = qratZero

-- ===== §3: 論理関数を射として読む =====
--
-- 論理関数 f は立方体の各頂点 ℓ_S に鋭い出力値 f(S) を割り当てる。これを、入力の
-- 立方体（目印 2^n 個）から出力のビット区間（目印 ℓ₀, ℓ₁）への射として読む。
--
--   T_f(ℓ_S, ℓ₁) = w_out(ℓ₁, f(ℓ_S)) = f(S)
--
-- 出力目印 ℓ₁ が鋭い出力値から受ける影響は、f(S) = 1 のとき 1、そうでないとき 0 で、
-- ちょうど f(S) に等しい。だから射 f の遷移係数の表は f の真理値表そのものになる。
--
-- 内部点での出力は整合条件 (⋆) が渡す。
--
--   w_out(ℓ₁, f(x)) = Σ_S T_f(ℓ_S, ℓ₁) · W_S(x) = Σ_S f(S) W_S(x) =: f̃(x)

morOfFun :: Int -> (Sub -> Integer) -> GMor
morOfFun n f = GMor [ [ qratSub qratOne (fq s), fq s ] | s <- subsetsN n ]
  where fq s = qratOf (f s) 1

-- (⋆) の適用そのもの。出力側の目印 ℓ₁ の成分が f̃(x) になる
tildeByStar :: Int -> (Sub -> Integer) -> [QRat] -> QRat
tildeByStar n f xs = nthQ 1 (starApply (cubeProfile n xs) (morOfFun n f))

-- 補間式を直接書いたもの
tildeF :: Int -> (Sub -> Integer) -> [QRat] -> QRat
tildeF n f xs = qsum [ qratMul (qratOf (f s) 1) (cubeW s xs) | s <- subsetsN n ]

-- ===== §4: 実係数の正規形とその一意性 =====
--
-- 単項式 x^T = Π_{k∈T} x_k で展開すると f̃(x) = Σ_T c_T x^T になる。頂点 𝟏_R では
-- x^T = [T ⊆ R] なので
--
--   f(R) = Σ_{T ⊆ R} c_T                                            (Z)
--
-- Z_{R,T} = [T ⊆ R] は対角がすべて 1 の三角行列だから可逆で、逆は
--
--   c_T = Σ_{R ⊆ T} (−1)^{|T|−|R|} f(𝟏_R)                           (M)
--
-- になる。符号 (−1)^{|T|−|R|} は部分集合の包含という階層の上のメビウス関数で、
-- 証明3.2 の境界作用素 ∂ が単体に与える符号と同じ向きづけから来ている。

monomial :: Sub -> [QRat] -> QRat
monomial t xs = foldr qratMul qratOne
  [ x | (k, x) <- zip [0 ..] xs, testBit t k ]

mobiusCoef :: Int -> (Sub -> Integer) -> Sub -> Integer
mobiusCoef n f t =
  sum [ sgn * f r
      | r <- subsetsN n
      , isSub r t
      , let sgn = if even (popCount t - popCount r) then 1 else negate 1
      ]

zetaVal :: Int -> (Sub -> Integer) -> Sub -> Integer
zetaVal n c r = sum [ c t | t <- subsetsN n, isSub t r ]

-- 単項式展開。(M) の係数で書いた式
tildeFromCoef :: Int -> (Sub -> Integer) -> [QRat] -> QRat
tildeFromCoef n f xs =
  qsum [ qratMul (qratOf (mobiusCoef n f t) 1) (monomial t xs) | t <- subsetsN n ]

-- ゼータの三角性。T が R に含まれないと 0、対角は 1
zetaTriangular :: Int -> Bool
zetaTriangular n =
  and [ not (isSub t r) || popCount t <= popCount r
      | t <- subsetsN n, r <- subsetsN n ]
  && all (\r -> isSub r r) (subsetsN n)

-- メビウスの打ち消しの等式。U ⊆ R に対して
--
--   Σ_{T : U ⊆ T ⊆ R} (−1)^{|T|−|U|} = [U = R]
--
-- T = U ∪ A（A ⊆ R∖U）と置き m = |R∖U| とすると和は (1−1)^m になる
cancelSum :: Int -> Sub -> Sub -> Integer
cancelSum n u r =
  sum [ if even (popCount t - popCount u) then 1 else negate 1
      | t <- subsetsN n, isSub u t, isSub t r ]

-- ===== §5: 含まれると境界が一意性を支える =====
--
-- (Z) と (M) に出てくる包含 T ⊆ R は Level 0 の「含まれる」を単項式の番号に当てたもの。
-- 部分集合の全体はこの「含まれる」で順序づいたブール束をなす。束の上で「含まれる所を
-- 全部足す」がゼータ、それを打ち消して戻すのがメビウスになる。
--
-- 打ち消しの符号は証明3.2 の ∂ と同じ向きづけであり、∂² = 0 が部分集合の階層を
-- 一つの鎖複体として閉じさせる。だから一意性は代数の都合ではなく、Level 0 の
-- 「含まれる」と ℝ³ の境界の構造から来ている。
--
-- 実行形では、階層の上の交代和がちょうど二段で消えることを見る。

-- 部分集合を単体として読む。番号 T の立位ビットがそのまま頂点になる
simplexOfSub :: Int -> Sub -> Simplex
simplexOfSub n t = simplex [ k | k <- [0 .. n - 1], testBit t k ]

subOfSimplex :: Simplex -> Sub
subOfSimplex sg = foldr (\k acc -> setBit acc k) (0 :: Sub) (vertices sg)

-- 階層の上の境界。符号は要素より下位に立つビットの個数で決まる。
-- (−1)^{|T|−|R|} ではない: 一段落ちるとき |T|−|R| は常に 1 なので、
-- その読みでは全ての面が同じ符号になり、二段で打ち消しが起きない。
subBoundary :: Int -> Sub -> [(Int, Sub)]
subBoundary n t = [ (c, subOfSimplex f) | (c, f) <- boundary (simplexOfSub n t) ]

-- ∂² = 0。証明3.2 が ℝ³ の制約1 から示したものをそのまま使う
chainSquareZero :: Int -> Sub -> Bool
chainSquareZero n t = d2Zero (simplexOfSub n t)

-- ===== §6: 二値への畳み込みと代数標準形 =====
--
-- 記憶深度を μ:∞→0 と畳むと連続な真理対象 [0,1] が二値 {0,1} へ移る。
-- 頂点値が 0 か 1 なので (M) の c_T は整数になり、符号 (−1)^{|T|−|R|} は 2 で
-- 割った余りではどれも 1 になるから
--
--   a_T = c_T mod 2
--
-- が成り立つ。乗算 ⋆ は二値の上で論理積に、足し上げは排他的論理和に縮む。

anfBit :: Int -> (Sub -> Integer) -> Sub -> Integer
anfBit n f t = mod (mobiusCoef n f t) 2

anfByXor :: Int -> (Sub -> Integer) -> Sub -> Integer
anfByXor n f t = mod (sum [ f r | r <- subsetsN n, isSub r t ]) 2

-- ANF の頂点評価: f(R) = ⊕_{T⊆R} a_T
evalAnf :: Int -> (Sub -> Integer) -> Sub -> Integer
evalAnf n a r = mod (sum [ a t | t <- subsetsN n, isSub t r ]) 2

-- 単項式の選択マスクとしての ANF。sel の第 t ビットが x^T の採否
evalAnfMask :: Int -> Integer -> Sub -> Integer
evalAnfMask n sel x =
  toInteger (mod (length [ t | t <- subsetsN n, testBit sel t, isSub t x ]) 2)

anfMaskMatches :: Int -> Integer -> (Sub -> Integer) -> Bool
anfMaskMatches n sel f =
  and [ evalAnfMask n sel r == f r | r <- subsetsN n ]

roundTrip :: Int -> (Sub -> Integer) -> Bool
roundTrip n f = and [ zetaVal n (mobiusCoef n f) r == f r | r <- subsetsN n ]

-- ===== 標本 =====

orFun, xorFun, majFun :: Sub -> Integer
orFun r  = if r == 0 then 0 else 1
xorFun r = toInteger (mod (popCount r) 2)
majFun r = if popCount r >= 2 then 1 else 0

-- 立方体の内部点。二進比でない成分も混ぜる
interior2, interior3 :: [QRat]
interior2 = [QRat 1 3, QRat 3 4]
interior3 = [QRat 1 3, QRat 3 4, QRat 2 5]

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("§1: 1ビットの影響は w(ℓ₁,x) = x、w(ℓ₀,x) = 1 − x。和は 1 で非負",
      all (\x -> constraintsHold bitObj (bitInfluence x))
          [qratZero, QRat 1 4, QRat 1 3, QRat 1 2, qratOne])

  , ("§1: 端点では影響が (1,0) と (0,1) になる",
      bitInfluence qratZero == [qratOne, qratZero]
      && bitInfluence qratOne == [qratZero, qratOne])

  , ("§1: 鋭いビット値は Θ で取り出す",
      sharpBit qratOne == 1 && sharpBit qratZero == 0
      && sharpBit (QRat 1 3) == 1)

  , ("§2 性質1: W_S(𝟏_R) = [S = R]（立方体版クロネッカー）",
      all propVertex [1, 2, 3])

  , ("§2 性質2: Σ_S W_S(x) = 1。内部点でも凸性の拘束が立つ",
      propSum 2 interior2 && propSum 3 interior3
      && propSum 2 [QRat 1 2, QRat 1 2])

  , ("§2 性質2: 立方体は 2^n 個の頂点目印を持つ凸影響対象になる",
      constraintsHold (cubeObj 2) (cubeProfile 2 interior2)
      && constraintsHold (cubeObj 3) (cubeProfile 3 interior3))

  , ("§2 性質3: W_S は各軸について一次（多重線形）",
      propMultilinear 2 interior2 && propMultilinear 3 interior3)

  , ("§2: 二進比でない成分でも正確に扱える（1/3 が分母に立つ）",
      qratEq (cubeW 0 [QRat 1 3, QRat 3 4]) (QRat 1 6)
      && qratEq (cubeW 3 [QRat 1 3, QRat 3 4]) (QRat 1 4))

  , ("§3: 遷移係数の表は真理値表そのもの。T_f(ℓ_S, ℓ₁) = f(S)",
      morRows (morOfFun 2 orFun)
        == [ [qratOne, qratZero], [qratZero, qratOne]
           , [qratZero, qratOne], [qratZero, qratOne] ])

  , ("§3: 射は凸図形の間の射になる（行和 1・非負）",
      convexMor (morOfFun 2 orFun) && convexMor (morOfFun 3 majFun))

  , ("§3: (⋆) が補間式をそのまま渡す — f̃(x) = Σ_S f(S) W_S(x)",
      and [ qratEq (tildeByStar n f xs) (tildeF n f xs)
          | (n, f, xs) <- [ (2, orFun, interior2), (2, xorFun, interior2)
                          , (3, majFun, interior3) ] ])

  , ("§4: 頂点で f̃ は元の論理関数に一致する（性質1 の帰結）",
      and [ qratEq (tildeF n f (vertexPt n r)) (qratOf (f r) 1)
          | (n, f) <- [(2, orFun), (2, xorFun), (3, majFun)]
          , r <- subsetsN n ])

  , ("§4: 単項式展開が補間式と一致する — Σ_S f(S) W_S(x) = Σ_T c_T x^T",
      and [ qratEq (tildeF n f xs) (tildeFromCoef n f xs)
          | (n, f, xs) <- [ (2, orFun, interior2), (2, xorFun, interior2)
                          , (3, majFun, interior3)
                          , (2, orFun, [QRat 1 2, QRat 1 5]) ] ])

  , ("§4: ゼータは対角 1 の三角行列である（|T| > |R| なら T ⊄ R）",
      all zetaTriangular [1, 2, 3])

  , ("§4: メビウス → ゼータの往復が真理値表に戻る（一意性）",
      roundTrip 2 orFun && roundTrip 2 xorFun && roundTrip 3 majFun)

  , ("§4: 打ち消しの等式 Σ_{U⊆T⊆R} (−1)^{|T|−|U|} = [U = R]",
      and [ cancelSum n u r == (if u == r then 1 else 0)
          | n <- [2, 3], r <- subsetsN n, u <- subsetsN n, isSub u r ])

  , ("§4: 係数は頂点値から一意に決まる。値を一つ変えると係数が変わる",
      let f1 = orFun
          f2 r = if r == 1 then 0 else orFun r
      in any (\t -> mobiusCoef 2 f1 t /= mobiusCoef 2 f2 t) (subsetsN 2))

  , ("§5: 部分集合の階層は「含まれる」で順序づく（Level 0 の原始）",
      and [ isSub (t .&. r) t && isSub (t .&. r) r
          | t <- subsetsN 3, r <- subsetsN 3 ])

  , ("§5: 階層は ∂² = 0 で鎖複体として閉じる（打ち消しが過不足なく働く）",
      all (chainSquareZero 3) (subsetsN 3)
      && all (chainSquareZero 4) (subsetsN 4))

  , ("§5: 境界の符号は下位ビットの個数で交代する（証明3.2 と同じ向きづけ）",
      subBoundary 3 7 == [(1, 6), (negate 1, 5), (1, 3)]
      && all (\(c, _) -> abs c == 1) (subBoundary 3 7))

  , ("§5: 一段落ちるだけでは符号が決まらない。位置が要る",
      and [ popCount t - popCount r == 1
          | t <- subsetsN 3, (_, r) <- subBoundary 3 t ])

  , ("§5: 一意性は幾何から出ている — 三角性と ∂² の向きづけ",
      zetaTriangular 3 && all (chainSquareZero 3) (subsetsN 3)
      && roundTrip 3 majFun)

  , ("§6: a_T = c_T mod 2。実係数を 2 で割った余りが ANF の係数になる",
      and [ anfBit n f t == anfByXor n f t
          | (n, f) <- [(2, orFun), (2, xorFun), (3, majFun)]
          , t <- subsetsN n ])

  , ("§6: OR = x₁ ⊕ x₂ ⊕ x₁x₂（a_∅=0, a_1=1, a_2=1, a_12=1）",
      map (anfBit 2 orFun) (subsetsN 2) == [0, 1, 1, 1])

  , ("§6: ANF の再構成が真理値表と一致する",
      and [ all (\r -> evalAnf n (anfBit n f) r == f r) (subsetsN n)
          | (n, f) <- [(2, orFun), (2, xorFun), (3, majFun)] ])

  , ("§6: 最簡性 — OR を表す ANF マスクは一つだけで、項数は 3",
      let matches = [ sel | sel <- [0 .. 15] :: [Integer]
                    , anfMaskMatches 2 sel orFun ]
          anfSel  = sum [ shiftL (1 :: Integer) t
                        | t <- subsetsN 2, anfBit 2 orFun t == 1 ]
      in matches == [anfSel] && popCount anfSel == 3)

  , ("§6: 二値の正規形も一意（GF(2) でも三角行列の対角が 1）",
      and [ length [ sel | sel <- [0 .. shiftL (1 :: Integer) (shiftL 1 n) - 1]
                   , anfMaskMatches n sel f ] == 1
          | (n, f) <- [(2, orFun), (2, xorFun)] ])

  , ("まとめ: 頂点値を決めれば内部への補間も二値の正規形も一意に決まる",
      let f = majFun; n = 3
      in qratEq (tildeF n f interior3) (tildeFromCoef n f interior3)
         && all (\r -> evalAnf n (anfBit n f) r == f r) (subsetsN n)
         && roundTrip n f)
  ]
