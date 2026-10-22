{-# LANGUAGE NoImplicitPrelude #-}
module NounNet where

import CounterConstraints
import CounterUnits (Op (..))
import CommonChamber (Mu (..))
import GclsCategory

-- ===== 名詞ネットワーク＝𝒬 重み付きオートマトン（07_名詞と影響ネットワーク.md）=====
-- doc: noun.object noun.automaton noun.behavior nerode.eq noun.identity.part
--
-- 影響対象は一つに限る（§10.1）。ネットワークは共有の影響対象
--
--   𝐆 = (G, L, w)、  w : L × G → 𝒬
--
-- であり、メタ名詞（Metanoun モジュール）はその上の測定装置になる。
-- アルファベット Σ = {i, j}。遷移モノイドは構成語の意味的正規形 snf で
-- 割った {i,j}* に一致し、非可換である（ij ≠ ji、定理6.1、§3.4）。
--
-- ノードの同一性は Nerode 合同で与える:
--
--   x ≈μ y ⟺ 全継続語 u で beh_μ(x)(u) = beh_μ(y)(u)
--
-- 一歩の座標では足りない（例4.1: -i と j は空語で一致しても継続 i で分離）。

type Landmark = QCoeff   -- 目印もノードと同じ空間の点。同一性は snf 語で決まる
type Node     = QCoeff   -- 関係語で到達する離散状態（07 §10.6: Node = QCoeff）

-- 原始関係語とその適用（iUnitQ, jUnitQ, opToQ, applyWord）は
-- counter_plane 側の GclsCategory に置いた。全層で同じ実装を共有する

-- 既定の目印族。正準 2-単体 Q₁ = (O, i, ij) の三頂点（例2.1）
defaultLandmarks :: [Landmark]
defaultLandmarks = [unitQ, iUnitQ, star iUnitQ jUnitQ]

-- snf 代表元の列挙: 隣接する同字を含まない語だけを長さ kmax まで生成する。
-- 隣接同字は pushW の正規化で畳まれるため、代表元には現れない
snfWordsUpTo :: Int -> [[Op]]
snfWordsUpTo kmax = concatMap gen [0 .. kmax]
  where
    gen 0 = [[]]
    gen n = [ w ++ [o] | w <- gen (n - 1), o <- [I, J], ok w o ]
    ok w  o = case reverse w of
      (o' : _) -> o' /= o
      []       -> True

-- ===== 個体と影響プロファイル =====

-- 個体（§2、§10.5）。二つの入口がある。
--   RelNode  … 関係語で到達する離散状態。w は Kronecker 型（x = ℓ なら 𝟏、外は 0）
--   Observed … 観測射（05 の各モーダル文法）が供給したプロファイル。
--              座標系の値を外から割り当てない。タレス比として得る
data Individual
  = RelNode Node
  | Observed [(Landmark, QCoeff)]
  deriving (Eq, Show)

-- Kronecker 型の重み。離散オービット上の整合な影響値になる
kroneckerOf :: Landmark -> Node -> QCoeff
kroneckerOf l x = if l == x then unitQ else QCoeff 0 0 [] 1

-- 個体の影響プロファイル x̂ = (w(ℓ₀,x), …, w(ℓₙ,x))。
-- 目印の順序がプロファイルの成分順になる
profileOf :: [Landmark] -> Individual -> Maybe [QCoeff]
profileOf lm (RelNode x)   = Just [ kroneckerOf l x | l <- lm ]
profileOf lm (Observed ps) = go lm
  where
    look l = case [ q | (l', q) <- ps, l' == l ] of
      (q : _) -> Just q
      []      -> Nothing
    go [] = Just []
    go (l : rest) = case look l of
      Nothing -> Nothing
      Just q  -> case go rest of
        Just qs -> Just (q : qs)
        Nothing -> Nothing

-- 整合 ◁（圏論 定義1.3、6c）: Σ_ℓ w(ℓ,x) = 𝟏 かつ w ≥ 0。
-- Σ は加算、すなわち平行四辺形則。帰属 ∈ の代替であり連続量を伴う
compatible :: [QCoeff] -> Bool
compatible ws = qratEq total qratOne && all nonneg ws
  where
    total  = foldl qratAdd qratZero (map magOf ws)
    nonneg (QCoeff n _ _ _) = n >= 0

-- ===== 挙動写像と Nerode 合同 =====

-- 記憶深度 μ の読み F_μ（定義3.4）。
--   μ = ∞ は構成語つきのまま、1 は型忘却 π（大きさだけ残す）、
--   0 は二値化 Θ ∘ π。μ = 2 は ∞ と同じ全情報の読みとして扱う
gradeOf :: Mu -> QCoeff -> QCoeff
gradeOf m q = case m of
  MInf -> q
  M2   -> q
  M1   -> QCoeff n d [] 1
    where (n, d) = piForget q
  M0   -> QCoeff (thetaBin (piForget q)) 0 [] 1

-- 継続語 u を適用した後の個体のプロファイルを読む。
-- 目印を複数読むので、beh_μ(x)(u) はプロファイル F_μ f̂_{u}(x) になる（§3.4）
behProfile :: Mu -> [Landmark] -> Node -> [Op] -> [QCoeff]
behProfile mu lm x u = [ gradeOf mu (kroneckerOf l (applyWord u x)) | l <- lm ]

-- Nerode 合同（§3.4）: 全継続語での挙動一致。
-- 継続語は長さ kmax までの snf 代表元に限る。遷移モノイド
-- ⟨i,j | i²=σ, j²=e⟩ は無限なので全継続の直接列挙は停止しない。
-- 分離（≈でない）は有限の証拠語で示せるので否定側は確定的。
-- 肯定側の完全判定が必要になったら、状態の周期性検出を足す
nerodeEqUpTo :: Int -> Mu -> [Landmark] -> Node -> Node -> Bool
nerodeEqUpTo kmax mu lm x y =
  and [ behProfile mu lm x u == behProfile mu lm y u | u <- snfWordsUpTo kmax ]

-- ===== ドキュメント主張の実行可能証明 =====

nodeNegI :: Node
-- -i。語は [I]、符号 σ（i² = σ の書き換えで符号欄へ落ちる）
nodeNegI = QCoeff 1 0 [I] (-1)

nodeJ :: Node
nodeJ = jUnitQ

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("(例4.1): 座標が一致しても -i と j は別状態 — 継続 i で分離する",
      not (nerodeEqUpTo 2 MInf defaultLandmarks nodeNegI nodeJ))
  , ("(命題3.1): Nerode 合同は右合同である — 同一状態は自明に右合同",
      nerodeEqUpTo 3 MInf defaultLandmarks unitQ unitQ
      && nerodeEqUpTo 3 MInf defaultLandmarks iUnitQ iUnitQ)
  , ("(例5.1): 関係は有向 — i の後に j と j の後に i は別の点に着く",
      applyWord [I, J] unitQ /= applyWord [J, I] unitQ)
  , ("(§3.4): 遷移の恒等式 — i² = σ、j² = e",
      applyWord [I, I] unitQ == QCoeff 1 0 [] (-1)
      && applyWord [J, J] unitQ == unitQ)
  , ("(§2): プロファイルは目印族に対して読まれる — 頂点は一点に 𝟏 を持つ",
      profileOf defaultLandmarks (RelNode iUnitQ)
        == Just [QCoeff 0 0 [] 1, unitQ, QCoeff 0 0 [] 1])
  , ("(§10.5): 観測個体のプロファイルは観測射の供給値そのまま読める",
      let obs = Observed [ (unitQ, QCoeff 1 2 [] 1)
                         , (iUnitQ, QCoeff 1 2 [] 1)
                         , (star iUnitQ jUnitQ, QCoeff 1 1 [] 1) ]
      in profileOf defaultLandmarks obs
           == Just [QCoeff 1 2 [] 1, QCoeff 1 2 [] 1, QCoeff 1 1 [] 1])
  , ("(定義1.3): 整合 ◁ — 例2.1 の (1/4, 1/4, 1/2) は Σλ = 1 を満たす",
      compatible [QCoeff 1 2 [] 1, QCoeff 1 2 [] 1, QCoeff 1 1 [] 1])
  , ("(定義1.3): 整合 ◁ — 和が 𝟏 から外れるプロファイルは拒否される",
      not (compatible [QCoeff 1 1 [] 1, QCoeff 0 0 [] 1, QCoeff 0 0 [] 1]))
  , ("(§4.3): 記憶深度で同一性が変わらない例 — この対は μ=0 でも継続 j で分離する",
      not (nerodeEqUpTo 2 M0 defaultLandmarks nodeNegI nodeJ))
  ]
