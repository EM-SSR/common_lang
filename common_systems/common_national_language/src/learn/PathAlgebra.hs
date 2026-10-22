{-# LANGUAGE NoImplicitPrelude #-}
module PathAlgebra where

import CounterConstraints
import CounterUnits (Op (..))
import GclsCategory
import NounNet (Landmark, Individual (..), defaultLandmarks)
import Metanoun (MetaNoun (..), Judgment, judgeMeta)
import Ideogram (Modality)
import CommonChamber (Value)

-- ===== 構成語付き経路代数 𝔸 と離散 ELLA 学習（08_経路代数と離散ELLA学習.md）=====
-- doc: path.algebra mono.iso add.at.boundary lattice.update support.split tolerance.band
-- doc: history.mu learn.tie.fix lattice.step support.sep kernel.write residual.quantaloid
--
-- 結論を先に置く。
--
--   (𝔸₁, ⋆) ≅ (QCoeff, ⋆)                          定理 2.2
--   ⊕ は QCoeff へ運べない。合算は中間境界の ⋁ に置く  命題 2.3
--   輸送できる学習則は残差随伴・格子更新・支持分離の三つ
--
-- ELLA 文書の NN 実行系（ゲイン g_θ、辺微分、チャート変換）は要らない。
-- 使う性質は「符号を越えない有限到達」だけで、ゲインを恒等写像へ落としても
-- そのまま立つ。

-- ===== 1. 係数環 Λ = ℤ[1/2] =====
--
--   Lam a d = a·2^{-d},   Λ_F = 2^{-F}ℤ
--
-- 符号は分子に宿す。語の側の σ^ε とは別欄であり、φ が両者を突き合わせる。

data Lam = Lam Integer Int deriving (Eq, Show)

-- 分子から 2 の因子を抜いて深度を下げる。既約形にすると derived Eq が
-- 値の相等と一致する（QRat の qnorm と同じ理由）
lamNorm :: Lam -> Lam
lamNorm (Lam a d)
  | a == 0            = Lam 0 0
  | d > 0 && even a   = lamNorm (Lam (a `div` 2) (d - 1))
  | otherwise         = Lam a d

lamZero, lamOne :: Lam
lamZero = Lam 0 0
lamOne  = Lam 1 0

-- 深度をそろえてから分子を足す（DagArith.alignDepth と同じ規則）
lamAdd :: Lam -> Lam -> Lam
lamAdd (Lam a d) (Lam b e) = lamNorm (Lam (a * pow (t - d) + b * pow (t - e)) t)
  where
    t = max d e
    pow k = shiftL (1 :: Integer) k

lamMul :: Lam -> Lam -> Lam
lamMul (Lam a d) (Lam b e) = lamNorm (Lam (a * b) (d + e))

lamNeg :: Lam -> Lam
lamNeg (Lam a d) = Lam (negate a) d

lamSub :: Lam -> Lam -> Lam
lamSub x y = lamAdd x (lamNeg y)

lamIsZero :: Lam -> Bool
lamIsZero l = case lamNorm l of
  Lam a _ -> a == 0

-- Λ_F 上の整数距離 n(q, q♮) = (q♮ − q)/Δ_F。
-- 格子に乗らない差は Nothing になる。3.2 の適用条件そのもの
lamSteps :: Int -> Lam -> Lam -> Maybe Integer
lamSteps f q qt = case lamNorm (lamSub qt q) of
  Lam a d | d <= f    -> Just (a * shiftL (1 :: Integer) (f - d))
          | otherwise -> Nothing

lamRat :: Lam -> QRat
lamRat (Lam a d) = qnorm (QRat a (toInteger (shiftL (1 :: Integer) d)))

-- |x| は帯の判定で要る
lamAbs :: Lam -> Lam
lamAbs (Lam a d) = Lam (abs a) d

-- ===== 2. 単項元と一般元（§1）=====
--
--   𝔸 = { Σ_ω a_ω[ω] | a_ω ∈ Λ, |supp a| < ∞ }
--   a[ω] ⋆ b[ν] = ab [nf(ων)]
--
-- 語は保持のたびに正規形へ落とす。ii ⇒ ρ⁻¹ の符号は係数へ移すので、
-- Mono の語欄は必ず交互語（同字が隣り合わない語）になる。

data Mono = Mono { mCoeff :: Lam, mWord :: [Op] } deriving (Eq, Show)

-- 生語から単項元を作る。σ^ε は係数の符号へ畳む
mkMono :: Lam -> [Op] -> Mono
mkMono a ops = Mono (if s < 0 then lamNeg a else a) w
  where (w, s) = foldl (flip pushW) ([], 1) ops

monoStar :: Mono -> Mono -> Mono
monoStar (Mono a w) (Mono b v) = mkMono (lamMul a b) (w ++ v)

monoOne :: Mono
monoOne = Mono lamOne []

-- 一般元。語について昇順、同語は一項、零係数の項は持たない
newtype PathAlg = PathAlg [Mono] deriving (Eq, Show)

-- 項の並びを正準形へ落とす。⊕ の実体もこれになる
mkAlg :: [Mono] -> PathAlg
mkAlg ms = PathAlg [ Mono c w
                   | w <- sort (uniq [ mWord m | m <- ms ])
                   , let c = foldl lamAdd lamZero [ mCoeff m | m <- ms, mWord m == w ]
                   , not (lamIsZero c) ]
  where
    uniq = foldr (\w acc -> if w `elem` acc then acc else w : acc) []

-- ⊕: 同語の係数加算（§1）
oplus :: PathAlg -> PathAlg -> PathAlg
oplus (PathAlg a) (PathAlg b) = mkAlg (a ++ b)

-- ⋆: 双線形に伸ばした直列合成。非可換性は語の接合が担う
starA :: PathAlg -> PathAlg -> PathAlg
starA (PathAlg a) (PathAlg b) = mkAlg [ monoStar x y | x <- a, y <- b ]

supp :: PathAlg -> [[Op]]
supp (PathAlg ms) = [ mWord m | m <- ms ]

-- ===== 3. 単埋め込み φ（定理 2.2）=====
--
--   φ : 𝔸₁ → QCoeff,  a[ω] ↦ (|a| の分子, 深度, snf 交互語, 符号)
--
-- φ は積を保ち、核は零になる。すなわち (𝔸₁,⋆) と (QCoeff,⋆) はモノイド同型。
--
-- 一つだけ約束が要る。QCoeff は (1,1) と (2,2) を別の値として持つので、
-- 全単射になるのは既約代表 qReduce の上でになる。φ の像は常に既約であり、
-- ψ は既約代表を返す。

phiOf :: Mono -> QCoeff
phiOf (Mono a w) = case lamNorm a of
  Lam n d -> QCoeff (fromIntegral (abs n)) d w (if n < 0 then negate 1 else 1)

psiOf :: QCoeff -> Mono
psiOf q = mkMono (lamNorm (Lam (toInteger (qNum q) * toInteger (qSign q)) (qDep q)))
                 (qWord q)

-- QCoeff の既約代表。大きさを ℤ[1/2] の既約形へ落とし、語を snf へ落とす
qReduce :: QCoeff -> QCoeff
qReduce = phiOf . psiOf

-- ===== 4. ⊕ は輸送されない（命題 2.3）=====
--
-- ⊕ は supp を広げる。QCoeff は supp の大きさが 1 の正規形しか持たない。
-- したがって「同じ語への複数経路の合算」は係数の内部では表せず、
-- チェンバー合成の中間境界上の ⋁（可換像では加算）へ置くしかない。
--
-- 位置の制約は GCLS の原理「加算は経路を忘れ、乗算は経路を保持する」から出る。

-- 一般元が単項へ落ちるかどうか。落ちない元が一つでもあれば命題 2.3 が立つ
isMonomial :: PathAlg -> Bool
isMonomial (PathAlg ms) = length ms <= 1

toMono :: PathAlg -> Maybe Mono
toMono (PathAlg [m]) = Just m
toMono _             = Nothing

-- 境界上の合算。03 §15 の連鎖律で ⋁ が担う位置に置く。
-- 大きさだけを見る可換像なので、語は落ちる
joinAtBoundary :: PathAlg -> QRat
joinAtBoundary (PathAlg ms) = foldl qratMax qratZero [ lamRat (lamAbs (mCoeff m)) | m <- ms ]


-- ===== 5. 格子上の無オーバーシュート更新（§3.2、ELLA 定理 12.1）=====
--
--   n(q,q♮) = (q♮ − q)/Δ_F ∈ ℤ,   1 ≤ s(n) ≤ |n|
--   ⟹ |q♮ − q_{t+1}| < |q♮ − q_t| かつ q_T = q♮ となる有限 T が在る
--
-- 学習率という自由度は入らない。歩数 s は 1 と |n| の間なら何でもよく、
-- 到達の有無は s の選び方に依らない。既定は最小歩 s = 1 を採る。

type StepRule = Integer -> Integer   -- n ↦ s(n)。1 ≤ s(n) ≤ |n| を守ること

stepMinimal :: StepRule
stepMinimal _ = 1

-- 半分ずつ寄せる。1 ≤ s ≤ |n| を守るので同じ結論が立つ
stepHalving :: StepRule
stepHalving n = max 1 (abs n `div` 2)

-- 一歩。格子に乗らない差は Nothing（適用条件の外）
lattStep :: Int -> StepRule -> Lam -> Lam -> Maybe Lam
lattStep f rule qt q = case lamSteps f q qt of
  Nothing -> Nothing
  Just 0  -> Just q
  Just n  ->
    let s = max 1 (min (abs n) (abs (rule n)))
        d = if n > 0 then s else negate s
    in Just (lamAdd q (lamNorm (Lam d f)))

-- 目標へ着くまでの軌道。上限は |n| 歩で足りる（各歩が 1 以上進むため）
lattRun :: Int -> StepRule -> Lam -> Lam -> Maybe [Lam]
lattRun f rule qt q0 = case lamSteps f q0 qt of
  Nothing -> Nothing
  Just n  -> go (fromIntegral (abs n) + 1) q0
  where
    go :: Int -> Lam -> Maybe [Lam]
    go budget q
      | budget < 0 = Nothing
      | lamIsZero (lamSub qt q) = Just [q]
      | otherwise = case lattStep f rule qt q of
          Nothing -> Nothing
          Just q' -> case go (budget - 1) q' of
            Just rest -> Just (q : rest)
            Nothing   -> Nothing

-- 目標との距離が毎歩ちょうど減るか（定理 12.1 の主張そのもの）
strictlyCloser :: Lam -> [Lam] -> Bool
strictlyCloser qt qs = and (zipWith closer qs (drop 1 qs))
  where
    closer a b = qratLeq (dist b) (dist a) && not (qratEq (dist a) (dist b))
    dist q = lamRat (lamAbs (lamSub qt q))

-- ===== 6. 支持分離（§3.3、ELLA 定理 17.1）=====
--
--   supp(ΔQ) ∩ Ω_old = ∅ ⟹ Y_{Q⊕ΔQ}(h) = Y_Q(h)
--
-- 言語側では supp(C_m) が「メタ名詞 m が判定で読む目印成分の集合」になる。
-- 全概念が同じ目印族 L を読む共有観測面では支持が完全に重なるので、
-- この分離は退化する。だから非忘却学習は次の二択に落ちる。
--
--   成分分割  各 m が固有の部分族 L_m ⊆ L を読む。比較は L_m の共通部分に限られる
--   追加のみ  既得の p_ℓ を凍結する。修正は教師の明示的な削除と再登録になる
--
-- どちらを採るかは運用決定であり、数学としては下の readOn の不変性に帰着する。

-- Ω で読む。旧履歴が触る語だけを残す射影
readOn :: [[Op]] -> PathAlg -> PathAlg
readOn omega (PathAlg ms) = mkAlg [ m | m <- ms, mWord m `elem` omega ]

-- 支持が離れているか
disjointSupp :: PathAlg -> [[Op]] -> Bool
disjointSupp d omega = not (any (`elem` omega) (supp d))

-- ===== 7. 許容帯（命題 4.2）=====
--
--   (λ ⇔ p) = min(λ,p)/max(λ,p)
--   ℓ 成分の寄与 ≥ η  ⟺  p_ℓ ∈ [η·λ_ℓ, λ_ℓ/η]      （λ, p > 0）
--
-- 証明は min/max ≥ η ⟺ ηλ ≤ p ≤ λ/η の両辺に max を掛けて割るだけになる。
-- 帯の内側にとどまる限り、中心への寄せは整合を下げない。

-- 成分整合。GclsCategory.agreeQ の大きさ欄がそのまま min/max になる
agreeScalar :: QCoeff -> QCoeff -> QRat
agreeScalar q p = fst (agreeQ q p)

-- 帯 [η·λ, λ/η]。η = 0 では上端が定まらず帯が閉じないので、値を返さない。
-- ドキュメントも λ, p > 0 の下で述べている（§3.2 の但し書き）
bandOf :: QRat -> QRat -> Maybe (QRat, QRat)
bandOf eta lam = case qratDiv lam eta of
  Just hi -> Just (qratMul eta lam, hi)
  Nothing -> Nothing

inBand :: Maybe (QRat, QRat) -> QRat -> Bool
inBand (Just (lo, hi)) p = qratLeq lo p && qratLeq p hi
inBand Nothing         _ = False

-- ===== 8. 教師付き分類の更新問題（定義 4.1）=====
--
--   1. 昇格   C_{m*}(x̂) > C_m(x̂)  （m ≠ m*）
--   2. 無オーバーシュート  各成分の更新は §3.2 の格子更新に従う
--   3. 非忘却  §3.3 の支持条件
--
-- 判定値の比較は Metanoun.judgeMeta の大きさ欄で読む。

judgeMag :: [Landmark] -> MetaNoun -> Individual -> [(Modality, Value)] -> Maybe QRat
judgeMag lm m x env = case judgeMeta lm m x env of
  Just j  -> Just (magOfJudgment j)
  Nothing -> Nothing

magOfJudgment :: Judgment -> QRat
magOfJudgment (r, _) = r

-- ===== 9. 履歴の内在化は μ 格付けが担う（§4.4）=====
--
-- ELLA 文書 §14 の可視成分／核成分の分解は、言語側では記憶深度の格付けに
-- そのまま対応する。
--
--   復号 D（実数意味論）   ↔  型忘却 π          命題 3.2
--   核 ker D（履歴の居場所） ↔  μ = ∞ の正準列   定理 13.1
--   K_a n_ω = n_{nf(aω)}   ↔  ⋆ の経路保持      n_{ji} ≠ n_{ij}
--
-- 新しい機構は要らない。ij と ji が別の正規形を持つことが因果順序の記録であり、
-- μ を落とさずに使うという運用規律だけが残る。

-- 履歴の一歩 K_a n_ω = n_{nf(aω)}。⋆ がそのまま担う
transportHistory :: Mono -> PathAlg -> PathAlg
transportHistory k n = starA (PathAlg [k]) n

-- ===== 10. 例 4.3 の同点とその破り =====
--
-- 07 §10.5 の目印族 L = (1, i, ij) の上で
--
--   x̂    = (3/8, 1/4, 3/8)
--   p^(O) = (1/2, 1/4, 1/4)      原点寄り
--   p^(D) = (1/4, 1/4, 1/2)      対角寄り
--
-- とすると
--
--   C_O(x̂) = 3/4 · 1 · 2/3 = 1/2,   C_D(x̂) = 2/3 · 1 · 3/4 = 1/2
--
-- でちょうど同点になる。x̂ は O ↔ ij の入れ子に対称な位置にあり、二つの原型も
-- 互いに入れ子像なので、作図深度を上げても解消しない。帳簿順で「原点寄り」へ
-- 落ちる。これが equivalence query の反例であり、教師ラベルが要る瞬間になる。
--
-- 教師が「対角寄り」を指示したときの最小更新は、対角寄り自身の対角成分を
-- 一歩だけ x̂ へ寄せる形になる。
--
--   p^(D)_{ij} : 1/2 = 8/16 → 7/16,   (3/8 ⇔ 7/16) = 6/7 > 3/4
--   ⟹ C_D(x̂) = 2/3 · 1 · 6/7 = 4/7 > 1/2 = C_O(x̂)
--
-- 格子は Λ_4、更新幅は 1 歩なので §3.2 の条件を満たす。更新した成分は
-- 「対角寄り」自身が読む支持の中にあるので、§3.3 の非忘却は成分分割方式でだけ
-- 保証される（共有観測面では追加のみ方式に落ちる）。
--
-- 文書 §4.3 は同じ数値（1/2 → 7/16、6/7、4/7）を「原点成分 p^(O)_O」の更新として
-- 書いているが、それでは C_O が上がるので分類は「原点寄り」のまま動かない。
-- 教師の指示へ反転させる更新は上の p^(D)_{ij} になる。

qOf :: Int -> Int -> QCoeff
qOf n d = QCoeff n d [] 1

xHat, protoOrigin, protoDiag, protoDiagFixed :: [QCoeff]
xHat           = [qOf 3 3, qOf 1 2, qOf 3 3]
protoOrigin    = [qOf 1 1, qOf 1 2, qOf 1 2]
protoDiag      = [qOf 1 2, qOf 1 2, qOf 1 1]
protoDiagFixed = [qOf 1 2, qOf 1 2, qOf 7 4]

-- C_m(x) = ⋆_{ℓ∈L} (w(ℓ,x) ⇔ p_ℓ)。成分チェンバー A_m = ∅ の場合（定義 10.1）
conceptScore :: [QCoeff] -> [QCoeff] -> QRat
conceptScore lam ps = foldl qratMul qratOne (zipWith agreeScalar lam ps)

-- 目印族の上へプロファイルを載せる。Metanoun 側と同じ読み方になることを
-- selfcheck で突き合わせる
asIndividual :: [QCoeff] -> Individual
asIndividual qs = Observed (zip defaultLandmarks qs)

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("(§1): ii ⇒ ρ⁻¹ の符号は係数へ落ちる。jj ⇒ +1 は語だけが消える",
      mkMono lamOne [I, I] == Mono (Lam (negate 1) 0) []
      && mkMono lamOne [J, J] == Mono lamOne [])
  , ("(§1): ⋆ は非可換 — [i]⋆[j] と [j]⋆[i] は別の語を持つ",
      starA algI algJ /= starA algJ algI)
  , ("(定理2.2): φ は積を保つ — φ(x ⋆ y) = φ(x) ⋆ φ(y)",
      and [ phiOf (monoStar x y) == qReduce (star (phiOf x) (phiOf y))
          | x <- monoSamples, y <- monoSamples ])
  , ("(定理2.2): φ は単射 — ψ∘φ = id（係数は既約形で持つ）",
      and [ psiOf (phiOf x) == x | x <- monoSamples ])
  , ("(定理2.2): φ は全射 — φ∘ψ = qReduce（既約代表の上で全単射）",
      and [ phiOf (psiOf q) == qReduce q | q <- qSamples ])
  , ("(定理2.2): 単位が対応する — φ(1[ε]) = 𝟏",
      phiOf monoOne == unitQ)
  , ("(定理2.2): 核は零 — 係数が零の項は 𝔸 に残らない",
      let PathAlg ms = mkAlg [Mono lamZero [I]] in null ms)
  , ("(命題2.3): ⊕ は supp を広げる — 単項へ落ちない元が在る",
      let x = oplus algI algJ
      in length (supp x) == 2 && not (isMonomial x) && toMono x == Nothing)
  , ("(命題2.3): 同語どうしの ⊕ だけは単項に留まる（supp が広がらない場合）",
      isMonomial (oplus algI algI))
  , ("(命題2.3): 合算は境界の ⋁ が担う — 大きさだけが残り語は落ちる",
      qratEq (joinAtBoundary (oplus algI algJ)) qratOne)
  , ("(命題2.3): ⊕ と ⋆ は分配する（𝔸 は代数であり、係数は環である）",
      starA (oplus algI algJ) algJ == oplus (starA algI algJ) (starA algJ algJ))
  , ("(§3.1): 残差随伴は言語側と共有済み — (1/2) ⇘ (3/8) = 3/4",
      qratEq (fst (residualRightQ (qOf 1 1) (qOf 3 3))) (QRat 3 4))
  , ("(§3.2): n(q,q♮) = (q♮ − q)/Δ_F は整数になる（Λ_4 上で 1/2 → 7/16 は 1 歩）",
      lamSteps 4 (Lam 1 1) (Lam 7 4) == Just (negate 1))
  , ("(§3.2): 格子に乗らない差は適用条件の外になる",
      lamSteps 1 (Lam 1 4) (Lam 0 0) == Nothing)
  , ("(定理12.1): 最小歩でも目標へ有限回で着き、距離は毎歩ちょうど減る",
      case lattRun 4 stepMinimal (Lam 7 4) (Lam 1 0) of
        Just tr -> strictlyCloser (Lam 7 4) tr && last tr == lamNorm (Lam 7 4)
        Nothing -> False)
  , ("(定理12.1): 歩数則を替えても結論は変わる — 1 ≤ s(n) ≤ |n| だけが要る",
      case lattRun 4 stepHalving (Lam 7 4) (Lam 1 0) of
        Just tr -> strictlyCloser (Lam 7 4) tr && last tr == lamNorm (Lam 7 4)
        Nothing -> False)
  , ("(定理12.1): 符号を越えない — 負の側から寄せても行き過ぎない",
      case lattRun 4 stepHalving (Lam 1 1) (Lam 1 4) of
        Just tr -> strictlyCloser (Lam 1 1) tr && last tr == lamNorm (Lam 1 1)
        Nothing -> False)
  , ("(定理17.1): supp(ΔQ) ∩ Ω = ∅ なら Ω の読みは変わらない",
      let q  = mkAlg [Mono lamOne [I], Mono lamOne [J]]
          dq = mkAlg [Mono lamOne [I, J]]
          om = [[I], [J]]
      in disjointSupp dq om && readOn om (oplus q dq) == readOn om q)
  , ("(定理17.1): 支持が重なると旧出力は動く（共有観測面での退化）",
      let q  = mkAlg [Mono lamOne [I]]
          dq = mkAlg [Mono lamOne [I]]
          om = [[I]]
      in not (disjointSupp dq om) && readOn om (oplus q dq) /= readOn om q)
  , ("(命題4.2): 寄与 ≥ η ⟺ p ∈ [η·λ, λ/η]（Λ_4 の全格子点で確かめる）",
      and [ qratLeq eta34 (agreeScalar lam38 (qOf k 4))
              == inBand (bandOf eta34 (QRat 3 8)) (QRat (toInteger k) 16)
          | k <- [1 .. 16] ])
  , ("(例4.3): x̂ に対して C_O と C_D はちょうど同点 — 帳簿順でしか割れない",
      qratEq (conceptScore xHat protoOrigin) (QRat 1 2)
      && qratEq (conceptScore xHat protoDiag) (QRat 1 2))
  , ("(例4.3): 教師が「対角寄り」を指示 — p^(D)_ij を 1 歩寄せると分類が反転する",
      let cD = conceptScore xHat protoDiagFixed
          cO = conceptScore xHat protoOrigin
      in qratEq cD (QRat 4 7) && qratLeq cO cD && not (qratEq cO cD))
  , ("(例4.3): その更新は Λ_4 上の 1 歩であり、η = 3/4 の帯の内側に留まる",
      lamSteps 4 (Lam 1 1) (Lam 7 4) == Just (negate 1)
      && inBand (bandOf eta34 (QRat 3 8)) (QRat 7 16))
  , ("(例4.3): 文書どおり p^(O)_O を寄せても分類は動かない（同じ数値で向きが逆）",
      let cO' = conceptScore xHat [qOf 7 4, qOf 1 2, qOf 1 2]
      in qratEq cO' (QRat 4 7)
         && qratLeq (conceptScore xHat protoDiag) cO'
         && not (qratEq (conceptScore xHat protoDiag) cO'))
  , ("(定義10.1): conceptScore は Metanoun.judgeMeta の大きさ欄と一致する",
      case judgeMag defaultLandmarks (MetaNoun (asIndividual protoOrigin) [])
                    (asIndividual xHat) [] of
        Just v  -> qratEq v (conceptScore xHat protoOrigin)
        Nothing -> False)
  , ("(§4.4): 履歴の一歩 K_a n_ω = n_{nf(aω)} は ⋆ がそのまま担う — n_ij ≠ n_ji",
      transportHistory (mkMono lamOne [I]) algJ
        /= transportHistory (mkMono lamOne [J]) algI)
  -- π は語と σ^ε をまとめて落とし、大きさと深度だけを残す（piForget）。
  -- K_a は係数 1 の単項なので、⋆ は大きさを変えずに語だけを動かす。
  -- 語が動く以上 σ^ε は変わりうるが、それは π の外にある。
  , ("(定理14.1): 核履歴の書込みは実数意味論 π を変えない — 大きさが保たれる",
      let n  = mkAlg [ mkMono (Lam 3 2) [I], mkMono (Lam 1 0) [J, I]
                     , mkMono (Lam (negate 5) 1) [] ]
          n' = transportHistory (mkMono lamOne [I]) n
          mags (PathAlg ms) = sort [ show (lamNorm (lamAbs (mCoeff m))) | m <- ms ]
      in mags n' == mags n && supp n' /= supp n)
  ]
  where
    algI = mkAlg [mkMono lamOne [I]]
    algJ = mkAlg [mkMono lamOne [J]]
    eta34 = QRat 3 4
    lam38 = qOf 3 3
    monoSamples =
      [ monoOne
      , mkMono lamOne [I]
      , mkMono lamOne [J]
      , mkMono (Lam 3 3) [I, J]
      , mkMono (Lam (negate 5) 2) [J, I]
      , mkMono (Lam 1 0) [I, I, J]
      ]
    qSamples =
      [ unitQ
      , QCoeff 2 2 [I] 1
      , QCoeff 3 3 [I, J] (negate 1)
      , QCoeff 4 1 [J] 1
      ]
