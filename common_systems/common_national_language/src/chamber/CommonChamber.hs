{-# LANGUAGE NoImplicitPrelude #-}
module CommonChamber where

import CounterConstraints
import CounterComputeSystem (Dyad, betaStep, phiPartial)
import CounterUnits (Op (..), UnitPoint (..), mkReal, applyI, applyU, negateUP)
import DagArith (SCoord, addS, negateS, alignDepth)
import qualified DagArith as Rat
import GclsCategory
  ( QCoeff (..), QRat (..), agreeQ, applyWord, mulWord, qratMul
  , qratLeq, joinJudge, residualRightJ, residualLeftJ, piJudge, homReach )

-- ===== チェンバー土台（コモン公用語の意味対象）=====
-- doc: chamber.def ser.canonical cnf.def layer.nf prim.table
--
-- C = ⟨(μ,d) | Γ⁻ ⇒ Λ₀;…;Λ_h ⇒ Γ⁺⟩。
-- 原始文字は新しい記号として作らず、積み上げた実装そのものを参照する:
--   単位適用は CounterUnits.applyU、負化は negateUP、β は CCS.betaStep、
--   φ∂ は CCS.phiPartial、加算は DagArith.addS。
-- ワイヤ型 = 値の種類そのもの。箱の横幅はポート列の長さから復元される。

-- ===== 値とワイヤ型 =====

data Value
  = VPt UnitPoint     -- 分岐語上の点。単位適用が走る
  | VCoord SCoord     -- 平面座標（四則演算の層）
  | VDyad Dyad        -- 二進有理数（Level 3 梯子）
  | VBit Int          -- 二値フラグ（φ∂ の出力）
  | VNoun QCoeff [QCoeff]
  -- 名詞ノード（07 §7）。ノードはプロファイル x̂ を運ぶ。
  -- 第一成分は関係を受けられる離散ノードのアドレス（構成語 QCoeff）、
  -- 第二成分は目印族上の影響プロファイル。判定チェンバーへの入口になる
  | VRefl Int
  -- 座標折返し（構成語 §7.1）。D_4 の八元を 13 §1.3 の番号で持つ:
  --   0 = E、1 = R_r、2 = R_w、3 = R_ij、4 = R_ji、5 = Q_+、6 = Q_-、7 = C_pi
  -- 値そのものは番号だが、意味は §7.1 の 2x2 行列であり、合成は行列積になる
  | VJudge QRat [Op] Int
  -- 判定値（07 §6.2、§10.2）: 整合対 (q ⇔ p) とその ⋆ 統合の値。
  -- 大きさは QRat（既約化しない有理数）、語と符号は μ=∞ のままで保持する。
  -- 所属は φ∂∘π で一段に落とすので、値型としてはこの形で持つ
  | VRational QRat
  | VChain [(Int, [Int])]
  | VRegion [Int]
  | VMono Int
  | VReference Int
  deriving (Eq, Read, Show)

-- 型レジストリ 𝒯（13 §1.2）との対応。PtUnit が Trace（構成履歴）、
-- PtCoord が Point（座標点）、PJudge が Q（影響値）になる
data Port = PtUnit | PtCoord | PtDyad | PtBit | PNoun | PJudge | PtRefl
          | PtRational | PtChain | PtRegion
          | PtMono | PtReference Int
  deriving (Eq, Ord, Read, Show)

kindOf :: Value -> Port
kindOf v = case v of
  VRefl _       -> PtRefl
  VPt _         -> PtUnit
  VCoord _      -> PtCoord
  VDyad _       -> PtDyad
  VBit _        -> PtBit
  VNoun _ _     -> PNoun
  VJudge {}     -> PJudge
  VRational _   -> PtRational
  VChain _      -> PtChain
  VRegion _     -> PtRegion
  VMono _       -> PtMono
  VReference k  -> PtReference k

mapKind :: Port -> Value -> Maybe Value
mapKind p v
  | kindOf v == p = Just v
  | otherwise     = Nothing

-- ===== 原始文字 = 積み上げた実装への参照 =====

data Prim
  = POne       -- one: I -> Dyad。原点 O に立つ（Common-Lang/2 §2 の五原始命令の筆頭）。
               -- 入力を取らない唯一の箱であり、Γ⁻ = I から始まる文章はここから立つ。
               -- 数の literal は要らない。ℤ[1/2] は one と beta・add・neg の合成で尽きる
  | PDupD      -- Δ_A: 二進有理数の明示複製（13 §1.2 で Dyad は Copyable 可）。
               -- 暗黙の複製は §15.4 の診断になるので、再利用は必ずこの箱を通す
  | PDropD     -- !_A: 二進有理数の明示廃棄。境界を I へ閉じる唯一の道であり、
               -- 計算に効かない文（16 §4 の I -> I）はこれで閉じる
  | PId        -- 恒等道（Level 0-1 の「道」、ユニットワイヤ用）
  | PCoordId   -- 座標用の恒等道（四則演算層のワイヤ）
  | PUnit Op   -- i / j 操作（Level 4/5、CounterUnits.applyU）
  | PNeg       -- 負化（Level 2、negateUP）
  | PBeta      -- β 梯子（Level 3 / CCS.betaStep、定理1.2 の自己相似写像）
  | PFold      -- φ∂ 二値抽出（CCS.phiPartial、唯一の非可逆操作）
  | PAdd       -- 加算の平行四辺形則（四則演算、DagArith.addS）
  | PAddD      -- 二進有理数の加算。深度をそろえてから足す（DagArith.alignDepth の Dyad 版）
  | PNegD      -- 二進有理数の負化（DagArith.negateS の Dyad 版）
  | PLeqD      -- 二進有理数の順序。深度をそろえて分子を比べる
  | PMul       -- 統合の論理積: 𝒬-豊穣の ⋆ による成分統合（DagArith.multiplyThales の Dyad 版）
  | PRel String
  -- 関係述語（07 §7）: 述語が関係のときは V の中身を遷移係数 T_f にとる。
  -- 文字列は原始関係 i, j の語（例 "ij"）。ser 直列化が壊れないよう
  -- カンマや括弧を含まない表現に限る。適用は GclsCategory.applyWord
  | PDupN      -- Δ_A: 名詞ノードの明示複製（07 §8.4）。μ=∞ では構成しない
  | PDropN     -- !_A: 名詞ノードの明示廃棄（07 §8.4）
  | PAgr       -- 整合対 (q ⇔ p) = (q ⇘ p) ⋆ (p ⇙ q)（07 §6.2）。GclsCategory.agreeQ
               -- 原型 p は第二入力ワイヤで受ける（分数プロファイル用）
  | PAgrU      -- 整合対の特殊形: 原型が 𝟏 に固定された箱。単位は quantale の原始値
  | PAgrZ      -- 整合対の特殊形: 原型が 0 に固定された箱。零は quantale の原始値。
               -- 離散ノードの one-hot プロファイルをこの二つで焼き込むことで、
               -- メタ名詞ごとに異なる正準形を持つ判定チェンバーになる（定理10.4）
  | PMulJ      -- 判定値の ⋆ 統合（C_identify の中身）
  | PPhiJ      -- 所属 φ∂∘π: 判定値を一段で二値へ落とす（07 §10.3）
  | POmW String
  -- Ω 閉包（07 §8.3、04 §15）: 周期的な関係語 u の自適用軌道を
  -- 有限に読む。文字列は原始関係 i, j の語。不動点ならその値、
  -- 周期軌道なら入口の状態へ一段で閉じる。反復は回さない
  | PLoadW     -- Load: 作業領域の語を読む（16 §5.0 の ta）。番地はワイヤで受ける
  | PStoreW    -- Store: 作業領域の語へ書く（同 ti）。番地と値の二本を受ける
  | POkR       -- Ok: 成功を報告して止まる（同 tu）
  | PPiF       -- π: 型忘却（16 §5.4）。Bit を Dyad へ落とす。値は動かないので
               -- 降下は空列になる。これがあると選択が生成元の合成で書ける:
               --   sel(c,a,b) = c ⋆ a ⊕ (1 ⊖ c) ⋆ b
  | POmOpen    -- Ω の開き（構成語 §5.4）。本体の層をここから数える
  | POmClose   -- Ω の閉じ。単調フラグを一本受ける（構成語 §5.5）。
               -- フラグが 0 の間は本体へ戻る。有限段で止まる根拠は 04 定理 9.1
  | PSupJ      -- ⋁: 判定値の上限（圏論 定理3.3）。𝒬 は完備束なので任意族の上限を持つ。
               -- 大きさは max、語は勝った側が運ぶ。並んで語が割れたら型を落とす
  | PResRJ     -- ↘: 右残差。a ⋆ b ≤ c ⟺ b ≤ a ↘ c（定理3.3）
  | PResLJ     -- ↙: 左残差。⋆ が非可換なので ↘ とは別の演算になり、
               -- 命題5.2 の「二つの含意」がこの二つの箱にあたる
  | PLeqJ      -- ≤: 𝒬 の順序。豊穣圏の 2-胞はこの不等式へ吸収される（定理3.4）
  | PHomQ      -- 𝔾(−,−): ホム対象。目印ごとの右残差を ⋀ で束ねた到達度（定理3.4）。
               -- 有向なので入れ替えると値が変わる（系3.5 の距離の向き）
  | PPiJ       -- π: 型忘却（定義3.4 の μ:∞→1）。大きさだけを残す。
               -- 所属 φ∂ は Θ∘π なので、この箱と phij の関係が二段の忘却になる
  -- ===== 圏論層の生成元（13 §1.1 の [15,38]、構成語 §7、圏論 第IV部）=====
  --
  -- 平文へ届く生成元は正準添字を取らないものに限る（16 §3.1）。だから
  -- 折返しは「番号を引数に取る一箱」ではなく、生成元と合成の四箱で持つ。
  -- §7.3 の生成関係が八元すべてを合成で出すので、表現力は落ちない。
  | PTrace     -- I -> Trace。構成履歴の入口。one が Dyad 層の入口であるのと同じ
               -- 位置づけで、これが無いと平文から i / j / rho へ届かない
  | PRhoM      -- rho^-: i i の簡約先（構成語 §6.3 の書換え、圏論 図4.C）。H^+ -> H^-
  | PRhoP      -- rho^+: j j の簡約先。H^- -> H^+。j^2 = +1 なので値は動かない。
               -- rho^- と別の箱であることは図が持つ（定理13.1 の忠実性）
  | PEndpoint  -- endpoint: Trace -> Point。履歴を座標点として読む。履歴は消さない
  | PReflE     -- I -> Reflection。折返しの単位 E
  | PReflR     -- I -> Reflection。実軸反転 R_r
  | PReflD     -- I -> Reflection。ij 対角反転 R_ij
  | PReflC     -- Reflection (x) Reflection -> Reflection。§7.2 の合成表。
               -- 行を先に、列を後に当てるので、行列では B・A になる
  | PAct       -- act: Reflection (x) Point -> Point（§7.4 の作用表）
  | PBetaInv   -- beta^{-1}(x) = 2x - a。実装の beta は a = 1（16 §5.1）
  | PFixL      -- fix: Omega_a[beta_a; x_0] = a を一箱で読む（16 式 5.7、5.8）。
               -- 反復を回さない。入力の値に依らず集積点を返す
  | PBisectD   -- beta_a(x) = (x + a) / 2。基準点 a を第二ワイヤで受ける（構成語 §8.1）。
               -- beta_a を正準添字つきの一箱で持つと平文へ届かないので（16 §3.1）、
               -- 添字をワイヤへ移した形をこちらに置く。Point 層の PBisectPoint と同じ式
  | PFixD      -- Omega_a[beta_a; x_0] = a。集積点 a を第二ワイヤで受ける（構成語 §5.2）。
               -- PFixL は a = 1 に固定された特殊形で、これが一般形になる。
               -- 初期値 x_0 は値に効かないので降下では落ちる（16 式 5.8）
  | PTheta     -- Theta: mu を 1 から 0 へ落とす二値化（圏論 定義3.4）。
               -- 所属 phij = Theta . pi なので、二段の忘却の後半にあたる
  | PNode      -- node: I -> Noun（16 §3.3 式 (3.2)、17 §3）。原点ノード Ô に立つ。
               -- one が Dyad 層の唯一の入口であるのと同じ位置づけで、
               -- Γ⁻ = I の平文から名詞層へ入る唯一の道になる。
               -- 個体ごとの literal は要らない。i, j の適用で任意のノードへ届く
  | PNodeUnit Op
  | PKoR | PPutW
  | PIdentity Port | PCopy Port | PDiscard Port
  | PCstD Integer Int
  | PBetaAt Integer Int | PInvAt Integer Int | PFixAt Integer Int
  | PReadR | PReadW | PDivD
  | PSimplex [Int] | PBoundary | PChainAdd
  | PRegion [Int] | PRegionOp String
  | PRegionAt -- 領域: Noun -> Region（幾何 Index の Level 0）。名詞ノードが立つ
              -- 場所の単位領域を返す。cell 番号は構成語から出るので、平文に
              -- 数字が現れない（16 §3.1）。node と同じく、これが領域層の唯一の入口になる
  | PProfile Int | PWeight Int
  | PTransport [[Dyad]]
  | PBisectPoint
  | PFixPoint
  | PReflection Int
  | PBetaPoint Int | PInversePoint Int | PReflectPoint Int
  | PExt Int Int | PAcc Int Int
  | PEqBranch Int | PLtBranch Int | PBranch Int
  | PSupFamily Int
  | POmega Int Chamber Chamber
  deriving (Eq, Ord, Read, Show)

-- 関係述語のための語と文字列の相互変換。ser の直列化を壊さないための制約
relWord :: String -> [Op]
relWord = map chOp
  where chOp 'i' = I
        chOp 'j' = J
        chOp _   = I   -- 不正文字は原始関係 i へ落ちる（整形式検査で弾かない）

relStr :: [Op] -> String
relStr = map chStr
  where chStr I = 'i'
        chStr J = 'j'

canonicalPoint :: Int -> SCoord
canonicalPoint p = case p of
  0 -> (0,0,0)
  1 -> (1,0,0)
  2 -> (negate 1,0,0)
  3 -> (0,1,0)
  4 -> (0,negate 1,0)
  5 -> (1,1,0)
  6 -> (negate 1,1,0)
  7 -> (1,negate 1,0)
  _ -> (negate 1,negate 1,0)

evalPrim :: Prim -> [Value] -> Maybe [Value]
evalPrim prim vs = case (prim, vs) of
  (POmega a body seed, inputs) -> evalOmega a body seed inputs
  (PSupFamily n, values) | n >= 0 && length values == n ->
    let collect [] out = Just out
        collect (VJudge m w s:rest) (VJudge a u t) =
          let (b,(v,r)) = joinJudge (a,(u,t)) (m,(w,s))
          in collect rest (VJudge b v r)
        collect _ _ = Nothing
    in case collect values (VJudge (QRat 0 1) [] 1) of
      Just out -> Just [out]
      Nothing -> Nothing
  (PBisectPoint, [VCoord x,VCoord a]) ->
    let (r,w,d) = addS x a in Just [VCoord (r,w,d+1)]
  (PFixPoint, [VCoord _,VCoord a]) -> Just [VCoord a]
  (PReflection k, []) | k >= 0 && k < 8 -> Just [VRefl k]
  (PBetaPoint k, [VCoord x]) | k >= 0 && k < 9 ->
    evalPrim PBisectPoint [VCoord x,VCoord (canonicalPoint k)]
  (PInversePoint k, [VCoord (r,w,d)]) | k >= 0 && k < 9 && d > 0 ->
    let (a,b,_) = canonicalPoint k
    in Just [VCoord (r-shiftL a (d-1),w-shiftL b (d-1),d-1)]
  (PReflectPoint k, [VCoord x]) | k >= 0 && k < 8 -> Just [VCoord (reflAct k x)]
  (PExt _ _, xs) -> evalPrim PMul xs
  (PAcc _ _, xs) -> evalPrim PAddD xs
  (PTransport images, xs) | validTransport images && length xs == length images -> do
    let width = case images of (row:_) -> length row; [] -> 0
        contribution j (v,row) = case drop j row of
          (coefficient:_) -> case evalPrim PMul [VDyad coefficient,v] of
            Just [y] -> Just y
            _ -> Nothing
          [] -> Nothing
        addTerm (Just v) value = case evalPrim PAddD [v,value] of
          Just [y] -> Just y
          _ -> Nothing
        addTerm Nothing _ = Nothing
        imageComponent j = do
          terms <- mapM (contribution j) (zip xs images)
          foldl addTerm (Just (VDyad (0,0))) terms
    mapM imageComponent [0 .. width - 1]
  (PIdentity _, [v]) -> Just [v]
  (PCopy _, [v]) -> Just [v, v]
  (PDiscard _, [_]) -> Just []
  (PCstD n d, []) | d >= 0 -> Just [VDyad (n, d)]
  (PNodeUnit op, [VNoun x p]) -> Just [VNoun (applyWord [op] x) p]
  (PBetaAt n d, [VDyad x]) | d >= 0 ->
    let (u, a, e) = dyAlign x (n, d) in Just [VDyad (u + a, e + 1)]
  (PInvAt n d, [VDyad (x, e)]) | e > d && d >= 0 ->
    Just [VDyad (x - shiftL n (e - 1 - d), e - 1)]
  (PFixAt n d, [VDyad _]) | d >= 0 -> Just [VDyad (n, d)]
  (PReadR, [VCoord (r, _, d)]) -> Just [VCoord (r, 0, d)]
  (PReadW, [VCoord (_, w, d)]) -> Just [VCoord (w, 0, d)]
  (PDivD, [VDyad (x, d), VDyad (y, e)]) ->
    case Rat.qratDiv (QRat x (shiftL 1 d)) (QRat y (shiftL 1 e)) of
      Just q -> Just [VRational q]
      Nothing -> Nothing
  (PSimplex vertices0, []) | all (\v -> v >= 0 && v < 64) vertices0 ->
    Just [VChain [(1, vertices (simplex vertices0))]]
  (PBoundary, [VChain cs]) -> Just [VChain (normalChain
    [(a * b, vertices f) | (a, vs0) <- cs, (b, f) <- boundary (simplex vs0)])]
  -- 影響の係数は {−1, 0, 1} に限る（影響関数 証明3.2）。σ_{n−1} が σ_n の境界に
  -- 符号つきで入るか入らないかの三択しかないので、それを外れた和は鎖でなくなる
  (PChainAdd, [VChain a, VChain b])
    | all (\(n, _) -> abs n <= 1) sum0 -> Just [VChain sum0]
    where sum0 = normalChain (a ++ b)
  (PRegion es, []) | all (\e -> e >= 0 && e < 64) es ->
    Just [VRegion (unique es)]
  (PRegionAt, [VNoun (QCoeff _ _ w _) _]) | cellOfWord w < cellCeiling ->
    Just [VRegion [cellOfWord w]]
  (PRegionOp op, args) -> regionPrim op args
  (PProfile n, xs) | n >= 0 && length xs == n ->
    case mapM dyadValue xs of
      Just ds -> Just [VNoun unitQC (map dyadToQC ds)]
      Nothing -> Nothing
  (PWeight k, [VNoun x ps]) | k >= 0 ->
    case drop k (if null ps then [x] else ps) of
      (QCoeff n d _ s : _) -> Just [VDyad (toInteger (n * s), d)]
      [] -> Nothing
  (POne,     [])               -> Just [VDyad (1, 0)]
  (PDupD,    [VDyad x])        -> Just [VDyad x, VDyad x]
  (PDropD,   [VDyad _])        -> Just []
  (PUnit op, [VPt p])          -> Just [VPt (applyU op p)]
  (PId,      [v])              -> Just [v]
  (PCoordId, [VCoord x])       -> Just [VCoord x]
  (PNeg,     [VPt p])          -> Just [VPt (negateUP p)]
  (PBeta,    [VDyad x])        -> Just [VDyad (betaStep x)]
  (PFold,    [VDyad x])        -> Just [VBit (phiPartial x)]
  (PPiF,     [VBit b])         -> Just [VDyad (toInteger b, 0)]
  (PAdd,     [VCoord x, VCoord y]) -> Just [VCoord (addS x y)]
  (PAddD,    [VDyad p, VDyad q]) ->
    let (x, y, d) = dyAlign p q in Just [VDyad (x + y, d)]
  (PNegD,    [VDyad (n, d)])     -> Just [VDyad (negate n, d)]
  (PLeqD,    [VDyad p, VDyad q]) ->
    let (x, y, _) = dyAlign p q in Just [VBit (if x <= y then 1 else 0)]
  (PMul,     [VDyad x, VDyad y]) -> Just [VDyad ((fst x * fst y, snd x + snd y))]
  (PRel w,   [VNoun x p, VNoun o po]) ->
    -- 主語へ関係語 u を適用し、目的語は素通しにする。
    -- 非可換なので適用順が意味を持つ（07 例5.1、§5.2）
    Just [VNoun (applyWord (relWord w) x) p, VNoun o po]
  (PDupN,    [VNoun x p])      -> Just [VNoun x p, VNoun x p]
  (PDropN,   [VNoun _ _])      -> Just []
  (PAgr,     [VDyad q, VDyad p]) ->
    -- 大きさと語は GclsCategory.agreeQ そのもの。重みは Dyad なので
    -- 空語の QCoeff へ持ち上げてから整合対を取る
    let (v, w) = agreeQ (dyadToQC q) (dyadToQC p)
        (ws, s) = w
    in Just [VJudge v ws s]
  (PAgrU,    [VDyad q]) ->
    let (v, w) = agreeQ (dyadToQC q) unitQC
        (ws, s) = w
    in Just [VJudge v ws s]
  (PAgrZ,    [VDyad q]) ->
    let (v, w) = agreeQ (dyadToQC q) zeroQC
        (ws, s) = w
    in Just [VJudge v ws s]
  (PMulJ,    [VJudge a ws s, VJudge b vs t]) ->
    -- C_identify の中身は ⋆。大きさは積、語は接合（mulWord）
    let w2 = mulWord (ws, s) (vs, t)
        (wOps, wSign) = w2
        v2 = qratMul a b
    in Just [VJudge v2 wOps wSign]
  (PPhiJ,    [VJudge (QRat n _) _ _]) ->
    -- 所属 φ∂∘π: 大きさが正であることだけを読む。閾値という原始はない
    Just [VBit (if n > 0 then 1 else 0)]
  (POmW w,   [VNoun x p])      -> case periodicClosure (relWord w) x of
    Just y  -> Just [VNoun y p]
    Nothing -> Nothing
  (PSupJ,    [VJudge a wa sa, VJudge b wb sb]) ->
    let (m, (w, sg)) = joinJudge (a, (wa, sa)) (b, (wb, sb))
    in Just [VJudge m w sg]
  (PResRJ,   [VJudge a wa sa, VJudge c wc sc]) ->
    let (m, (w, sg)) = residualRightJ (a, (wa, sa)) (c, (wc, sc))
    in Just [VJudge m w sg]
  (PResLJ,   [VJudge c wc sc, VJudge b wb sb]) ->
    let (m, (w, sg)) = residualLeftJ (c, (wc, sc)) (b, (wb, sb))
    in Just [VJudge m w sg]
  (PLeqJ,    [VJudge a _ _, VJudge b _ _]) ->
    Just [VBit (if qratLeq a b then 1 else 0)]
  (PHomQ,    [VNoun x px, VNoun y py]) ->
    -- プロファイルを持たないノードは番地そのものを一成分のプロファイルとして読む。
    -- node が立てる原点 Ô がその場合にあたる
    let a = if null px then [x] else px
        b = if null py then [y] else py
    in if length a /= length b
         then Nothing
         else let (m, (w, sg)) = homReach a b in Just [VJudge m w sg]
  (PPiJ,     [VJudge m w sg]) ->
    let (m', (w', sg')) = piJudge (m, (w, sg)) in Just [VJudge m' w' sg']
  -- 構成履歴の入口。実軸の単位点に立つ。空語が実軸であり、i / j はここから伸びる
  (PTrace,   [])               -> Just [VPt (UnitPoint [] 1 1)]
  (PRhoM,    [VPt p])          -> Just [VPt (negateUP p)]
  (PRhoP,    [VPt p])          -> Just [VPt p]
  (PEndpoint, [VPt p])         -> case endpointOf p of
    Just c  -> Just [VCoord c]
    Nothing -> Nothing
  (PReflE,   [])               -> Just [VRefl 0]
  (PReflR,   [])               -> Just [VRefl 1]
  (PReflD,   [])               -> Just [VRefl 3]
  (PReflC,   [VRefl a, VRefl b]) -> Just [VRefl (reflCompose a b)]
  (PAct,     [VRefl k, VCoord c]) -> Just [VCoord (reflAct k c)]
  (PBetaInv, [VDyad (n, d)])
    -- beta(m,d) = (m + 2^d, d+1) は深度を一つ上げる。逆は下げる。
    -- 深度 0 は像の外なので定義域に入らない（構成語 §4 の im beta_a）
    | d >= 1    -> Just [VDyad (n - shiftL 1 (d - 1), d - 1)]
    | otherwise -> Nothing
  -- Omega_a[beta_a; x_0] = a を一箱で読む。実装の beta は a = 1（16 式 5.7、5.8）
  (PFixL,    [VDyad _])        -> Just [VDyad (1, 0)]
  -- 基準点をワイヤで受ける形。PBisectPoint と同じ式を Dyad の上で取る
  (PBisectD, [VDyad x, VDyad a]) ->
    let (u, v, d) = dyAlign x a in Just [VDyad (u + v, d + 1)]
  -- x = (x + a) / 2 の解は x = a。初期値は値に効かない（構成語 §5.2）
  (PFixD,    [VDyad _, VDyad a]) -> Just [VDyad a]
  (PTheta,   [VJudge (QRat n _) _ _]) -> Just [VBit (if n > 0 then 1 else 0)]
  (PNode,    [])               -> Just [VNoun unitQC []]
  -- Ô = 原点。NounNet が原点として使う値と同じ QCoeff になる。
  -- プロファイル欄は空で立つ。観測したプロファイルはチェンバーの構造の側
  -- （原型の二進有理定数）が持つので、ワイヤの値へは載せない
  _                            -> Nothing

dyadValue :: Value -> Maybe Dyad
dyadValue (VDyad x) = Just x
dyadValue _ = Nothing

validTransport :: [[Dyad]] -> Bool
validTransport [] = False
validTransport (row:rows) = not (null row)
  && all ((== length row) . length) rows
  && all ((>= 0) . snd) (concat (row:rows))

unique :: Ord a => [a] -> [a]
unique = foldr (\x xs -> if elem x xs then xs else x : xs) [] . sort

normalChain :: [(Int, [Int])] -> [(Int, [Int])]
normalChain cs = [(n, vs) | vs <- unique (map snd cs),
                           let n = sum [a | (a, ws) <- cs, ws == vs], n /= 0]

-- ===== 名詞ノードの場所を cell 番号へ =====
-- doc: level0.primitives addr.relative
--
-- 構成語は D∞ = ⟨i, j | i² = j² = e⟩ の元であり、(m, ε) の対で尽きる。
--
--   i = (0,1)、 j = (1,1)
--   (m,ε)·(m',ε') = (m + (1−2ε)m',  ε + ε' − 2εε')
--
-- m は ℤ を走るので、ジグザグで ℕ へ畳んでから ε を下位 bit に置く。
--
--   cell(w) = 2·zz(m) + ε、   zz(m) = 2m (m ≥ 0)、−2m−1 (m < 0)
--
-- zz は単射なので cell も単射になる。別のノードが同じ単位領域を指すことは無く、
-- 共通部と合わせが目印の重なりを正しく写す。
-- 単位領域の天井。commonc は領域を一語の mask で持つので、cell は 31 個までになる。
-- ∂ が cell + 1 の頂点を出すため、鎖の頂点は 32 個まで入る。
-- O から 15 歩までの構成語がこの網に収まる
cellCeiling :: Int
cellCeiling = 31

cellOfWord :: [Op] -> Int
cellOfWord = enc . foldl step (0, 0)
  where
    step (m, e) I = (m, 1 - e)
    step (m, e) J = (m + (1 - 2 * e), 1 - e)
    enc (m, e) = 2 * (if m >= 0 then 2 * m else negate (2 * m) - 1) + e

-- doc: level0.primitives influence.boundary
regionPrim :: String -> [Value] -> Maybe [Value]
regionPrim op args = case (op, args) of
  ("intersection", [VRegion a, VRegion b]) -> reg [x | x <- a, elem x b]
  ("union", [VRegion a, VRegion b]) -> reg (a ++ b)
  ("exterior", [VRegion universe, VRegion a]) -> reg [x | x <- universe, notElem x a]
  ("contains", [VRegion a, VRegion b]) -> flag (all (`elem` a) b)
  ("overlaps", [VRegion a, VRegion b]) -> flag (any (`elem` b) a)
  ("adjacent", [VRegion a, VRegion b]) ->
    flag (not (any (`elem` b) a) && or [abs (x - y) == 1 | x <- a, y <- b])
  ("inside", [VDyad (n, 0), VRegion a]) -> flag (elem (fromInteger n) a)
  ("outside", [VDyad (n, 0), VRegion a]) -> flag (notElem (fromInteger n) a)
  ("path", [VRegion a]) -> flag (not (null a) && all (\(x,y) -> y == x + 1) (zip a (drop 1 a)))
  ("boundary", [VRegion a]) ->
    Just [VChain (normalChain (concat [[(-1,[e]), (1,[e+1])] | e <- a]))]
  _ -> Nothing
  where
    reg xs = Just [VRegion (unique xs)]
    flag x = Just [VBit (if x then 1 else 0)]

-- ===== 座標折返し（構成語 §7）=====
--
-- 八元を 2x2 の整数行列で持つ。合成は行列積になるので、§7.2 の表を書き写さない。
-- 表そのものは selfcheck が突き合わせる。
--
--   E = [[1,0],[0,1]]      R_r  = [[1,0],[0,-1]]   R_w = [[-1,0],[0,1]]
--   R_ij = [[0,1],[1,0]]   R_ji = [[0,-1],[-1,0]]
--   Q_+ = [[0,-1],[1,0]]   Q_-  = [[0,1],[-1,0]]   C_pi = [[-1,0],[0,-1]]

type Refl = (Int, Int, Int, Int)      -- (a, b, c, d) = [[a,b],[c,d]]

reflMatrix :: Int -> Refl
reflMatrix k = case k of
  0 -> ( 1,  0,  0,  1)
  1 -> ( 1,  0,  0, -1)
  2 -> (-1,  0,  0,  1)
  3 -> ( 0,  1,  1,  0)
  4 -> ( 0, -1, -1,  0)
  5 -> ( 0, -1,  1,  0)
  6 -> ( 0,  1, -1,  0)
  _ -> (-1,  0,  0, -1)

reflOfMatrix :: Refl -> Int
reflOfMatrix m = case [ k | k <- [0 .. 7], reflMatrix k == m ] of
  (k : _) -> k
  []      -> 0

-- 表の成分 A ◇ B は B ∘ A になる（§7.2 の但し書き）。行を先に当てる
reflCompose :: Int -> Int -> Int
reflCompose a b = reflOfMatrix (matMul (reflMatrix b) (reflMatrix a))

matMul :: Refl -> Refl -> Refl
matMul (a, b, c, d) (e, f, g, h) =
  (a * e + b * g, a * f + b * h, c * e + d * g, c * f + d * h)

-- §7.4 の作用。深度は折返しで動かない
reflAct :: Int -> SCoord -> SCoord
reflAct k (r, w, d) = (a * r + b * w, c * r + e * w, d)
  where (a, b, c, e) = reflMatrix k

-- ===== 構成履歴の終点（圏論 定理4.2、13 §1.3）=====
--
-- 座標写像は忠実でないので、履歴の側から読む。正準点は §7.4 の並びになる。
--
--   空語   実軸  (v, 0)          [i]        i 側  (0,  v)
--   [j]    j 側  (0, -v)         [i,j] = ij       (v,  v)   p_++
--   [j,i] = ji   (v, -v)  p_+-
--
-- 大きさは spotOf の絶対値、向きは signU が持つ。この読み方だけが三つの事実と
-- 同時に整合する。applyU の II 畳みは両方を反転するので、積で読むと i^2 が
-- 恒等になってしまう。
--
--   i^2 = -1     II 畳みが signU を反転する        向きが反転する
--   j^2 = +1     JJ 畳みは何も動かさない            向きが変わらない
--   定理4.2      negateUP が signU を反転する      -(b i) と b j が同じ点になる
--
-- これより長い語の終点は文書が固定していない。値を与えないで整形式検査へ回す
endpointOf :: UnitPoint -> Maybe SCoord
endpointOf (UnitPoint w s c) = case w of
  []      -> Just (v, 0, 0)
  [I]     -> Just (0, v, 0)
  [J]     -> Just (0, negate v, 0)
  [I, J]  -> Just (v, v, 0)
  [J, I]  -> Just (v, negate v, 0)
  _       -> Nothing
  where v = c * abs s

-- 二進有理数の深度そろえ。値 = 分子 / 2^深度 なので、深い側へ寄せる。
-- SCoord の分子は Int 幅、Dyad の分子は Integer 幅という違いだけで、
-- 規則は DagArith.alignDepth と同じ。一致は selfcheck で検査する
dyAlign :: Dyad -> Dyad -> (Integer, Integer, Int)
dyAlign (a, da) (b, db) = (a * shiftL 1 (d - da), b * shiftL 1 (d - db), d)
  where d = max da db

-- Dyad を空語の QCoeff へ持ち上げる。大きさだけの読み（μ=1 相当）
dyadToQC :: Dyad -> QCoeff
dyadToQC (n, d) = QCoeff (fromInteger n) d [] 1

unitQC, zeroQC :: QCoeff
unitQC = QCoeff 1 0 [] 1
zeroQC = QCoeff 0 0 [] 1

-- Ω_a[F;x₀] の名詞オートマトン版（07 §8.3、04 §15.1）。
-- F = 関係語 u の自適用。軌道 x₀ → x₀u → x₀u² → … を境界で読む:
--   不動点 x·u = x          … その値を返す
--   周期   x·uᵏ = x (k ≥ 1) … 入口の状態 x₀ へ一段で閉じる
--   境界まで閉じない         … 整形式でないので値を与えない
-- β_a の数値ケース（x = β_a(x) を解いて x = a）は Totality.solveFix が扱う
periodicClosure :: [Op] -> QCoeff -> Maybe QCoeff
periodicClosure ops x0 = go x0 omBound
  where
    f = applyWord ops
    omBound = 8   -- 探索上限。周期の長い語は未閉包として拒否する
    go x k
      | k < 0     = Nothing
      | f x == x0 = Just x0
      | f x == x  = Just x
      | otherwise = go (f x) (k - 1)

kindsOfPrim :: Prim -> ([Port], [Port])
kindsOfPrim prim = case prim of
  POmega _ body _ -> (take (length (chIn body) - length (chOut body)) (chIn body),chOut body)
  PSupFamily n -> (replicate n PJudge,[PJudge])
  PBisectPoint -> ([PtCoord,PtCoord],[PtCoord])
  PFixPoint -> ([PtCoord,PtCoord],[PtCoord])
  PReflection _ -> ([],[PtRefl])
  PBetaPoint _ -> ([PtCoord],[PtCoord])
  PInversePoint _ -> ([PtCoord],[PtCoord])
  PReflectPoint _ -> ([PtCoord],[PtCoord])
  PExt _ _ -> ([PtDyad,PtDyad],[PtDyad])
  PAcc _ _ -> ([PtDyad,PtDyad],[PtDyad])
  PEqBranch _ -> ([PtDyad,PtDyad],[])
  PLtBranch _ -> ([PtDyad,PtDyad],[])
  PBranch _ -> ([],[])
  PIdentity t -> ([t], [t])
  PCopy t -> ([t], [t,t])
  PDiscard t -> ([t], [])
  PCstD _ _ -> ([], [PtDyad])
  PNodeUnit _ -> ([PNoun], [PNoun])
  PKoR -> ([], [])
  PPutW -> ([PtDyad], [])
  PBetaAt _ _ -> ([PtDyad], [PtDyad])
  PInvAt _ _ -> ([PtDyad], [PtDyad])
  PFixAt _ _ -> ([PtDyad], [PtDyad])
  PReadR -> ([PtCoord], [PtCoord])
  PReadW -> ([PtCoord], [PtCoord])
  PDivD -> ([PtDyad, PtDyad], [PtRational])
  PSimplex _ -> ([], [PtChain])
  PBoundary -> ([PtChain], [PtChain])
  PChainAdd -> ([PtChain, PtChain], [PtChain])
  PRegion _ -> ([], [PtRegion])
  PRegionAt -> ([PNoun], [PtRegion])
  PRegionOp op -> case op of
    "inside" -> ([PtDyad, PtRegion], [PtBit])
    "outside" -> ([PtDyad, PtRegion], [PtBit])
    "path" -> ([PtRegion], [PtBit])
    "boundary" -> ([PtRegion], [PtChain])
    _ -> ([PtRegion, PtRegion], [if elem op ["intersection","union","exterior"] then PtRegion else PtBit])
  PProfile n -> (replicate n PtDyad, [PNoun])
  PWeight _ -> ([PNoun], [PtDyad])
  PTransport images -> (replicate (length images) PtDyad,
    replicate (case images of (row:_) -> length row; [] -> 0) PtDyad)
  POne    -> ([], [PtDyad])
  PDupD   -> ([PtDyad], [PtDyad, PtDyad])
  PDropD  -> ([PtDyad], [])
  PUnit _ -> ([PtUnit], [PtUnit])
  PId     -> ([PtUnit], [PtUnit])
  PCoordId -> ([PtCoord], [PtCoord])
  PNeg    -> ([PtUnit], [PtUnit])
  PBeta   -> ([PtDyad], [PtDyad])
  PFold   -> ([PtDyad], [PtBit])
  PAdd    -> ([PtCoord, PtCoord], [PtCoord])
  PAddD   -> ([PtDyad, PtDyad], [PtDyad])
  PNegD   -> ([PtDyad], [PtDyad])
  PLeqD   -> ([PtDyad, PtDyad], [PtBit])
  PMul    -> ([PtDyad, PtDyad], [PtDyad])
  PRel _  -> ([PNoun, PNoun], [PNoun, PNoun])
  PDupN   -> ([PNoun], [PNoun, PNoun])
  PDropN  -> ([PNoun], [])
  PAgr    -> ([PtDyad, PtDyad], [PJudge])
  PAgrU   -> ([PtDyad], [PJudge])
  PAgrZ   -> ([PtDyad], [PJudge])
  PMulJ   -> ([PJudge, PJudge], [PJudge])
  PPhiJ   -> ([PJudge], [PtBit])
  POmW _  -> ([PNoun], [PNoun])
  PLoadW  -> ([PtDyad], [PtDyad])
  PStoreW -> ([PtDyad, PtDyad], [])
  POkR    -> ([], [])
  PPiF    -> ([PtBit], [PtDyad])
  POmOpen -> ([], [])
  POmClose -> ([PtBit], [])
  PSupJ   -> ([PJudge, PJudge], [PJudge])
  PResRJ  -> ([PJudge, PJudge], [PJudge])
  PResLJ  -> ([PJudge, PJudge], [PJudge])
  PLeqJ   -> ([PJudge, PJudge], [PtBit])
  PHomQ   -> ([PNoun, PNoun], [PJudge])
  PPiJ    -> ([PJudge], [PJudge])
  PNode   -> ([], [PNoun])
  PTrace  -> ([], [PtUnit])
  PRhoM   -> ([PtUnit], [PtUnit])
  PRhoP   -> ([PtUnit], [PtUnit])
  PEndpoint -> ([PtUnit], [PtCoord])
  PReflE  -> ([], [PtRefl])
  PReflR  -> ([], [PtRefl])
  PReflD  -> ([], [PtRefl])
  PReflC  -> ([PtRefl, PtRefl], [PtRefl])
  PAct    -> ([PtRefl, PtCoord], [PtCoord])
  PBetaInv -> ([PtDyad], [PtDyad])
  PFixL   -> ([PtDyad], [PtDyad])
  PBisectD -> ([PtDyad, PtDyad], [PtDyad])
  PFixD   -> ([PtDyad, PtDyad], [PtDyad])
  PTheta  -> ([PJudge], [PtBit])

-- ===== 原子箱・層・チェンバー =====

-- 表示用のタグは意味を作らない。意味は Prim（＝既存実装）と CNF 側にある
data Atom = Atom
  { atomTag  :: String
  , atomPrim :: Prim
  } deriving (Eq, Ord, Read, Show)

atomPorts :: Atom -> ([Port], [Port])
atomPorts a = kindsOfPrim (atomPrim a)

mkAtom :: String -> Prim -> Atom
mkAtom t p = Atom t p

primOne, primDupD, primDropD :: Atom
primOne   = mkAtom "one"  POne
primDupD  = mkAtom "dupd" PDupD
primDropD = mkAtom "drpd" PDropD

primId, primCId, primI, primJ, primNeg, primBeta, primFold, primAdd :: Atom
primId   = mkAtom "id"   PId
primCId  = mkAtom "cid"  PCoordId
primI    = mkAtom "i"    (PUnit I)
primJ    = mkAtom "j"    (PUnit J)
primNeg  = mkAtom "neg"  PNeg
primBeta = mkAtom "beta" PBeta
primFold = mkAtom "fold" PFold
primAdd  = mkAtom "add"  PAdd
primMul :: Atom
primMul  = mkAtom "mul"  PMul

-- 二進有理数の層。counter_plane 側で定義済みの演算への参照であり、
-- 新しい概念を持ち込むものではない
primAddD, primNegD, primLeqD :: Atom
primAddD = mkAtom "addd" PAddD
primNegD = mkAtom "negd" PNegD
primLeqD = mkAtom "leqd" PLeqD

-- 名詞層の原始箱。引数を取らないものはレジストリに入り、発音単位を持つ
primDupN, primDropN, primAgr, primAgrU, primAgrZ, primMulJ, primPhiJ, primNode :: Atom
primDupN  = mkAtom "dup"  PDupN
primDropN = mkAtom "drop" PDropN
primAgr   = mkAtom "agr"  PAgr
primAgrU  = mkAtom "agru" PAgrU
primAgrZ  = mkAtom "agrz" PAgrZ
primMulJ  = mkAtom "mulj" PMulJ
primPhiJ  = mkAtom "phij" PPhiJ
primNode  = mkAtom "node" PNode

-- 作業領域と報告、そして閉包。16 §5.0 は Load / Store / Ok を平文へ届くと定め、
-- 構成語 §5.4 は閉包を「一回分の F と戻り境界を持つ自己相似箱」と定める。
-- どれも正準添字を取らないので、16 §3.1 の「平文に数字も括弧もラベルも現れない」を守る
-- 圏論層の原始箱（圏論 第III部）。どれも引数を取らないのでレジストリに入り、
-- 発音単位を一つずつ持つ。𝒬 の演算がそのまま語として書けるようになる
primSupJ, primResRJ, primResLJ, primLeqJ, primHomQ, primPiJ :: Atom
primSupJ  = mkAtom "sup"  PSupJ
primResRJ = mkAtom "resr" PResRJ
primResLJ = mkAtom "resl" PResLJ
primLeqJ  = mkAtom "leqj" PLeqJ
primHomQ  = mkAtom "hom"  PHomQ
primPiJ   = mkAtom "pij"  PPiJ

-- 圏論層の原始箱。どれも正準添字を取らないので平文へ届く（16 §3.1）
primTrace, primRhoM, primRhoP, primEndp :: Atom
primTrace = mkAtom "trc"  PTrace
primRhoM  = mkAtom "rhom" PRhoM
primRhoP  = mkAtom "rhop" PRhoP
primEndp  = mkAtom "epnt" PEndpoint

primReflE, primReflR, primReflD, primReflC, primAct :: Atom
primReflE = mkAtom "rid"  PReflE
primReflR = mkAtom "refr" PReflR
primReflD = mkAtom "refd" PReflD
primReflC = mkAtom "rcmp" PReflC
primAct   = mkAtom "act"  PAct

primBetaInv, primFixL, primTheta :: Atom
primBetaInv = mkAtom "binv"  PBetaInv
primFixL    = mkAtom "fixl"  PFixL
primTheta   = mkAtom "theta" PTheta

-- 基準点をワイヤで受ける二分割と閉包。beta_a と Omega_a を平文で書く道になる。
-- 正準添字つきの beta-at / fix-at は .cml の側に残り、こちらは添字を持たない
primBisectD, primFixD :: Atom
primBisectD = mkAtom "bis"  PBisectD
primFixD    = mkAtom "omga" PFixD

primLoadW, primStoreW, primOkR, primPiF, primOmOpen, primOmClose :: Atom
primLoadW   = mkAtom "load"  PLoadW
primStoreW  = mkAtom "store" PStoreW
primOkR     = mkAtom "ok"    POkR
primPiF     = mkAtom "pi"    PPiF
primOmOpen  = mkAtom "omop"  POmOpen
primOmClose = mkAtom "omcl"  POmClose


-- 直列化から復元するときの原始文字辞書
primitiveTable :: [(String, Atom)]
primitiveTable =
  [ (atomTag a, a)
  | a <- [ primId, primCId, primI, primJ, primNeg, primBeta, primFold
         , primAdd, primMul, primDupN, primDropN, primAgr, primAgrU, primAgrZ, primMulJ, primPhiJ
         , primAddD, primNegD, primLeqD, primOne, primDupD, primDropD
         , primNode
         , primLoadW, primStoreW, primOkR, primPiF, primOmOpen, primOmClose
         -- 追加は末尾に置く。レジストリ順が音節番号なので、途中へ挿すと
         -- 既存の語の発音が全部ずれる（06 §2 の E_speech）
         , primSupJ, primResRJ, primResLJ, primLeqJ, primHomQ, primPiJ
         -- 圏論層（13 §1.1 の [15,38]）。音節表は 70 音節あるので、
         -- ここまで足しても一音節ずつに収まる（10 §4）
         , primTrace, primRhoM, primRhoP, primEndp
         , primReflE, primReflR, primReflD, primReflC, primAct
         , primBetaInv, primFixL, primTheta
         -- 基準点をワイヤで受ける形（22 式 22.7、22.8）
         , primBisectD, primFixD
         -- 名詞層への i / j と関係述語（07 §5.1、17 §4.2）
         , mkAtom "nodei" (PNodeUnit I), mkAtom "nodej" (PNodeUnit J)
         , mkAtom "reli" (PRel "i"), mkAtom "relj" (PRel "j")
         -- 外部環境への報告と一 byte 出力（16 §5.0）
         , mkAtom "ko" PKoR, mkAtom "put" PPutW
         -- 座標の実成分と無限成分（13 §1.2 の Point）
         , mkAtom "readr" PReadR, mkAtom "readw" PReadW
         -- 除算と幾何の鎖（01 §6、influence.boundary）
         , mkAtom "div" PDivD, mkAtom "boundary" PBoundary
         , mkAtom "chainadd" PChainAdd
         -- 領域層（幾何連合論理集合 Index の Level 0）。操作は四つで尽きる。
         -- 共通部・合わせ・外側・境界。領域そのものは名詞ノードから立てる。
         -- ここまでで ∂ の入力になる鎖が平文から作れるようになり、
         -- 13 §1.1 の「∂_G は鎖の型を先に立てる必要がある」が閉じる
         , mkAtom "rgat"  PRegionAt
         , mkAtom "rgcap" (PRegionOp "intersection")
         , mkAtom "rgcup" (PRegionOp "union")
         , mkAtom "rgout" (PRegionOp "exterior")
         , mkAtom "rgbd"  (PRegionOp "boundary")
         -- 関係。Index は「操作の関係」として導けると書いているが、値として
         -- 使うには二値の席が要る。四つとも同じ四操作の上の述語になる
         , mkAtom "rgin"   (PRegionOp "contains")
         , mkAtom "rgov"   (PRegionOp "overlaps")
         , mkAtom "rgadj"  (PRegionOp "adjacent")
         , mkAtom "rgpath" (PRegionOp "path") ] ]

-- 表の外に残る原子は無い。欄は .cml の側の別名解決のために残す
extensionTable :: [(String,Atom)]
extensionTable = []

lookupAtom :: String -> Maybe Atom
lookupAtom t = lookup t (primitiveTable ++ extensionTable)

-- 層: 同じ因果深度の箱たち。(q, 箱)。q 昇順が正準形で、
-- 箱に覆われない位置は恒等ワイヤで通過する
newtype Layer = Layer { layerAtoms :: [(Int, Atom)] } deriving (Eq, Ord, Read, Show)

-- 記憶深度 μ の格付け（圏論 定義3.4）
data Mu = M0 | M1 | M2 | MInf deriving (Eq, Ord, Read, Show)

-- ===== 発音単位集合 P の導出（06 §1）=====
--
-- P = { σ(c,v) = cv | c ∈ C, v ∈ V }: 単純開音節を体系的に生成し、
-- 「人間が発声可能な有限集合」を命名なしに構成する。
-- 各音素の内部構造 (子音, 母音) は生成から既知である。

type Phone = String

-- 子音の並びは音節番号を決める。レジストリが伸びると Σ_base が右へ広がるので、
-- 追加は必ず末尾へ置く。途中へ挿すと既存の語の発音が全部ずれる。
--
-- 後半の五つは有声音で、前半と同じ調音位置の対になっている（k–g、s–z、t–d、
-- h–b、h–p）。生成規則 σ(c,v) = cv は変わらないので、§1 の「命名なしに構成する」
-- はそのまま保たれる。
consonants :: [String]
consonants =
  [ "k", "s", "t", "n", "h", "m", "y", "r", "w"
  , "g", "z", "d", "b", "p" ]

vowels :: [String]
vowels = ["a", "i", "u", "e", "o"]

syllabary :: [Phone]
syllabary = [c ++ v | c <- consonants, v <- vowels]

-- 予約番号: 0 = 層境界、1 = 無声ワイヤ、2 = 零標示音 z_e（06 §16）。
-- 原始概念文字は unitBase 以降。零標示は予約帯に置くので原子箱の像と衝突しない:
--   idx(z_e) < unitBase、かつ z_e ∉ E_speech(原子箱)   (06 §16.2)
idxBoundary, idxSilent, idxZeroMark, unitBase :: Int
idxBoundary = 0
idxSilent   = 1
idxZeroMark = 2
unitBase    = 3

-- 零標示音 z_e。本体が空のチェンバーの像になる可聴音節（無音にはしない）
zeroMarkPhone :: Phone
zeroMarkPhone = phoneOfIdx idxZeroMark

phoneOfIdx :: Int -> Phone
phoneOfIdx k = case drop k syllabary of
  (p : _) -> p
  []      -> ""

idxOfPhone :: Phone -> Maybe Int
idxOfPhone p = go 0 syllabary
  where
    go _ []           = Nothing
    go k (x : xs)
      | x == p    = Just k
      | otherwise = go (k + 1) xs

-- ===== 正準番号から名前へ（10 式 1.2、§4）=====
--
-- 音節表は 70 音節しかない。基準レジストリは 60 語で閉じており、そこまでが
-- 一音節の名前を持つ。残る七音節は採用語彙の字母 Σ_V であって、名前には使わない
-- （06 §17.4。ここを削ると採用列の符号空間が尽きる）。
-- 基準の外に足す生成元は拡張であり、10 §4 のとおり名前が伸びる。
--
--   name(k) = [σ_k]                                          k < nameCap
--   name(k) = ku · [σ_{3+q}, σ_{3+r}]                        k ≥ nameCap
--             k − nameCap = 60q + r
--
-- 頭の ku は零標示音であり、どの一音節名とも一致しない。だから名前の集合は
-- 接頭自由になり、PlainText.lexAt の最長一致が一意に決まる。
-- ka（層境界）と ki（無声ワイヤ）は層の機械が先に食うので、桁には出てこない。
baseRegistry, nameCap, nameRadix :: Int
baseRegistry = 60
nameCap      = unitBase + baseRegistry
nameRadix    = baseRegistry

-- ponytail: 三音節までで 65² = 4225 語を持つ。それでも足りなくなったら
-- 桁を一つ増やす（q の再帰展開）。今のレジストリは 70 語に届いていない
nameOfIdx :: Int -> [Phone]
nameOfIdx k
  | k < nameCap = [phoneOfIdx k]
  | q < nameRadix = [zeroMarkPhone, phoneOfIdx (unitBase + q), phoneOfIdx (unitBase + r)]
  | otherwise = []
  where (q, r) = divMod (k - nameCap) nameRadix

-- 名前を一つ読み、番号と残りの音節を返す。nameOfIdx の逆になる
idxOfName :: [Phone] -> Maybe (Int, [Phone])
idxOfName ps = case ps of
  (p : a : b : rest)
    | p == zeroMarkPhone
    , Just qa <- digit a
    , Just qb <- digit b -> Just (nameCap + qa * nameRadix + qb, rest)
  (p : rest) -> case idxOfPhone p of
    Just k | k < nameCap -> Just (k, rest)
    _                    -> Nothing
  [] -> Nothing
  where
    digit ph = case idxOfPhone ph of
      Just k | k >= unitBase && k < nameCap -> Just (k - unitBase)
      _                                     -> Nothing

-- ===== 基準字母と採用字母（06 §17.3、翻訳 06 §1〜§2）=====
--
-- E_speech が出す音節は四種類しかない。層境界 s、無声ワイヤ g、零標示 z_e、
-- そして原子箱ひとつにつき一音節。この四つが基準字母になる。
--
--   Σ_base = {σ₀, σ₁, σ₂} ∪ { σ_{unitBase+k} | a_k ∈ 𝒜 }        翻訳 06 (1.2)
--   Σ_V    = Σ ∖ Σ_base                                          翻訳 06 (2.1)
--
-- 採用語彙を Σ_V の上だけで取ると、定理 2.2 が「採用列はどの意味の基準列とも
-- 一致しない」を返す。𝒞 は無限集合（命題 8.1）なので、候補ごとの検査では
-- この条件が閉じない。字母で切ると型として閉じる。
--
-- レジストリが伸びると Σ_V は縮む。値を書かずにここで導出するのはそのため。

-- 一音節の名前に取られた区間が Σ_base になる。nameCap を超えた生成元は
-- 三音節の名前を持ち、その桁は既に Σ_base の中にあるので Σ_V は縮まない。
-- だから採用語彙の字母は 2 音節ぶん残り続ける（06 §17.4）
sigmaBase :: [Phone]
sigmaBase = take (min nameCap (unitBase + length primitiveTable)) syllabary

sigmaV :: [Phone]
sigmaV = drop (min nameCap (unitBase + length primitiveTable)) syllabary

data Chamber = Chamber
  { chMu  :: Mu         -- 記憶深度
  , chDep :: Int        -- 旧形式の有限欄。順序数の作図深度は chamberGrade で読む
  , chIn  :: [Port]     -- Γ⁻
  , chLay :: [Layer]    -- Λ₀;…;Λ_h
  , chOut :: [Port]     -- Γ⁺
  }
  | GradedChamber
  { chMu :: Mu
  , chDep :: Int
  , chIn :: [Port]
  , chLay :: [Layer]
  , chOut :: [Port]
  , chOrdinal :: [Int]
  , chAddresses :: [Int]
  } deriving (Eq, Ord, Read, Show)

-- The five-field constructor is the legacy finite representation. New source
-- grades are retained on the chamber itself, including through serialization.
withGrade :: [Int] -> [Int] -> Chamber -> Chamber
withGrade depth addresses c = GradedChamber (chMu c) (chDep c) (chIn c)
  (chLay c) (chOut c) (trimOrdinal depth) addresses

-- 作図深度は係数列 d = d0 + d1*omega + d2*omega^2 + ... で持つ（13 (2.4)）。
-- 上位の 0 は順序数として存在しないので、正準形では落とす。
trimOrdinal :: [Int] -> [Int]
trimOrdinal = reverse . dropZeroHead . reverse

dropZeroHead :: [Int] -> [Int]
dropZeroHead (0 : xs) = dropZeroHead xs
dropZeroHead xs       = xs

chamberGrade :: Chamber -> ([Int],[Int])
chamberGrade (GradedChamber _ _ _ _ _ depth addresses) = (depth,addresses)
chamberGrade c = (foldl ordinalPlus []
  [foldl ordinalMax [] [primitiveGrade (atomPrim a) | (_,a) <- xs]
   | Layer xs <- chLay c],
   concat [primitiveAddresses (atomPrim a) | Layer xs <- chLay c, (_,a) <- xs])

primitiveAddresses :: Prim -> [Int]
primitiveAddresses (POmega address body seed) =
  address : (snd (chamberGrade body) ++ snd (chamberGrade seed))
primitiveAddresses _ = []

primitiveGrade :: Prim -> [Int]
primitiveGrade p = case p of
  -- d(Omega_a[F]) = d(F)*omega。最高次 omega^k が omega^(k+1) へ上がる（13 (2.4)）
  POmega _ body _ -> case dropZeroHead (reverse (fst (chamberGrade body))) of
    [] -> []
    ds -> replicate (length ds) 0 ++ [1]
  PIdentity _ -> []
  PId -> []
  PCoordId -> []
  PFixPoint -> [0,1]
  PFixAt _ _ -> [0,1]
  PFixL -> [0,1]
  PFixD -> [0,1]
  _ -> [1]

ordinalPlus :: [Int] -> [Int] -> [Int]
ordinalPlus a b = case reverse (dropZero (reverse b)) of
  [] -> a
  bs -> let k = length bs - 1
            at xs i = case drop i xs of x:_ -> x; [] -> 0
        in [if i < k then at bs i else at a i + at bs i
           | i <- [0 .. max (length a) (length bs) - 1]]
  where dropZero (0:xs) = dropZero xs
        dropZero xs = xs

ordinalMax :: [Int] -> [Int] -> [Int]
ordinalMax a b = if reverse (pad a) >= reverse (pad b) then a else b
  where pad xs = take (max (length a) (length b)) (xs ++ repeat 0)

composeGrade :: ([Int] -> [Int] -> [Int]) -> Chamber -> Chamber -> Chamber -> Chamber
composeGrade operation a b result = case (a,b) of
  (Chamber {},Chamber {}) -> result
  _ -> let (da,aa) = chamberGrade a
           (db,ab) = chamberGrade b
       in withGrade (operation da db) (aa ++ ab) result

-- ===== 構造的な frontier 更新（命題5.1）=====

stepPorts :: [Port] -> Layer -> Maybe [Port]
stepPorts front (Layer xs) = go 0 [] xs
  where
    total = length front
    go cur acc [] = Just (acc ++ drop cur front)
    go cur acc ((pos, a) : rest)
      | pos < cur                          = Nothing
      | pos + length ins > total           = Nothing
      | take (length ins) (drop pos front) /= ins = Nothing
      | otherwise =
          go (pos + length ins) (acc ++ take (pos - cur) (drop cur front) ++ outs) rest
      where
        ins = fst (atomPorts a)
        outs = snd (atomPorts a)

runPorts :: [Port] -> [Layer] -> Maybe [Port]
runPorts g []     = Just g
runPorts g (l : ls) = case stepPorts g l of
  Just g' -> runPorts g' ls
  Nothing -> Nothing

wellFormed :: Chamber -> Bool
wellFormed c = runPorts (chIn c) (chLay c) == Just (chOut c)
  && all (allowed . atomPrim . snd) (concatMap layerAtoms (chLay c))
  && case c of
       GradedChamber {} -> all (>= 0) (chOrdinal c)
         && all (\a -> a >= 0 && a <= 8) (chAddresses c)
       _ -> True
  where
    allowed (PCopy t) = notElem t [PtUnit,PJudge] && (t /= PNoun || chMu c /= MInf)
    allowed PDupN = chMu c /= MInf
    allowed (PDiscard t) = notElem t [PtUnit,PJudge]
    allowed (PSupFamily n) = n >= 0
    allowed (POmega a body seed) = omegaWellFormed a body seed
    allowed _ = True

-- ===== 実行: 箱が実際に積み上げた演算を走らせる =====

omegaWellFormed :: Int -> Chamber -> Chamber -> Bool
omegaWellFormed address body seed =
  address >= 0 && address <= 8 && wellFormed body && wellFormed seed
  && chMu body == chMu seed
  && length (chIn body) >= length state
  && drop (length external) (chIn body) == state
  && chOut seed == state
  && (null (chIn seed) || chIn seed == external)
  where
    state = chOut body
    external = take (length (chIn body) - length state) (chIn body)

-- Closed forms justified by closure.const: a constant orbit, an already fixed
-- initial state, or repeated bisection at a common base. The body and initial
-- construction remain in POmega, rather than replacing the syntax by its value.
evalOmega :: Int -> Chamber -> Chamber -> [Value] -> Maybe [Value]
evalOmega address body seed external
  | not (omegaWellFormed address body seed) = Nothing
  | otherwise = case evalChamber seed (if null (chIn seed) then [] else external) of
      Nothing -> Nothing
      Just initial -> case evalChamber body (external ++ initial) of
        Just next | sameBoundary next initial || omegaStateIndependent body -> Just next
        Just _ -> case omegaBisectionBase body of
          Just base -> case evalChamber body (external ++ [base]) of
            Just [fixed] | sameBoundary [fixed] [base] -> Just [base]
            _ -> Nothing
          Nothing -> Nothing
        _ -> Nothing
-- The dependency calculation follows the typed frontier, including untouched
-- wires. It proves independence from the feedback state without sampling it.
omegaStateIndependent :: Chamber -> Bool
omegaStateIndependent body = case runDependencies
      (replicate externalCount False ++ replicate (length (chOut body)) True) (chLay body) of
        Just deps -> not (or deps)
        Nothing -> False
  where
    externalCount = length (chIn body) - length (chOut body)
    runDependencies front [] = Just front
    runDependencies front (Layer es:rest) = case layerDependencies front 0 es of
      Just out -> runDependencies out rest
      Nothing -> Nothing
    layerDependencies front cursor [] = Just (drop cursor front)
    layerDependencies front cursor ((q,a):rest)
      | q < cursor || q + length ins > length front = Nothing
      | otherwise = case layerDependencies front (q + length ins) rest of
          Just tailDeps -> Just (take (q-cursor) (drop cursor front)
            ++ replicate (length outs) (or (take (length ins) (drop q front))) ++ tailDeps)
          Nothing -> Nothing
      where (ins,outs) = atomPorts a

omegaBisectionBase :: Chamber -> Maybe Value
omegaBisectionBase body
  | chIn body /= chOut body || length (chOut body) /= 1 = Nothing
  | otherwise = baseOf operations
  where
    operations = [atomPrim a | Layer es <- chLay body, (_,a) <- es,
                   atomPrim a `notElem` [PIdentity PtDyad,PIdentity PtCoord,PCoordId]]
    baseOf ops = case ops of
      PBeta:rest | all (== PBeta) rest -> Just (VDyad (1,0))
      PBetaAt n d:rest | all (== PBetaAt n d) rest -> Just (VDyad (n,d))
      PBetaPoint k:rest | all (== PBetaPoint k) rest -> Just (VCoord (canonicalPoint k))
      PReflectPoint k:rest -> case reverse rest of
        PReflectPoint j:middle | reflCompose k j == 0 ->
          case baseOf (reverse middle) of
            Just (VCoord point) -> Just (VCoord (reflAct j point))
            _ -> Nothing
        _ -> Nothing
      _ -> Nothing

-- Equality of boundary coordinates does not erase construction depth from the
-- stored values. Different dyadic denominators may denote the same point.
sameBoundary :: [Value] -> [Value] -> Bool
sameBoundary xs ys = length xs == length ys && and (zipWith same xs ys)
  where
    same (VDyad a) (VDyad b) = equalDyad a b
    same (VCoord (r,w,d)) (VCoord (s,v,e)) =
      equalDyad (r,d) (s,e) && equalDyad (w,d) (v,e)
    same a b = a == b
    -- 分母をそろえて比べる。x/2^d = y/2^e <=> x*2^(h-d) = y*2^(h-e), h = max d e
    equalDyad :: Integral a => (a, Int) -> (a, Int) -> Bool
    equalDyad (n,d) (m,e)
      | d < 0 || e < 0 = False
      | otherwise = let h = max d e
                    in scaleUp (toInteger n) (h-d) == scaleUp (toInteger m) (h-e)
    -- 2^k 倍。冪演算子は語彙表に無いので倍加で作る
    scaleUp :: Integer -> Int -> Integer
    scaleUp v k = foldl addSelf v (replicate k ())
    addSelf :: Integer -> () -> Integer
    addSelf a _ = a + a

-- 層の中の箱は互いに依存しない（02 §1 のテンソル積）。位置は昇順で重ならないので、
-- どの箱も他の箱の出力を読まない。だから
--
--   1. 箱の適用を全部作る
--   2. frontier へ並べ直す
--
-- の二段に分ける。左から順に畳んでいたのは CPU の都合であって、層の意味の側の
-- 順序ではない。並べ直しだけは位置の昇順に見る。
stepLayer :: [Value] -> Layer -> Maybe [Value]
stepLayer front (Layer xs) = case applyAll 0 xs of
    Nothing   -> Nothing
    Just outs -> Just (weave 0 [] (zip xs outs))
  where
    total = length front
    applyAll _   []                 = Just []
    applyAll cur ((pos, a) : rest)
      | pos < cur                = Nothing
      | pos + length ins > total = Nothing
      | map kindOf seg /= ins    = Nothing
      | otherwise = case evalPrim (atomPrim a) seg of
          Just o  -> case applyAll (pos + length ins) rest of
            Just os -> Just (o : os)
            Nothing -> Nothing
          Nothing -> Nothing
      where
        ins = fst (atomPorts a)
        seg = take (length ins) (drop pos front)
    weave cur acc [] = acc ++ drop cur front
    weave cur acc (((pos, a), o) : rest) =
      weave (pos + length (fst (atomPorts a)))
            (acc ++ take (pos - cur) (drop cur front) ++ o) rest

-- ===== 実行: 語ぜんたいを層の順に走らせる =====
--
-- 層は深さの順に合成される（02 §6）。境界の型が合わない語には値を与えない。

evalChamber :: Chamber -> [Value] -> Maybe [Value]
evalChamber c vs
  | not (wellFormed c) || map kindOf vs /= chIn c = Nothing
  | otherwise = case runLayers vs (chLay c) of
      Just outs | map kindOf outs == chOut c -> Just outs
      _                                      -> Nothing

runLayers :: [Value] -> [Layer] -> Maybe [Value]
runLayers g []       = Just g
runLayers g (l : ls) = case stepLayer g l of
  Just g' -> runLayers g' ls
  Nothing -> Nothing

-- ===== CNF と直列化 =====

-- CNF(C): 位置の正準整列をしてから整形式検査をする。
-- 整列すれば通る構成も、並びのままでは拒否される——それが正準化である
cnf :: Chamber -> Maybe Chamber
cnf c
  | wellFormed sorted = Just sorted
  | otherwise         = Nothing
  where sorted = c { chLay = [Layer (sort (layerAtoms l)) | l <- chLay c] }

-- ===== 直列化（専用フォーマット v1）=====
--
-- 書式: mu;dep;inPorts;layers;outPorts
--   ports  = p(+p)*        （空は空文字列）
--   layers = layer(/layer)*（空は空文字列）
--   layer  = item(,item)*、item = pos~tag
-- タグは ~ , : ; | + を含まない原始文字名に限る。
-- parse ∘ ser = id が成立しなければならない。

ser :: Chamber -> String
ser c
  | GradedChamber {} <- c = '@' : show c
  | any (\(_, a) -> notElem (atomPrim a) (map (atomPrim . snd) primitiveTable))
        (concatMap layerAtoms (chLay c)) = '@' : show c
  | otherwise = joinWith ";"
  [ muS (chMu c), show (chDep c)
  , portsS (chIn c), layersS (chLay c), portsS (chOut c) ]

muS :: Mu -> String
muS m = case m of
  M0 -> "0"; M1 -> "1"; M2 -> "2"; MInf -> "i"

muP :: String -> Maybe Mu
muP s = case s of
  "0" -> Just M0; "1" -> Just M1; "2" -> Just M2; "i" -> Just MInf
  _   -> Nothing

portS :: Port -> String
portS p = case p of
  PtUnit -> "u"; PtCoord -> "c"; PtDyad -> "d"; PtBit -> "b"
  PNoun -> "n"; PJudge -> "g"; PtRefl -> "r"
  PtRational -> "q"; PtChain -> "chain"; PtRegion -> "region"
  PtMono -> "mono"
  PtReference k -> "ref:" ++ show k

portP :: String -> Maybe Port
portP s = case s of
  "u" -> Just PtUnit; "c" -> Just PtCoord; "d" -> Just PtDyad
  "b" -> Just PtBit; "n" -> Just PNoun; "g" -> Just PJudge
  "r" -> Just PtRefl
  "q" -> Just PtRational
  "chain" -> Just PtChain
  "region" -> Just PtRegion
  "mono" -> Just PtMono
  _ -> case s of
    ('r':'e':'f':':':rest) -> case reads rest of
      [(k,"")] | k >= 0 -> Just (PtReference k)
      _ -> Nothing
    _ -> Nothing

portsS :: [Port] -> String
portsS ps = joinWith "+" (map portS ps)

portsP :: String -> [Port]
portsP "" = []
portsP s  = map readPort (splitOnC '+' s)
  where readPort x = maybe PtUnit id (portP x)

joinWith :: String -> [String] -> String
joinWith _   []       = ""
joinWith _   [x]      = x
joinWith sep (x : xs) = x ++ sep ++ joinWith sep xs

splitOnC :: Char -> String -> [String]
splitOnC ch s = go s []
  where
    go [] acc       = [reverse acc]
    go (c : rest) acc
      | c == ch   = reverse acc : go rest []
      | otherwise = go rest (c : acc)

intP :: String -> Int
intP s = case reads s of
  [(v, "")] -> v
  _         -> 0

layersS :: [Layer] -> String
layersS ls = joinWith "/" (map layerS ls)

layerS :: Layer -> String
layerS (Layer xs) =
  joinWith "," [show pos ++ "~" ++ atomTag a ++ "~" ++ show (atomPrim a)
               | (pos, a) <- xs]

layersP :: String -> Maybe [Layer]
layersP "" = Just []
layersP s  = go (splitOnC '/' s) []
  where
    go [] acc = Just (reverse acc)
    go (x : rest) acc = case layerP x of
      Just l  -> go rest (l : acc)
      Nothing -> Nothing

layerP :: String -> Maybe Layer
layerP s =
  let items = splitOnC ',' s
      pairs = map itemP items
  in if elem Nothing pairs
       then Nothing
       else Just (Layer [x | Just x <- pairs])

itemP :: String -> Maybe (Int, Atom)
itemP it = case splitOnC '~' it of
  [posS, tag, primS] -> case reads posS of
    [(pos, "")] -> case reads primS of
      [(pr, "")] -> Just (pos, Atom tag pr)
      _          -> Nothing
    _           -> Nothing

parse :: String -> Maybe Chamber
parse ('@' : s) = case reads s of
  [(c, "")] | wellFormed c -> Just c
  _ -> Nothing
parse s = case splitOnC ';' s of
  [sm, sd, gin, lay, gout] -> case muP sm of
    Nothing -> Nothing
    Just mu -> case layersP lay of
      Nothing -> Nothing
      Just ls -> let c = Chamber mu (intP sd) (portsP gin) ls (portsP gout)
                 in if wellFormed c then Just c else Nothing
  _ -> Nothing

-- ===== 合成 =====

seqC :: Chamber -> Chamber -> Maybe Chamber
seqC a b
  | chMu a == chMu b && chOut a == chIn b =
      Just (composeGrade ordinalPlus a b
        (Chamber (chMu a) (max (chDep a) (chDep b))
                    (chIn a) (chLay a ++ chLay b) (chOut b)))
  | otherwise = Nothing

portFrontierSeqM :: [Port] -> [Layer] -> Maybe ([[Port]], [Port])
portFrontierSeqM g ls = go g ls []
  where
    go f [] acc    = Just (reverse acc, f)
    go f (l : rest) acc = case stepPorts f l of
      Just f' -> go f' rest (f : acc)
      Nothing -> Nothing

-- テンソル積 C₁ ⊗ C₂。同じ μ を要求する。
-- 層数が異なる場合は短い側を恒等層で h = max まで補ってから接合する
-- （恒等層は stepPorts 不変なので意味を変えない）
tensorC :: Chamber -> Chamber -> Maybe Chamber
tensorC a b
  | chMu a /= chMu b = Nothing
  | otherwise =
      let na = length (chLay a)
          nb = length (chLay b)
          h  = max na nb
          pa = chLay a ++ replicate (h - na) (Layer [])
          pb = chLay b ++ replicate (h - nb) (Layer [])
      in case (portFrontierSeqM (chIn a) pa, portFrontierSeqM (chIn b) pb) of
          (Just (insA, outA), Just (insB, outB)) ->
            let layers =
                  zipWith3 (\ia (Layer xa) (Layer xb) ->
                              Layer (xa ++ [(p + length ia, x) | (p, x) <- xb]))
                           insA pa pb
            in Just (composeGrade ordinalMax a b
                 (Chamber (chMu a) (max (chDep a) (chDep b))
                             (chIn a ++ chIn b) layers (outA ++ outB)))
          _ -> Nothing

-- ===== 名詞層の土台（07 §8.2、§8.4）=====
--
-- 参照 #k: 既定義のチェンバーを一つの原子箱として置く。
-- 名前でなく、正準内容の順で付けた番号で指す。再帰は Ω の内部で閉じるので
-- 参照関係は非巡回になる
refC :: [Chamber] -> Int -> Maybe Chamber
refC reg k
  | k < 0 = Nothing
  | otherwise = case drop k keys of
      key:_ -> case [c | c <- reg, referenceKey c == key] of
        c:_ -> cnf c
        [] -> Nothing
      [] -> Nothing
  where
    keys = foldr (\s xs -> if elem s xs then xs else s:xs) []
             (sort (map referenceKey reg))
    referenceKey c = ser (c {chLay =
      [Layer [(q,a {atomTag=""}) | (q,a) <- sort es] | Layer es <- chLay c]})

-- 複製構造を選ぶ型クラスの判定。構成語を保持する型（μ=∞ のノード）には
-- 複製構造を与えない。無断複製は ij の履歴を壊す（07 §8.4、構成語 §3.5）
copyableMu :: Mu -> Bool
copyableMu MInf = False
copyableMu _    = True

-- Δ_A: 一つの名詞ノードを二つの関係で使うための明示複製
dupNC :: Chamber -> Maybe Chamber
dupNC c
  | not (copyableMu (chMu c)) = Nothing
  | otherwise =
      cnf (Chamber (chMu c) (chDep c) [PNoun]
            [Layer [(0, mkAtom "dup" PDupN)]] [PNoun, PNoun])

-- !_A: 使わないノードの明示廃棄。境界が縮む
dropNC :: Chamber -> Maybe Chamber
dropNC c =
  cnf (Chamber (chMu c) (chDep c) [PNoun]
        [Layer [(0, mkAtom "drop" PDropN)]] [])
-- ===== ドキュメント主張の実行可能証明 =====

iWord :: Chamber
iWord = Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]

iiWord :: Chamber
iiWord = iWord `chain` iWord

jWord :: Chamber
jWord = Chamber MInf 0 [PtUnit] [Layer [(0, primJ)]] [PtUnit]

betaWord :: Chamber
betaWord = Chamber MInf 0 [PtDyad] [Layer [(0, primBeta)]] [PtDyad]

foldWord :: Chamber
foldWord = Chamber MInf 0 [PtDyad] [Layer [(0, primFold)]] [PtBit]

addWord :: Chamber
addWord = Chamber MInf 0 [PtCoord, PtCoord] [Layer [(0, primAdd)]] [PtCoord]

chain :: Chamber -> Chamber -> Chamber
chain a b = case seqC a b of
  Just c' -> c'
  Nothing -> a

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("原始文字は既存実装を参照する — i 語の実行は applyI そのもの",
      let p  = mkReal oVertexSample 1
          r0 = evalChamber iWord [VPt p]
      in r0 == Just [VPt (applyI p)])
  , ("語の実行: ii 語は negateUP に一致する（i² = −1 が言語の意味論に出る）",
      let p  = mkReal oVertexSample 1
          r0 = evalChamber iiWord [VPt p]
      in r0 == Just [VPt (negateUP p)])
  , ("語の実行: jj 語は恒等（j² = +1）",
      let p = mkReal oVertexSample 1
      in evalChamber (jWord `chain` jWord) [VPt p] == Just [VPt p])
  , ("β 語は梯子の一歩を実行する（CCS 定理1.2 の写像）",
      evalChamber betaWord [VDyad (ladderAt 3)] == Just [VDyad (ladderAt 4)])
  , ("fold 語は φ∂ を呼び、二値フラグへ畳む",
      evalChamber foldWord [VDyad (1, 1)] == Just [VBit 1])
  , ("二進有理層: PAddD は DagArith.addS と同じ値を出す（分子と深度が一致する）",
      case evalPrim PAddD [VDyad (3, 1), VDyad (1, 2)] of
        Just [VDyad (n, d)] -> addS (3, 0, 1) (1, 0, 2) == (fromInteger n, 0, d)
        _                   -> False)
  , ("二進有理層: PNegD は DagArith.negateS と同じ",
      case evalPrim PNegD [VDyad (5, 3)] of
        Just [VDyad (n, d)] -> negateS (5, 0, 3) == (fromInteger n, 0, d)
        _                   -> False)
  , ("二進有理層: 深度そろえは DagArith.alignDepth と同じ規則",
      let (x, y, d) = dyAlign (3, 1) (1, 2)
          (p, q)    = alignDepth (3, 0, 1) (1, 0, 2)
      in (fromInteger x, 0, d) == p && (fromInteger y, 0, d) == q)
  , ("二進有理層: PLeqD は深度をそろえてから分子を比べる（3/2 < 7/4）",
      evalPrim PLeqD [VDyad (3, 1), VDyad (7, 2)] == Just [VBit 1]
      && evalPrim PLeqD [VDyad (7, 2), VDyad (3, 1)] == Just [VBit 0])
  , ("add 語は四則演算層の平行四辺形則そのものである",
      let x = (2, 4, 3)
          y = (1, 6, 3)
      in evalChamber addWord [VCoord x, VCoord y] == Just [VCoord (addS x y)])
  , ("命題5.1: frontier 幅はポート列から一意に更新される（add で二本が一本へ）",
      runPorts [PtCoord, PtCoord] [Layer [(0, primAdd)]] == Just [PtCoord]
      && runPorts (chOut addWord) [] == chOut' addWord)
  , ("整形式性: ポート型が一致しない箱は拒否される",
      not (wellFormed (Chamber MInf 0 [PtDyad] [Layer [(0, primI)]] [PtUnit])))
  , ("CNF: 位置を正準整列してから検査する。並び替えで通る構成は同じ正準形へ落ちる",
      let unsorted = Chamber MInf 0 [PtUnit, PtUnit]
                       [Layer [(2, primI), (0, primI)]]
                       [PtUnit, PtUnit]
          sorted   = Chamber MInf 0 [PtUnit, PtUnit]
                       [Layer [(0, primI), (2, primI)]]
                       [PtUnit, PtUnit]
      in cnf unsorted == cnf sorted)
  , ("CNF: 非整形式には値を与えない",
      cnf (Chamber MInf 0 [PtDyad] [Layer [(0, primI)]] [PtUnit]) == Nothing)
  , ("parse(ser(C)) ≅ C: 直列化の往復",
      all (\c -> parse (ser c) == Just c)
        [iWord, iiWord, jWord, betaWord, foldWord, addWord])
  , ("seqC: cod/dom 接合が一致するときだけ合成できる",
      seqC betaWord foldWord /= Nothing
      && seqC iWord betaWord == Nothing)
  , ("tensorC: 並列合成は境界を連結し、後続の位置を前側の幅だけずらす",
      let a = Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]
          b = Chamber MInf 0 [PtUnit] [Layer [(0, primNeg)]] [PtUnit]
      in tensorC a b == Just (Chamber MInf 0 [PtUnit, PtUnit]
                                [Layer [(0, primI), (1, primNeg)]]
                                [PtUnit, PtUnit]))
  , ("(07 §7): 名詞ノードはワイヤ上の値として流れる。関係述語は主語へ適用する",
      let v = Chamber MInf 0 [PNoun, PNoun]
                [Layer [(0, mkAtom "v" (PRel (relStr [J])))]]
                [PNoun, PNoun]
          x = QCoeff 1 0 [J] 1
          p = [QCoeff 0 0 [] 1, QCoeff 0 0 [] 1, QCoeff 0 0 [] 1]
      in evalChamber v [VNoun unitQ' p, VNoun x p]
           == Just [VNoun (applyWord [J] unitQ') p, VNoun x p])
  , ("(07 §7): 関係は有向 — i の後に j と j の後に i は別の結果になる",
      applyWord [I, J] nounO /= applyWord [J, I] nounO)
  , ("(07 §8.2): 参照 #k は ser 昇順での位置で既定義チェンバーを指す",
      let reg = [betaWord, iWord]
      in refC reg 0 == cnf betaWord && refC reg 1 == cnf iWord
         && refC reg 2 == Nothing)
  , ("(07 §8.4): Δ_A — μ=∞ のノードは複製できない（無断複製の禁止）",
      dupNC iWord == Nothing
      && dupNC nounWireM1 /= Nothing)
  , ("(07 §8.4): Δ_A の実行 — ノードが二本に増える",
      case dupNC nounWireM1 of
        Just d  -> evalChamber d [VNoun nounO []]
                      == Just [VNoun nounO [], VNoun nounO []]
        Nothing -> False)
  , ("(07 §8.4): !_A — 廃棄で境界が縮む",
      case dropNC nounWireM1 of
        Just d  -> wellFormed d
                   && evalChamber d [VNoun nounO []] == Just []
        Nothing -> False)
  , ("(07 §6.2): 整合対箱 PAgr — 一致は 𝟏、不一致は下がる",
      let agr = Chamber MInf 0 [PtDyad, PtDyad] [Layer [(0, primAgr)]] [PJudge]
          r1 = evalChamber agr [VDyad (1, 2), VDyad (1, 2)]
          r0 = evalChamber agr [VDyad (0, 0), VDyad (1, 2)]
      in case (r1, r0) of
           (Just [VJudge a _ _], Just [VJudge b _ _]) ->
             qratEqC a (QRat 1 1) && qratEqC b (QRat 0 16)
           _ -> False)
  , ("(07 §10.3): PPhiJ — 所属 φ∂∘π で一段に二値へ落ちる",
      let jch = Chamber MInf 0 [PJudge] [Layer [(0, primPhiJ)]] [PtBit]
      in evalChamber jch [VJudge (QRat 1 1) [] 1] == Just [VBit 1]
         && evalChamber jch [VJudge (QRat 0 16) [] 1] == Just [VBit 0])
  , ("(07 §8.3): Ω_a — 不動点へ一段で閉じる（jj = e の自適用）",
      evalChamber omJJ [VNoun nounO []] == Just [VNoun nounO []])
  , ("(07 §8.3): Ω_a — 周期軌道は入口の状態へ閉じる（ii = σ の周期）",
      evalChamber omII [VNoun nounO []] == Just [VNoun nounO []])
  , ("(07 §8.3): Ω_a — 境界まで閉じない軌道には値を与えない（ij は無限に伸びる）",
      evalChamber omIJ [VNoun nounO []] == Nothing)

  -- ===== 層はテンソル積である（02 §1）=====

  , ("02 §1: 層は互いに依存しない箱のテンソル積。箱ごとの適用を並べたものに一致する",
      let l  = Layer [(0, primBeta), (1, primNegD)]
          vs = [VDyad (3, 2), VDyad (5, 3)]
          a  = evalPrim (atomPrim primBeta) [VDyad (3, 2)]
          b  = evalPrim (atomPrim primNegD) [VDyad (5, 3)]
      in stepLayer vs l == (case (a, b) of
                              (Just x, Just y) -> Just (x ++ y)
                              _                -> Nothing))

  , ("02 §5: 覆われない位置は恒等ワイヤで通る。箱の幅は型から復元される",
      stepLayer [VDyad (3, 2), VDyad (5, 3)] (Layer [(0, primBeta)])
        == Just [VDyad (betaStep (3, 2)), VDyad (5, 3)]
      && stepLayer [VDyad (3, 2), VDyad (5, 3)] (Layer [(1, primNegD)])
        == Just [VDyad (3, 2), VDyad (negate 5, 3)])

  , ("02 §1: 箱の位置が重なる層は受けない（テンソル積にならない）",
      stepLayer [VDyad (1, 0), VDyad (1, 0)]
                (Layer [(0, primAddD), (1, primNegD)]) == Nothing)

  , ("層の実行順序は結果を変えない。三箱の層でも同じ frontier が出る",
      let vs = [VDyad (7, 3), VDyad (5, 3), VDyad (1, 1)]
          l  = Layer [(0, primBeta), (1, primNegD), (2, primFold)]
      in stepLayer vs l
           == Just [ VDyad (betaStep (7, 3)), VDyad (negate 5, 3)
                   , VBit (phiPartial (1, 1)) ])

  -- ===== 圏論層（圏論 第III部）が語として走ること =====

  , ("定理3.3: ⋁ が語として走る。大きさは max を取る",
      evalChamber supWord [VJudge (QRat 1 4) [] 1, VJudge (QRat 1 2) [] 1]
        == Just [VJudge (QRat 1 2) [] 1])

  , ("定理3.3: ⋁ は語が割れると型を落とす（加算は経路を忘れる）",
      evalChamber supWord [VJudge (QRat 1 2) [I] 1, VJudge (QRat 1 2) [J] 1]
        == Just [VJudge (QRat 1 2) [] 1])

  , ("定理3.3: 随伴律 a ⋆ b ≤ c ⟺ b ≤ a ↘ c が語の合成で確かめられる",
      let ms = [QRat 0 1, QRat 1 4, QRat 1 2, QRat 2 3, QRat 1 1]
          leq x y = evalChamber leqWord [VJudge x [] 1, VJudge y [] 1] == Just [VBit 1]
          resr a c = case evalChamber resrWord [VJudge a [] 1, VJudge c [] 1] of
            Just [VJudge m _ _] -> m
            _                   -> QRat 0 1
      in and [ leq (qratMul a b) c == leq b (resr a c)
             | a <- ms, b <- ms, c <- ms ])

  , ("定理3.3: ↘ と ↙ は別の箱である。語の輸送が左右で分かれる",
      evalChamber resrWord [VJudge qOne [I] 1, VJudge qOne [J] 1]
        /= evalChamber reslWord [VJudge qOne [J] 1, VJudge qOne [I] 1])

  , ("定理3.4: ホムは有向である。向きを変えると到達度が変わる",
      let x = VNoun (QCoeff 1 2 [] 1) []
          y = VNoun (QCoeff 1 0 [] 1) []
      in evalChamber homWord [x, y] /= evalChamber homWord [y, x])

  , ("定理3.4 単位律: 1 ≤ 𝔾(x, x)",
      let x = VNoun (QCoeff 1 2 [] 1) []
      in evalChamber homWord [x, x] == Just [VJudge qOne [] 1])

  , ("定義3.4: π が語として走る。大きさを残して型を落とす",
      evalChamber pijWord [VJudge (QRat 2 3) [I, J] (negate 1)]
        == Just [VJudge (QRat 2 3) [] 1])

  , ("定義3.4: 所属 φ∂ は Θ∘π である。π を挟んでも結果が変わらない",
      let v = VJudge (QRat 2 3) [I] (negate 1)
          direct = evalChamber phijWord [v]
          viaPi  = case evalChamber pijWord [v] of
            Just [v'] -> evalChamber phijWord [v']
            _         -> Nothing
      in direct == viaPi && direct == Just [VBit 1])

  , ("圏論層の箱は整形式検査を通り、発音単位を一つずつ持つ",
      all wellFormed [supWord, resrWord, reslWord, leqWord, homWord, pijWord]
      && all (\t -> elem t (map fst primitiveTable))
             ["sup", "resr", "resl", "leqj", "hom", "pij"])

  , ("圏論層の箱は直列化を往復できる（ser ∘ parse = id）",
      all (\c -> parse (ser c) == Just c)
          [supWord, resrWord, reslWord, leqWord, homWord, pijWord])

  -- ===== 座標折返しと構成履歴（構成語 §7、圏論 定理3.1）=====

  , ("(§7.3): 四つの反転は位数 2、四分の一回転の二乗が半回転になる",
      all (\k -> reflCompose k k == 0) [1, 2, 3, 4]
      && reflCompose 5 5 == 7 && reflCompose 6 6 == 7
      && reflCompose 5 6 == 0 && reflCompose 6 5 == 0
      && reflCompose 7 7 == 0
      && reflCompose 3 4 == 7 && reflCompose 4 3 == 7)

  , ("(§7.4): 正準点への作用表が行列の作用と一致する",
      and [ reflAct k (canonPt p) == canonPt q
          | (p, row) <- zip [0 ..] actTable, (k, q) <- zip [0 ..] row ])

  , ("(§7.1): 八つの折返しは相異なる",
      length [ () | a <- [0 .. 7], b <- [0 .. 7], reflMatrix a == reflMatrix b ] == 8)

  , ("(定理3.1): ij と ji は別の点へ届く — ij = (+1,+1)、ji = (+1,-1)",
      let o  = UnitPoint [] 1 1
          ij = applyU J (applyU I o)
          ji = applyU I (applyU J o)
      in endpointOf ij == Just (1, 1, 0) && endpointOf ji == Just (1, negate 1, 0)
         && endpointOf ij /= endpointOf ji)

  , ("(定理4.2): 座標写像は忠実でない — -(b i) と b j の座標が一致する",
      endpointOf (negateUP (applyU I (UnitPoint [] 1 1)))
        == endpointOf (applyU J (UnitPoint [] 1 1)))

  , ("(§6.3): rho^- は i i の簡約先であり、二度当てると恒等になる",
      let o = UnitPoint [] 1 1
      in evalPrim PRhoM [VPt o] /= Just [VPt o]
         && andThen (evalPrim PRhoM [VPt o]) (evalPrim PRhoM) == Just [VPt o])

  , ("(16 §5.1): beta の逆が beta を戻す — beta^{-1}(beta(x)) = x",
      all (\x -> andThen (evalPrim PBeta [VDyad x]) (evalPrim PBetaInv) == Just [VDyad x])
          [(0, 0), (1, 0), (3, 2), (negate 1, 1)]
      && evalPrim PBetaInv [VDyad (1, 0)] == Nothing)

  , ("(16 式 5.7): fix は集積点 a = 1 を返す。初期値にも深度にも依らない",
      let vals = [ evalPrim PFixL [VDyad (n, d)]
                 | n <- [0, 1, 7, negate 3], d <- [0, 2] ]
      in all (== Just [VDyad (1, 0)]) vals)

  , ("(定義3.4): Theta は大きさだけを読む二値化になる",
      evalPrim PTheta [VJudge (QRat 1 2) [] 1] == Just [VBit 1]
      && evalPrim PTheta [VJudge (QRat 0 1) [] 1] == Just [VBit 0])

  , ("圏論層の追加箱は整形式検査を通り、発音単位を一つずつ持つ",
      all wellFormed catWords
      && all (\t -> elem t (map fst primitiveTable))
             ["trc", "rhom", "rhop", "epnt", "rid", "refr", "refd"
             , "rcmp", "act", "binv", "fixl", "theta"])

  , ("圏論層の追加箱は直列化を往復できる（ser ∘ parse = id）",
      all (\c -> parse (ser c) == Just c) catWords)

  ]
  where
    -- 箱を二つ続けて当てる。Maybe の bind は語彙に無いので、ここで書く
    andThen m f = case m of
      Just v  -> f v
      Nothing -> Nothing
    -- 構成語 §7.4 の表。行が入力の正準点、列が折返し。値は正準点の番号
    canonPt :: Int -> SCoord
    canonPt p = case p of
      0 -> (0, 0, 0)
      1 -> (1, 0, 0)
      2 -> (negate 1, 0, 0)
      3 -> (0, 1, 0)
      4 -> (0, negate 1, 0)
      5 -> (1, 1, 0)
      6 -> (negate 1, 1, 0)
      7 -> (1, negate 1, 0)
      _ -> (negate 1, negate 1, 0)
    actTable :: [[Int]]
    actTable =
      [ [0, 0, 0, 0, 0, 0, 0, 0]
      , [1, 1, 2, 3, 4, 3, 4, 2]
      , [2, 2, 1, 4, 3, 4, 3, 1]
      , [3, 4, 3, 1, 2, 2, 1, 4]
      , [4, 3, 4, 2, 1, 1, 2, 3]
      , [5, 7, 6, 5, 8, 6, 7, 8]
      , [6, 8, 5, 7, 6, 8, 5, 7]
      , [7, 5, 8, 6, 7, 5, 8, 6]
      , [8, 6, 7, 8, 5, 7, 6, 5]
      ]
    catWords =
      [ oneBox primTrace [] [PtUnit]
      , oneBox primRhoM  [PtUnit] [PtUnit]
      , oneBox primRhoP  [PtUnit] [PtUnit]
      , oneBox primEndp  [PtUnit] [PtCoord]
      , oneBox primReflE [] [PtRefl]
      , oneBox primReflR [] [PtRefl]
      , oneBox primReflD [] [PtRefl]
      , oneBox primReflC [PtRefl, PtRefl] [PtRefl]
      , oneBox primAct   [PtRefl, PtCoord] [PtCoord]
      , oneBox primBetaInv [PtDyad] [PtDyad]
      , oneBox primFixL  [PtDyad] [PtDyad]
      , oneBox primTheta [PJudge] [PtBit]
      ]
    qOne = QRat 1 1
    oneBox p ins outs = Chamber MInf 0 ins [Layer [(0, p)]] outs
    supWord  = oneBox primSupJ  [PJudge, PJudge] [PJudge]
    resrWord = oneBox primResRJ [PJudge, PJudge] [PJudge]
    reslWord = oneBox primResLJ [PJudge, PJudge] [PJudge]
    leqWord  = oneBox primLeqJ  [PJudge, PJudge] [PtBit]
    homWord  = oneBox primHomQ  [PNoun, PNoun]   [PJudge]
    pijWord  = oneBox primPiJ   [PJudge]         [PJudge]
    phijWord = oneBox primPhiJ  [PJudge]         [PtBit]
    nounO = QCoeff 1 0 [] 1
    unitQ' = nounO
    nounWireM1 = Chamber M1 0 [PNoun] [] [PNoun]
    omJJ = Chamber MInf 0 [PNoun] [Layer [(0, mkAtom "om" (POmW "jj"))]] [PNoun]
    omII = Chamber MInf 0 [PNoun] [Layer [(0, mkAtom "om" (POmW "ii"))]] [PNoun]
    omIJ = Chamber MInf 0 [PNoun] [Layer [(0, mkAtom "om" (POmW "ij"))]] [PNoun]
    qratEqC (QRat a b) (QRat c d) = a * d == c * b
    ladderAt n = (toInteger (shiftL (1 :: Int) n) - 1, n)
    oVertexSample = 32   -- 実軸 O。RealUnit の offset と同じ値
    chOut' c = Just (chOut c)
