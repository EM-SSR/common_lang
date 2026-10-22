{-# LANGUAGE NoImplicitPrelude #-}
module Ideogram where

import CounterConstraints
import CounterComputeSystem (Dyad)
import CommonChamber
import DagPlane (CellPt (..), mkT1Pt, lawTotal, eqScaled, xyOf)
import CounterUnits (mkReal, applyI, negateUP)

-- ===== 表意語（01_意味対象と表意語.md）=====
-- doc: word.def word.render addr.relative concept.build
--
-- 語の意味       = CNF(C)
-- 語の可搬表現   = ser(C)
-- 語の人間向け表示 = Render(ser(C))
--
-- Render は意味を作らない。表示が違っても parse 後のチェンバーが同じなら同義。
-- 文字と概念の一対一対応は行わない。語そのものが小さな有向ストリング図であり、
-- その原始文字は counter_plane の積み上げた演算である。

newtype Word = Word { wordChamber :: Chamber } deriving (Eq, Show)

mkWord :: Chamber -> Maybe Word
mkWord c = case cnf c of
  Just c' -> Just (Word c')
  Nothing -> Nothing

wordSer :: Word -> String
wordSer w = ser (wordChamber w)

wordParse :: String -> Maybe Word
wordParse s = case parse s of
  Just c  -> mkWord c
  Nothing -> Nothing

-- 命題1.1: 二つのレンダリング。どちらも ser を失わずに表示するので、
-- パース後に同じ正準形へ戻る＝同じ語
renderPlain :: Word -> String
renderPlain = wordSer

renderDecorated :: Word -> String
renderDecorated w = "W[" ++ wordSer w ++ "]"

parseRendered :: String -> Maybe Word
parseRendered ('W' : '[' : rest) = stripEnd rest []
parseRendered s                  = wordParse s

stripEnd :: String -> String -> Maybe Word
stripEnd []         acc = wordParse (reverse acc)
stripEnd (']' : []) acc = wordParse (reverse acc)
stripEnd (c : cs)   acc = stripEnd cs (c : acc)

-- 語の同一性: CNF 一致のみで決まる。字形の類似は関係しない
wordEq :: Word -> Word -> Bool
wordEq = (==)

-- ===== 概念の相対アドレス（定理3.1）=====
--
-- 個体 x の同定は影響対象 𝐆=(G,L,w) の目印族に対する影響プロファイル
--
--   ĥ = (w(ℓ₀,x), …, w(ℓₙ,x))
--
-- で行う。w は 6c のタレス比＝重心座標であり、幾何が内在的に決める量。
-- 属性ベクトルを外から割り当てることはしない。
-- 分離条件 (3.1) の下で A_L(x)=ĥ は単射になる。
--
-- 実行形: T₁=(O,i,ij) 上の点は CellPt であり、
--   ĥ = (λ_O, λ_i, λ_ij)、拘束 Σλ = 2^depth
-- という三つ組がそのまま影響プロファイルになる。

sameInfluence :: CellPt -> CellPt -> Bool
sameInfluence p q = eqScaled (xyOf p) (xyOf q)

-- 分離条件: プロファイルが一致するなら点は同一（A_L の単射性）
separationHolds :: [(Int, Int, Int)] -> Bool
separationHolds pts =
  and [ not (sameInfluence p q) || p == q
      | p <- cells, q <- cells ]
  where cells = [ mkT1Pt a b d | (a, b, d) <- pts ]

-- ===== 整形式と真偽の分離（§7）=====
--
-- WellFormed(C_S)=1 でありながら φ∂(C_S(x))=0 であってよい。
-- 名詞概念は不要。fold 語に零を流せば整形式かつ非真となる。

observationOf :: Chamber -> [Value] -> Maybe Bool
observationOf c vs = case evalChamber c vs of
  Just [VBit b] -> Just (b > 0)
  _             -> Nothing

-- ===== 原始段階の語彙閉包 =====
--
-- 現在構築できる語の原子は primitiveTable のみ。
-- 名詞概念チェンバーは、モーダル成分チェンバー（下記 ConceptChamber）として
-- 構成可能になった: 成分を列挙へ落とさず、各境界を独立に保持する。

primitiveStageVocabulary :: [String]
primitiveStageVocabulary = map fst primitiveTable

usesOnlyPrimitives :: Chamber -> Bool
usesOnlyPrimitives c =
  and [ elem (atomTag a) primitiveStageVocabulary
      | l <- chLay c, (_, a) <- layerAtoms l ]

-- ===== 概念チェンバー（01 §4〜6。多モーダル層の完成により構成可能になった）=====
--
-- 「リンゴという概念」は個体の列挙でも特徴ベクトルでもなく、
-- モーダル境界ごとの成分チェンバー C_α を ⊗ で束ね、
-- 𝒬-豊穣の論理積 ⋆ で統合した構成対象である:
--
--   C_concept = CNF( (⊗_{α∈A} C_α) ; C_identify )、C_identify の中身は ⋆
--
-- 各成分は独立なモーダル境界として保持され、必要なモーダルだけ観測される。
-- 成分チェンバーの中身は既存原始文字の合成で作る。

data Modality = MVisual | MSound | MMotion | MShape | MRelation | MTaste
  deriving (Eq, Ord, Show)

type Component = (Modality, Chamber)

-- 成分チェンバー: 整合度ワイヤ（VDyad）を受け取り、同じく整合度を返す。
-- 中身は既存原始文字の合成で構築する
componentChamber :: Modality -> Chamber -> Component
componentChamber m ch = (m, ch)

data ConceptChamber = ConceptChamber
  { ccComponents :: [Component]
  , ccDep        :: Int
  } deriving (Eq, Show)

mkConcept :: [Component] -> Int -> ConceptChamber
mkConcept comps dep = ConceptChamber comps dep

modTagOf :: Modality -> String
modTagOf m = case m of
  MVisual   -> "visual"
  MSound    -> "sound"
  MMotion   -> "motion"
  MShape    -> "shape"
  MRelation -> "relation"
  MTaste    -> "taste"

-- 統合 C_identify: 各成分チェンバーを実行し、出力整合度を ⋆ で畳む。
-- ⋆ は 𝒬-豊穣の乗法（starDyad）であり、DagArith.multiplyThales の Dyad 版
evaluateConcept :: [(Modality, Value)] -> ConceptChamber -> Maybe Dyad
evaluateConcept env cc = foldr step (Just (1, 0)) (ccComponents cc)
  where
    step (m, ch) acc = case lookupMod m env of
      Nothing -> Nothing
      Just v  -> case evalChamber ch [v] of
        Just [VDyad out] -> case acc of
          Just a  -> Just (dyMulCC out a)
          Nothing -> Nothing
        _ -> Nothing

lookupMod :: Modality -> [(Modality, Value)] -> Maybe Value
lookupMod m env = case [v | (m', v) <- env, m' == m] of
  (v : _) -> Just v
  []      -> Nothing

dyMulCC :: Dyad -> Dyad -> Dyad
dyMulCC (a, x) (b, y) = (a * b, x + y)

-- 成分が一つでも欠けた記述は、別の概念チェンバーになる（定理5.1）
sameConcept :: ConceptChamber -> ConceptChamber -> Bool
sameConcept = (==)

-- ===== ドキュメント主張の実行可能証明 =====

iWordC :: Chamber
iWordC = Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]

jWordC :: Chamber
jWordC = Chamber MInf 0 [PtUnit] [Layer [(0, primJ)]] [PtUnit]

betaFoldWord :: Chamber
betaFoldWord =
  Chamber MInf 0 [PtDyad]
    [Layer [(0, primBeta)], Layer [(0, primFold)]]
    [PtBit]

foldWordC :: Chamber
foldWordC = Chamber MInf 0 [PtDyad] [Layer [(0, primFold)]] [PtBit]

conceptTwoComponent :: ConceptChamber
conceptTwoComponent = mkConcept
  [ componentChamber MVisual (Chamber MInf 0 [PtDyad] [] [PtDyad])
  , componentChamber MTaste  (Chamber MInf 0 [PtDyad] [] [PtDyad]) ] 2

conceptOneComponent :: ConceptChamber
conceptOneComponent = mkConcept
  [ componentChamber MVisual (Chamber MInf 0 [PtDyad] [] [PtDyad]) ] 2

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("語: 整形式チェンバーからだけ語が作れる",
      let ok  = mkWord iWordC
          bad = mkWord (Chamber MInf 0 [PtDyad] [Layer [(0, primI)]] [PtUnit])
      in ok /= Nothing && bad == Nothing)
  , ("命題1.1: 表示は意味を作らない — 二つの表示が同じ語へ戻る",
      let w = case mkWord betaFoldWord of
                Just x  -> x
                Nothing -> Word emptyChamber
      in parseRendered (renderDecorated w) == Just w
         && parseRendered (renderPlain w) == Just w)
  , ("語の同一性: 字形が似ていても正準形が違えば別の語",
      mkWord iWordC /= mkWord jWordC)
  , ("定理3.1: 影響プロファイルは相対アドレスになる（重心座標で個体を分離）",
      separationHolds [(1, 3, 2), (2, 3, 2), (5, 11, 4)]
      && sameInfluence (mkT1Pt 1 3 2) (mkT1Pt 4 12 4))
  , ("定理3.1: プロファイルは拘束 Σλ=2^depth を持つ（6c）",
      lawTotal (mkT1Pt 1 3 2) && lawTotal (mkT1Pt 5 11 4))
  , ("§7: 整形式と真偽は分離する — 整形式だが観測が非真である文がある",
      let wf   = wellFormed foldWordC
          obs  = observationOf foldWordC [VDyad (0, 3)]
      in wf && obs == Just False)
  , ("§7: 同じ語でも入力により観測は変わる（真偽は文でなく対で決まる）",
      observationOf betaFoldWord [VDyad (7, 3)] == Just True)
  , ("命題8.1: 有限の原始語彙から無限の構成が生成される（i の累乗は意味も違う）",
      let powers = take 5 (iterate (\c -> chainI c) iWordC)
          chainI c = case seqC c iWordC of
                       Just c' -> c'
                       Nothing -> c
          sers  = map ser powers
          pt    = mkReal 32 1
          evals = map (\c -> evalChamber c [VPt pt]) powers
      in and [x /= y | (x, y) <- zip sers (safeTail sers)]
         && case safeIdx 2 evals of
              Just (Just [VPt q]) -> q == negateUP (applyI pt)
              _                   -> False)
  , ("原始段階: 構築可能な語の原子は原始文字のみ（名詞は成分チェンバーとして構成される）",
      usesOnlyPrimitives iWordC && usesOnlyPrimitives jWordC
      && usesOnlyPrimitives betaFoldWord
      && notElem "unregisteredTag" primitiveStageVocabulary)
  , ("概念チェンバー: モーダル成分の ⋆ 統合として構成・実行できる",
      let env = [ (MVisual, VDyad (1, 1)), (MTaste, VDyad (1, 1)) ]
      in case evaluateConcept env conceptTwoComponent of
           Just d  -> snd d == 2
           Nothing -> False)
  , ("定理5.1: 記述は正準形が一致するときだけ概念を同定する",
      not (sameConcept conceptTwoComponent conceptOneComponent))
  ]
  where
    safeTail :: [String] -> [String]
    safeTail (_ : xs) = xs
    safeTail []       = []

    safeIdx :: Int -> [a] -> Maybe a
    safeIdx _ []      = Nothing
    safeIdx 0 (x : _) = Just x
    safeIdx k (_ : xs) = safeIdx (k - 1) xs

emptyChamber :: Chamber
emptyChamber = Chamber M0 0 [] [] []


