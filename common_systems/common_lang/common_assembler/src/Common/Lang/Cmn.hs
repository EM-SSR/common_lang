{-# LANGUAGE NoImplicitPrelude #-}
module Common.Lang.Cmn where

import CounterConstraints
import CommonChamber
import PlainText hiding (showI)
import Common.Core.Pipe (MBox (..))
import Common.Core.Eval (runCore, Outcome (..), Report (..), defaultBudget)
import Common.Core.Dyad (depthsOf, depthAt)
import Common.Lang.Descend

-- ===== Common 言語の入口（16 章）=====
-- doc: plain.text plain.descend descend.sound plain.rules
--
-- 平文から実行までを一本に通す。
--
--   .cmn  --D_text-->  C_P  --Desc-->  MBox*  --[[·]]_C-->  値
--
-- 途中に文法解析は無い。D_text は E_speech の逆であり、Desc は位置から
-- ワイヤ番号を数えるだけになる（16 §5）。

-- 平文からチェンバーへ、そして走らせる形の意味 program へ
compileText :: String -> Either String (Chamber, [(Int, MBox)], [Int])
compileText txt = case readPlain txt of
  Left e  -> Left e
  Right c -> compileChamber c

compileChamber :: Chamber -> Either String (Chamber, [(Int, MBox)], [Int])
compileChamber c = case descendRunnable c of
    Left e         -> Left e
    Right (bs, out)  -> Right (c, bs, out)

-- 退避語。二値の八箱が既定値を置く先になる（16 §5.3）。本文の語の上へ出るので、
-- host はここを触ってはいけない
scratchOf :: String -> Either String Integer
scratchOf txt = case readPlain txt of
  Left e  -> Left e
  Right c -> case descendWith c of
    Left e          -> Left e
    Right (s, _, _) -> Right s

-- core 意味論で走らせ、出力境界の値を読む
runText :: Int -> String -> Either String [(Integer, Int)]
runText budget txt = case compileText txt of
  Left e -> Left e
  Right compiled -> runCompiled budget compiled

runCompiled :: Int -> (Chamber, [(Int, MBox)], [Int]) -> Either String [(Integer, Int)]
runCompiled budget (_, bs, out) = case runCore budget bs of
    Unclosed s       -> Left ("未閉包（" ++ showI s ++ " 歩）")
    Closed RKo _ _   -> Left "失敗報告"
    -- 語は分子、深度は compile 時の事実。二つを合わせて二進有理数へ戻す
    Closed _ work _  -> Right (worksOf [ depthAt (depthsOf bs) w | w <- out ] work)

-- チェンバーの側で直接評価する。降下を通さない読み
evalText :: String -> Either String [(Integer, Int)]
evalText txt = case readPlain txt of
  Left e  -> Left e
  Right c -> case evalChamber c [] of
    Just vs -> case dyadsOf vs of
      Just ds -> Right ds
      Nothing -> Left "出力境界が二進有理数でない"
    Nothing -> Left "チェンバーが走らない"

-- ===== ドキュメント主張の実行可能証明 =====
--
-- 定理 5.1 は、同じ平文がチェンバーとしても意味 program としても同じ値を返すと言う。
-- 左辺は evalChamber、右辺は core 意味論。二つは別の実装なので突き合わせに値がある。

-- 2 = 1 ⊕ 1
sampleTwo :: String
sampleTwo = textTwo

-- 3/4 = β(β(0))、0 = 1 ⊕ (⊖1)
sampleThreeQuarter :: String
sampleThreeQuarter = textThreeQuarter

-- 1 = (1 ⊕ 1) ⋆ β(0)。四つの one を立て、加算・負化・二分割・乗算を通す
sampleOneAgain :: String
sampleOneAgain = "hu hu hu hu ka, no ki ha ka, ki no ka, ki se ka, ti ka."

-- 計算に効かない文（16 §4）を挟んでも値は変わらない。
-- 廃棄で閉じた文は I → I であり、境界流を動かさない
sampleWithAside :: String
sampleWithAside = textAside ++ " " ++ textTwo

samples :: [(String, String)]
samples =
  [ ("2",    sampleTwo)
  , ("3/4",  sampleThreeQuarter)
  , ("1",    sampleOneAgain)
  , ("aside", sampleWithAside)
  ]

selfcheck :: [(String, Bool)]
selfcheck =
  [ ("(定理5.1): 平文はチェンバーとしても意味 program としても同じ値を返す",
      and [ agree t | (_, t) <- samples ])
  , ("(16 §5): 降下した値が期待どおり — 2、3/4、1",
      [ runText defaultBudget t | (_, t) <- take 3 samples ]
        == [ Right [(2, 0)], Right [(3, 2)], Right [(2, 1)] ])
  , ("(16 §4): 空の層を挟んでも値は変わらない",
      runText defaultBudget sampleWithAside == runText defaultBudget sampleTwo)
  , ("(命題11.1): 空白・改行・句読点を入れても降下は同じ箱列を出す",
      boxesOf sampleThreeQuarter
        == boxesOf "huhuka, kihaka.\n  noka\n  seka seka!")
  , ("(16 §5): 降下は名前を変えない — one は Cst になる",
      case compileText "hu ka" of
        Right (_, bs, _) -> take 1 (map snd bs) == [BCst 1 0]
        Left _           -> False)
  , ("(16 §1.1): Γ⁻ が I でない平文は降下を拒む",
      case descendRunnable (Chamber MInf 0 [PtDyad] [] [PtDyad]) of
        Left _  -> True
        Right _ -> False)

  ]
  where
    agree t = case (evalText t, runText defaultBudget t) of
      (Right a, Right b) -> a == b
      _                  -> False
    boxesOf t = case compileText t of
      Right (_, bs, _) -> Just (map snd bs)
      Left _           -> Nothing
