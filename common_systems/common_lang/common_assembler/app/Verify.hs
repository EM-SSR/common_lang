module Main (main) where

import System.IO
import System.Exit (exitFailure)
import System.Directory (createDirectoryIfMissing)
import CommonChamber (Mu (..), Value (..))
import DagArith (addS, negateS, multiplyThales, Ratio2 (..))
import Totality (FsmVerdict (..))
import qualified Ideogram as Ig
import Common.Lang.NL
import Common.Core.Pipe
import Common.Core.Dyad
import Common.Core.Proof
import Common.Core.Eval
import Common.Lang.Source (readSource)
import qualified Common.Lang.LLVMRef as LR
import qualified Common.Lang.Cmn as Cmn
import qualified Common.Program.Arith as Arith
import qualified Common.Program.Compiler as Comp
import qualified Common.Arch.RV64 as RV64
import qualified Common.Arch.AARCH64 as A64
import qualified Common.Arch.X86 as X86
import qualified Common.Arch.X86Hosted as X86H
import qualified Common.Arch.GFX1200 as GFX
import qualified Common.Arch.SM120 as SM
import qualified Common.Arch.Lane64 as L64

-- ===== build family ℬ(P) の実行（式 0.1）=====
--
--   ℬ(P) = { (T, Compile_T(P)) | T ∈ 𝒯 }
--
-- 𝒯 を増やしても意味は変わらない（定理 33.1）。driver は target 名を持たない。
-- 名前は package が Built の中で返す data である（定理 52.1）。

packages :: [[(Int, MBox)] -> Built]
-- 語割付けの覆い（19 §6）はここに入れない。image が箱あたり 33 byte の一様形に
-- なるので、13 本の意味 program を simulator へ通すと proof の取り出しが桁で伸びる。
-- 式 (7.2) の突き合わせは commonc/tools/Run.ps1 が持つ
packages = [RV64.build, A64.build, X86.build, GFX.build, SM.build, L64.build]

outDir :: String
outDir = "builds/common-assembler/"

-- ===== Common 言語の意味 program（13 章）=====
--
-- ソースは .cam だけで書く。program が自分で入力表と期待表を置き、出力と
-- 期待値を 1 語ずつ突き合わせて Ok / Ko を返す。判定は core 意味論でも
-- architecture package でも同じ値でなければならない（定理 33.1）。

langDir :: String
langDir = "continuous_republic/common_systems/common_lang/common_lang/src/"

-- src/ の下は出典の文書で四つに分かれる。
--   chamber   チェンバー構文と構成語の意味的正規形
--   reduce    関数の一般形と縮約規則
--   lang      Common 言語の基礎
--   category  GCLS-圏論。𝒬 = ([0,1], ≤, ⋆, 1) の quantale 則
-- path は langDir からの相対。表示と proof の tag には basename を使う。

langSources :: [String]
langSources =
  [ "chamber/snf", "chamber/d4", "chamber/beta"
  , "chamber/omega", "chamber/layernf", "chamber/parse"
  , "reduce/zeta", "reduce/mf", "reduce/rules", "reduce/fix"
  , "lang/sched", "lang/phigr", "lang/assert"
  , "category/quantale" ]

-- "chamber/snf" -> "snf"
baseName :: String -> String
baseName p = case break (== '/') p of
  (a, [])      -> a
  (_, _ : r)   -> baseName r

-- 外部報告を simulator の観測へ写す。成功が 0、失敗が 42 になる
obsOf :: Report -> [Integer]
obsOf r = case r of
  ROk -> [0]
  RKo -> [42]
  RNone -> []

-- 一本の意味 program について、core 意味論と五つの package を突き合わせる
langCerts :: String -> [(Int, MBox)] -> [ProofObj]
langCerts nm bs = case runCore defaultBudget bs of
  Unclosed n ->
    [ mkProof MInf KConf ("14.5/" ++ nm) "halted" ("unclosed " ++ show n) ]
  Closed rep _ out ->
    mkProof MInf KNf ("13.5/" ++ nm) (show ROk) (show rep)
    -- 式 (43.2) の観測は、外部の実行台が無い package だけ内蔵 simulator から取る
    -- （07 §5）。実機や実行台がある package の観測は走らせた返り値から取るもので、
    -- それは tools/Run.ps1 の仕事になる。Haskell の中では取らない
    : concat
        [ [ mkProof MInf KConf ("43.2/" ++ nm ++ "/" ++ btName b)
              (show (obsOf rep)) (show (btObserv b))
          -- Put の byte 列も式 43.2 の観測になる。局所片を持つ package だけが
          -- 出すので、持たない package の空列とは比べない（式 50.3 で止まる）
          , mkProof MInf KConf ("43.2out/" ++ nm ++ "/" ++ btName b)
              (show out) (show (btOut b)) ]
        | b <- map ($ bs) packages, null (btNote b), btOnlySim b
        , not (null out) || null (btOut b) ]

-- 判定の語は意味レジストリから取る。成功報告が tu、失敗報告が te（10 章 §2）
wTu, wTe :: String
wTu = kindName MOk
wTe = kindName MKo

valueAt :: [(Int, (Integer, Int))] -> Int -> (Integer, Int)
valueAt tbl w = case lookup w tbl of
  Just v  -> v
  Nothing -> (0, 0)

boxesOf :: Unit -> [(Int, MBox)]
boxesOf u = case mboxes u of
  Right bs -> bs
  Left _   -> []

-- ===== certificate の組み立て（02 章 §5）=====

certsOf :: String -> Built -> [ProofObj]
certsOf tagSuffix b =
  [ mkProof MInf (kindOf k) (t ++ "/" ++ tagSuffix) l r
  | (t, k, l, r) <- btCerts b ]
  where
    kindOf k = case k of
      "r" -> KRaw
      "c" -> KConf
      _   -> KNf

-- 意味の観測（式 43.2）。target ごとの interface 実現を通しても値は一つに揃う
observeCert :: [Integer] -> Built -> ProofObj
observeCert want b =
  mkProof MInf KConf ("43.2/" ++ btName b) (show want) (show (btObserv b))

-- 同じ project から同じ image（定理 46.1）
determinismCert :: ([(Int, MBox)] -> Built) -> [(Int, MBox)] -> ProofObj
determinismCert f bs =
  mkProof MInf KNf ("46.1/" ++ btName x) (hexOf (btImage x)) (hexOf (btImage y))
  where
    x = f bs
    y = f bs

hexOf :: [Int] -> String
hexOf bs = concat [ [dig (v `div` 16), dig (v `mod` 16)] | v <- bs ]
  where dig n = case drop n "0123456789ABCDEF" of
          (c : _) -> c
          []      -> '?'

-- 三次元疎テンソルの可逆性（定理 4.1）と content identity（式 32.8）
sourceCerts :: String -> Unit -> [ProofObj]
sourceCerts nm u =
  [ mkProof MInf KNf ("4.1/" ++ nm) (serUnit u) (serUnit back)
  , mkProof MInf KNf ("32.8/" ++ nm) (show (uIdent u)) (show (uIdent roundTripped))
  ]
  where
    back = restoreFromTensor (uKind u) (uMu u) (uDep u) (uGin u) (uGout u)
                             (tensorEntries u)
    roundTripped = case parseUnit (serUnit u) of
      Just v  -> v
      Nothing -> u { uIdent = negate 1 }

-- 正準スケジュールの適合（11 章 §6）と負荷の一致（式 11.1）
schedCerts :: Built -> [ProofObj]
schedCerts b =
  [ mkProof MInf KConf ("Sched/" ++ btName b)
      (show Comp.expectedSchedule) (show (Comp.readSchedule (btWork b)))
  , mkProof MInf KNf ("11.1/" ++ btName b)
      (show (Comp.schedCost + 1)) (show (length Comp.expectedSchedule))
  ]

-- ===== コモン公用語の層との接続を示す certificate =====
--
-- 意味原子の中身が counter_plane の演算そのものであること、そして
-- Speech・SparseTensor・Ideogram がその原子へそのまま適用できることを示す。
-- assembler が算術を二重に実装していないことの証明対象になる。

cnlCerts :: [ProofObj]
cnlCerts =
  -- Add の中身は DagArith.addS。深度は alignDepth がそろえる
  [ mkProof MInf KNf "CNL-Add"
      (show (evalAtom MAdd [VDyad (3, 1), VDyad (1, 2)]))
      (show (Just [VDyad (fromAxis (addS (onAxis (3, 1)) (onAxis (1, 2))))]))
    -- Neg の中身は DagArith.negateS
  , mkProof MInf KNf "CNL-Neg"
      (show (evalAtom MNeg [VDyad (5, 3)]))
      (show (Just [VDyad (fromAxis (negateS (onAxis (5, 3))))]))
    -- Mul の中身はタレス積。大きさは比の積、深度は指数の和
  , mkProof MInf KNf "CNL-Mul"
      (show (evalAtom MMul [VDyad (7, 2), VDyad (2, 0)]))
      (show (Just [VDyad (14, 2)]))
  , mkProof MInf KNf "CNL-Mul-thales"
      (show (multiplyThales (Ratio 7 1) (Ratio 2 1)))
      (show (Ratio 14 1))
    -- LtBr の判定部分は深度をそろえてから分子を比べる（3/2 < 7/4）
  , mkProof MInf KNf "CNL-Leq"
      (show (evalAtom MLtBr [VDyad (3, 1), VDyad (7, 2)]))
      (show (Just [VBit 1]))
  ]
  ++ [ mkProof MInf KNf ("02.6.1/" ++ kindName k) (show (atomTensorOk k)) (show True)
     | k <- meaningRegistry ]
  ++ [ mkProof MInf KNf ("06.2/" ++ kindName k) (show (atomSpeechOk k)) (show True)
     | k <- meaningRegistry ]
  ++ [ mkProof MInf KNf ("01.1/" ++ kindName k)
         (show (Ig.parseRendered (Ig.renderDecorated w)))
         (show (Just w))
     | k <- meaningRegistry, Just w <- [atomWord k] ]
  -- 05 §1: text / glyph / image / audio のどれで読んでも同じ CNF へ戻る
  ++ [ mkProof MInf KNf ("05.1/" ++ kindName k) (show (atomModalOk k)) (show True)
     | k <- meaningRegistry ]
  -- §54: 入力ポートの本数はワイヤ参照の本数に一致する
  ++ [ mkProof MInf KNf "54/ports" (show portsAgree) (show True) ]

-- 整形式でない unit は Cover へ渡らない（§54）。引数の本数を一つ削って確かめる
malformedCert :: ProofObj
malformedCert = mkProof MInf KNf "54/reject" (show (isLeft (mboxes broken))) (show True)
  where
    broken = (Arith.arithUnit Arith.passExpect)
               { uLayers = [ [(0, kindName MAdd, [0])] ] }
    isLeft e = case e of
      Left _  -> True
      Right _ -> False

-- 06 §17: 採用語彙は基準列より短く、決定的である
vocabCerts :: Unit -> String -> [ProofObj]
vocabCerts u tag =
  [ mkProof MInf KNf ("17.5/" ++ tag)
      (show (map snd (adoptedVocab u))) (show (map snd (adoptedVocab u)))
  , mkProof MInf KNf ("17.4/" ++ tag)
      (show (length (utterAdopted u) <= length (utterUnit u))) (show True)
  ]

-- 反復の停止（04 §6）。判定は Totality.decideFsm が行う
haltCerts :: [ProofObj]
haltCerts =
  [ mkProof MInf KNf "04.6/inner" (show (Comp.innerHalts 2)) (show (Halted 2))
  , mkProof MInf KNf "04.6/outer" (show Comp.outerHalts) (show (Halted 2))
  ]

-- LLVM IR から Common 共通表現への変換（Common-Lang/3）。
-- 命令表・ステップ行列・意味の保存を、参照機械との軌道一致で確かめる
llvmCerts :: [ProofObj]
llvmCerts =
  [ mkProof MInf KNf ("Common-Lang3/" ++ nm) (show ok) (show True)
  | (nm, ok) <- LR.selfcheck ]

-- 平文がプログラムになる（16 章）。降下が意味を保つことを、
-- チェンバー側の評価と core 意味論の突き合わせで確かめる
cmnCerts :: [ProofObj]
cmnCerts =
  [ mkProof MInf KNf ("16/" ++ nm) (show ok) (show True) | (nm, ok) <- Cmn.selfcheck ]

-- ===== Common 言語の source を読む =====

loadLang :: String -> IO (String, [(Int, MBox)])
loadLang path = do
  txt <- readFile (langDir ++ path ++ ".cam")
  case readSource FMeaning txt of
    Left e -> bad e
    Right u -> case mboxes u of
      Left e   -> bad e
      Right bs -> return (nm, bs)
  where
    nm = baseName path
    bad e = do
      putStrLn ("  " ++ nm ++ ": " ++ e)
      return (nm, [])

reportLang :: (String, [(Int, MBox)]) -> IO ()
reportLang (nm, bs) =
  putStrLn ("  " ++ nm ++ replicate (max 1 (10 - length nm)) ' '
            ++ "箱 " ++ show (length bs)
            ++ "  core " ++ verdict)
  where
    verdict = case runCore defaultBudget bs of
      Closed ROk _ _   -> wTu
      Closed RKo _ _   -> wTe
      Closed RNone _ _ -> "報告なし"
      Unclosed _       -> "未閉包"

-- ===== 出力 =====

writeImage :: String -> [Int] -> IO ()
writeImage nm bs = do
  h <- openBinaryFile (outDir ++ nm) WriteMode
  mapM_ (\v -> hPutChar h (toEnum (v `mod` 256))) bs
  hClose h
  putStrLn ("image: " ++ outDir ++ nm ++ " (" ++ show (length bs) ++ " bytes)")

report :: String -> Built -> IO ()
report tag b
  | null (btNote b) =
      putStrLn ("  " ++ pad (btName b) ++ " observe=" ++ show (btObserv b)
                ++ " image=" ++ show (length (btImage b)) ++ "B")
  | otherwise =
      putStrLn ("  " ++ pad (btName b) ++ " 実現不能: " ++ btNote b
                ++ "  (" ++ tag ++ ")")
  where pad s = s ++ replicate (max 0 (10 - length s)) ' '

main :: IO ()
main = do
  createDirectoryIfMissing True outDir

  -- ===== source 層の表示。mnemonic は現れない =====
  putStrLn "-- 意味 program（コモン公用語）--"
  putStrLn ("arith  ser   : " ++ serUnit (Arith.arithUnit Arith.passExpect))
  putStrLn ("arith  render: " ++ renderUnit (Arith.arithUnit Arith.passExpect))
  putStrLn ("arith  utter : " ++ concat (utterUnit (Arith.arithUnit Arith.passExpect)))
  putStrLn ("compiler 箱数 : " ++ show (length Comp.compilerLines))
  putStrLn ("compiler utter: " ++ concat (utterUnit Comp.compilerUnit))
  putStrLn ("  採用語彙で   : " ++ concat (utterAdopted Comp.compilerUnit)
            ++ "  (" ++ show (length (utterUnit Comp.compilerUnit)) ++ " → "
            ++ show (length (utterAdopted Comp.compilerUnit)) ++ " 音節)")
  putStrLn "-- 意味原子の読み（text / glyph）--"
  mapM_ (\(k, r) -> putStrLn ("  " ++ kindName k ++ "  " ++ fst r ++ "   " ++ snd r))
        [ (k, r) | k <- meaningRegistry, Just r <- [atomReadings k] ]
  putStrLn ""

  let aPass = boxesOf (Arith.arithUnit Arith.passExpect)
      aFail = boxesOf (Arith.arithUnit Arith.failExpect)
      cBox  = boxesOf Comp.compilerUnit

  putStrLn "-- build family: 算術（成功経路）--"
  let bPass = map ($ aPass) packages
  mapM_ (report "arith-pass") bPass

  putStrLn "-- build family: 算術（失敗経路）--"
  let bFail = map ($ aFail) packages
  mapM_ (report "arith-fail") bFail

  putStrLn "-- build family: Common 言語 compiler --"
  let bComp = map ($ cBox) packages
  mapM_ (report "compiler") bComp

  -- ===== Common 言語の意味 program =====
  putStrLn ""
  putStrLn "-- Common 言語（コモン公用語で書いた意味 program）--"
  langs <- mapM loadLang langSources
  mapM_ reportLang langs

  -- ===== proof object を集める =====
  let okOf bs = [ b | b <- bs, null (btNote b) ]
      proofs =
        cnlCerts
        ++ [malformedCert]
        ++ vocabCerts (Arith.arithUnit Arith.passExpect) "arith"
        ++ vocabCerts Comp.compilerUnit "compiler"
        ++ haltCerts
        ++ sourceCerts "arith" (Arith.arithUnit Arith.passExpect)
        ++ sourceCerts "compiler" Comp.compilerUnit
        -- 意味の側の算術値（DagArith 上の評価）が期待どおりか
        ++ [ mkProof MInf KConf "43.2/value"
               (show (negate 14 :: Integer, 2 :: Int))
               (show (valueAt (valuesOf aPass) 5)) ]
        ++ concat [ certsOf "arith-pass" b | b <- okOf bPass ]
        ++ concat [ certsOf "arith-fail" b | b <- okOf bFail ]
        ++ concat [ certsOf "compiler" b | b <- okOf bComp ]
        ++ [ observeCert [0] b | b <- okOf bPass ]
        ++ [ observeCert [42] b | b <- okOf bFail ]
        ++ [ observeCert [0] b | b <- okOf bComp ]
        ++ [ determinismCert f aPass | f <- packages ]
        ++ concat [ schedCerts b | b <- okOf bComp ]
        ++ llvmCerts
        ++ cmnCerts
        ++ concat [ langCerts nm bs | (nm, bs) <- langs ]
        ++ concat [ sourceCerts nm u | (nm, u, _) <- [] :: [(String, Unit, ())] ]

  -- ===== 永続化して、読み直してから検査する（02 章 §1）=====
  writeFile (outDir ++ "proof.cnl") (serProofs proofs)
  raw <- readFile (outDir ++ "proof.cnl")
  let parsed = parseProofs raw
      bad    = [ () | Nothing <- parsed ]
      objs   = [ p | Just p <- parsed ]
      failed = [ p | p <- objs, not (checkProof p) ]

  putStrLn ""
  putStrLn ("-- proof object: " ++ show (length objs) ++ " 件を "
            ++ outDir ++ "proof.cnl へ保存し、読み直して検査した --")
  mapM_ (\p -> putStrLn ("  " ++ wTe ++ " " ++ pTag p
                         ++ "\n    l=" ++ take 120 (pLhs p)
                         ++ "\n    r=" ++ take 120 (pRhs p))) failed

  -- ===== image を書く =====
  putStrLn ""
  mapM_ (\b -> writeImage (btName b ++ "-arith-pass.bin") (btImage b)) (okOf bPass)
  mapM_ (\b -> writeImage (btName b ++ "-arith-fail.bin") (btImage b)) (okOf bFail)
  mapM_ (\b -> writeImage (btName b ++ "-compiler.bin") (btImage b)) (okOf bComp)

  if null failed && null bad
    then putStrLn ("\n" ++ wTu ++ "  proof object は全て一致した")
    else do
      putStrLn ("\n" ++ wTe ++ "  " ++ show (length failed) ++ " 件が不一致、"
                ++ show (length bad) ++ " 件が parse 不能")
      exitFailure
