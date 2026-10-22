module Main where

import CommonChamber
import Common.Lang.Cml
import Common.Lang.Cmn
import Common.Core.Eval (defaultBudget)
import Common.Core.Pipe (MBox(..))
import qualified Common.Lang.Descend as D
import DagArith (QRat(..))
import qualified DagInfluence as G
import qualified PlainText as P
import qualified Common.Lang.Construction as Construction
import qualified Abbrev as A
import CounterUnits (Op(..))
import Quantale (QCoeff(..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  mapM_ (\(name,ok) -> putStrLn ((if ok then "ok " else "FAIL ") ++ name)) checks
  if all snd checks then pure () else exitFailure

checks :: [(String,Bool)]
checks =
  [ ("finite ordinal before and after omega", addOrdinal [3] [0,1] == [0,1]
       && addOrdinal [0,1] [3] == [3,1] && omegaDepth [4,2] == [0,0,1])
  -- 表が伸びると Σ_base が右へ広がり Σ_V が縮む。既存の語の音節は動かない
  -- 一音節の名前は sigma_67 で終わる。そこから先は三音節へ伸びるので、
  -- 採用語彙の字母は二音節ぶん残り続ける（10 §4、06 §17.4）
  , ("legacy phonetic alphabet remains reserved", length primitiveTable == 69
      && sigmaV == words "be bo pa pi pu pe po"
      && nameOfIdx 62 == ["bu"] && nameOfIdx 63 == ["ku","ke","ke"])
  , ("legacy atom pronunciations remain unchanged", take 47 (map fst primitiveTable) == words
      "id cid i j neg beta fold add mul dup drop agr agru agrz mulj phij addd negd leqd one dupd drpd node load store ok pi omop omcl sup resr resl leqj hom pij trc rhom rhop epnt rid refr refd rcmp act binv fixl theta")
  -- 22 §4 で表へ移した語。追加は末尾に限る
  , ("extended atoms take the tail of the registry", drop 47 (map fst primitiveTable) == words
      ("bis omga nodei nodej reli relj ko put readr readw div boundary chainadd "
       ++ "rgat rgcap rgcup rgout rgbd rgin rgov rgadj rgpath"))
  , ("canonical CML syllables use their own generator registry",
      and [generatorCode (phoneOfIdx (unitBase+k)) == Right k | k <- [0..37]])
  , ("canonical CML arithmetic runs", case readCml (source "2 0 0" "3"
      "0 0 ke 1 0\n0 0 ke 1 0\n1 0 ko") of
      Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(2,0)]
      _ -> False)
  , ("documented CML Dyad star and phi example is typed",
      case readCml (unlines ["mu i","d 2 0 0","in d d","out b","0 0 me","1 0 mi"]) of
        Right c -> evalChamber (cmlChamber c) [VDyad (1,0),VDyad (1,0)] == Just [VBit 1]
          && decodeCml [] (codeCml c) == Right c
        _ -> False)
  , ("CML encoding exactly matches equation 2.1 and the published example",
      case readCml (unlines ["mu i","d 2 0 0","in d d","out b","0 0 me","1 0 mi"]) of
        Right c -> codeCml c == [3,2,0,0,2,1,0,3,3,4,0,0,25,0,1,0,23,0,-1]
        _ -> False)
  , ("CML aliases of the same primitive have one canonical code",
      case mapM (readCml . source "1 0 0" "d" . ("0 0 " ++))
             ["Cst 1 0","cst 1 0","ke 1 0","0 1 0"] of
        Right (c:cs) -> all ((== codeCml c) . codeCml) cs
          && all (\d -> decodeCml [] (codeCml d) == Right d) (c:cs)
        _ -> False)
  , ("CML comments begin at the hash without requiring whitespace",
      case readCml (unlines ["#123","mu i#grade","d 1 0 0#depth","in","out d",
                            "0 0 Cst 1 0#constant"]) of
        Right c -> evalChamber (cmlChamber c) [] == Just [VDyad (1,0)]
        _ -> False)
  , ("canonical Dyad star and phi run after closed construction",
      case readCml (source "3 0 0" "b" "0 0 Cst 1 0\n0 0 Cst 1 0\n1 0 me\n2 0 mi") of
        Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(1,0)]
        _ -> False)
  , ("canonical observe accepts the lowered judge representation",
      case readCml (source "3 0 0" "b" "0 0 Cst 1 1\n1 0 agru\n2 0 observe") of
        Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(1,0)]
        _ -> False)
  , ("canonicalization does not widen explicitly typed judge operations",
      isLeft (readCml (source "2 0 0" "b" "0 0 Cst 1 0\n1 0 phij"))
      && isLeft (readCml (source "2 0 0" "g" "0 0 Cst 1 0\n0 0 Cst 1 0\n1 0 mulj")))
  , ("canonical conditional branches target source layers",
      and [case readCml (source "4 0 0" "" (unlines
          ["0 0 Cst 1 0","0 0 Cst " ++ show right ++ " 0","1 0 " ++ branch ++ " 3","2 0 Ko","3 0 Ok"])) of
        Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right []
        _ -> False | (branch,right) <- [("EqBr",1::Int),("LtBr",2)]])
  , ("canonical unconditional branch skips failure", case readCml
      (source "3 0 0" "" "0 0 Br 2\n1 0 Ko\n2 0 Ok") of
      Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right []
      _ -> False)
  , ("branch outside source is rejected", case readCml
      (source "1 0 0" "" "0 0 Br 9") of
      Right c -> isLeft (compileChamber (cmlChamber c))
      Left _ -> True)
  , ("canonical type six is Mono", readPort "6" == Right PtMono && portCode PtMono == 6)
  , ("reference types do not collide with extension types",
      and [readPort (show (8+k)) == Right (PtReference k) && portCode (PtReference k) == 8+k | k <- [0..20]]
      && all (<0) (map portCode [PtRational,PtChain,PtRegion]))
  , ("all canonical basepoints support bisection and inverse",
      and [case generator 20 [k] of
        Right beta -> case evalPrim (atomPrim beta) [VCoord (3,5,2)] of
          Just values -> case generator 21 [k] of
            Right inverse -> evalPrim (atomPrim inverse) values == Just [VCoord (3,5,2)]
            _ -> False
          _ -> False
        _ -> False | k <- [0..8]])
  , ("extension without adopted pronunciation is rejected",
      case P.writeWith P.baseLexicon pointTransport of Left _ -> True; _ -> False)
  , ("adopted vocabulary extension retains old pronunciations",
      let old = take 1 A.testTable
      in case A.extendVocab 2 A.testChannel A.testDelP A.testInsP old A.testRecs of
        Right extended -> take (length old) extended == old && length extended > length old
          && and [A.prefixFree u [v | (d,v) <- extended, d /= c] | (c,u) <- extended]
        Left _ -> False)
  , ("cml bytecode round trip", case readCml two of
       Right c -> decodeCml [] (codeCml c) == Right c
       _ -> False)
  , ("cml lowering computes 2", case readCml two of
       Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(2,0)]
       _ -> False)
  , ("extended depth encoding preserves every coefficient", case readCml two of
       Right c -> let wide = c { cmlDepth = [2,0,0,0,0] }
                  in decodeCmlDepth 5 [] (codeCml wide) == Right wide
       _ -> False)
  , ("extended depth is not truncated", case readCml two of
       Right c -> take 6 (codeCml (c { cmlDepth = [2,0,0,0,1] })) == [3,2,0,0,0,1]
       _ -> False)
  , ("declared depth is checked", isLeft (readCml (source "1 0 0" "d" "0 0 one\n0 0 one\n1 0 addd")))
  , ("canonical reference expands", case readCml two of
       Right c -> case readCmlWith [c] (source "2 0 0" "d" "0 0 #0") of
         Right d -> evalChamber (cmlChamber d) [] == Just [VDyad (2,0)]
         _ -> False
       _ -> False)
  -- Level 0 の領域関係と演算（22 表の V18）
  , ("region relations and operations run from CML",
      case (readCml (unlines ["mu i","d 2 0 0","in","out region","addr",
                              "0 0 region 1 2 3","0 0 region 3 4","1 0 union"]),
            readCml (unlines ["mu i","d 2 0 0","in","out b","addr",
                              "0 0 region 1 2 3","0 0 region 2","1 0 contains"]),
            readCml (unlines ["mu i","d 2 0 0","in","out b","addr",
                              "0 0 region 1 2 3","0 0 region 3 4","1 0 overlaps"])) of
        (Right u, Right c, Right o) ->
          evalChamber (cmlChamber u) [] == Just [VRegion [1,2,3,4]]
          && evalChamber (cmlChamber c) [] == Just [VBit 1]
          && evalChamber (cmlChamber o) [] == Just [VBit 1]
        _ -> False)
  -- ext と acc は縮約行列の層へそのまま降りる（22 表の V23）
  , ("ext and acc lower to the reduction atoms",
      case (readCml (unlines ["mu i","d 2 0 0","in","out d","addr",
                              "0 0 Cst 3 0","0 0 Cst 5 0","1 0 ext 0 0"]),
            readCml (unlines ["mu i","d 2 0 0","in","out d","addr",
                              "0 0 Cst 3 0","0 0 Cst 5 0","1 0 acc 0 0"])) of
        (Right e, Right a) ->
          (compileChamber (cmlChamber e) >>= runCompiled defaultBudget) == Right [(15,0)]
          && (compileChamber (cmlChamber a) >>= runCompiled defaultBudget) == Right [(8,0)]
        _ -> False)
  , ("boundary squared is zero", case readCml (source "3 0 0" "chain"
       "0 0 simplex 0 1 2 3\n1 0 boundary\n2 0 boundary") of
       Right c -> evalChamber (cmlChamber c) [] == Just [VChain []]
       _ -> False)
  , ("reference aliases and definition order do not change indices",
      case (readCml (source "1 0 0" "d" "0 0 Cst 1 0"),
            readCml (source "1 0 0" "d" "0 0 Cst 2 0")) of
        (Right a,Right b) -> and
          [case readCmlWith refs (source "1 0 0" "d" "0 0 #1") of
            Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(2,0)]
            _ -> False | refs <- [[a,b],[b,a,a],[a,a,b,b]]]
        _ -> False)
  , ("negative references are rejected", isLeft (generatorCode "#-1"))
  , ("chamber references ignore duplicate aliases",
      let a = Chamber MInf 1 [] [Layer [(0,mkAtom "first" (PCstD 1 0))]] [PtDyad]
          alias = a {chLay=[Layer [(0,mkAtom "renamed" (PCstD 1 0))]]}
          b = Chamber MInf 1 [] [Layer [(0,mkAtom "second" (PCstD 2 0))]] [PtDyad]
      in refC [alias,b,a] 1 == Just b && refC [a] (-1) == Nothing)
  , ("lowering validates the declared output boundary",
      isLeft (compileChamber (Chamber MInf 1 [] [Layer [(0,primOne)]] [PtBit])))
  , ("source branches relocate across expanded references",
      case readCml (source "2 0 0" "" "0 0 one\n1 0 drpd") of
        Right ref -> case readCmlWith [ref]
          (source "5 0 0" "" "0 0 #0\n1 0 Br 3\n2 0 Ko\n3 0 Ok") of
          Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right []
          _ -> False
        _ -> False)
  , ("branches inside references relocate to their own body",
      case readCml (source "3 0 0" "" "0 0 Br 2\n1 0 Ko\n2 0 Ok") of
        Right ref -> case readCmlWith [ref]
          (source "5 0 0" "" "0 0 one\n1 0 drpd\n2 0 #0") of
          Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right []
          _ -> False
        _ -> False)
  , ("parallel reference expansion tracks changing wire widths",
      case readCml (unlines ["mu i","d 2 0 0","in d","out d",
                            "0 0 dupd","1 0 addd"]) of
        Right ref -> case readCmlWith [ref] (source "4 0 0" "d"
          "0 0 Cst 3 0\n0 0 Cst 5 0\n1 0 #0\n1 1 negd\n2 0 addd") of
          Right c -> evalChamber (cmlChamber c) [] == Just [VDyad (1,0)]
            && (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(1,0)]
          _ -> False
        _ -> False)
  , ("parallel closed references preserve output order", case readCml two of
      Right ref -> case readCmlWith [ref] (source "3 0 0" "d"
        "0 0 #0\n0 0 Cst 9 0\n1 0 addd") of
        Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(11,0)]
        _ -> False
      _ -> False)
  , ("beta inverse at arbitrary dyadic base", case evalPrim (PBetaAt 3 2) [VDyad (5,3)] of
       Just vs -> case evalPrim (PInvAt 3 2) vs of
         Just [VDyad (n,d)] -> n * 8 == 5 * 2^d
         _ -> False
       _ -> False)
  , ("noun composition retains order",
      let start = evalPrim PNode []
          apply ops = foldl (\vs op -> vs >>= evalPrim (PNodeUnit op)) start ops
      in apply [I,J] /= apply [J,I])
  , ("copy at infinite depth is rejected", isLeft (readCml (source "2 0 0" "n n" "0 0 node\n1 0 copy 7")))
  , ("Trace and Q remain linear at every memory grade",
      and [not (wellFormed (Chamber mu 1 [t] [Layer [(0,mkAtom "copy" (PCopy t))]] [t,t]))
        && not (wellFormed (Chamber mu 1 [t] [Layer [(0,mkAtom "discard" (PDiscard t))]] []))
        | mu <- [M0,M1,M2,MInf], t <- [PtUnit,PJudge]])
  , ("copyable value types keep explicit structural operations",
      and [wellFormed (Chamber mu 1 [t] [Layer [(0,mkAtom "copy" (PCopy t))]] [t,t])
        && wellFormed (Chamber mu 1 [t] [Layer [(0,mkAtom "discard" (PDiscard t))]] [])
        | mu <- [M0,M1,M2,MInf], t <- [PtCoord,PtRefl,PtDyad,PtBit,PtMono]])
  , ("division lowers to exact rational", case readCml (source "2 0 0" "q" "0 0 cst 2 0\n0 0 cst 3 0\n1 0 div") of
       Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(2,0),(3,0)]
       _ -> False)
  , ("division by zero reports failure", case readCml (source "2 0 0" "q" "0 0 cst 2 0\n0 0 cst 0 0\n1 0 div") of
       Right c -> isLeft (compileChamber (cmlChamber c) >>= runCompiled defaultBudget)
       _ -> False)
  , ("judge operations preserve noncommutative words and signs",
      and [judgeAgreement op a b | op <- [PMulJ,PSupJ,PResRJ,PResLJ], a <- judges, b <- judges])
  , ("chosen judge word survives subsequent multiplication",
      and [judgePipeline a b c | a <- judges, b <- judges, c <- take 3 judges])
  , ("hom retains noncommutative words and signs through meets",
      and [homAgreement a b | a <- judges, b <- judges])
  , ("candidate-family supremum executes from CML", case readCml (source "3 0 0" "g"
      "0 0 Cst 1 2\n0 0 Cst 3 2\n1 0 agru\n1 1 agru\n2 0 sup-family 2") of
      Right c -> sameJudge (VJudge (QRat 3 4) [] 1)
        (compileChamber (cmlChamber c) >>= runCompiled defaultBudget)
      _ -> False)
  , ("empty candidate family has bottom degree", case readCml (source "1 0 0" "g" "0 0 sup-family 0") of
      Right c -> sameJudge (VJudge (QRat 0 1) [] 1)
        (compileChamber (cmlChamber c) >>= runCompiled defaultBudget)
      _ -> False)
  , ("candidate family rejects wrong input types and negative size",
      isLeft (readCml (source "2 0 0" "g" "0 0 Cst 1 0\n1 0 sup-family 1"))
      && isLeft (readCml (source "1 0 0" "g" "0 0 sup-family -1")))
  , ("runtime influence construction and observation", case readCml (source "3 0 0" "d"
       "0 0 cst 1 2\n0 0 cst 3 2\n1 0 profile 2\n2 0 weight 1") of
       Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(3,2)]
       _ -> False)
  , ("runtime influence survives directional construction", case readCml (source "4 0 0" "d"
       "0 0 cst 1 2\n0 0 cst 3 2\n1 0 profile 2\n2 0 nodei\n3 0 weight 0") of
       Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget) == Right [(1,2)]
       _ -> False)
  , ("runtime influence remains in output", case readCml (source "2 0 0" "n"
       "0 0 cst 1 2\n0 0 cst 3 2\n1 0 profile 2") of
       Right c -> (compileChamber (cmlChamber c) >>= runCompiled defaultBudget)
         == Right [(1,0),(0,0),(0,0),(1,0),(2,0),(1,2),(0,0),(0,0),(1,0),(3,2),(0,0),(0,0),(1,0)]
       _ -> False)
  , ("runtime influence reaches a directional rational degree",
      case readCml (source "4 0 0" "g"
        "0 0 Cst 3 2\n0 0 Cst 1 2\n0 0 Cst 1 2\n0 0 Cst 3 2\n1 0 profile 2\n1 2 profile 2\n2 0 relation 0 1\n3 0 hom") of
        Right c -> sameJudge (VJudge (QRat 1 3) [] 1)
          (compileChamber (cmlChamber c) >>= runCompiled defaultBudget)
        _ -> False)
  , ("runtime hom agrees with profile semantics including zeros",
      and [case readCml (source "3 0 0" "g" (unlines
          (["0 0 Cst " ++ show n ++ " 2" | n <- a ++ b]
          ++ ["1 0 profile 2","1 2 profile 2","2 0 hom"]))) of
        Right c -> case evalChamber (cmlChamber c) [] of
          Just [expected] -> sameJudge expected (compileChamber (cmlChamber c) >>= runCompiled defaultBudget)
          _ -> False
        _ -> False | a <- [[0,0],[0,4],[1,3],[3,1],[4,4]] :: [[Int]],
                     b <- [[0,0],[0,4],[1,3],[3,1],[4,4]]])
  , ("landmark images determine the transported point", transportCheck)
  , ("adopted utterance executes the geometric construction", utteranceTransportCheck)
  , ("landmark correspondence transports the bisection construction", constructionTransportCheck)
  , ("bisection closure and all reflections execute as constructions", all closureConstructionCheck [0..7])
  , ("closure depth preserves order around omega",
      let atom p = Layer [(0,mkAtom "depth" p)]
          c layers = Chamber MInf 0 [] layers []
      in constructionDepth (c [atom PBisectPoint,atom PFixPoint]) == [0,1]
         && constructionDepth (c [atom PFixPoint,atom PBisectPoint]) == [1,1]
         && constructionDepth (c [atom PFixPoint,atom PFixPoint]) == [0,2])
  , ("cml closure retains ordinal depth through encoding", case readCml (unlines
      ["mu i","d 0 1 0","in 0 0","out 0","0 0 close-bisection"]) of
      Right c -> decodeCml [] (codeCml c) == Right c
      _ -> False)
  , ("internal chamber retains source grade through serialization",
      case readCml (unlines ["mu i","d 0 1 0","in c c","out c","addr omega",
                             "0 0 close-bisection"]) of
        Right doc -> let c = cmlChamber doc in chamberGrade c == ([0,1],[1])
          && parse (ser c) == Just c
        _ -> False)
  , ("invalid internal grade is rejected on deserialization",
      let c = Chamber MInf 1 [] [Layer [(0,primOne)]] [PtDyad]
      in parse (ser (withGrade [-1] [] c)) == Nothing
        && parse (ser (withGrade [1] [9] c)) == Nothing)
  , ("lowering preserves the closure grade alongside executable code",
      case readCml (unlines ["mu i","d 0 1 0","in","out d","addr omega",
                             "0 0 Cst 0 0","1 0 fix-at 3 0"]) of
        Right doc -> case compileChamber (cmlChamber doc) of
          Right compiled@(c,_,_) -> chamberGrade c == ([0,1],[1])
            && runCompiled defaultBudget compiled == Right [(3,0)]
          _ -> False
        _ -> False)
  , ("adopted closure words preserve grade and choose the matching address",
      case readCml (unlines ["mu i","d 0 1 0","in","out d","addr omega",
                             "0 0 Cst 0 0","1 0 fix-at 3 0"]) of
        Right doc -> case sigmaV of
          a:b:_ ->
            let c = cmlChamber doc
                other = withGrade [0,1] [2] c
                table = [([a],other),([b],c)] ++ P.baseLexicon
            in case P.writeWith table c of
              Right text -> take 2 text == b && case P.readWith table text of
                Right restored -> chamberGrade restored == ([0,1],[1])
                  && (compileChamber restored >>= runCompiled defaultBudget) == Right [(3,0)]
                _ -> False
              _ -> False
          _ -> False
        _ -> False)
  , ("internal composition uses ordinal rather than integer depth",
      case (readCml (unlines ["mu i","d 0 1 0","in c c","out c","addr omega",
                             "0 0 close-bisection"]),
            readCml (unlines ["mu i","d 3 0 0","in c c","out c c",
                             "0 0 R 0","1 0 R 0","2 0 R 0"]),
            readCml (unlines ["mu i","d 3 0 0","in c","out c",
                             "0 0 R 0","1 0 R 0","2 0 R 0"])) of
        (Right closure,Right before,Right after) ->
          fmap chamberGrade (seqC (cmlChamber before) (cmlChamber closure)) == Just ([0,1],[1])
          && fmap chamberGrade (seqC (cmlChamber closure) (cmlChamber after)) == Just ([3,1],[1])
          && fmap chamberGrade (tensorC (cmlChamber before) (cmlChamber closure)) == Just ([0,1],[1])
        _ -> False)
  ]
  where
    source depth out body = unlines ["mu i", "d " ++ depth, "in", "out " ++ out, body]
    two = source "2 0 0" "d" "0 0 one\n0 0 one\n1 0 addd"
    isLeft (Left _) = True
    isLeft _ = False

judges :: [Value]
judges = [VJudge q w s | q <- [QRat 0 1,QRat 1 2,QRat 1 1],
                       (w,s) <- [([],1),([I],1),([J],1),([I,J],1),([J,I],-1)]]

judgeAgreement :: Prim -> Value -> Value -> Bool
judgeAgreement op a b = case evalPrim op [a,b] of
  Just [expected] -> sameJudge expected $ do
    (slots,acc) <- D.descAtom 31 (mkAtom "test" op) [D.K a,D.K b] D.emptyAcc
    executeJudge slots acc
  _ -> False

judgePipeline :: Value -> Value -> Value -> Bool
judgePipeline a b c = case evalPrim PSupJ [a,b] >>= \vs -> evalPrim PMulJ (vs ++ [c]) of
  Just [expected] -> sameJudge expected $ do
    (slots,acc) <- D.descAtom 31 primSupJ [D.K a,D.K b] D.emptyAcc
    (out,acc1) <- D.descAtom 31 primMulJ (slots ++ [D.K c]) acc
    executeJudge out acc1
  _ -> False

homAgreement :: Value -> Value -> Bool
homAgreement a b = case (coefficient a,coefficient b) of
  (Just x,Just y) ->
    let u = VNoun x [x,y]
        v = VNoun y [y,x]
    in case evalPrim PHomQ [u,v] of
      Just [expected] -> sameJudge expected $ do
        (out,acc) <- D.descAtom 31 primHomQ [D.K u,D.K v] D.emptyAcc
        executeJudge out acc
      _ -> False
  _ -> False
  where
    coefficient (VJudge (QRat n d) w s) = Just (QCoeff (fromIntegral n) (if d == 2 then 1 else 0) w s)
    coefficient _ = Nothing

executeJudge :: D.Wires -> D.Acc -> Either String [(Integer,Int)]
executeJudge [slot] acc = do
  (out,acc1) <- D.matSlot slot acc
  let store a (i,w) = let (address,a1) = D.cstB i 0 a
                     in snd (D.push (BStore address w) a1)
      acc2 = foldl store acc1 (zip [0..] out)
      (_,acc3) = D.push BOk acc2
  runCompiled defaultBudget (Chamber MInf 0 [] [] [],D.boxesOfAcc acc3,out)
executeJudge _ _ = Left "判定値の出口数が不正"

sameJudge :: Value -> Either String [(Integer,Int)] -> Bool
sameJudge (VJudge (QRat n d) w s) (Right [(a,0),(b,0),(m,0),(e,0),(sg,0)]) =
  a*d == n*b && b > 0 && (m,e) == D.dinf w && sg == toInteger s
sameJudge _ _ = False

landmarkImages :: [[(Integer,Int)]]
landmarkImages = [[(1,0),(0,0),(0,0)],[(1,1),(1,1),(0,0)],[(0,0),(0,0),(1,0)]]

pointInput :: Chamber
pointInput = Chamber MInf 1 [] [Layer [(0,mkAtom "point" (PCstD 1 2)),
  (0,mkAtom "point" (PCstD 1 2)),(0,mkAtom "point" (PCstD 1 1))]] (replicate 3 PtDyad)

pointTransport :: Chamber
pointTransport = Chamber MInf 1 (replicate 3 PtDyad)
  [Layer [(0,mkAtom "transport" (PTransport landmarkImages))]] (replicate 3 PtDyad)

transportCheck :: Bool
transportCheck = case seqC pointInput pointTransport of
  Nothing -> False
  Just c -> case compileChamber c >>= runCompiled defaultBudget of
    Right result -> map asRat result == G.starApply [QRat 1 4,QRat 1 4,QRat 1 2]
      (G.GMor (map (map asRat) landmarkImages))
      && and (zipWith equalDyad result [(3,3),(1,3),(1,1)])
    _ -> False
  where
    asRat (n,d) = let divisor = gcd n (2^d) in QRat (n `div` divisor) (2^d `div` divisor)
    equalDyad (n,d) (m,e) = n*2^e == m*2^d

utteranceTransportCheck :: Bool
utteranceTransportCheck = case sigmaV of
  (pointWord:moveWord:_) ->
    let lexicon = ([pointWord],pointInput):([moveWord],pointTransport):P.baseLexicon
        utterance = pointWord ++ P.sepP ++ moveWord ++ P.sepP
    in case P.readWith lexicon utterance >>= compileChamber >>= runCompiled defaultBudget of
      Right result -> length result == 3 && and (zipWith equalDyad result [(3,3),(1,3),(1,1)])
      _ -> False
  _ -> False
  where equalDyad (n,d) (m,e) = n*2^e == m*2^d

constructionTransportCheck :: Bool
constructionTransportCheck =
  let point operations = Chamber MInf (length operations) []
        [Layer [(0,mkAtom "construction" operation)] | operation <- operations] [PtCoord]
      source = [("a",point [PTrace,PEndpoint]),("b",point [PTrace,PRhoM,PEndpoint])]
      target = [("a",point [PTrace,PUnit I,PEndpoint]),("b",point [PTrace,PUnit I,PRhoM,PEndpoint])]
      drawing = Construction.Construction
        [("start",Construction.Landmark "a"),("base",Construction.Landmark "b"),
         ("middle",Construction.Bisect "start" "base"),
         ("result",Construction.Bisect "middle" "base")] "result"
  in case (Construction.realize source drawing,Construction.realize target drawing) of
    (Right original,Right moved) ->
      case (evalChamber original [],evalChamber moved [],compileChamber moved >>= runCompiled defaultBudget) of
        (Just [VCoord a],Just [VCoord b],Right [(r,d),(w,e)]) ->
          b == reflAct 3 a && d == e && b == (fromInteger r,fromInteger w,d)
          && length [() | Layer xs <- chLay moved, (_,atom) <- xs, atomPrim atom == PBisectPoint] == 2
        _ -> False
    _ -> False

closureConstructionCheck :: Int -> Bool
closureConstructionCheck k =
  let closed operations output = Chamber MInf (length operations) []
        [Layer [(0,mkAtom "construction" p)] | p <- operations] output
      images = [("a",closed [PTrace,PEndpoint] [PtCoord]),
                ("b",closed [PTrace,PUnit I,PEndpoint] [PtCoord]),
                ("r",closed [PReflection k] [PtRefl])]
      drawing = Construction.Construction
        [("start",Construction.Landmark "a"),("base",Construction.Landmark "b"),
         ("middle",Construction.Bisect "start" "base"),
         ("limit",Construction.CloseBisection "middle" "base"),
         ("result",Construction.Reflect "r" "limit")] "result"
      expected = reflAct k (0,1,0)
  in case Construction.realize images drawing of
    Right c -> parse (ser c) == Just c && evalChamber c [] == Just [VCoord expected]
      && case compileChamber c >>= runCompiled defaultBudget of
        Right [(r,d),(w,e)] -> d == e && (fromInteger r,fromInteger w,d) == expected
        _ -> False
    _ -> False
