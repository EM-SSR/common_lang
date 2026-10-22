module Common.Lang.Construction where

import CommonChamber
import Control.Monad (foldM, unless)
import Data.List (nub)

-- doc: word.def grammar.dag beta.def beta.transport
type Reference = String

data PointStep
  = Landmark Reference
  | Bisect Reference Reference
  | CloseBisection Reference Reference
  | Reflect Reference Reference
  | Image Reference
  | Sequential Reference Reference
  | Parallel Reference Reference
  | Apply Reference Reference
  | Closure Int Reference Reference
  | Candidates Reference [Reference]
  deriving (Eq, Ord, Read, Show)

data Construction = Construction
  { constructionSteps :: [(Reference,PointStep)]
  , constructionOutput :: Reference
  } deriving (Eq, Read, Show)

-- 目印の像もチェンバー。結果の座標へ置換せず、像を作る構成を接合する。
realize :: [(Reference,Chamber)] -> Construction -> Either String Chamber
realize images (Construction steps output) = do
  unless (length (nub (map fst images)) == length images) (Left "目印の像が重複している")
  built <- foldM step [] steps
  maybe (Left "出力の構成参照がない") Right (lookup output built)
  where
    point c = chIn c == [] && chOut c == [PtCoord] && wellFormed c
    reference built name = maybe (Left ("構成参照が先行していない: " ++ name)) Right (lookup name built)
    step built (name,body) = do
      unless (name `notElem` map fst built) (Left ("構成参照が重複している: " ++ name))
      c <- case body of
        Landmark anchor -> do
          image <- maybe (Left ("目印の像がない: " ++ anchor)) Right (lookup anchor images)
          unless (point image) (Left ("目印の像の境界が Point でない: " ++ anchor))
          Right image
        Image anchor -> do
          image <- maybe (Left ("構成の像がない: " ++ anchor)) Right (lookup anchor images)
          unless (wellFormed image) (Left ("構成の像が整形式でない: " ++ anchor))
          Right image
        Sequential left right -> join built seqC left right
        Parallel left right -> join built tensorC left right
        Apply operation argument -> do
          op <- maybe (Left ("作用の像がない: " ++ operation)) Right (lookup operation images)
          value <- reference built argument
          unless (wellFormed op) (Left "作用の像が整形式でない")
          maybe (Left "作用と引数の境界が接合できない") Right (seqC value op)
        Closure address function initial -> do
          body <- reference built function
          seed <- reference built initial
          unless (omegaWellFormed address body seed) (Left "閉包の状態境界が一致しない")
          let operation = POmega address body seed
              (ins,outs) = kindsOfPrim operation
          Right (withGrade (primitiveGrade operation) (primitiveAddresses operation)
            (Chamber (chMu body) 1 ins [Layer [(0,mkAtom "Omega" operation)]] outs))
        Candidates predicate arguments -> do
          p <- reference built predicate
          args <- mapM (reference built) arguments
          candidateSupremum p args
        Bisect x a -> do
          binary built PBisectPoint x a
        CloseBisection x a -> binary built PFixPoint x a
        Reflect reflector x -> do
          r <- maybe (Left ("折返しの像がない: " ++ reflector)) Right (lookup reflector images)
          unless (chIn r == [] && chOut r == [PtRefl] && wellFormed r)
            (Left "折返しの境界が Reflection でない")
          p <- reference built x
          apply PAct r p
      Right ((name,c):built)
    join built composition left right = do
      a <- reference built left
      b <- reference built right
      maybe (Left "構成の境界が接合できない") Right (composition a b)
    binary built operation x a = do
      start <- reference built x
      base <- reference built a
      apply operation start base
    apply prim left right = do
      pair <- maybe (Left "作図の入力境界が接合できない") Right (tensorC left right)
      let (ins,outs) = kindsOfPrim prim
          operation = Chamber (chMu pair) 1 ins [Layer [(0,mkAtom "construction" prim)]] outs
      maybe (Left "作図の作用境界が接合できない") Right (seqC pair operation)

-- Each argument constructs X tensor Y explicitly. Their input boundaries stay
-- in order: sharing an X value requires an explicit, well-typed copy upstream.
-- This also permits a question whose arguments are themselves open chambers.
candidateSupremum :: Chamber -> [Chamber] -> Either String Chamber
candidateSupremum predicate arguments = do
  unless (wellFormed predicate && chOut predicate == [PJudge])
    (Left "候補の評価チェンバーは Q を一つ返す必要がある")
  scores <- mapM evaluate arguments
  let starts = scanl (+) 0 (map (length . chLay) scores)
  layers <- concat <$> sequence
    [map (place position) <$> scopedLayers start score
    | (position,start,score) <- zip3 [0..] starts scores]
  let depth = foldl ordinalPlus [] (map (fst . chamberGrade) scores)
      addresses = concatMap (snd . chamberGrade) scores
      combined = withGrade depth addresses (Chamber (chMu predicate) 0
        (concatMap chIn scores) layers (replicate (length scores) PJudge))
      p = PSupFamily (length scores)
      (ins,outs) = kindsOfPrim p
      supremum = Chamber (chMu predicate) 1 ins
        [Layer [(0,mkAtom "sup-family" p)]] outs
  unless (wellFormed combined) (Left "候補族の入力境界が接合できない")
  maybe (Left "候補族と上限の境界が一致しない") Right (seqC combined supremum)
  where
    evaluate argument = do
      unless (wellFormed argument) (Left "候補の構成が整形式でない")
      predicateLayers <- scopedLayers (length (chLay argument)) predicate
      maybe (Left "候補と評価チェンバーの境界が一致しない")
        Right (seqC argument (predicate {chLay=predicateLayers}))
    place position (Layer es) = Layer [(position+q,a) | (q,a) <- es]
    scopedLayers start c = mapM layer (chLay c)
      where
        target t
          | t >= 0 && t <= length (chLay c) = Right (start+t)
          | otherwise = Left "候補内の分岐先が範囲外"
        layer (Layer es) = Layer <$> mapM atom es
        atom (q,a) = do
          p <- case atomPrim a of
            PEqBranch t -> PEqBranch <$> target t
            PLtBranch t -> PLtBranch <$> target t
            PBranch t -> PBranch <$> target t
            p -> Right p
          Right (q,a {atomPrim=p})
