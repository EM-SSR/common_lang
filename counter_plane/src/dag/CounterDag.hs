{-# LANGUAGE NoImplicitPrelude #-}
module CounterDag where

import CounterConstraints

-- ===== Level 6+: 構成履歴の DAG（晴れ上がり）=====
-- doc: level6.dag gcls.dag
--
-- Index.md より:
--   - Level5 以降は階層ではなく有向非巡回グラフ
--   - ij のような合成操作は i と j の両方を祖先に持つため、
--     「Level はいくつか」という問いが一意でなくなる
--
-- 構成履歴は接続行列（行 = 親ノード、立位ビット = 子ノード）として
-- Data.Bits 上に記録する。単体複体行列と同一の表現規約を使う。

type NodeId = Int

data OpNode
  = NOrigin                 -- Level 0: O
  | NNeg    NodeId          -- Level 2: 反転
  | NInt    NodeId          -- Level 3: 整数再帰の一歩
  | NEscI   NodeId          -- Level 4: ω からの独立方向脱出 (i)
  | NEscJ   NodeId          -- Level 5: ω⁻ からの独立方向脱出 (j)
  | NComp   NodeId NodeId   -- Level 6+: 二系統の合成 (ij など)
  deriving (Eq, Show)

data Dag = Dag
  { dagSize  :: Int
  , dagNodes :: [(NodeId, OpNode)]
  , dagAdj   :: [(NodeId, Word64)]
  } deriving (Eq, Show)

emptyDag :: Dag
emptyDag = Dag 0 [] []

parentsOf :: OpNode -> [NodeId]
parentsOf node = case node of
  NOrigin   -> []
  NNeg p    -> [p]
  NInt p    -> [p]
  NEscI p   -> [p]
  NEscJ p   -> [p]
  NComp a b -> [a, b]

lookupN :: NodeId -> Dag -> Maybe OpNode
lookupN n d = lookup n (dagNodes d)

childRow :: NodeId -> Dag -> Word64
childRow u d = maybe zeroBits id (lookup u (dagAdj d))

insertRow :: NodeId -> Word64 -> [(NodeId, Word64)] -> [(NodeId, Word64)]
insertRow u b [] = [(u, b)]
insertRow u b ((w, r) : rest)
  | w == u    = (u, r .|. b) : rest
  | otherwise = (w, r) : insertRow u b rest

-- 子孫への到達可能性（推移閉包）。ノード数は 64 以下に制限される
reachesFrom :: Dag -> NodeId -> Word64
reachesFrom d root = go (bit root) (bit root)
  where
    go seen frontier
      | frontier == zeroBits = seen
      | otherwise =
          let next = foldr (.|.) zeroBits
                       [childRow u d | u <- [0 .. dagSize d - 1], frontier `testBit` u]
          in go (seen .|. next) (next .&. complement seen)

-- 新ノード追加。親は存在しなければならない。
-- 追加は末端へのみ行われるため閉路は構造的に発生しない
addNode :: OpNode -> Dag -> Maybe (Dag, NodeId)
addNode node d
  | not (all exists (parentsOf node)) = Nothing
  | otherwise =
      Just (Dag (nid + 1)
                (dagNodes d ++ [(nid, node)])
                (foldr (\p rows -> insertRow p (bit nid) rows) (dagAdj d)
                       (parentsOf node))
           , nid)
  where
    nid = dagSize d
    exists i = maybe False (const True) (lookupN i d)

-- 任意の辺 u→v を後から張る（検証用）。
-- v が既に u へ到達可能なとき閉路になるため拒否しなければならない
linkNodes :: Dag -> NodeId -> NodeId -> Maybe Dag
linkNodes d u v
  | not (exists u && exists v)        = Nothing
  | reachesFrom d v `testBit` u       = Nothing
  | otherwise = Just d { dagAdj = insertRow u (bit v) (dagAdj d) }
  where
    exists i = maybe False (const True) (lookupN i d)

-- ノードの祖先レベル集合。合成ノードでは一意に決まらない
levelSet :: Dag -> NodeId -> [Int]
levelSet d n = case lookupN n d of
  Nothing   -> []
  Just node -> case node of
    NOrigin   -> [0]
    NNeg _    -> [2]
    NInt _    -> [3]
    NEscI _   -> [4]
    NEscJ _   -> [5]
    NComp a b -> uniq (levelSet d a ++ levelSet d b)

uniq :: [Int] -> [Int]
uniq = foldr (\x acc -> x : filter (/= x) acc) []

-- 標準的なサンプル DAG:
-- O → 整数2歩 → (反転 → j 脱出) と (i 脱出) → 合成 ij
sampleDag :: Maybe (Dag, NodeId)
sampleDag = do
  (d1, o)  <- addNode NOrigin emptyDag
  (d2, i1) <- addNode (NInt o) d1
  (d3, i2) <- addNode (NInt i1) d2
  (d4, ni) <- addNode (NNeg i2) d3
  (d5, ei) <- addNode (NEscI i2) d4
  (d6, ej) <- addNode (NEscJ ni) d5
  addNode (NComp ei ej) d6

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("L6+: 合成ノードの祖先レベル集合は複数要素を持つ（階層では表せない）",
      case sampleDag of
        Just (d, comp) -> let lv = levelSet d comp
                          in length lv >= 2 && elem 4 lv && elem 5 lv
        Nothing -> False)
  , ("L6+: 閉路を作る辺の追加は拒否される（子孫から祖先への辺）",
      case sampleDag of
        Just (d, comp) ->
          linkNodes d comp 1 == Nothing && linkNodes d 1 3 /= Nothing
        Nothing -> False)
  , ("L6+: 全ての辺が閉路を構成しない（非巡回性）",
      case sampleDag of
        Just (d, _) ->
          all ok (dagAdj d)
          where ok (u, row) =
                  all (\v -> not (reachesFrom d v `testBit` u))
                      [v | v <- [0 .. dagSize d - 1], row `testBit` v]
        Nothing -> False)
  , ("L6+: 推移閉包が子孫全体へ伝播する",
      case sampleDag of
        Just (d, _) | Just (NInt _) <- lookupN 1 d ->
          popCount (reachesFrom d 0) == length (dagNodes d)
        _ -> False)
  ]
