{-# LANGUAGE NoImplicitPrelude #-}
module SentenceGrammar where

import CounterConstraints
import CounterUnits (Op (..))
import CommonChamber
import DagArith (addS)
import GclsCategory (QCoeff (..), applyWord)
import Ideogram (mkWord, wordParse, wordSer, Word (..))
import SparseTensor (sentenceEntries)

-- ===== 文法（02_三次元疎テンソルと文法.md §8〜§11）=====
-- doc: grammar.dag sov word.boundary.free
--
-- 文法は文字列規則ではなく型付き接続規則である。
-- 「どの出力がどの入力へ入るか」を先に DAG で作り、その正準層を一列へ読む。
-- SOV は独立した公理ではなく、引数を先に構成し作用を後に置く層構造の
-- 一次元表示として出る（命題9.1）。
--
-- 述語 V の中身は四則演算層の加算（DagArith.addS）であり、
-- 「二つの座標を取り、和を出す」という既存実装そのものである。

-- ===== 語構築のための原始パターン =====

wireChamber :: Mu -> Port -> Chamber
wireChamber mu w = Chamber mu 0 [w] [] [w]

atomChamber :: Mu -> Int -> Atom -> Chamber
atomChamber mu d a =
  Chamber mu d (fst (atomPorts a)) [Layer [(0, a)]] (snd (atomPorts a))

-- ===== 一次元読順 =====

readingOrder :: Chamber -> [String]
readingOrder c = [atomTag a | l <- chLay c, (_, a) <- layerAtoms l]

-- ===== SOV 文 =====
--
-- 主語 S、目的語 O を第0層に並べ、述語 V を第1層に置く。
-- Λ₀ = C_S ⊗ C_O、Λ₁ = C_V。一次元へ読むと S O V になる。

wCoordL, wCoordR :: Port
wCoordL = PtCoord
wCoordR = PtCoord

atomS, atomO, atomV :: Atom
atomS = mkAtom "S" PCoordId    -- 主語: 座標を通過する（座標用の恒等道）
atomO = mkAtom "O" PCoordId    -- 目的語: 同じく恒等道
atomV = mkAtom "V" PAdd        -- 述語: 加算の平行四辺形則（DagArith.addS）

subjectWord, objectWord, verbChamber :: Chamber
subjectWord = atomChamber MInf 1 atomS
objectWord  = atomChamber MInf 1 atomO
verbChamber = Chamber MInf 1 [wCoordL, wCoordR]
                       [Layer [(0, atomV)]]
                       [PtCoord]

sovSentence :: Maybe Chamber
sovSentence = case tensorC subjectWord objectWord of
  Just so -> seqC so verbChamber
  Nothing -> Nothing

-- ===== 名詞ノードの SOV 文（07 §7）=====
--
-- 主語 S と目的語 O を名詞ノード、述語 V を関係チェンバーにする。
-- cod(C_S ⊗ C_O) = dom(C_V) のときだけ文 = (C_S ⊗ C_O); C_V に接合できる。
-- Λ₀ = C_S ⊗ C_O、Λ₁ = C_V。述語が関係のときは中身を遷移係数 T_f にとり、
-- 関係語 u が主語ノードへ適用される。非可換なので適用順が意味を持つ

nounWordS, nounWordO :: Chamber
nounWordS = wireChamber MInf PNoun
nounWordO = wireChamber MInf PNoun

nounVerb :: [Op] -> Chamber
nounVerb ops = Chamber MInf 0 [PNoun, PNoun]
                        [Layer [(0, mkAtom "v" (PRel (relStr ops)))]]
                        [PNoun, PNoun]

nounSentence :: [Op] -> Maybe Chamber
nounSentence ops = case tensorC nounWordS nounWordO of
  Just so -> seqC so (nounVerb ops)
  Nothing -> Nothing

-- ===== 関係付きの文（common_translator/03 §8、17 §4.3）=====
--
-- 平文から書ける形の SOV 文。名詞は node で立ち、助詞と述語は関係語として当たる。
--
--   Λ₀ = node ⊗ node ⊗ node            主語・目的語・文末ノード
--   Λ₁ = T_{w_S} @ 0                   主語の助詞
--   Λ₂ = T_{w_O} @ 1                   目的語の助詞
--   Λ₃ = T_{w_V} @ 0                   述語
--   Λ₄ = !_Noun ⊗ !_Noun ⊗ !_Noun      文末
--
-- T_w は主語と目的語の二本を読むので、末尾に文末ノードを一本置かないと
-- 目的語側へ関係語を当てられない。廃棄は位置 0,1,2 に並べる。位置 0 に三つ
-- 置くと二つ目で cur を追い越して非正準層になる。
--
-- 助詞をポートの表示だけで持つと「ねこ は みず を のむ」が
-- 「ねこ が みず を のむ」へ戻って壊れる。だから助詞は関係語として第一級に持つ。

relBox :: [Op] -> Atom
relBox w = mkAtom "rel" (PRel (relStr w))

relSentence :: [Op] -> [Op] -> [Op] -> Maybe Chamber
relSentence wS wO wV = cnf (Chamber MInf 0 []
  [ Layer [(0, primNode), (0, primNode), (0, primNode)]
  , Layer [(0, relBox wS)]
  , Layer [(1, relBox wO)]
  , Layer [(0, relBox wV)]
  , Layer [(0, primDropN), (1, primDropN), (2, primDropN)]
  ] [])

-- 「ねこ が さかな を たべる 。」と「ねこ は みず を のむ 。」の骨格。
-- 語ごとの関係語は語彙表が配る。ここでは相異なる snf 語を三つ使えば足りる
sentenceGa, sentenceHa :: Maybe Chamber
sentenceGa = relSentence [I]    [J]    [I, J]
sentenceHa = relSentence [J, I] [J]    [J, I]

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("命題9.1: SOV は層構造の一次元表示として出る",
      case sovSentence of
        Just s  -> readingOrder s == ["S", "O", "V"]
        Nothing -> False)
  , ("§8: 同じ層の要素は並列、後段の作用は前段の出力へ接続する",
      case sovSentence of
        Just s ->
          length (chLay s) == 2
          && layerAtoms (firstLayer s) == [(0, atomS), (1, atomO)]
          && lastIsV s
        Nothing -> False)
  , ("文の意味論: SOV 文を実行すると加算が走る（述語は DagArith.addS）",
      case sovSentence of
        Just s ->
          evalChamber s [VCoord (2, 4, 3), VCoord (1, 6, 3)]
            == Just [VCoord (3, 10, 3)]
            && addS (2, 4, 3) (1, 6, 3) == (3, 10, 3)
        Nothing -> False)
  , ("§10: 語順と意味順序を同一視しない — ⊗ と ; は別の構成である",
      let par = tensorC subjectWord objectWord
          serP = case par of
                   Just p  -> ser p
                   Nothing -> ""
      in case seqC subjectWord objectWord of
           Just sq -> ser sq /= serP
           Nothing -> True)
  , ("§11: 単語境界は意味論の原始でない — 表示差異が意味を変えない",
      let w1 = mkWord subjectWord
          decorated = case w1 of
            Just w  -> parseDecorated ("|" ++ wordSer w)
            Nothing -> Nothing
      in decorated == w1)
  , ("文章の疎テンソル: k 軸で語位置が区別される",
      let cs = case sovSentence of
                 Just s  -> [subjectWord, verbChamber, s]
                 Nothing -> []
          ses = sentenceEntries cs
      in any (\((k, _, _), t) -> k == 0 && t == "S") ses
         && any (\((k, _, _), t) -> k == 2 && t == "V") ses)
  , ("(07 §7): 名詞ノードの SOV 文 — cod(C_S ⊗ C_O) = dom(C_V) で接合する",
      -- 名詞ワイヤは原子を持たない恒等道なので Λ₀ は自明層になり、
      -- チェンバー形式からは落ちる。層数 1 = Λ₁(C_V) のみが現れる
      case nounSentence [I] of
        Just s  -> length (chLay s) == 1 && wellFormed s
        Nothing -> False)
  , ("(07 §7): 関係述語の実行 — u が主語ノードへ適用され、目的語は素通しする",
      case nounSentence [J] of
        Just s ->
          let p = [QCoeff 0 0 [] 1, QCoeff 0 0 [] 1, QCoeff 0 0 [] 1]
              o = QCoeff 1 0 [I] 1
          in evalChamber s [VNoun unitQn p, VNoun o p]
               == Just [VNoun (applyWord [J] unitQn) p, VNoun o p]
        Nothing -> False)
  , ("(07 §7): 関係は有向 — 述語の適用順で文の意味が変わる",
      case (nounSentence [I, J], nounSentence [J, I]) of
        (Just a, Just b) ->
          let p = [QCoeff 0 0 [] 1]
          in evalChamber a [VNoun unitQn p, VNoun unitQn p]
             /= evalChamber b [VNoun unitQn p, VNoun unitQn p]
        _ -> False)
  , ("(07 §7): 境界の型が合わなければ接合しない",
      not (wellFormed (Chamber MInf 0 [PtDyad]
             [Layer [(0, mkAtom "v" (PRel "i"))]] [PtDyad])))
  , ("(03 §8): 関係付きの文は Γ⁻ = Γ⁺ = I に閉じる（16 §4）",
      case sentenceGa of
        Just s  -> null (chIn s) && null (chOut s) && wellFormed s
                   && evalChamber s [] == Just []
        Nothing -> False)
  , ("(03 §8): node が三本立ち、廃棄が位置 0,1,2 で閉じる",
      case sentenceGa of
        Just s  -> map (map (atomTag . snd) . layerAtoms) (chLay s)
                     == [["node","node","node"],["rel"],["rel"],["rel"]
                        ,["drop","drop","drop"]]
                   && map (map fst . layerAtoms) (chLay s)
                     == [[0,0,0],[0],[1],[0],[0,1,2]]
        Nothing -> False)
  , ("(03 §8): 助詞と述語が違えば正準形が違う — が/は が意味に残る",
      case (sentenceGa, sentenceHa) of
        (Just a, Just b) -> ser a /= ser b
        _                -> False)
  , ("(03 §8): 関係は有向 — 述語の関係語の順で正準形が変わる",
      case (relSentence [I] [J] [I, J], relSentence [I] [J] [J, I]) of
        (Just a, Just b) -> ser a /= ser b
        _                -> False)
  , ("(03 §8): parse(ser(C)) ≅ C — 関係付きの文も直列化を往復する",
      case sentenceGa of
        Just s  -> parse (ser s) == Just s
        Nothing -> False)
  ]
  where
    unitQn = QCoeff 1 0 [] 1
    firstLayer c = case chLay c of
      (l : _) -> l
      []      -> Layer []

lastIsV :: Chamber -> Bool
lastIsV c = case reverse (chLay c) of
  (l : _) -> layerAtoms l == [(0, atomV)]
  _       -> False

parseDecorated :: String -> Maybe Word
parseDecorated ('|' : rest) = wordParse rest
parseDecorated s            = wordParse s

