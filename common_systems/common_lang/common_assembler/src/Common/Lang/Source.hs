{-# LANGUAGE NoImplicitPrelude #-}
module Common.Lang.Source where

import CounterConstraints
import CommonChamber (Mu (..), muP, splitOnC)
import Common.Lang.NL

-- ===== .cam source ファイルの読み取り =====
-- doc: casm.src.format casm.src.parse casm.src.driver
--
-- 意味 program をファイルへ書くための表面形。書式は一行一箱で、
--
--   <ラベル> <音節名> <引数>*
--
-- ラベルは箱に付ける名前である。値の参照も分岐先も同じ名前で書くので、
-- 箱の番号を手で数えない。名前の要らない箱は "." を置く。
--
-- 引数の読み方は意味レジストリが決める。wireArgs の位置はラベル参照、
-- labelArgs の位置もラベル参照、残りは十進の literal になる。
-- 同じ位置に両方が来ることはない（10 章 §3）。
--
-- 先頭に置く指示は三つ:
--   mu <0|1|2|i>   記憶深度 μ
--   d  <整数>      作図深度 d
--   use <path>     別の .cam をその位置へ差し込む
--
-- use は driver が展開する。ラベルの解決は展開の後に一度だけ走るので、
-- 差し込んだ側と差し込まれた側は同じ名前空間を持つ。パスは use を書いた
-- ファイルからの相対になる。同じファイルを二度差し込むと誤りとして上げる。
--
-- # から行末まではコメントになる。
--
-- 例:
--   mu i
--   d  2
--
--   a  ke  3 1        # 3/2
--   b  ke  1 2        # 1/4
--   s  ko  a b        # 深度をそろえて足す
--   .  su  s e  ok    # 等しければ ok へ分離
--   ok tu

data SourceFile = SourceFile
  { sfMu    :: Mu
  , sfDep   :: Int
  , sfLines :: [(String, MKind, [Either String Int])]
    -- ^ (ラベル, 原子, 引数)。Left はラベル参照、Right は literal
  }

-- ===== 字句 =====

-- コメントを落として空白で切る。タブも空白として扱う
tokensOf :: String -> [String]
tokensOf ln = [ t | t <- splitOnC ' ' (map untab (dropComment ln)), not (null t) ]
  where
    untab c = if c == '\t' || c == '\r' then ' ' else c
    dropComment s = case break' '#' s of (a, _) -> a

break' :: Char -> String -> (String, String)
break' ch s = go s []
  where
    go []       acc = (reverse acc, [])
    go (c : cs) acc
      | c == ch   = (reverse acc, c : cs)
      | otherwise = go cs (c : acc)

noLabel :: String
noLabel = "."

-- ===== 構文 =====

parseSource :: String -> Either String SourceFile
parseSource txt = go (zip [1 :: Int ..] (splitOnC '\n' txt)) MInf 0 []
  where
    go [] mu dp acc = Right (SourceFile mu dp (reverse acc))
    go ((n, raw) : rest) mu dp acc = case tokensOf raw of
      []                -> go rest mu dp acc
      ["mu", v]         -> case muP v of
        Just m  -> go rest m dp acc
        Nothing -> Left (at n ++ "mu は 0 / 1 / 2 / i のどれか: " ++ v)
      ["d", v]          -> case readInt v of
        Just k  -> go rest mu k acc
        Nothing -> Left (at n ++ "d は整数: " ++ v)
      ("use" : _)       -> Left (at n ++ "use が展開されていない")
      (lb : nm : args) -> case kindByName nm of
        Nothing -> Left (at n ++ "未登録の意味原子: " ++ nm)
        Just k
          | length args /= arityOf k ->
              Left (at n ++ nm ++ " の引数は " ++ show (arityOf k) ++ " 本")
          | otherwise -> case classify k args of
              Left e   -> Left (at n ++ e)
              Right as -> go rest mu dp ((lb, k, as) : acc)
      [one] -> Left (at n ++ "原子名が無い: " ++ one)
    at n = "line " ++ show n ++ ": "

-- 引数を「ラベル参照」と「literal」へ振り分ける
classify :: MKind -> [String] -> Either String [Either String Int]
classify k args = seqE [ pick p a | (p, a) <- zip [0 ..] args ]
  where
    refs = wireArgs k ++ labelArgs k
    pick p a
      | elem p refs = Right (Left a)
      | otherwise   = case readInt a of
          Just v  -> Right (Right v)
          Nothing -> Left ("literal のはずが数値でない: " ++ a)

seqE :: [Either String a] -> Either String [a]
seqE []             = Right []
seqE (Left e : _)   = Left e
seqE (Right x : xs) = case seqE xs of
  Right ys -> Right (x : ys)
  Left e   -> Left e

-- ===== unit の組み立て =====
--
-- ラベル解決は NL.linesToUnit がそのまま行う。未定義のラベルは箱の総数
-- （＝image の終端）へ落ちるので、halt を指す label として使える

toUnit :: FileKind -> SourceFile -> Unit
toUnit fk sf = linesToUnit fk (sfMu sf) (sfDep sf) [ mk l | l <- sfLines sf ]
  where
    mk (lb, k, as) = mkLine (label lb) k (\r -> map (arg r) as)
    label lb = if lb == noLabel then "" else lb
    arg r a = case a of
      Left nm -> r nm
      Right v -> v

-- 未定義ラベルの検出。停止位置を指す意図と、書き間違いを分けるために、
-- 「箱の総数」以外の未解決名を報告する
unresolved :: SourceFile -> [String]
unresolved sf =
  [ nm | (_, _, as) <- sfLines sf, Left nm <- as, notElem nm defined ]
  where defined = [ lb | (lb, _, _) <- sfLines sf, lb /= noLabel ]

-- 12 §3.1 の res(s) = min は、同じラベルが二度出ても先頭を採る。だから重複は
-- 誤りではないが、二つ目の定義を指したつもりの参照が黙って一つ目へ向く。
-- 生存区間が全域へ伸びて landmark が枯れる形で後から出るので、ここで名前を挙げる
duplicateLabels :: String -> [String]
duplicateLabels txt = case parseSource txt of
  Left _   -> []
  Right sf -> dedup [ lb | (lb, _, _) <- sfLines sf, lb /= noLabel
                         , count lb > (1 :: Int) ]
    where
      labs = [ lb | (lb, _, _) <- sfLines sf, lb /= noLabel ]
      count lb = length [ () | l <- labs, l == lb ]
      dedup []       = []
      dedup (x : xs) = x : dedup (filter (/= x) xs)

readSource :: FileKind -> String -> Either String Unit
readSource fk txt = case parseSource txt of
  Left e   -> Left e
  Right sf -> case unresolved sf of
    []  -> Right (toUnit fk sf)
    bad -> Left ("未定義のラベル: " ++ show bad)
