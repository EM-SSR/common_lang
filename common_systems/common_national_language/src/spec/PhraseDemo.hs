module Main where

import CounterConstraints
import CommonChamber
import Speech
import NounNet
import Metanoun

-- ===== 例文 4: SOV 文構造（02 §9）=====
-- doc: sov grammar.dag
--
-- Λ₀ = C_S ⊗ C_O、Λ₁ = C_V
-- 引数を先に構成し作用を後に置くと SOV 語順が出る（命題9.1）
atomS, atomO, atomV :: Atom
atomS = mkAtom "S" PCoordId
atomO = mkAtom "O" PCoordId
atomV = mkAtom "V" PAdd

sovSentence :: Maybe Chamber
sovSentence =
  let sW = Chamber MInf 1 [PtCoord] [Layer [(0, atomS)]] [PtCoord]
      oW = Chamber MInf 1 [PtCoord] [Layer [(0, atomO)]] [PtCoord]
      vC = Chamber MInf 1 [PtCoord, PtCoord] [Layer [(0, atomV)]] [PtCoord]
  in case tensorC sW oW of
       Just so -> seqC so vC
       Nothing -> Nothing


pronounce :: Chamber -> String
pronounce c = concat (encode c)



main :: IO ()
main = do
  putStrLn ""
  putStrLn "=== 例文 1: 単一原始文字「i を適用する」==="
  putStrLn ("  発音: " ++ pronounce sampleWordI)
  putStrLn ""
  putStrLn "=== 例文 2: 単一原始文字「beta 二分割」==="
  putStrLn ("  発音: " ++ pronounce wordBeta)
  putStrLn ""
  putStrLn "=== 例文 3: β→fold 二層合成 ==="
  putStrLn ("  音素列: " ++ show (encode wordBetaFold))
  putStrLn ("  発音: " ++ pronounce wordBetaFold)
  putStrLn ""
  putStrLn "=== 例文 4: SOV 文構造 ==="
  putStrLn ("  文節表示: " ++ case sovSentence >>= renderPhrased of
    Just s  -> s
    Nothing -> "(構成失敗)")
  putStrLn ("  発音: " ++ case sovSentence of
    Just s  -> pronounce s
    Nothing -> "(構成失敗)")
  putStrLn ""
  putStrLn "=== 例文 5: 三層チェンバー（β並列→折返並列→統合）==="
  putStrLn ("  発音: " ++ pronounce multiLayerWord)
  putStrLn ""
  putStrLn "=== 例文 6: 表現可能な名詞の全列挙 ==="
  putStrLn ("  列挙範囲: 長さ " ++ show nounKmax ++ " までの原始関係語が原点 O から"
            ++ "到達できる状態 + 観測個体の見本 + 所属する具体名詞")
  putStrLn ("  メタ名詞: " ++ concatMap (\(n, _) -> n ++ " ") nounMetaRegistry)
  -- マーカー行以降が CSV 本体。tools/DumpNounCsv.ps1 がこれを抽出して
  -- builds/nouns.csv へ書き出す
  putStrLn "-----8<----- nouns.csv -----8<-----"
  mapM_ putStrLn nounCsvLines



