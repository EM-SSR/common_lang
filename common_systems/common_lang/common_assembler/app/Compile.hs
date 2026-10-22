module Main (main) where

import System.IO
import System.Environment (getArgs)
import Data.Bits (testBit)
import System.Exit (exitFailure)
import Control.Monad (foldM)
import Data.Char (isSpace)
import qualified Multimodal as Modal
import CommonChamber (Mu (..))
import Common.Lang.NL
import Common.Lang.Source
import Common.Lang.Anf (Sys (..), sysSize)
import Common.Lang.LLVM
import Common.Lang.LLVMText (readLL)
import qualified Common.Lang.Cmn as Cmn
import qualified Common.Lang.Cml as Cml
import PlainText (readWith, baseLexicon, readLexicon, writeWith, groupBy2)
import CommonChamber (chLay, chamberGrade, chOut, evalChamber)
import Common.Core.Pipe
import Common.Core.Proof
import Common.Core.Eval
import qualified Common.Arch.RV64 as RV64
import qualified Common.Arch.AARCH64 as A64
import qualified Common.Arch.X86 as X86
import qualified Common.Arch.X86Hosted as X86H
import qualified Common.Arch.GFX1200 as GFX
import qualified Common.Arch.SM120 as SM
import qualified Common.Arch.Lane64 as L64

-- ===== Common Assembler の compile driver =====
--
--   common <src.cam> [-t <target>] [-o <image>] [-p <proof>] [--list]
--   common <src.cam> --run [--steps N]
--
-- 何も指定しなければ、登録済みの全 target で build して結果を並べる。
-- --run は core 意味論 ⟦P⟧_C で走らせる（14 章）。package を
-- 一つも使わないので、package の実装が途中でも意味 program を検算できる。
-- target 名は package が Built の中で返す data なので、driver は名前の表を持たない
-- （定理 52.1）。-t は返ってきた名前との一致で選ぶ。

packages :: [[(Int, MBox)] -> Built]
packages =
  [RV64.build, A64.build, X86.build, X86H.build, X86H.buildW, GFX.build, SM.build, L64.build]

data Opts = Opts
  { oSrc    :: String
  , oTarget :: String
  , oImage  :: String
  , oProof  :: String
  , oList   :: Bool
  , oRun    :: Bool
  , oCheckPar :: Bool
  , oSteps  :: Int
  , oLlvm   :: Bool
  , oAddrW  :: Int
  , oIn     :: [(String, Int)]
  , oSim    :: Bool
  , oLex    :: String
  , oRefs   :: [String]
  , oGrammar :: [(String,String)]
  , oFrames :: Int
  }

defaults :: Opts
defaults = Opts "" "" "" "" False False False defaultBudget False 2 [] True "" [] [] 0

parseArgs :: [String] -> Either String Opts
parseArgs = go defaults
  where
    go o [] | null (oSrc o) && not (oList o) && oFrames o <= 0 = Left "source ファイルを指定する"
            | otherwise = Right o
    go o ("-t" : v : r) = go o { oTarget = v } r
    go o ("-o" : v : r) = go o { oImage  = v } r
    go o ("-p" : v : r) = go o { oProof  = v } r
    go o ("--list" : r) = go o { oList = True } r
    go o ("--run"  : r) = go o { oRun = True } r
    go o ("--check-par" : r) = go o { oCheckPar = True } r
    go o ("--llvm" : r) = go o { oLlvm = True } r
    -- 式 (43.2) の観測は package 内蔵の simulator が取る。image を出すだけなら要らない。
    -- 大きい意味 program では simulator が compile より重くなる
    go o ("--no-sim" : r) = go o { oSim = False } r
    go o ("--lex" : v : r) = go o { oLex = v } r
    go o ("--ref" : v : r) = go o { oRefs = oRefs o ++ [v] } r
    go o ("--frames" : v : r) = case reads v of
      [(k, "")] -> go o { oFrames = k } r
      _         -> Left ("--frames は整数: " ++ v)
    go o ("--emit-grammar" : mode : path : r)
      | mode `elem` ["text","glyph","image","audio"] =
          go o {oGrammar=oGrammar o ++ [(mode,path)]} r
      | otherwise = Left "--emit-grammar は text、glyph、image、audio のいずれか"
    go o ("--addr" : v : r) = case reads v of
      [(k, "")] -> go o { oAddrW = k } r
      _         -> Left ("--addr は整数: " ++ v)
    go o ("--in" : v : r) = case bindings v of
      Just bs -> go o { oIn = oIn o ++ bs } r
      Nothing -> Left ("--in は name=value の並び: " ++ v)
    go o ("--steps" : v : r) = case reads v of
      [(k, "")] -> go o { oSteps = k } r
      _         -> Left ("--steps は整数: " ++ v)
    go o (a : r)
      | take 1 a == "-" = Left ("読めない option: " ++ a)
      | otherwise       = go o { oSrc = a } r

usage :: String
usage = unlines
  [ "common <src.cam> [-t <target>] [-o <image>] [-p <proof>] [--list]"
  , ""
  , "  -t   target を一つ選ぶ。省略すると全 target を build する"
  , "  -o   実行イメージの書き出し先"
  , "  -p   proof object の書き出し先"
  , "  --list  登録済みの target と意味レジストリを並べる"
  , "  --run   core 意味論で走らせる。package を使わない"
  , "  --check-par  逐次と層並列を突き合わせる。層分解を疑うときだけ使う"
  , "  --steps 歩数上限。既定は 1000000"
  , "  --no-sim  式 (43.2) の観測を取らない。image だけを出すときに使う"
  , ""
  , "  .cmn は Common 言語（平文）、.cam は Common Assembler として読む"
  , "  --lex  採用語彙表（音節列、tab、正準チェンバー）"
  , "  --ref  正準参照する .cml。依存するファイルを先に指定する（複数可）"
  , "  --emit-grammar 種類 ファイル  意味を保持する構成表現を保存（text/glyph/image/audio）"
  , "  --frames N  --ref で読んだ三つの .cml を動画として N こま観測する（05 §13）"
  , "  .cch/.cimg/.caud は、それぞれ保存した構成表現として読み込む"
  , ""
  , "  --llvm  .ll を読み、Common-Lang/3 の 𝒯 でステップ行列へ写して走らせる"
  , "  --addr  メモリ窓のアドレス幅 a。既定は 2"
  , "  --in    初期頂点。name=value をコンマで並べる"
  ]

-- "a=3,b=5" を読む
bindings :: String -> Maybe [(String, Int)]
bindings = go [] . splitOn ','
  where
    go acc [] = Just (reverse acc)
    go acc (t : ts) = case break (== '=') t of
      (n, '=' : v) | not (null n) -> case reads v of
        [(k, "")] -> go ((n, k) : acc) ts
        _         -> Nothing
      _ -> Nothing

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, [])      -> [a]
  (a, _ : rest) -> a : splitOn c rest

-- ===== target 一覧と意味レジストリ =====

listAll :: IO ()
listAll = do
  putStrLn "-- target --"
  mapM_ (\b -> putStrLn ("  " ++ btName b)) (map ($ probe) packages)
  putStrLn "-- 意味レジストリ（音節名 / 引数の本数）--"
  mapM_ (\k -> putStrLn ("  " ++ kindName k ++ "  " ++ show (arityOf k)
                         ++ "  " ++ show k))
        meaningRegistry
  where
    -- 名前を引き出すためだけの空 program。どの package も空列を受ける
    probe = []

-- ===== 出力 =====

writeImage :: String -> [Int] -> IO ()
writeImage nm bs = do
  h <- openBinaryFile nm WriteMode
  mapM_ (\v -> hPutChar h (toEnum (v `mod` 256))) bs
  hClose h

report :: Bool -> Built -> IO ()
report sim b
  | null (btNote b) =
      putStrLn ("  " ++ pad (btName b) ++ " image=" ++ show (length (btImage b))
                ++ "B  observe=" ++ (if sim then show (btObserv b) else "-")
                ++ "  proof=" ++ show (length (btCerts b)))
  | otherwise =
      putStrLn ("  " ++ pad (btName b) ++ " 実現不能: " ++ btNote b)
  where pad s = s ++ replicate (max 0 (10 - length s)) ' '

main :: IO ()
main = do
  argv <- getArgs
  case parseArgs argv of
    Left e -> do
      putStrLn ("common: " ++ e)
      putStr usage
      exitFailure
    Right o
      | oList o -> listAll
      | oFrames o > 0 && null (oSrc o) -> video o
      | oLlvm o -> llvm o
      | endsWith ".cmn" (oSrc o) -> cmn o
      | endsWith ".cml" (oSrc o) -> cmn o
      | any (`endsWith` oSrc o) [".cch",".cgly",".cimg",".caud"] -> cmn o
      | oFrames o > 0 -> video o
      | otherwise -> run o

-- ===== 動画（05 §13）=====
--
-- 動画は三つのチェンバーで持つ。初期状態 X_0、遷移 F、観測 R。
--
--   X_0 : I -> S、  F : S -> S、  R : S -> A
--
-- こま数は表示の都合であって、同一性は (X_0, F, R) の側にある。だから
-- 何こま観測しても同じ意味対象になる。
--
--   common --frames N --ref x0.cml --ref f.cml --ref r.cml

video :: Opts -> IO ()
video o = do
  refs <- mapM readFile (oRefs o)
  case foldM readRef [] refs of
    Left e -> stop e
    Right rs -> case map Cml.cmlChamber rs of
      [x0, f, r]
        | not (Modal.videoWellFormed (Modal.Video x0 f r)) ->
            stop "動画の三つのチェンバーの境界が繋がらない"
        | otherwise -> case Modal.videoFrames (oFrames o) (Modal.Video x0 f r) of
            Nothing -> stop "動画のこまが観測できない"
            Just frames -> mapM_ shot (zip [0 :: Int ..] frames)
      _ -> stop "--frames は --ref を三つ要る（初期状態・遷移・観測）"
  where
    readRef prior text = do
      ref <- Cml.readCmlWith prior text
      Right (prior ++ [ref])
    shot (k, frame) = putStrLn ("こま " ++ show k ++ " : " ++ show frame)
    stop e = do
      putStrLn ("common: " ++ e)
      exitFailure

-- ===== Common 言語の入口（16 章）=====
--
-- .cmn は平文そのものになる。欄も行構文も語境界も無い。読みは E_speech の逆で
-- あり、降下は位置からワイヤ番号を数えるだけになる。
--
--   .cmn  --D_text-->  C_P  --Desc-->  MBox*  --[[.]]_C-->  値

cmn :: Opts -> IO ()
cmn o = do
  txt <- readFile (oSrc o)
  lexResult <- if null (oLex o) then pure (Right baseLexicon)
               else readLexicon <$> readFile (oLex o)
  refs <- mapM readFile (oRefs o)
  let source
        | endsWith ".cml" (oSrc o) = Cml.cmlChamber <$>
            (foldM readReference [] refs >>= (\rs -> Cml.readCmlWith rs txt))
        | endsWith ".cch" (oSrc o) = maybe (Left "意味構成表現が不正") Right (Modal.pText txt)
        | endsWith ".cgly" (oSrc o) = maybe (Left "字体の構成表現が不正") Right (Modal.pGlyph txt)
        | endsWith ".cimg" (oSrc o) = case reads txt of
            [(img,rest)] | all isSpace rest -> maybe (Left "画像文法の境界が不正") Right (Modal.pImage img)
            _ -> Left "画像文法の構成表現が不正"
        | endsWith ".caud" (oSrc o) = case reads txt of
            [(audio,rest)] | all isSpace rest -> maybe (Left "音声文法の境界が不正") Right (Modal.pAudio audio)
            _ -> Left "音声文法の構成表現が不正"
        | otherwise = lexResult >>= (\lex0 -> readWith lex0 txt)
      readReference prior text = do
        ref <- Cml.readCmlWith prior text
        Right (prior ++ [ref])
  case source of
    Left e -> do
      putStrLn ("common: " ++ oSrc o ++ ": " ++ e)
      exitFailure
    Right c -> do
      mapM_ (\(mode,path) -> writeFile path (case mode of
        "image" -> show (Modal.fImage c)
        "audio" -> show (Modal.fAudio c)
        "glyph" -> Modal.fGlyph c
        _ -> Modal.fText c)) (oGrammar o)
      let pronunciation = lexResult >>= (\lex0 -> writeWith lex0 c)
      putStrLn ("source : " ++ oSrc o ++ "  層 " ++ show (length (chLay c))
                ++ "  d係数=" ++ show (fst (chamberGrade c)))
      putStrLn ("境界   : " ++ show (chOut c))
      case pronunciation of
        Right speech -> putStrLn ("平文   : " ++ groupBy2 8 (take 160 speech)
                         ++ (if length speech > 160 then " …" else ""))
        Left reason -> putStrLn ("平文   : " ++ reason)
      -- 降下の表は Dyad 層の生成元だけを持つ（16 §5、定理 5.1 の仮定）。
      -- 名詞層と判定層の箱は降下先を持たないので、その場合はチェンバーの側で走らせる。
      -- 二つの読みが両方とも動くことが定理 5.1 の突き合わせになる
      case Cmn.compileChamber c of
        Right (_, bs, _out) -> do
          putStrLn ("降下   : 箱 " ++ show (length bs)
                    ++ (case Cmn.scratchOf txt of
                          Right sw -> "  退避語 " ++ show sw
                          Left _   -> ""))
          -- 降下した箱は .cam と同じ MBox 列なので、build family も同じになる。
          -- x86_64-hosted で比べると commonc の出力と byte 単位で突き合わせられる
          -- （19 式 5.1）。-t を付ければ他の target へも落ちる
          let built = [ f bs | f <- packages ]
              chosen | null (oTarget o) = built
                     | otherwise = [ b | b <- built, btName b == oTarget o ]
          case oImage o of
            "" -> return ()
            _ | null chosen -> do
                  putStrLn ("common: 未登録の target: " ++ oTarget o)
                  exitFailure
            nm -> case [ b | b <- chosen, null (btNote b) ] of
              [b] -> do
                writeImage nm (btImage b)
                putStrLn ("image  : " ++ nm ++ " (" ++ show (length (btImage b))
                          ++ " bytes)  observe="
                          ++ (if oSim o then show (btObserv b) else "-"))
              _   -> putStrLn "common: -o は target を一つに絞ったときだけ使える（-t を付ける）"
          case Cmn.runCompiled (oSteps o) (c, bs, _out) of
            Left e   -> do
              putStrLn ("run    : " ++ e)
              exitFailure
            Right ds -> mapM_ shown (zip [0 :: Int ..] ds)
        Left e -> do
          putStrLn ("降下   : " ++ e)
          case evalChamber c [] of
            Just vs -> do
              mapM_ shownV (zip [0 :: Int ..] vs)
              -- 降下の表に無い箱を含む平文は意味 program にならない（16 §5 の表）。
              -- チェンバーの側では走るので値は出るが、image は出せない
              case oImage o of
                "" -> return ()
                _  -> exitFailure
            Nothing -> do
              putStrLn "eval   : チェンバーが走らない"
              exitFailure
  where
    shown (i, (x, d)) =
      putStrLn ("  出力[" ++ show i ++ "] = " ++ show x
                ++ (if d == 0 then "" else "/2^" ++ show d))
    shownV (i, v) = putStrLn ("  出力[" ++ show i ++ "] = " ++ show v)


endsWith :: String -> String -> Bool
endsWith suf s = drop (length s - length suf) s == suf

-- ===== LLVM IR からの入口（Common-Lang/3）=====
--
-- 状態ビットの割当て（§1）、命令表（§2）、pc マルチプレクサと単調停止フラグ
-- によるステップ行列（§3）を通し、X_t = M_step^t X_0 の omega 読みを出す。

llvm :: Opts -> IO ()
llvm o = do
  txt <- readFile (oSrc o)
  case readLL (oAddrW o) txt of
    Left e -> do
      putStrLn ("common: " ++ oSrc o ++ ": " ++ e)
      exitFailure
    Right pg -> do
      let st = buildStep pg
          lo = stLayout st
          x0 = initVertex lo (oIn o)
      putStrLn ("source : " ++ oSrc o ++ "  ブロック " ++ show (length (pBlocks pg))
                ++ "  w=" ++ show (pWidth pg) ++ "  a=" ++ show (pAddrW pg))
      putStrLn ("state  : σ=" ++ show (lTotal lo)
                ++ "  SSA 値 " ++ show (length (lNames lo))
                ++ "  pc 幅 " ++ show (lPcW lo))
      putStrLn ("系     : ノード " ++ show (length (sNodes (stSys st)))
                ++ "  項数 " ++ show (sysSize (stSys st)))
      case omegaRead st x0 (oSteps o) of
        Just v  -> putStrLn ("omega  : 停止  結果 " ++ show v)
        Nothing -> do
          putStrLn ("omega  : " ++ show (oSteps o) ++ " 歩で停止フラグが立たない")
          exitFailure

-- 名前つきの初期値を状態ビットへ置く。書かない値は零になる
initVertex :: Layout -> [(String, Int)] -> [Int]
initVertex lo binds =
  [ bitAt i | i <- [0 .. lTotal lo - 1] ]
  where
    w = lWidth lo
    bitAt i
      | i < lMemAt lo =
          let n = nameAt (i `div` w)
          in case lookup n binds of
               Just v  -> if testBit v (i `mod` w) then 1 else 0
               Nothing -> 0
      | otherwise = 0
    nameAt k = case drop k (lNames lo) of
      (n : _) -> n
      []      -> ""

-- ===== use の展開（12 §1）=====
--
-- 一行の指示を、指したファイルの中身へ置き換える。ラベルの解決は展開の後に
-- 一度だけ走るので、前段と後段は同じ名前空間を持つ。
--
-- 差し込みは深さ優先で、同じファイルを二度差し込むと止める。二度目は
-- 箱を二重に置くので、ラベルの重複として後から出るより早い方がよい。

expandUses :: [FilePath] -> FilePath -> IO (Either String String)
expandUses seen path
  | path `elem` seen = pure (Left ("use が同じファイルを二度指す: " ++ path))
  | otherwise = do
      txt <- readFile path
      parts <- mapM line (splitOn '\n' txt)
      pure (unlines <$> sequence parts)
  where
    line raw = case words (takeWhile (/= '#') raw) of
      ["use", target] -> expandUses (path : seen) (dirOf path ++ target)
      _               -> pure (Right raw)

-- パスの区切りは host が決めるので、最後に現れた方を採る
dirOf :: FilePath -> FilePath
dirOf path = case [ k | (k, c) <- zip [0 ..] path, c == '/' || c == '\\' ] of
  [] -> ""
  ks -> take (last ks + 1) path

run :: Opts -> IO ()
run o = do
  loaded <- expandUses [] (oSrc o)
  txt <- case loaded of
    Left e -> do
      putStrLn ("common: " ++ oSrc o ++ ": " ++ e)
      exitFailure
    Right t -> pure t
  -- 12 §3.1 の res(s) = min は先頭の定義を採る。二つ目を指したつもりの参照が
  -- 黙って一つ目へ向き、実行されない箱を読むと ⟨0,0⟩ が返る（14 §1）。
  -- use で二つのファイルを繋ぐと名前空間が一つになるので、ここで止める
  case duplicateLabels txt of
    [] -> pure ()
    bad -> do
      putStrLn ("common: " ++ oSrc o ++ ": ラベルの二重定義: " ++ unwords bad)
      exitFailure
  case readSource FMeaning txt of
    Left e -> do
      putStrLn ("common: " ++ oSrc o ++ ": " ++ e)
      exitFailure
    Right unit -> case mboxes unit of
      Left e -> do
        putStrLn ("common: " ++ oSrc o ++ ": " ++ e)
        exitFailure
      Right bs -> do
        putStrLn ("source : " ++ oSrc o ++ "  箱 " ++ show (length bs)
                  ++ "  ν=" ++ show (uIdent unit))
        case duplicateLabels txt of
          [] -> return ()
          ls -> putStrLn ("警告   : ラベルが重複している（res は先頭を採る）: "
                          ++ unwords ls)
        putStrLn ("utter  : " ++ concat (utterUnit unit))
        if oRun o then core o bs else do
         let built = [ f bs | f <- packages ]
             chosen | null (oTarget o) = built
                    | otherwise = [ b | b <- built, btName b == oTarget o ]
         if null chosen
           then do
             putStrLn ("common: 未登録の target: " ++ oTarget o)
             exitFailure
           else do
             putStrLn "-- build family --"
             mapM_ (report (oSim o)) chosen
             emit o chosen unit

-- ===== core 意味論での実行（14 章 §4）=====
--
-- 観測は外部報告 o と作業領域 W の対になる。報告が te（失敗）か、
-- 上限で閉じなかった場合は終了コードを立てる

core :: Opts -> [(Int, MBox)] -> IO ()
-- 既定は層並列で走らせる。層の中の箱は互いに依存しないので、これが意味の側の
-- 実行になる（02 §1、定理2.1）。
--
-- --check-par を付けたときだけ逐次でも走らせて突き合わせる。常時二本走らせると
-- 歩数の多い program では時間が二倍になり、比較まで両方の状態を保つ分の領域も要る。
-- 層分解の正しさは program の大きさに依らないので、突き合わせは小さい program で
-- 一度取れば足りる。
core o bs
  | oCheckPar o && runCore (oSteps o) bs /= runCorePar (oSteps o) bs = do
      putStrLn "run    : 逐次と層並列の結果が一致しない。層分解が壊れている"
      exitFailure
core o bs = case (runCorePar (oSteps o) bs, ()) of
  (Unclosed s, _) -> do
    putStrLn ("run    : 未閉包（" ++ show s ++ " 歩で c = n に達しない）")
    exitFailure
  (Closed rep work out, _) -> do
    putStrLn ("run    : 報告 " ++ nameOf rep ++ "  非零の語 " ++ show (length work)
              ++ "  層 " ++ show (length (scheduleLayers bs))
              ++ "  最大幅 " ++ show (foldr max 0 (layerWidths bs)))
    case out of
      [] -> return ()
      _  -> putStrLn ("out    : " ++ show (length out) ++ " byte  "
                      ++ map (toEnum . (`mod` 256)) out)
    mapM_ (\(i, (v, d)) -> putStrLn ("  w[" ++ show i ++ "] = " ++ show v
                                     ++ (if d == 0 then "" else "/2^" ++ show d)))
          (take 64 work)
    case rep of
      RKo -> exitFailure
      _   -> return ()
  where
    nameOf r = case r of
      ROk   -> kindName MOk ++ "（成功）"
      RKo   -> kindName MKo ++ "（失敗）"
      RNone -> "なし"


emit :: Opts -> [Built] -> Unit -> IO ()
emit o chosen unit = do
  let ok = [ b | b <- chosen, null (btNote b) ]
  case oImage o of
    "" -> return ()
    nm -> case ok of
      [b] -> do
        writeImage nm (btImage b)
        putStrLn ("image  : " ++ nm ++ " (" ++ show (length (btImage b)) ++ " bytes)")
      _   -> putStrLn "common: -o は target を一つに絞ったときだけ使える（-t を付ける）"
  case oProof o of
    "" -> return ()
    nm -> do
      let ps = sourceCerts unit
               ++ concat [ certsOf (btName b) b | b <- ok ]
      writeFile nm (serProofs ps)
      putStrLn ("proof  : " ++ nm ++ " (" ++ show (length ps) ++ " 件)")

-- 三次元疎テンソルの可逆性（定理 4.1）と content identity（式 32.8）
sourceCerts :: Unit -> [ProofObj]
sourceCerts u =
  [ mkProof MInf KNf "4.1" (serUnit u) (serUnit back)
  , mkProof MInf KNf "32.8" (show (uIdent u)) (show (uIdent again))
  ]
  where
    back = restoreFromTensor (uKind u) (uMu u) (uDep u) (uGin u) (uGout u)
                             (tensorEntries u)
    again = case parseUnit (serUnit u) of
      Just v  -> v
      Nothing -> u { uIdent = negate 1 }

certsOf :: String -> Built -> [ProofObj]
certsOf tag b =
  [ mkProof MInf (kindOf k) (t ++ "/" ++ tag) l r | (t, k, l, r) <- btCerts b ]
  where
    kindOf k = case k of
      "r" -> KRaw
      "c" -> KConf
      _   -> KNf
