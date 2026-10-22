import System.Exit (exitFailure)
import RealUnit
import CounterInteger
import CounterUnits
import qualified CounterExtend
import qualified CounterDag
import qualified DagPlane
import qualified DagArith
import qualified DagInfluence
import qualified Quantale
import qualified GclsCategory
import qualified EnrichedG
import qualified ConstructCalculus
import qualified Foundations
import qualified NormalizedBool
import qualified CounterComputeSystem

main :: IO ()
main = do
  let allChecks = RealUnit.selfcheck
               ++ CounterInteger.selfcheck
               ++ CounterUnits.selfcheck
               ++ CounterExtend.selfcheck
               ++ CounterDag.selfcheck
               ++ DagPlane.selfcheck
               ++ DagArith.selfcheck
               ++ DagInfluence.selfcheck
               ++ Quantale.selfcheck
               ++ GclsCategory.selfcheck
               ++ EnrichedG.selfcheck
               ++ ConstructCalculus.selfcheck
               ++ Foundations.selfcheck
               ++ NormalizedBool.selfcheck
               ++ CounterComputeSystem.selfcheck
  mapM_ report allChecks
  let bad = [ n | (n, False) <- allChecks ]
  putStrLn ("total: " ++ show (length allChecks) ++ ", fail: " ++ show (length bad))
  if null bad then return () else exitFailure
  where
    report (name, ok) = putStrLn ((if ok then "ok   " else "FAIL ") ++ name)
