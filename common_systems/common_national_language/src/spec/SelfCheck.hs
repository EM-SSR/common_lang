import System.Exit (exitFailure)
import qualified CommonChamber
import qualified JoinRank
import qualified Ideogram
import qualified SparseTensor
import qualified SentenceGrammar
import qualified InfoTheory
import qualified Totality
import qualified Multimodal
import qualified Speech
import qualified Abbrev
import qualified NounNet
import qualified Metanoun
import qualified PathAlgebra
import qualified PlainText

main :: IO ()
main = do
  let allChecks = CommonChamber.selfcheck
               ++ JoinRank.selfcheck
               ++ Ideogram.selfcheck
               ++ SparseTensor.selfcheck
               ++ SentenceGrammar.selfcheck
               ++ InfoTheory.selfcheck
               ++ Totality.selfcheck
               ++ Multimodal.selfcheck
               ++ Speech.selfcheck
               ++ Abbrev.selfcheck
               ++ NounNet.selfcheck
               ++ Metanoun.selfcheck
               ++ PathAlgebra.selfcheck
               ++ PlainText.selfcheck
  mapM_ report allChecks
  let bad = [ n | (n, False) <- allChecks ]
  putStrLn ("total: " ++ show (length allChecks) ++ ", fail: " ++ show (length bad))
  putStrLn "-- 導出された発音記号（正準番号 p_k 列）--"
  print (Speech.renderSymbols (Speech.encode Speech.sampleWordBetaFold))
  if null bad then return () else exitFailure
  where
    report (name, ok) = putStrLn ((if ok then "ok   " else "FAIL ") ++ name)
