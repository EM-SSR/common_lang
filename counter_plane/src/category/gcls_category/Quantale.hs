{-# LANGUAGE NoImplicitPrelude #-}
module Quantale (module Quantale, module DagArith) where

import CounterConstraints
import CounterUnits (Op (..))
import DagArith hiding (selfcheck)

-- ===== 豊穣の基底 𝒬（圏論 第III部「豊穣の基底」、定理3.3）=====
-- doc: Q.base Q.quantale star.distrib_sup star.noncommute residual.adjoint
-- doc: arith.mul mul.distribute snf.word
--
-- ドキュメントは 𝒬 を二通りに書いている。両方を型として分けて持つ。
--
--   単項式  QCoeff   大きさ × 分岐語 × 符号。3章② の「方向の合成」そのもの
--   一般元  QVal     単項式の形式和。3章③ の「一般の積」が閉じる場所
--
-- なぜ二つ要るか。3章③ は一般の積を
--
--     p₁ ⋆ p₂ = a₁ ⋆ p₂ ⊕ b₁ ⋆ p₂                              (3③)
--
-- と分配で定める。右辺は型の違う二項の和だから、単項式一個では受けきれない。
-- 遷移係数 T_f の成分はこの和の側にある。だから (2.1) の ⋆-行列積は QVal 上で
-- 走る。単項式だけで書くと、和を取った瞬間に型を落とすことになる。
--
-- 台と順序について、ドキュメントは 𝒬 = ([0,1], ≤, ⋆, 1) と書き、同時に ⋆ が
-- 非可換だと言う。大きさだけの [0,1] の上でタレス乗算は可換なので、この二つは
-- そのままでは両立しない。非可換性を担っているのは分岐語（型）である。
-- したがって実装では
--
--     𝒬 = 分岐語で格付けされた QVal        ⋆ は非可換
--     π : QVal → [0,1]                     係数の総和。型を落とす準同型
--
-- と置く。π が命題3.2 の「対称化は型忘却に等しい」であり、定義3.4 の μ:∞→1 に
-- あたる。ドキュメントの [0,1] は π の像にあたる。

-- ===== 分岐語と意味的正規形 snf =====
--
-- Σ = {i, j}。書き換えは 3章② の自乗表そのもの。
--
--     i i ⇒ ρ⁻¹  （符号が反転する）
--     j j ⇒ ρ⁺¹  （符号はそのまま）
--     i j ⇏ j i  （臨界対は解消しない。これが非可換性の構文的な中身）
--
-- 正規形は i と j が交互に並ぶ語で、符号は別の欄に落ちる。

type BWord = [Op]

-- 語の末尾へ一単位足す。同じ単位が来たら畳んで符号へ移す
pushW :: Op -> (BWord, Int) -> (BWord, Int)
pushW u (w, sgn) = case reverse w of
  (u' : rest) | u' == u -> case u of
    I -> (reverse rest, negate sgn)
    J -> (reverse rest, sgn)
  _ -> (w ++ [u], sgn)

-- 語の接合。左から右へ畳むので snf(u v) が出る
mulWord :: (BWord, Int) -> (BWord, Int) -> (BWord, Int)
mulWord (w, s) (w', s') = foldl (flip pushW) (w, s * s') w'

snfWord :: BWord -> (BWord, Int)
snfWord ops = foldl (flip pushW) ([], 1) ops

-- 語の逆元。i⁻¹ = σi、j⁻¹ = j。反転で i の個数は変わらないので符号は動かない
invWord :: (BWord, Int) -> (BWord, Int)
invWord (w, s) = (reverse w, s)

-- 正規形かどうか。同じ単位が隣り合わない
snfNormal :: BWord -> Bool
snfNormal w = and [ a /= b | (a, b) <- zip w (drop 1 w) ]

-- ===== 単項式 QCoeff =====
--
-- 大きさは二進比 n/2^d で持つ。6d の二分割が作る値はすべてこの形になる。
-- 語と符号が 3章② の方向合成を運ぶ。

data QCoeff = QCoeff
  { qNum  :: Int
  , qDep  :: Int
  , qWord :: BWord
  , qSign :: Int
  } deriving (Eq, Read, Show)   -- Read: CommonChamber.Value の直列化で使う

unitQ, zeroQ :: QCoeff
unitQ = QCoeff 1 0 [] 1
zeroQ = QCoeff 0 0 [] 1

iUnitQ, jUnitQ :: QCoeff
iUnitQ = QCoeff 1 0 [I] 1
jUnitQ = QCoeff 1 0 [J] 1

opToQ :: Op -> QCoeff
opToQ I = iUnitQ
opToQ J = jUnitQ

-- ⋆ = ① 大きさのタレス乗算 ＋ ② 方向の合成（定理3.1 の係数版）
star :: QCoeff -> QCoeff -> QCoeff
star (QCoeff n d w s) (QCoeff n' d' w' s') =
  let (w2, s2) = mulWord (w, s * s') (w', 1)
  in QCoeff (n * n') (d + d') w2 s2

-- 大きさ。符号は含まない。残差と整合対はこの読みを使う（07 §1 は大きさの比）
magOf :: QCoeff -> QRat
magOf (QCoeff n d _ _) = qratDyad (toInteger n) d

-- 符号込みの値。形式和へ埋めるときはこちら。i ⋆ i = −1 の符号がここで効く
signedMagOf :: QCoeff -> QRat
signedMagOf q = applySign (qSign q) (magOf q)

-- 語 u の適用 f_u(x)。語は左から右へ、点には右から掛かる:
--   f_{ij}(O) = (O ⋆ i) ⋆ j = ij
-- ⋆ が非可換なので適用順が意味を持つ（07 例5.1）
applyWord :: BWord -> QCoeff -> QCoeff
applyWord ops x = foldl (\acc o -> star acc (opToQ o)) x ops

-- ===== 一般元 QVal = 単項式の形式和 =====
--
-- 語ごとに一つの係数を持つ。語は昇順、係数 0 の項は落とす。この正規化のおかげで
-- derived な Eq が値の相等と一致する。
--
--     p = Σ_u  a_u · u,      a_u ∈ ℚ,  u ∈ {i,j}*/snf
--
-- 3章③ の一般の積はこの上で閉じる。加算 ⊕ は平行四辺形則（語ごとに足す。
-- 語が違えば混ざらない = 加算は経路を忘れない方向へは働かない）、
-- 乗算 ⋆ は畳み込み（語を接合して snf で畳む）。

newtype QVal = QVal { qvTerms :: [(BWord, QRat)] } deriving (Eq, Read, Show)

-- 語の昇順へ整列し、同じ語をまとめ、0 を落とす。
-- 整列の鍵は語だけである。QRat に Ord を derive すると分子分母の辞書順になり、
-- 値の順序 qratLeq と一致しない比較が黙って通るので、鍵は明示して持つ
qvNorm :: [(BWord, QRat)] -> QVal
qvNorm ts = QVal (collect (sortByWord ts))
  where
    collect [] = []
    collect ((w, c) : rest) =
      let (same, others) = span (\(w', _) -> w' == w) rest
          total = foldr qratAdd c (map snd same)
      in if qratEq total qratZero
           then collect others
           else (w, total) : collect others

sortByWord :: [(BWord, QRat)] -> [(BWord, QRat)]
sortByWord = foldr ins []
  where
    ins x []                        = [x]
    ins x@(w, _) (y@(w', _) : rest)
      | w <= w'   = x : y : rest
      | otherwise = y : ins x rest

qvZero, qvOne :: QVal
qvZero = QVal []
qvOne  = QVal [([], qratOne)]

-- 単項式の埋め込み。𝒬 の格付けの一段を取り出す
qvOfCoeff :: QCoeff -> QVal
qvOfCoeff q = qvNorm [(qWord q, signedMagOf q)]

qvOfRat :: QRat -> QVal
qvOfRat c = qvNorm [([], c)]

-- 語 u の成分を読む。書かれていない語の係数は 0
qvAt :: BWord -> QVal -> QRat
qvAt w (QVal ts) = maybe qratZero id (lookup w ts)

qvWords :: QVal -> [BWord]
qvWords (QVal ts) = map fst ts

-- ⊕ 加算（平行四辺形則）。語ごとに足す
qvAdd :: QVal -> QVal -> QVal
qvAdd (QVal a) (QVal b) = qvNorm (a ++ b)

qvNeg :: QVal -> QVal
qvNeg (QVal a) = QVal [ (w, qratNeg c) | (w, c) <- a ]

qvSub :: QVal -> QVal -> QVal
qvSub x y = qvAdd x (qvNeg y)

qvSum :: [QVal] -> QVal
qvSum = foldr qvAdd qvZero

-- ⋆ 乗算。3章③ の分配をそのまま書いたもの。
-- 語は接合して snf で畳み、畳みで出た符号は係数へ移す
qvStar :: QVal -> QVal -> QVal
qvStar (QVal a) (QVal b) = qvNorm
  [ (w2, applySign s2 (qratMul c d))
  | (u, c) <- a
  , (v, d) <- b
  , let (w2, s2) = mulWord (u, 1) (v, 1) ]

applySign :: Int -> QRat -> QRat
applySign s c = if s < 0 then qratNeg c else c

-- 実の大きさによるスケーリング（3章③ の a₁ ⋆ p₂ の項）
qvScale :: QRat -> QVal -> QVal
qvScale c (QVal a) = qvNorm [ (w, qratMul c d) | (w, d) <- a ]

-- ===== 順序と上限（定理3.3 の束の側）=====
--
-- 格付けごとの比較。同じ語の成分どうしを比べる。これが ⋀/⋁ を持つ完備束の骨で、
-- 有限台なので上限は成分ごとの最大で書ける。

qvLeq :: QVal -> QVal -> Bool
qvLeq x y = and [ qratLeq (qvAt w x) (qvAt w y) | w <- allWords x y ]

allWords :: QVal -> QVal -> [BWord]
allWords x y = dedup (sort (qvWords x ++ qvWords y))
  where
    dedup []  = []
    dedup [a] = [a]
    dedup (a : b : rest)
      | a == b    = dedup (b : rest)
      | otherwise = a : dedup (b : rest)

qvJoin :: QVal -> QVal -> QVal
qvJoin x y = qvNorm [ (w, qratMax (qvAt w x) (qvAt w y)) | w <- allWords x y ]

qvJoinAll :: [QVal] -> QVal
qvJoinAll = foldr qvJoin qvZero

qvMeet :: QVal -> QVal -> QVal
qvMeet x y = qvNorm [ (w, qratMin (qvAt w x) (qvAt w y)) | w <- allWords x y ]

-- ===== 記憶深度の忘却（命題3.2、定義3.4）=====
--
--   π : 𝒬 → ℝ≥0      型と符号を落とし、大きさだけを残す（μ:∞→1）
--   Θ : ℝ≥0 → {0,1}  正の連続度を 1 へ畳む（μ:1→0）
--
-- 命題3.2 が言うのは π(ij) = π(ji) = 1、すなわち型を落とすと ij と ji の
-- 区別が消えるということである。
--
-- 単項式では π は積を積へ送る:
--
--     π(m·u ⋆ m'·v) = m m' = π(m·u) · π(m'·v)
--
-- 形式和では等号が緩む。語が畳んで符号が反転すると項どうしが打ち消し、
-- 大きさが落ちるからである。
--
--     π(a ⋆ b) ≤ π(a) · π(b)
--
-- この緩みは欠陥ではなく、定理3.4 の豊穣の合成律
-- 𝔾(H,K) ⋆ 𝔾(G,H) ≤ 𝔾(G,K) と同じ形をしている。等号が要るのは単項式の段で、
-- 不等号で足りるのが豊穣の段になる。

piQ :: QVal -> QRat
piQ (QVal ts) = foldr qratAdd qratZero (map (qratAbs . snd) ts)

thetaQ :: QRat -> Int
thetaQ c = if qratLt qratZero c then 1 else 0

-- 単項式版。既存の呼び出し口をそのまま残す
piForget :: QCoeff -> (Int, Int)
piForget q = (qNum q, qDep q)

thetaBin :: (Int, Int) -> Int
thetaBin (n, _) = if n > 0 then 1 else 0

-- ===== 𝒬 = ([0,1], ≤, ⋁, ⋆, 1)（定理3.3）=====
--
-- 台はドキュメントのとおり単位区間である。6d が ij 対角線上に k/2^n を稠密に
-- 構成する、その区間そのものになる。元は大きさだけを持つので、ここでの ⋆ は
-- タレス比の積であり可換になる。
--
-- 非可換性は係数の格付け（分岐語）の側にある。格付けを付けた QVal は
-- 半環にはなるが quantale にはならない。理由は書き換え i i ⇒ ρ⁻¹ にあり、
-- 積が符号を反転する場合に順序が逆転して ⋆ が単調でなくなる。
-- 定理3.3 の束の主張は 𝒬 の側、定理3.1 の非可換性は格付けの側にある。
-- 符号そのものは第 IV 部の構成計算 𝒞 の生成元 ρ が持つ。

inQ :: QRat -> Bool
inQ c = qratLeq qratZero c && qratLeq c qratOne

-- 有限族の上限と下限。6d の二分割列はこの ⋁ で読む
qJoinAll :: [QRat] -> QRat
qJoinAll = foldr qratMax qratZero

qMeetAll :: [QRat] -> QRat
qMeetAll = foldr qratMin qratOne

-- 6d の二分割列。深度を一段ずつ深くして 1 へ寄る単調列で、
-- 定理3.3 の分配律の証明が上限を取る族はこれである。
--
--   b_k = (2^k − 1) / 2^k        k = 0, 1, 2, …

bisectionMags :: Int -> [QRat]
bisectionMags n = [ qratDyad (shiftL 1 k - 1) k | k <- [0 .. n] ]

-- ===== 残差と随伴（定理3.3 の順序つきモノイドの側）=====
--
--   a ⋆ b ≤ c  ⟺  b ≤ a ↘ c  ⟺  a ≤ c ↙ b
--
-- 残差は条件を満たす b の上限そのものである。
--
--   a ↘ c = ⋁ { b ∈ [0,1] : a ⋆ b ≤ c } = min(1, c ⊘ a)
--
-- a = 0 では条件が全ての b で成り立つので、上限は台の上端 1 になる。
residualQ :: QRat -> QRat -> QRat
residualQ a c
  | qratEq a qratZero = qratOne
  | otherwise = case qratDiv c a of
      Just r  -> qratMin qratOne r
      Nothing -> qratOne

-- ===== 整合対の残差（07 §1）=====
--
-- 同じ ⊘ の記号を使うが、零の扱いが定理3.3 の残差と違う。整合対は
-- 「二つのプロファイルがどれだけ一致するか」を測るので、零の側に別の読みが要る。
--
--   0 ⊘ 0 = 1   零成分どうしは完全一致（例10.7 の原型 p̂=(0,0,1) の判定に要る）
--   x ⊘ 0 = 0   相手が零なのに自分が正なら一致しない。quantale の残差どおり
--               上端 1 を返すと、候補が零で原型が満点の成分に 𝟏 を与えてしまう
--   0 ⊘ x = 0   通常の除算どおり
--
-- 随伴律が要るのは定理3.3 の側、判定に要るのはこちらである。混ぜてはいけない。
agreeResidual :: QRat -> QRat -> QRat
agreeResidual a c
  | qratEq a qratZero = if qratEq c qratZero then qratOne else qratZero
  | otherwise = case qratDiv c a of
      Just r  -> qratMin qratOne r
      Nothing -> qratZero

-- 語は逆元輸送する（構成語 §6.6）。
--   (m_a, a) ↘ (m_c, c) = (m_c ⊘ m_a, snf(a⁻¹ c))
--   (m_c, c) ↙ (m_b, b) = (m_c ⊘ m_b, snf(c b⁻¹))
residualRightQ :: QCoeff -> QCoeff -> (QRat, (BWord, Int))
residualRightQ a c =
  ( agreeResidual (magOf a) (magOf c)
  , mulWord (invWord (qWord a, qSign a)) (qWord c, qSign c) )

residualLeftQ :: QCoeff -> QCoeff -> (QRat, (BWord, Int))
residualLeftQ c b =
  ( agreeResidual (magOf b) (magOf c)
  , mulWord (qWord c, qSign c) (invWord (qWord b, qSign b)) )

-- 整合対 (q ⇔ p) = (q ↘ p) ⋆ (p ↘ q) = min(q,p) / max(q,p)（07 §6.2）
--
-- 07 §10.2 は第二因子を ↙ と書くが、定義を代入すると p ↙ q と q ↘ p は
-- 大きさが同じ値になり、整合対が min(1, p⊘q)² になる。それでは
-- q ⇔ p ≠ p ⇔ q となり、§6.2 の「両方向に差し引く」も
-- 08 命題4.2 の min/max も立たない。↘ 二本を採る。
agreeQ :: QCoeff -> QCoeff -> (QRat, (BWord, Int))
agreeQ q p =
  let (mr, wr) = residualRightQ q p
      (ml, wl) = residualRightQ p q
  in (qratMul mr ml, mulWord wr wl)

-- ===== 判定値の上での 𝒬 の演算（コモン公用語の原始文字が呼ぶ口）=====
--
-- 判定値は「大きさ × 語 × 符号」の三つ組で持つ（CommonChamber.VJudge）。
-- 圏論の演算をこの三つ組の上で書いておくと、コモン公用語の箱がそのまま呼べる。

type Judge = (QRat, (BWord, Int))

-- ⋁ 上限（定理3.3 の完備束）。大きさは max を取る。語は勝った側のものを運ぶが、
-- 大きさが並んで語が割れたときは型を落とす。3章 前提2「加算は経路を忘れる」であり、
-- 上限は加算の側の演算になる
joinJudge :: Judge -> Judge -> Judge
joinJudge (ma, wa) (mb, wb)
  | qratLt ma mb = (mb, wb)
  | qratLt mb ma = (ma, wa)
  | wa == wb     = (ma, wa)
  | otherwise    = (ma, ([], 1))

-- ⋀ 下限。到達度を目印ごとに束ねるときに使う
meetJudge :: Judge -> Judge -> Judge
meetJudge (ma, wa) (mb, wb)
  | qratLt ma mb = (ma, wa)
  | qratLt mb ma = (mb, wb)
  | wa == wb     = (ma, wa)
  | otherwise    = (ma, ([], 1))

-- 残差。大きさは定理3.3 の ↘、語は逆元輸送（構成語 §6.6）。
-- ⋆ が非可換なので左右で別の演算になり、命題5.2 の二つの含意にあたる
residualRightJ :: Judge -> Judge -> Judge
residualRightJ (ma, wa) (mc, wc) = (residualQ ma mc, mulWord (invWord wa) wc)

residualLeftJ :: Judge -> Judge -> Judge
residualLeftJ (mc, wc) (mb, wb) = (residualQ mb mc, mulWord wc (invWord wb))

-- ⋆ 判定値の合成
starJudge :: Judge -> Judge -> Judge
starJudge (ma, wa) (mb, wb) = (qratMul ma mb, mulWord wa wb)

unitJudge, zeroJudge :: Judge
unitJudge = (qratOne,  ([], 1))
zeroJudge = (qratZero, ([], 1))

-- 型忘却 π（定義3.4 の μ:∞→1）。大きさだけを残す
piJudge :: Judge -> Judge
piJudge (m, _) = (m, ([], 1))

-- ===== 定理3.4 のホム対象 =====
--
-- 𝐆 の点が 𝐇 に整合する度合いを目印ごとに右残差で読み、⋀ で束ねる。
--
--   𝔾(x, y) = ⋀_ℓ ( x̂_ℓ ↘ ŷ_ℓ ) = ⋀_ℓ min(1, ŷ_ℓ ⊘ x̂_ℓ)
--
-- 単位律 1 ≤ 𝔾(x,x) は各成分が 1 になることから出る。
-- 合成律 𝔾(y,z) ⋆ 𝔾(x,y) ≤ 𝔾(x,z) は成分ごとの
--   min(1, c⊘b) · min(1, b⊘a) ≤ min(1, c⊘a)
-- から出る。⋀ は各成分の不等式を保つ。
-- 有向である（系3.5）。x と y を入れ替えると別の値になる。
homReach :: [QCoeff] -> [QCoeff] -> Judge
homReach xs ys = foldl meetJudge unitJudge
  [ ( residualQ (magOf a) (magOf b)
    , mulWord (invWord (qWord a, qSign a)) (qWord b, qSign b) )
  | (a, b) <- zip xs ys ]

-- ===== 6d の二分割列 =====
--
-- 定理3.3 の分配律の証明が上限を取る族はこれである。深度を一段ずつ深くして
-- 値へ寄る単調列で、全項が同じ語を持つ。
--
--   b_k = (2^k − 1) / 2^k · u        k = 0, 1, 2, …

bisectionChain :: BWord -> Int -> [QVal]
bisectionChain u n =
  [ qvNorm [(w, applySign s (qratDyad (shiftL 1 k - 1) k))]
  | k <- [0 .. n]
  , let (w, s) = snfWord u ]

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("snf: i i ⇒ ρ⁻¹（符号が反転）、j j ⇒ ρ⁺¹（符号はそのまま）",
      snfWord [I, I] == ([], negate 1)
      && snfWord [J, J] == ([], 1)
      && snfWord [I, J] == ([I, J], 1))

  , ("snf: 正規形は i と j が交互に並ぶ語になる",
      all (snfNormal . fst . snfWord)
          [[I,I,J], [J,J,I,I], [I,J,I,J], [I,I,I], []])

  , ("定理3.1: 臨界対 ij / ji は解消しない — 別の正規形を持つ",
      snfWord [I, J] /= snfWord [J, I])

  , ("定理3.1: ⋆ は非可換。大きさは等しく語だけが違う",
      star iUnitQ jUnitQ /= star jUnitQ iUnitQ
      && qWord (star iUnitQ jUnitQ) == [I, J]
      && qWord (star jUnitQ iUnitQ) == [J, I]
      && piForget (star iUnitQ jUnitQ) == piForget (star jUnitQ iUnitQ))

  , ("3章③: 一般の積は形式和の上で閉じる — (1 ⊕ i) ⋆ (1 ⊕ j) が四項に開く",
      let p = qvAdd qvOne (qvOfCoeff iUnitQ)
          q = qvAdd qvOne (qvOfCoeff jUnitQ)
      in qvStar p q
           == qvNorm [ ([], qratOne), ([I], qratOne)
                     , ([J], qratOne), ([I,J], qratOne) ])

  , ("3章③: 積は非可換。(1⊕i)⋆(1⊕j) と (1⊕j)⋆(1⊕i) は ij / ji で分かれる",
      let p = qvAdd qvOne (qvOfCoeff iUnitQ)
          q = qvAdd qvOne (qvOfCoeff jUnitQ)
      in qvStar p q /= qvStar q p
         && qratEq (qvAt [I,J] (qvStar p q)) qratOne
         && qratEq (qvAt [I,J] (qvStar q p)) qratZero)

  , ("3章②: i ⋆ i = −1 が形式和でも出る（符号が係数へ移る）",
      let i1 = qvOfCoeff iUnitQ
      in qvStar i1 i1 == qvNorm [([], qratNeg qratOne)]
         && qvStar (qvOfCoeff jUnitQ) (qvOfCoeff jUnitQ) == qvOne)

  , ("定理3.3: ⋆ は結合的（非可換のまま）",
      let a = qvAdd qvOne (qvOfCoeff iUnitQ)
          b = qvAdd (qvOfCoeff jUnitQ) (qvOfRat (QRat 1 3))
          c = qvAdd (qvOfCoeff iUnitQ) (qvOfCoeff jUnitQ)
      in qvStar (qvStar a b) c == qvStar a (qvStar b c))

  , ("定理3.3: 1 は ⋆ の両側単位元",
      let a = qvAdd (qvOfRat (QRat 2 5)) (qvOfCoeff (QCoeff 3 2 [I,J] 1))
      in qvStar qvOne a == a && qvStar a qvOne == a)

  , ("定理3.3: ⊕ は可換かつ結合的（加算は平行四辺形則）",
      let a = qvOfCoeff iUnitQ
          b = qvOfRat (QRat 1 4)
          c = qvOfCoeff (QCoeff 1 1 [J] 1)
      in qvAdd a b == qvAdd b a
         && qvAdd (qvAdd a b) c == qvAdd a (qvAdd b c)
         && qvAdd a qvZero == a)

  , ("定理3.3: ⋆ は ⊕ に左右から分配する（3章③ の分配律そのもの）",
      let a = qvAdd qvOne (qvOfCoeff iUnitQ)
          b = qvOfRat (QRat 1 3)
          c = qvOfCoeff jUnitQ
      in qvStar a (qvAdd b c) == qvAdd (qvStar a b) (qvStar a c)
         && qvStar (qvAdd b c) a == qvAdd (qvStar b a) (qvStar c a))

  , ("定理3.3: ⋁ は成分ごとの最大。可換・結合的・冪等",
      let a = qvNorm [([], QRat 1 2), ([I], QRat 1 4)]
          b = qvNorm [([], QRat 1 3), ([J], QRat 3 4)]
          c = qvNorm [([I], QRat 1 2)]
      in qvJoin a b == qvJoin b a
         && qvJoin (qvJoin a b) c == qvJoin a (qvJoin b c)
         && qvJoin a a == a)

  , ("定理3.3: ≤ は ⋁ の順序と一致する — x ≤ y ⟺ x ⋁ y = y",
      let xs = [ qvZero, qvOne, qvOfCoeff iUnitQ
               , qvNorm [([], QRat 1 2), ([I], QRat 1 4)]
               , qvNorm [([], QRat 3 4)] ]
      in and [ qvLeq x y == (qvJoin x y == y) | x <- xs, y <- xs ])

  , ("定理3.3: 𝒬 の台は単位区間。6d の二分割列はその中にある",
      all inQ (bisectionMags 6) && inQ qratOne && inQ qratZero
      && not (inQ (QRat 3 2)) && not (inQ (qratNeg qratOne)))

  , ("定理3.3 分配 (star.distrib_sup): a ⋆ ⋁ b_k = ⋁ (a ⋆ b_k)",
      let a  = QRat 1 3
          bs = bisectionMags 6
      in qratEq (qratMul a (qJoinAll bs)) (qJoinAll (map (qratMul a) bs)))

  , ("定理3.3 分配 (star.distrib_sup): (⋁ a_k) ⋆ b = ⋁ (a_k ⋆ b)",
      let b  = QRat 2 5
          as = bisectionMags 6
      in qratEq (qratMul (qJoinAll as) b) (qJoinAll (map (\x -> qratMul x b) as)))

  , ("定理3.3: 𝒬 は完備束。⋁ と ⋀ が有限族で決まり、単位 1 が最大元になる",
      let bs = bisectionMags 6
      in qratEq (qJoinAll bs) (QRat 63 64) && qratEq (qMeetAll bs) qratZero
         && all (\c -> qratLeq c qratOne) bs)

  , ("6d: 二分割列は単調に増え、上限は列の最後の項になる",
      let bs = bisectionMags 6
      in and [ qratLeq x y | (x, y) <- zip bs (drop 1 bs) ]
         && qratEq (qJoinAll bs) (qJoinAll (drop 6 bs)))

  , ("格付けの側は quantale ではない: 符号の畳み i i ⇒ ρ⁻¹ が順序を反転する",
      let a  = qvOfCoeff iUnitQ
          bs = bisectionChain [I] 3
      in qvStar a (qvJoinAll bs) /= qvJoinAll (map (qvStar a) bs))

  , ("格付けの側は半環である: ⋆ は ⊕ に分配し、⊕ の単位 0 を吸収する",
      let a  = qvOfCoeff iUnitQ
          bs = bisectionChain [I] 3
      in qvStar a (qvSum bs) == qvSum (map (qvStar a) bs)
         && qvStar a qvZero == qvZero)

  , ("命題3.2: π(ij) = π(ji) = 1。型を落とすと ij と ji の区別が消える",
      let ij = qvStar (qvOfCoeff iUnitQ) (qvOfCoeff jUnitQ)
          ji = qvStar (qvOfCoeff jUnitQ) (qvOfCoeff iUnitQ)
      in ij /= ji && qratEq (piQ ij) (piQ ji) && qratEq (piQ ij) qratOne)

  , ("定義3.4: 単項式では π が積を積へ送る（μ:∞→1 の基底変換）",
      let ms = [ QCoeff 1 0 [I] 1, QCoeff 3 2 [J] 1
               , QCoeff 1 1 [I,J] 1, QCoeff 1 0 [] 1, QCoeff 5 3 [J,I] 1 ]
      in and [ qratEq (piQ (qvStar (qvOfCoeff a) (qvOfCoeff b)))
                      (qratMul (piQ (qvOfCoeff a)) (piQ (qvOfCoeff b)))
             | a <- ms, b <- ms ])

  , ("定義3.4: 形式和では等号が緩む。π(a ⋆ b) ≤ π(a) ⋆ π(b)（豊穣の合成律の形）",
      let vals = [ qvOne, qvOfCoeff iUnitQ, qvOfCoeff jUnitQ
                 , qvAdd qvOne (qvOfCoeff iUnitQ)
                 , qvAdd (qvOfCoeff iUnitQ) (qvOfCoeff jUnitQ)
                 , qvSub qvOne (qvOfCoeff (QCoeff 1 1 [I] 1)) ]
      in and [ qratLeq (piQ (qvStar a b)) (qratMul (piQ a) (piQ b))
             | a <- vals, b <- vals ])

  , ("定義3.4: 打ち消しがあると等号が実際に破れる（i ⋆ i の符号反転）",
      let a = qvAdd qvOne (qvOfCoeff iUnitQ)
      in qratLt (piQ (qvStar a a)) (qratMul (piQ a) (piQ a)))

  , ("命題3.2: π は ⊕ については劣加法的（打ち消しのない項では等号）",
      let a = qvOfCoeff iUnitQ
          b = qvOfRat (QRat 1 3)
      in qratEq (piQ (qvAdd a b)) (qratAdd (piQ a) (piQ b))
         && qratLeq (piQ (qvAdd a (qvNeg a))) (qratAdd (piQ a) (piQ a)))

  , ("定義3.4: Θ は連続度を二値へ落とす（μ:1→0）",
      thetaQ (QRat 1 3) == 1 && thetaQ qratZero == 0
      && thetaQ (qratNeg qratOne) == 0)

  , ("定理3.3 随伴: a ⋆ b ≤ c ⟺ b ≤ a ↘ c（台 [0,1] の全ての組で確かめる）",
      let vals = [QRat 0 1, QRat 1 4, QRat 1 3, QRat 1 2, QRat 2 3, QRat 1 1]
      in and [ qratLeq (qratMul a b) c == qratLeq b (residualQ a c)
             | a <- vals, b <- vals, c <- vals ])

  , ("定理3.3 随伴: ↘ は条件を満たす b の上限そのもの — a ⋆ (a ↘ c) ≤ c",
      let vals = [QRat 0 1, QRat 1 4, QRat 1 3, QRat 1 2, QRat 2 3, QRat 1 1]
      in and [ qratLeq (qratMul a (residualQ a c)) c | a <- vals, c <- vals ])

  , ("整合対の残差は定理3.3 の残差と零の扱いが違う。混ぜてはいけない",
      qratEq (residualQ qratZero (QRat 1 2)) qratOne
      && qratEq (agreeResidual qratZero (QRat 1 2)) qratZero
      && qratEq (residualQ qratZero qratZero) (agreeResidual qratZero qratZero))

  , ("定理3.3: ⋆ が非可換なので ↘ と ↙ は一致しない（語の輸送が左右で違う）",
      let ij = star iUnitQ jUnitQ
      in snd (residualRightQ ij iUnitQ) /= snd (residualLeftQ ij iUnitQ))

  , ("残差 (07 例1.2): a=1/2, c=3/8 で a ↘ c = 3/4、語は空に落ちる",
      let (m, w) = residualRightQ (QCoeff 1 1 [] 1) (QCoeff 3 3 [] 1)
      in qratEq m (QRat 3 4) && w == ([], 1))

  , ("残差: 復元 — m_a ⋆ (a ↘ c) が c に戻る",
      qratEq (qratMul (magOf (QCoeff 1 1 [] 1))
                      (fst (residualRightQ (QCoeff 1 1 [] 1) (QCoeff 3 3 [] 1))))
             (magOf (QCoeff 3 3 [] 1)))

  , ("整合対: q ⇔ q = 𝟏（大きさ 1、空語、符号 +）",
      let (m, w) = agreeQ iUnitQ iUnitQ
      in qratEq m qratOne && w == ([], 1))

  , ("整合対: 離れるほど大きさが下がる（1/2 ⇔ 1/4 の大きさは 1/2）",
      qratEq (fst (agreeQ (QCoeff 1 1 [] 1) (QCoeff 1 2 [] 1))) (QRat 1 2))

  , ("整合対: 対称になる — q ⇔ p = p ⇔ q（両方向に差し引くため）",
      qratEq (fst (agreeQ (QCoeff 1 1 [] 1) (QCoeff 1 2 [] 1)))
             (fst (agreeQ (QCoeff 1 2 [] 1) (QCoeff 1 1 [] 1))))

  , ("整合対: 零成分どうしの一致は 𝟏 を返す（例10.7 の原型 p̂=(0,0,1) 用）",
      qratEq (fst (agreeQ zeroQ zeroQ)) qratOne
      && qratEq (fst (agreeQ unitQ zeroQ)) qratZero)

  , ("語の適用: f_{ij}(O) = (O ⋆ i) ⋆ j。適用順が意味を持つ",
      applyWord [I, J] unitQ /= applyWord [J, I] unitQ
      && qWord (applyWord [I, J] unitQ) == [I, J])

  , ("判定値の ⋁: 大きさは max。語が割れたら型を落とす（加算は経路を忘れる）",
      joinJudge (QRat 1 4, ([I], 1)) (QRat 1 2, ([J], 1)) == (QRat 1 2, ([J], 1))
      && joinJudge (QRat 1 2, ([I], 1)) (QRat 1 2, ([J], 1)) == (QRat 1 2, ([], 1))
      && joinJudge (QRat 1 2, ([I], 1)) (QRat 1 2, ([I], 1)) == (QRat 1 2, ([I], 1)))

  , ("判定値の ⋁ は可換・結合的・冪等（完備束の骨）",
      let js = [ (QRat 1 4, ([I], 1)), (QRat 1 2, ([J], 1))
               , (QRat 3 4, ([], 1)), (QRat 1 2, ([I], 1)) ]
      in and [ joinJudge a b == joinJudge b a | a <- js, b <- js ]
         && and [ joinJudge (joinJudge a b) c == joinJudge a (joinJudge b c)
                | a <- js, b <- js, c <- js ]
         && all (\a -> joinJudge a a == a) js)

  , ("判定値の残差: 随伴律が大きさの上で成り立つ",
      let ms = [qratZero, QRat 1 4, QRat 1 2, QRat 2 3, qratOne]
      in and [ qratLeq (fst (starJudge (a, ([], 1)) (b, ([], 1)))) c
                 == qratLeq b (fst (residualRightJ (a, ([], 1)) (c, ([], 1))))
             | a <- ms, b <- ms, c <- ms ])

  , ("判定値の残差: ↘ と ↙ は語の輸送が違うので別の演算になる",
      residualRightJ (qratOne, ([I], 1)) (qratOne, ([J], 1))
        /= residualLeftJ (qratOne, ([J], 1)) (qratOne, ([I], 1)))

  , ("定理3.4 単位律: 1 ≤ 𝔾(x, x)",
      let xs = [QCoeff 1 1 [I] 1, QCoeff 3 2 [] 1, QCoeff 1 0 [J] 1]
      in qratEq (fst (homReach xs xs)) qratOne)

  , ("定理3.4 合成律: 𝔾(y,z) ⋆ 𝔾(x,y) ≤ 𝔾(x,z)",
      let x = [QCoeff 1 2 [] 1, QCoeff 1 1 [] 1]
          y = [QCoeff 1 1 [] 1, QCoeff 3 2 [] 1]
          z = [QCoeff 3 2 [] 1, QCoeff 1 0 [] 1]
      in qratLeq (fst (starJudge (homReach y z) (homReach x y)))
                 (fst (homReach x z)))

  , ("系3.5: ホムは有向である。向きを変えると到達度が変わる",
      let x = [QCoeff 1 2 [] 1, QCoeff 1 1 [] 1]
          y = [QCoeff 1 0 [] 1, QCoeff 1 2 [] 1]
      in not (qratEq (fst (homReach x y)) (fst (homReach y x))))

  , ("定義3.4: π は判定値から型を落とす。大きさは動かない",
      piJudge (QRat 2 3, ([I, J], negate 1)) == (QRat 2 3, ([], 1)))
  ]
