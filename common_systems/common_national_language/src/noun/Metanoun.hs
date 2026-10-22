{-# LANGUAGE NoImplicitPrelude #-}
module Metanoun where

import CounterConstraints
import CounterComputeSystem (Dyad)
import CounterUnits (Op (..))
import CommonChamber
import DagPlane (CellPt (..), lamNums, lawTotal, mkT1Pt)
import Ideogram (Modality (..))
import GclsCategory
import NounNet
import Multimodal (Image (..), pImage)
import Abbrev
import Speech (Utterance, Channel, syllabicChannel, decode, encode, renderSymbols)

-- ===== メタ名詞（07 §6、§10）=====
-- doc: metanoun.identity metanoun.part metanoun.observe noun.concrete noun.sentence
--
-- 概念は個体の列挙でも特徴ベクトルでもなく、候補状態を受けて整合度を返す
-- 判定チェンバーである（§6.1）。メタ名詞は「名詞を定義するための名詞」であり、
-- 追加の原始はゼロで次の組になる（定義10.1、10.2）:
--
--   m = (y_m, A_m, {C_α})
--   C_m(x) = CNF( (⊗_{α∈A} C_α(x)) ⊗ ⋆_{ℓ∈L} (w(ℓ,x) ⇔ p_ℓ); C_identify )
--   (q ⇔ p) = (q ⇘ p) ★ (p ⇙ q)、   C_identify の中身は ★
--
-- 所属は唯一の非可逆観測 φ∂ ∘ π で一段に落とす。閾値という原始は導入しない:
--
--   x ⊨ m ⟺ φ∂(π(C_m(x))) = 1        （定義10.3）
--
-- ネットワークは一つに限る（§10.1）。全ノードが同一の目印族 L で測られる
-- ときだけプロファイルが比較可能になる。

type Judgment = (QRat, ([Op], Int))

-- 値の相等。大きさは既約化しないので交差乗算で比べる（GclsCategory.qratEq）
judgmentEq :: Judgment -> Judgment -> Bool
judgmentEq (a, w) (b, w') = qratEq a b && w == w'

-- ===== メタ名詞 =====

data MetaNoun = MetaNoun
  { protoIndividual :: Individual          -- y_m: 原型ノード。p̂ = ŷ_m が原型になる
  , metaComponents  :: [(Modality, Chamber)]
  -- A_m: モーダル成分チェンバー。空なら成分整合だけで閉じる（定義10.1）
  } deriving (Eq, Show)

-- 成分チェンバーの出力整合度を 𝒬 の値へ持ち上げる。
-- 出力は Dyad（大きさだけ、空語）なので語欄は空でよい
fromDyadJ :: Dyad -> Judgment
fromDyadJ (n, d) = (QRat n (toInteger (shiftL (1 :: Int) d)), ([], 1))

-- 整合度どうしの ★ 統合（C_identify の中身）。大きさは積、語は接合
joinJ :: Judgment -> Judgment -> Judgment
joinJ (mr, wr) (ml, wl) = (qratMul mr ml, mulWord wr wl)

-- 判定チェンバー C_m(x)。連続な整合度が必要な文脈では φ∂ を通さず
-- この値のまま読む（定義10.3 の注記）。
-- 接合順は式の並びどおり: モーダル成分を先に束ね、成分整合を後に掛ける
judgeMeta :: [Landmark] -> MetaNoun -> Individual -> [(Modality, Value)] -> Maybe Judgment
judgeMeta lm m x env =
  case (profileOf lm x, profileOf lm (protoIndividual m), componentOuts) of
    (Just px, Just pp, Just comps) ->
      let agrees = zipWith agreeQ px pp      -- ⋆_{ℓ∈L} (w ⇔ p) の因子
          unit   = (qratOne, ([], 1))
          base   = foldl joinJ unit comps   -- 成分を先に
      in Just (foldl joinJ base agrees)     -- 成分整合を後に
    _ -> Nothing
  where
    componentOuts = sequenceJ
      [ case lookupMod mo env of
          Nothing -> Nothing
          Just v  -> case evalChamber ch [v] of
                       Just [VDyad d] -> Just (fromDyadJ d)
                       _              -> Nothing
      | (mo, ch) <- metaComponents m ]
    lookupMod mo es = case [ v | (mo', v) <- es, mo' == mo ] of
      (v : _) -> Just v
      []      -> Nothing

-- Maybe のリストを右から畳む。prelude 語彙に mapM / sequence がないため
sequenceJ :: [Maybe a] -> Maybe [a]
sequenceJ []           = Just []
sequenceJ (Nothing : _) = Nothing
sequenceJ (Just x : rest) = case sequenceJ rest of
  Just xs -> Just (x : xs)
  Nothing -> Nothing

-- 所属（定義10.3）。φ∂ ∘ π: 大きさが正であることだけを読む。
-- 誤りでなく観測結果として 0 を返してよい（整形式と真偽の分離、01 §7）
memberOf :: [Landmark] -> MetaNoun -> Individual -> [(Modality, Value)] -> Bool
memberOf lm m x env = case judgeMeta lm m x env of
  Just (QRat n _, _) -> n > 0
  Nothing            -> False

-- メタ名詞の同一性（定理10.4）: 意味の一致は判定チェンバーの正準形一致。
-- 判定チェンバーを関数として持つので、候補個体の有限集合上の外延一致で
-- 読み替える。識別継続族や閾値のような補助データは不要である（命題10.5）:
-- 所属条件へ挙動一致を足しても所属関係は変わらない
sameJudgment :: [Landmark] -> [Individual] -> [(Modality, Value)] -> MetaNoun -> MetaNoun -> Bool
sameJudgment lm inds env a b =
  and [ sameOne i | i <- inds ]
  where
    sameOne i = case (judgeMeta lm a i env, judgeMeta lm b i env) of
      (Just j1, Just j2) -> judgmentEq j1 j2
      _                  -> False

-- ===== 具体名詞（定義10.6）=====

-- 具体名詞はメタ名詞に所属する個体への呼称である。
-- 意味は個体の CNF ではなく参照と所属の対になる:
--   ref(w) = x、  x ⊨ m
-- 同じメタ名詞に属する二個体は別の具体名詞になり、一つの名前へ潰れない。
-- 個体どうしの区別は Nerode 合同が担う
data ConcreteNoun = ConcreteNoun
  { cnIndividual :: Individual   -- 参照 ref(w)
  , cnMeta       :: MetaNoun     -- 所属先のメタ名詞
  , cnWitness    :: Chamber      -- 個体の記述チェンバー。呼称の発音源
  } deriving (Show)

-- 呼称の発音。採用語彙があれば採用列、なければ基準割当て（06 §17）
nameOf :: [(Chamber, Utterance)] -> ConcreteNoun -> Utterance
nameOf adopted cn = extCol adopted (cnWitness cn)

-- 所属の検査。x ⊨ m の読みそのもの
isInstance :: [Landmark] -> [(Modality, Value)] -> ConcreteNoun -> Bool
isInstance lm env cn = memberOf lm (cnMeta cn) (cnIndividual cn) env

-- ===== 実在するモノの名詞化（§10.5）=====
--
-- 手続きは観測と判定の二段に分かれる。
--   第一段（観測）: 各モーダルを観測射で読み、w(ℓ,x) をタレス比として得る。
--                    座標系の値を外から割り当てない。
--   第二段（判定）: 観測値を x̂ に並べ、C_m(x) を計算し、所属を読む。
-- 整合条件を破る観測は整形式でないので個体にならない（01 §7）
observeIndividual :: [(Landmark, QCoeff)] -> Maybe Individual
observeIndividual ps
  | null ps   = Nothing
  | compatible [ q | (_, q) <- ps ] = Just (Observed ps)
  | otherwise = Nothing

-- ===== ドキュメント主張の実行可能証明 =====

lmDefault :: [Landmark]
lmDefault = defaultLandmarks

vertexIJ :: Individual
vertexIJ = RelNode (applyWord [I, J] unitQ)

-- 例2.1 / 例10.7 の観測個体 x̂ = (1/4, 1/4, 1/2)
obsQuarter :: Individual
obsQuarter = Observed
  [ (unitQ, QCoeff 1 2 [] 1)
  , (applyWord [I] unitQ, QCoeff 1 2 [] 1)
  , (applyWord [I, J] unitQ, QCoeff 1 1 [] 1)
  ]

noComponents :: MetaNoun -> Bool
noComponents = null . metaComponents

metaVertex :: MetaNoun
-- 原型を頂点 ij に置くメタ名詞（例6.1）。成分なし A_m = ∅
metaVertex = MetaNoun vertexIJ []

metaFractional :: MetaNoun
-- 原型を例2.1 の内部点に置くメタ名詞。零成分を持たない原型
metaFractional = MetaNoun obsQuarter []

envEmpty :: [(Modality, Value)]
envEmpty = []

witnessA :: Chamber
witnessA = Chamber MInf 0 [PtDyad] [Layer [(0, primBeta)]] [PtDyad]

witnessB :: Chamber
witnessB = Chamber MInf 0 [PtUnit] [Layer [(0, primI)]] [PtUnit]

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("(例6.1): 原型そのものへの判定は 𝟏 を返す",
      case judgeMeta lmDefault metaVertex vertexIJ envEmpty of
        Just (v, w) -> qratEq v qratOne && w == ([], 1)
        Nothing     -> False)
  , ("(例10.7): 頂点の概念に対し x̂=(1/4,1/4,1/2) の整合度は 𝟏 を下回る",
      case judgeMeta lmDefault metaVertex obsQuarter envEmpty of
        Just (v, _) -> not (qratEq v qratOne)
        Nothing     -> False)
  , ("(例10.7): 所属は φ∂∘π で一段に落ちる — 頂点は 1、内部点候補は 0",
      memberOf lmDefault metaVertex vertexIJ envEmpty
      && not (memberOf lmDefault metaVertex obsQuarter envEmpty))
  , ("(定義10.2): 成分整合だけで閉じるメタ名詞（A_m = ∅）",
      noComponents metaVertex
      && case judgeMeta lmDefault metaFractional obsQuarter envEmpty of
           Just _  -> True
           Nothing -> False)
  , ("(定理10.4): 同一の原型を持つメタ名詞は同じ意味を持つ",
      sameJudgment lmDefault [vertexIJ, obsQuarter] envEmpty metaVertex metaVertex)
  , ("(定理10.4): 原型が違えば判定チェンバーも違い、別のメタ名詞になる",
      not (sameJudgment lmDefault [vertexIJ, obsQuarter] envEmpty metaVertex metaFractional))
  , ("(命題10.5): 所属と Nerode 合同は独立 — 合同しない対でも所属の向きは保たれる",
      let sep = not (nerodeEqUpTo 2 MInf lmDefault (applyWord [I] unitQ) (applyWord [J] unitQ))
          in1 = memberOf lmDefault metaFractional obsQuarter envEmpty
      in sep && in1)
  , ("(定義10.6): 具体名詞は所属する個体を参照する",
      isInstance lmDefault envEmpty (ConcreteNoun obsQuarter metaFractional witnessA))
  , ("(§10.5): 観測は整合なプロファイルだけを個体へ上げる",
      let good = observeIndividual
                   [ (unitQ, QCoeff 1 2 [] 1)
                   , (applyWord [I] unitQ, QCoeff 1 2 [] 1)
                   , (applyWord [I, J] unitQ, QCoeff 1 1 [] 1) ]
          bad  = observeIndividual
                   [ (unitQ, QCoeff 2 0 [] 1)
                   , (applyWord [I] unitQ, QCoeff 0 0 [] 1)
                   , (applyWord [I, J] unitQ, QCoeff 0 0 [] 1) ]
      in case good of
           Just (Observed _) -> True
           _                 -> False
        && not (case bad of Just _ -> True; Nothing -> False))
  , ("(定義10.6): 同じメタ名詞に属しても呼称は個体ごとに別列になる",
      let c1 = ConcreteNoun obsQuarter metaFractional witnessA
          c2 = ConcreteNoun vertexIJ metaFractional witnessB
          table = selectVocab syllabicChannel (1, 1) (1, 3)
                    [ (witnessA, 10), (witnessB, 4) ]
      in nameOf table c1 /= nameOf table c2)
  , ("(§10.4): 呼称の発音は採用語彙または基準割当てから得て、復号で記述へ戻る",
      let c1 = ConcreteNoun obsQuarter metaFractional witnessA
          table = selectVocab syllabicChannel (1, 1) (1, 3) [ (witnessA, 10), (witnessB, 4) ]
          u = nameOf table c1
      in decodeFull table
           (decode (chMu witnessA) (chDep witnessA) (chIn witnessA) (chOut witnessA))
           u == Just witnessA)
  , ("(§10.5): 観測射は記述チェンバーとプロファイルの両方を供給する",
      case nounObservations of
        (o : _) -> wellFormed (obsWitness o)
                   && case profileOf lmDefault (obsInd o) of
                        Just ps -> length ps == 3 && compatible ps
                        Nothing -> False
        []      -> False)
  , ("(6d): 深度を上げても同じ点 — 精緻化した観測は原型と 𝟏 一致する",
      case nounObservations of
        (oA : oB : _) -> case judgeMeta lmDefault metaReal (obsInd oB) envEmpty of
          Just (v, _) -> qratEq v qratOne
          Nothing     -> False
        _ -> False)
  , ("(§10.5): 別の点は判定値が下がる（連続な整合度として読む）",
      case nounObservations of
        (oA : oB : oC : _) ->
          let vB = judgeMeta lmDefault metaReal (obsInd oB) envEmpty
              vC = judgeMeta lmDefault metaReal (obsInd oC) envEmpty
          in case (vB, vC) of
               (Just (a, _), Just (c, _)) -> ratLt c a
               _                          -> False
        _ -> False)
  , ("(§10.5): 観測個体も呼称を持てる — 無音は欠陥なので作らない",
      let prons = [ pronOf (obsWitness o) | o <- nounObservations ]
      in all (not . null) prons)
  , ("(§10.2): 判定チェンバーはメタ名詞ごとに固有の正準形を持つ",
      -- 離散原型は PAgrU/PAgrZ で焼き込まれる。分数原型は未対応で Nothing
      case judgeChamberM lmDefault metaVertex of
        Just jc -> wellFormed jc
                   && judgeChamberM lmDefault metaFractional == Nothing
        Nothing -> False)
  , ("(§10.2): 判定チェンバーの実行が memberOf と一致する（二実装の意味論一致）",
      case judgeChamberM lmDefault metaVertex of
        Nothing -> False
        Just jc ->
          let run ws = case evalChamber jc [ VDyad q | q <- ws ] of
                         Just [VBit b] -> b > 0
                         _             -> False
              dy (QCoeff n d _ _) = (toInteger n, d)
              prof x = case profileOf lmDefault x of
                         Just ps -> map dy ps
                         Nothing -> []
          in run (prof obsQuarter) == memberOf lmDefault metaVertex obsQuarter envEmpty
             && run (prof vertexIJ) == memberOf lmDefault metaVertex vertexIJ envEmpty)
  , ("(§8): 関係ノード・メタ名詞・具体名詞の三形がすべてチェンバー化できる",
      case ( nounChamberOf (NNode [I])
           , nounChamberOf (NMeta metaVertex)
           , nounChamberOf (NConc (ConcreteNoun obsQuarter metaFractional witnessA)) ) of
        (Just _, Just _, Just _) -> True
        _                        -> False)
  ]

-- ===== 実在するモノの観測射（07 §10.5 第一段）=====
--
-- 一つの観測から二つの表示が出る（00 の方針）:
--   記述チェンバー … 05 の画像モーダル文法が領域を読んだもの。発音可能
--   影響プロファイル … 6c の重心座標 λ がタレス比として供給するもの。判定可能
-- 座標系の値を外から割り当てない。λ は幾何が内在的に決める
data Observation = Observation
  { obsInd      :: Individual
  , obsWitness  :: Chamber
  }

observeOnT1 :: CellPt -> Maybe Individual
observeOnT1 pt
  | lawTotal pt = observeIndividual (zip lmDefault qs)
  | otherwise   = Nothing
  where
    (a, b, c) = lamNums pt
    q n       = QCoeff n (lamDep pt) [] 1
    qs        = [q a, q b, q c]

-- 観測射 f_image: 領域セル列と幾何点の対から個体を作る。
-- 記述チェンバーは pImage の往復検査（整形式性）を通るものでなければならない
observeFromRegion :: Image -> CellPt -> Maybe Observation
observeFromRegion img pt = case pImage img of
  Nothing  -> Nothing
  Just wit -> case observeOnT1 pt of
    Just ind -> Just (Observation ind wit)
    Nothing  -> Nothing

nounifyOnT1 :: MetaNoun -> CellPt -> Maybe Bool
-- 第二段までの全体経路: 幾何観測 → 判定 → 二値（§10.5）
nounifyOnT1 m pt = case observeOnT1 pt of
  Nothing  -> Nothing
  Just ind -> Just (memberOf lmDefault m ind envEmpty)

-- ===== 任意の名詞のチェンバー化（07 §8、§10.2）=====
-- doc: noun.foundation omega.closure metanoun.identity
--
-- すべての名詞を第一級の意味対象＝チェンバーへ持ち上げる。
--
-- 判定チェンバー C_m はメタ名詞ごとに固有の正準形を持つ（定理10.4）。
-- 離散ノードの原型は one-hot プロファイル（p_ℓ ∈ {0, 𝟏}）なので、
-- 成分ごとに整合対の特殊形を焼き込む:
--   p_ℓ = 𝟏 の成分 … PAgrU（単位との整合対）
--   p_ℓ = 0 の成分 … PAgrZ（零との整合対）
-- 𝟏 と 0 は quantale の原始値なので、定数の新設には当たらない。
-- 分数の原型（観測から来る内部点）は定数原始が存在しないため
-- 焼き込めず、その場合は Nothing を返す。現時点で扱える範囲はここまでになる

judgeChamberM :: [Landmark] -> MetaNoun -> Maybe Chamber
judgeChamberM lm m = case profileOf lm (protoIndividual m) of
  Nothing  -> Nothing
  Just pp  -> case sequenceJ (map boxOf pp) of
    Nothing  -> Nothing
    Just boxes ->
      let n     = length pp
          agrL  = Layer (zip [0 :: Int ..] boxes)
          folds = replicate (if n < 2 then 0 else n - 1) (Layer [(0, primMulJ)])
          phiL  = Layer [(0, primPhiJ)]
      in cnf (Chamber MInf 0 (replicate n PtDyad) ([agrL] ++ folds ++ [phiL]) [PtBit])
  where
    boxOf q = case qNum q of
      k | k == shiftL 1 (qDep q) -> Just primAgrU
        | k == 0                 -> Just primAgrZ
      _                          -> Nothing

-- チェンバー化の対象となる名詞の三つの形
data AnyNoun
  = NNode [Op]         -- 関係ノード。語を実行するチェンバーが意味対象
  | NMeta MetaNoun     -- メタ名詞。固有の判定チェンバーが意味対象
  | NConc ConcreteNoun -- 具体名詞。記述チェンバーが意味対象

nounChamberOf :: AnyNoun -> Maybe Chamber
nounChamberOf (NNode w)  = cnf (nounWitness w)
nounChamberOf (NMeta m)  = judgeChamberM lmDefault m
nounChamberOf (NConc cn) = cnf (cnWitness cn)

-- 有理数の大小比較。正規化済みだが交差乗算で比べる
ratLt :: QRat -> QRat -> Bool
ratLt (QRat a b) (QRat c d) = a * d < c * b

-- ===== 全名詞の列挙（tools/DumpNounCsv.ps1 から使う）=====
-- doc: noun.concrete metanoun.observe noun.sentence
--
-- 現在の実装で表現可能な名詞を機械的に列挙し、CSV レコード列へ落とす。
-- 各行はコモン公用語そのもので記述する:
--   語の記述 = ser(C)、発音 = E_speech、呼称 = 採用語彙 V^ext、
--   プロファイルと判定値 = 𝒬 の大きさ n/2^d。表示は意味を作らない
-- 列挙範囲:
--   relnode  … 原始関係 i, j の語（長さ nounKmax までの snf 代表元）が
--              原点 O から到達できる状態すべて（RelNode）
--   observed … 観測射が作った個体。記述チェンバーを持つので
--              発音と呼称を持てる。無音にはしない（06 §16 と同じ原則）
--   concrete … メタ名詞に所属する個体への呼称。所属する組だけ行を持つ

nounKmax :: Int
nounKmax = 4

-- ネットワーク上で宣言済みのメタ名詞。ネットワークは一つ（§10.1）
nounMetaRegistry :: [(String, MetaNoun)]
nounMetaRegistry =
  [ ("m_vertex", metaVertex)
  , ("m_i",      MetaNoun (RelNode iUnitQ) [])
  , ("m_frac",   metaFractional)
  , ("m_real",   metaReal)
  ]

-- 語とそれが到達するノードの対。同じノードへ着く語は最後の代表だけ残す
nounEntries :: [([Op], Node)]
nounEntries = dedupFstN [ (w, applyWord w unitQ) | w <- snfWordsUpTo nounKmax ]

dedupFstN :: Eq b => [(a, b)] -> [(a, b)]
dedupFstN []           = []
dedupFstN ((a, b) : rest)
  | elem b kept        = keep
  | otherwise          = (a, b) : keep
  where keep = dedupFstN rest
        kept = [ c | (_, c) <- keep ]

-- 語の言語内記述。空語は単位 e、以降は原始文字をセミコロンで接合
nounWordDesc :: [Op] -> String
nounWordDesc []  = "e"
nounWordDesc ops = csvJoinS ";" [ opT o | o <- ops ]
  where opT I = "i"
        opT J = "j"

-- 語を実行するチェンバー。原始文字の逐次合成そのもの。
-- 空語は空本体になり、発音は零標示音 z_e 一つへ落ちる（06 §16）
nounWitness :: [Op] -> Chamber
nounWitness []  = Chamber MInf 0 [] [] []
nounWitness ops = foldl step idW ops
  where
    idW       = Chamber MInf 0 [PtUnit] [] [PtUnit]
    step acc o = case seqC acc atomC of
      Just c  -> c
      Nothing -> acc
      where atomC = Chamber MInf 0 [PtUnit] [Layer [(0, atomOf o)]] [PtUnit]
    atomOf I = primI
    atomOf J = primJ

-- 採用語彙への頻度入力。短い語ほど高頻度という測定レコードの代わり。
-- 実運用では §17.7 の観測レコード (C, n) を入れる
-- 空本体（零標示音）は採用対象から外す。零標示は構造予約であり、
-- 改名されると §16.2 の正準割当てが死ぬ。基準列は既に最短でもある
nounFreqRecs :: [(Chamber, Int)]
nounFreqRecs =
  [ (nounWitness w, if 30 - i < 1 then 1 else 30 - i)
  | (i, (w, _)) <- zip [0 :: Int ..] nounEntries
  , not (null (chLay (nounWitness w))) ]
  ++ [ (obsWitness o, 5) | o <- nounObservations ]
  ++ [ (jc, 50) | (_, m) <- nounMetaRegistry, Just jc <- [judgeChamberM lmDefault m] ]

nounVocabTable :: [(Chamber, Utterance)]
nounVocabTable = selectVocab syllabicChannel (1, 1) (1, 3) nounFreqRecs

-- CSV の一行に整形する
csvField :: String -> String
csvField f = "\"" ++ concatMap esc f ++ "\""
  where esc ch = if ch == '"' then "\"\"" else [ch]

csvJoinS :: String -> [String] -> String
csvJoinS _   []   = ""
csvJoinS _   [x]  = x
csvJoinS sep (x : xs) = x ++ sep ++ csvJoinS sep xs

fmtQMag :: QCoeff -> String
fmtQMag (QCoeff n d _ _) = show n ++ "/" ++ show (shiftL (1 :: Int) d)

fmtJudge :: MetaNoun -> Individual -> String
fmtJudge m ind = case judgeMeta lmDefault m ind envEmpty of
  Just (QRat a b, _) -> show a ++ "/" ++ show b
  Nothing            -> ""

fmtMember :: MetaNoun -> Individual -> String
fmtMember m ind = if memberOf lmDefault m ind envEmpty then "1" else "0"

fmtLams :: Individual -> (String, String, String)
fmtLams ind = case profileOf lmDefault ind of
  Just (a : b : c : _) -> (fmtQMag a, fmtQMag b, fmtQMag c)
  _                    -> ("", "", "")

pronOf :: Chamber -> String
pronOf wit = case renderSymbols (encode wit) of
  Just s  -> s
  Nothing -> ""

-- 個体ごとの共通部分。メタ名詞レジストリの順に判定値と所属を並べる
nounRowBody :: String -> String -> Chamber -> Individual -> Maybe ConcreteNoun -> String
nounRowBody kind wdesc wit ind mc = csvJoinS ","
  [ csvField kind
  , csvField wdesc'
  , csvField (ser wit)
  , csvField (pronOf wit)
  , csvField nameF
  , csvField lamO, csvField lamI, csvField lamIJ ]
  ++ concat [ "," ++ csvField (fmtJudge m ind) ++ "," ++ csvField (memBit m ind)
            | (_, m) <- nounMetaRegistry ]
  where
    wdesc' = case mc of
      Just cn -> metaTag cn ++ ":" ++ wdesc
      Nothing -> wdesc
    metaTag cn = case [ n | (n, m) <- nounMetaRegistry, cnMeta cn == m ] of
      (n : _) -> n
      []      -> "?"
    -- 呼称は意味の種別によらず採用表の一覧から出る。単一の名前空間であり、
    -- 同じチェンバー（同義）は同じ呼称を共有する
    nameF = nameColOf wit
    memBit m i = fmtMember m i
    (lamO, lamI, lamIJ) = fmtLams ind

nounCsvHeader :: String
nounCsvHeader = csvJoinS ","
  (map csvField ["kind", "word", "ser", "pron", "name", "lambda_O", "lambda_i", "lambda_ij"]
   ++ concat [ [csvField ("judge_" ++ n), csvField ("member_" ++ n)] | (n, _) <- nounMetaRegistry ])

-- ===== 見本の観測（実在するモノの名詞化の実例）=====
--
-- 領域セル列を画像モーダルへ読ませ、同じ対象の幾何点からプロファイルを
-- 取る。objA と objB は同じ点の深度差（6d の精緻化）。objC は別の点
regionRowsA, regionRowsB, regionRowsC :: [[(Int, Int, String)]]
regionRowsA = [[(0, 1, "beta")], [(0, 1, "fold")]]
regionRowsB = [[(0, 1, "beta")]]
regionRowsC = [[(0, 1, "fold")]]

nounObservations :: [Observation]
nounObservations =
  [ o | Just o <-
        [ observeFromRegion (Image MInf 0 [PtDyad] regionRowsA [PtBit]) (mkT1Pt 2 6 3)
        , observeFromRegion (Image MInf 0 [PtDyad] regionRowsB [PtDyad]) (mkT1Pt 4 12 4)
        , observeFromRegion (Image MInf 0 [PtDyad] regionRowsC [PtBit]) (mkT1Pt 6 7 3)
        ] ]

-- 原型も観測から作る。objA のプロファイルが m_real の原型になる
metaReal :: MetaNoun
metaReal = case nounObservations of
  (o : _) -> MetaNoun (obsInd o) []
  []      -> metaVertex

nounRelRows :: [String]
nounRelRows =
  [ nounRowBody "relnode" (nounWordDesc w) (nounWitness w) (RelNode x) Nothing
  | (w, x) <- nounEntries ]

-- 観測個体の行。記述チェンバーを持つので ser/pron を載せ、
-- 採用語彙にあれば呼称も持つ。無音にはしない（06 §16 と同じ原則）
-- 観測個体の行。記述チェンバーを持つので ser/pron を載せ、
-- 所属するメタ名詞があれば呼称も持つ。無音にはしない（06 §16 と同じ原則）
nounObsRows :: [String]
nounObsRows =
  [ nounRowBody "observed" "(image)" (obsWitness o) (obsInd o)
      (case membersOf o of
         (m : _) -> Just (ConcreteNoun (obsInd o) m (obsWitness o))
         []      -> Nothing)
  | o <- nounObservations ]
  where
    membersOf o = [ m | (_, m) <- nounMetaRegistry
                  , isInstance lmDefault envEmpty (ConcreteNoun (obsInd o) m (obsWitness o)) ]

nounConcreteRows :: [String]
nounConcreteRows =
  [ nounRowBody "concrete" (nounWordDesc w) (nounWitness w) (RelNode x) (Just cn)
  | (_, m) <- nounMetaRegistry
  , (w, x) <- nounEntries
  , let cn = ConcreteNoun (RelNode x) m (nounWitness w)
  , isInstance lmDefault envEmpty cn ]

-- チェンバーの呼称列。採用表にあれば採用列、なければ空
nameColOf :: Chamber -> String
nameColOf c = case renderSymbols (extCol nounVocabTable c) of
  Just s  -> s
  Nothing -> ""

-- メタ名詞の判定チェンバー行。原型が焼き込まれているので
-- 正準形はメタ名詞ごとに固有になる（定理10.4）
nounJudgmentRows :: [String]
nounJudgmentRows =
  [ csvJoinS ","
      [ csvField "judgment", csvField ("C_m:" ++ mname), csvField (ser jc)
      , csvField (pronOf jc), csvField (nameColOf jc)
      , csvField "", csvField "", csvField "" ]
    ++ concat (replicate (length nounMetaRegistry) ",\"\",\"\"")
  | (mname, m) <- nounMetaRegistry
  , Just jc <- [judgeChamberM lmDefault m] ]

nounCsvLines :: [String]
nounCsvLines = nounCsvHeader : nounRelRows ++ nounObsRows ++ nounConcreteRows ++ nounJudgmentRows
