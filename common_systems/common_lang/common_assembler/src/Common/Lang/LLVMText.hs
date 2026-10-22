{-# LANGUAGE NoImplicitPrelude #-}
module Common.Lang.LLVMText where

import CounterConstraints
import CommonChamber (splitOnC)
import Common.Lang.LLVM

-- ===== .ll の字面から IR の抽象構文へ =====
-- doc: llvm.transform llvm.state
-- 参照: docs/Common-Lang/3.LLVM-IRからCommon共通表現への変換 §4.1 手順 1
--
-- §4.1 の手順 1 は「各 SSA 値に番地を割り当てる」から始まる。その前段、
-- ファイルの字面を命令の並びへ直す部分がこの module になる。数式は無い。
--
-- 読める範囲は §2 の表にある命令に限る。表に無い命令へ当たったら、その行を
-- 名前つきで返して止まる。黙って読み飛ばすと 𝒯 の像が静かに間違うので、
-- 未知の命令は必ず誤りとして上げる（§4.1 手順 2 が言う「表への追加」を
-- 人が行うための入口になる）。
--
-- 幅は一つに揃える。§1 の σreg はどの SSA 値にも同じ幅を配るので、
-- ファイル中に現れた整数型の最大幅を w に採る。zext / sext / trunc は
-- その器の中で元の幅と先の幅を指定する形になる。

-- ===== 字句 =====

-- ';' から行末までがコメントになる
dropComment :: String -> String
dropComment ln = case splitOnC ';' ln of
  (x : _) -> x
  []      -> ""

untab :: Char -> Char
untab c = if c == '\t' then ' ' else c

-- ',' と '(' ')' '[' ']' '{' '}' '*' は独立した字句にする
tokensOf :: String -> [String]
tokensOf ln =
  [ t | t <- splitOnC ' ' (concatMap spread (map untab (dropComment ln))), not (null t) ]
  where
    spread c = if c `elem` ",()[]{}*" then [' ', c, ' '] else [c]

-- ===== 型と operand =====

-- "i8" -> Just 8
intWidth :: String -> Maybe Int
intWidth t = case t of
  ('i' : ds) | not (null ds) && all isDigit ds -> Just (readNat ds)
  _ -> Nothing

isDigit :: Char -> Bool
isDigit c = c >= '0' && c <= '9'

readNat :: String -> Int
readNat = foldl (\a c -> a * 10 + (fromEnum c - fromEnum '0')) 0

-- 整数の literal。負号を許す
readInt :: String -> Maybe Int
readInt s = case s of
  ('-' : ds) | not (null ds) && all isDigit ds -> Just (negate (readNat ds))
  ds         | not (null ds) && all isDigit ds -> Just (readNat ds)
  _ -> Nothing

-- "%a" -> Reg "a"、"5" -> Imm 5
operandOf :: String -> Maybe Operand
operandOf s = case s of
  ('%' : n) | not (null n) -> Just (Reg n)
  _ -> case readInt s of
    Just v  -> Just (Imm v)
    Nothing -> if s == "true" then Just (Imm 1)
               else if s == "false" then Just (Imm 0)
               else Nothing

labelOf :: String -> Maybe String
labelOf s = case s of
  ('%' : n) | not (null n) -> Just n
  _ -> Nothing

-- ===== 行の分類 =====

data Line
  = LDefine
  | LEnd
  | LLabel String
  | LInstr Instr
  | LTerm Term
  deriving (Eq, Show)

-- add / sub などに付く nsw、nuw、exact、inbounds は意味を変えないので落とす
dropFlags :: [String] -> [String]
dropFlags = filter (`notElem` ["nsw", "nuw", "exact", "inbounds", "align", "nounwind"])

binOpOf :: String -> Maybe BinOp
binOpOf t = lookup t
  [("and", OAnd), ("or", OOr), ("xor", OXor)
  ,("add", OAdd), ("sub", OSub), ("mul", OMul)]

shiftOpOf :: String -> Maybe ShiftOp
shiftOpOf t = lookup t [("shl", SShl), ("lshr", SLshr), ("ashr", SAshr)]

cmpOpOf :: String -> Maybe CmpOp
cmpOpOf t = lookup t [("eq", CEq), ("ne", CNe), ("ult", CUlt), ("slt", CSlt)]

-- 一行を読む。読めない行は Left で行の中身を返す
lineOf :: [String] -> Either String (Maybe Line)
lineOf ts0 = case dropFlags ts0 of
  [] -> Right Nothing
  ts -> case ts of
    ("define" : _) -> Right (Just LDefine)
    ["}"]          -> Right (Just LEnd)
    [nm] | last nm == ':' -> Right (Just (LLabel (init nm)))
    ("br" : "label" : l : _) -> case labelOf l of
      Just nm -> Right (Just (LTerm (TBr nm)))
      Nothing -> bad
    ("br" : _ : c : "," : "label" : t : "," : "label" : f : _) ->
      case (operandOf c, labelOf t, labelOf f) of
        (Just co, Just tl, Just fl) -> Right (Just (LTerm (TBrIf co tl fl)))
        _ -> bad
    ("ret" : _ : v : _) -> case operandOf v of
      Just vo -> Right (Just (LTerm (TRet vo)))
      Nothing -> bad
    ("ret" : ["void"]) -> Right (Just (LTerm (TRet (Imm 0))))
    ("switch" : _ : v : "," : "label" : d : "[" : rest) ->
      case (operandOf v, labelOf d) of
        (Just vo, Just dl) -> case switchArms rest of
          Just arms -> Right (Just (LTerm (TSwitch vo arms dl)))
          Nothing   -> bad
        _ -> bad
    ("store" : _ : val : "," : _ : addr : _) ->
      case (operandOf val, operandOf addr) of
        (Just vo, Just ao) -> Right (Just (LInstr (IStore ao vo)))
        _ -> bad
    (('%' : n) : "=" : rhs) -> instrOf n rhs
    _ -> bad
  where
    bad = Left (unwordsS ts0)

    -- "i8 1 , label %p i8 2 , label %q ]"
    switchArms rest = go (filter (/= "]") rest) []
      where
        go [] acc = Just (reverse acc)
        go (_ : k : "," : "label" : l : more) acc =
          case (readInt k, labelOf l) of
            (Just kv, Just lv) -> go more ((kv, lv) : acc)
            _                  -> Nothing
        go _ _ = Nothing

    instrOf n rhs = case rhs of
      (op : ty : a : "," : b : _)
        | Just bop <- binOpOf op, Just _ <- intWidth ty ->
            two (\x y -> IBin n bop x y) a b
        | Just sop <- shiftOpOf op, Just _ <- intWidth ty ->
            case (operandOf a, operandOf b) of
              (Just ao, Just (Imm c)) -> Right (Just (LInstr (IShiftC n sop ao c)))
              (Just ao, Just bo)      -> Right (Just (LInstr (IShiftV n sop ao bo)))
              _                       -> bad
      ("icmp" : c : ty : a : "," : b : _)
        | Just cop <- cmpOpOf c, Just _ <- intWidth ty ->
            two (\x y -> ICmp n cop x y) a b
      ("select" : _ : c : "," : _ : a : "," : _ : b : _) ->
        case (operandOf c, operandOf a, operandOf b) of
          (Just co, Just ao, Just bo) -> Right (Just (LInstr (ISel n co ao bo)))
          _ -> bad
      ("zext" : ty : a : "to" : _) -> conv IZext ty a
      ("sext" : ty : a : "to" : _) -> conv ISext ty a
      ("trunc" : _ : a : "to" : ty2 : _) -> case (operandOf a, intWidth ty2) of
        (Just ao, Just wOut) -> Right (Just (LInstr (ITrunc n ao wOut)))
        _ -> bad
      ("load" : _ : "," : _ : a : _) -> case operandOf a of
        Just ao -> Right (Just (LInstr (ILoad n ao)))
        Nothing -> bad
      ("phi" : ty : rest) | Just _ <- intWidth ty -> case phiArms rest [] of
        Just arms -> Right (Just (LInstr (IPhi n arms)))
        Nothing   -> bad
      _ -> bad
      where
        two f a b = case (operandOf a, operandOf b) of
          (Just ao, Just bo) -> Right (Just (LInstr (f ao bo)))
          _ -> bad
        conv f ty a = case (operandOf a, intWidth ty) of
          (Just ao, Just wIn) -> Right (Just (LInstr (f n ao wIn)))
          _ -> bad

    -- "[ %a , %t ] , [ %b , %f ]"
    phiArms ts acc = case ts of
      [] -> Just (reverse acc)
      ("," : more) -> phiArms more acc
      ("[" : v : "," : l : "]" : more) ->
        case (operandOf v, labelOf l) of
          (Just vo, Just lv) -> phiArms more ((vo, lv) : acc)
          _                  -> Nothing
      _ -> Nothing

unwordsS :: [String] -> String
unwordsS ts = case ts of
  []       -> ""
  (x : xs) -> foldl (\a t -> a ++ " " ++ t) x xs

-- ===== ファイル一つ =====
--
-- 幅は現れた整数型の最大値になる。§1 の σreg はどの SSA 値にも同じ幅を配る。

widthOfText :: String -> Int
widthOfText txt =
  foldl max 1 [ w | ln <- splitOnC '\n' txt, t <- tokensOf ln, Just w <- [intWidth t] ]

-- 読み取り。a はメモリ窓のアドレス幅で、.ll には書かれないので外から渡す
readLL :: Int -> String -> Either String Program
readLL addrW txt = case collect (splitOnC '\n' txt) [] of
  Left e   -> Left e
  Right ls -> case blocksOf ls "" [] [] of
    Left e   -> Left e
    Right bs -> if null bs then Left "ブロックが一つも無い"
                           else Right (Program w addrW bs)
  where
    w = widthOfText txt
    collect [] acc = Right (reverse acc)
    collect (ln : more) acc = case lineOf (tokensOf ln) of
      Left e         -> Left ("表に無い命令: " ++ e)
      Right Nothing  -> collect more acc
      Right (Just x) -> collect more (x : acc)

    -- ラベル行で区切る。最初のラベルより前の命令は先頭ブロックへ入れる
    blocksOf [] nm ins acc =
      Right (reverse (if null ins then acc else Block nm (reverse ins) (TRet (Imm 0)) : acc))
    blocksOf (x : more) nm ins acc = case x of
      LDefine   -> blocksOf more nm ins acc
      LEnd      -> blocksOf more nm ins acc
      LLabel l  -> blocksOf more l [] acc
      LInstr i  -> blocksOf more nm (i : ins) acc
      LTerm t   -> blocksOf more "" [] (Block nm (reverse ins) t : acc)
