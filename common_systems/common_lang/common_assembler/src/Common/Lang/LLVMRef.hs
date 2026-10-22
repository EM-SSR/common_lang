{-# LANGUAGE NoImplicitPrelude #-}
module Common.Lang.LLVMRef where

import CounterConstraints
import Common.Lang.Anf
import Common.Lang.LLVM
import Common.Lang.LLVMText (readLL)
import qualified NormalizedBool as NB

-- ===== LLVM 抽象機械の参照実装と、意味の保存の検査 =====
-- doc: llvm.transform llvm.cost anf.unique
-- 参照: docs/Common-Lang/3.LLVM-IRからCommon共通表現への変換 §4、§6
--
-- 定理 4.3 は、任意の初期頂点に対し
--
--   X(1_{R_t}) = M_step^t X(1_{R_0})     (すべての t)
--
-- を主張する。左辺を出すには LLVM 側の抽象機械が要る。この module がそれを
-- 数式ではなく素朴な整数演算で書き、Common.Lang.LLVM の系と軌道をビット単位で
-- 突き合わせる。二つの実装が独立していることが検査の値打ちになるので、
-- ここでは Anf を計算に使わない。

-- ===== 参照側の状態 =====

data Ref = Ref
  { rRegs :: [(String, Int)]
  , rMem  :: [(Int, Int)]
  , rPc   :: Int
  , rPrev :: Int
  , rHalt :: Int
  , rRes  :: Int
  } deriving (Eq, Show)

refInit :: Ref
refInit = Ref [] [] 0 0 0 0

maskW :: Int -> Int -> Int
maskW w v = v .&. (shiftL 1 w - 1)

getReg :: Ref -> String -> Int
getReg r n = case lookup n (rRegs r) of
  Just v  -> v
  Nothing -> 0

putReg :: String -> Int -> Ref -> Ref
putReg n v r = r { rRegs = [ (m, x) | (m, x) <- rRegs r, m /= n ] ++ [(n, v)] }

getMem :: Ref -> Int -> Int
getMem r a = case lookup a (rMem r) of
  Just v  -> v
  Nothing -> 0

putMem :: Int -> Int -> Ref -> Ref
putMem a v r = r { rMem = [ (b, x) | (b, x) <- rMem r, b /= a ] ++ [(a, v)] }

valOf :: Layout -> Ref -> Operand -> Int
valOf lo r o = case o of
  Imm v -> maskW (lWidth lo) v
  Reg n -> maskW (lWidth lo) (getReg r n)

-- ===== 一命令 =====
--
-- 幅はどの SSA 値も w になる。zext / sext / trunc は、その w ビットの器の中で
-- 「元の幅」「先の幅」を指定する形になる（§1 の σreg の割当てがそう決めている）。

refInstr :: Program -> Layout -> Ref -> Instr -> Ref
refInstr pr lo r ins = case ins of
  IBin n op a b ->
    let (p, q) = (v a, v b) in putReg n (m (case op of
      OAnd -> p .&. q
      OOr  -> p .|. q
      OXor -> xor p q
      OAdd -> p + q
      OSub -> p - q
      OMul -> p * q)) r
  IShiftC n op a c -> putReg n (shiftBy op (v a) c) r
  -- 変数シフト量が w 以上なら、§2 のマルチプレクサはどの chi_c も立たないので
  -- 零を返す。LLVM はこの場合を poison と定めるので、式の側に合わせる
  IShiftV n op a b -> putReg n (if v b >= w then 0 else shiftBy op (v a) (v b)) r
  ICmp n op a b ->
    let (p, q) = (v a, v b)
    in putReg n (if cmp op p q then 1 else 0) r
  ISel n c a b -> putReg n (if v c .&. 1 == 1 then v a else v b) r
  IZext n a wIn  -> putReg n (maskW wIn (v a)) r
  ISext n a wIn  ->
    let x = maskW wIn (v a)
    in putReg n (m (if testBit x (wIn - 1)
                      then x .|. (shiftL 1 w - shiftL 1 wIn)
                      else x)) r
  ITrunc n a wOut -> putReg n (maskW wOut (v a)) r
  ILoad n a       -> putReg n (maskW (lWordW lo) (getMem r (addr (v a)))) r
  IStore a b      -> putMem (addr (v a)) (maskW (lWordW lo) (v b)) r
  IPhi n arms ->
    let hit = [ v val | (val, blk) <- arms, blockIndex pr blk == rPrev r ]
    in putReg n (case hit of
         (x : _) -> x
         []      -> 0) r
  where
    w = lWidth lo
    m = maskW w
    v = valOf lo r
    addr a = a .&. (shiftL 1 (lAddrW lo) - 1)
    cmp op p q = case op of
      CEq  -> p == q
      CNe  -> p /= q
      CUlt -> p < q
      CSlt -> signedOf w p < signedOf w q
    shiftBy op p c
      | c >= w    = case op of
          SAshr -> if testBit p (w - 1) then shiftL 1 w - 1 else 0
          _     -> 0
      | otherwise = case op of
          SShl  -> m (shiftL p c)
          SLshr -> shiftR p c
          SAshr -> m (if testBit p (w - 1)
                        then shiftR p c .|. (shiftL 1 w - shiftL 1 (w - c))
                        else shiftR p c)

signedOf :: Int -> Int -> Int
signedOf w p = if testBit p (w - 1) then p - shiftL 1 w else p

-- ===== 一段 =====
--
-- h = 1 なら §3 の停止ガード (1 XOR h) が全項を消すので、状態は動かない。

refStep :: Program -> Layout -> Ref -> Ref
refStep pr lo r
  | rHalt r == 1 = r
  | otherwise    = term (foldl (refInstr pr lo) r (bInstrs blk))
  where
    blk = case drop (rPc r) (pBlocks pr) of
      (b : _) -> b
      []      -> case pBlocks pr of
        (b : _) -> b
        []      -> Block "" [] (TRet (Imm 0))
    term r2 = case bTerm blk of
      TBr nm      -> r2 { rPc = blockIndex pr nm, rPrev = rPc r }
      TBrIf c t f ->
        let nm = if valOf lo r2 c .&. 1 == 1 then t else f
        in r2 { rPc = blockIndex pr nm, rPrev = rPc r }
      TSwitch val arms d ->
        let x = valOf lo r2 val
            nm = case [ b | (k, b) <- arms, k == x ] of
                   (b : _) -> b
                   []      -> d
        in r2 { rPc = blockIndex pr nm, rPrev = rPc r }
      TRet val -> r2 { rPrev = rPc r, rHalt = 1, rRes = valOf lo r2 val }

-- ===== 状態のビット表示 =====
--
-- Layout の番地割当てをそのまま使う。これが X(1_R) にあたる。

refBits :: Layout -> Ref -> [Int]
refBits lo r = [ b i | i <- [0 .. lTotal lo - 1] ]
  where
    w = lWidth lo
    b i
      | i < lMemAt lo   = bitOf (getReg r (nameAt (i `div` w))) (i `mod` w)
      | i < lPcAt lo    =
          let al = (i - lMemAt lo) `div` lWordW lo
              k  = (i - lMemAt lo) `mod` lWordW lo
          in bitOf (getMem r al) k
      | i < lPrevAt lo  = bitOf (rPc r) (i - lPcAt lo)
      | i < lHaltAt lo  = bitOf (rPrev r) (i - lPrevAt lo)
      | i == lHaltAt lo = rHalt r
      | otherwise       = bitOf (rRes r) (i - lResAt lo)
    bitOf v k = if testBit v k then 1 else 0
    nameAt k = case drop k (lNames lo) of
      (n : _) -> n
      []      -> ""

refOrbit :: Program -> Layout -> Ref -> Int -> [[Int]]
refOrbit pr lo r0 n = map (refBits lo) (take (n + 1) (iterate (refStep pr lo) r0))

-- ===== 定理 4.3 の検査 =====
--
-- 同じ初期頂点から、系の軌道と参照機械の軌道をビット単位で比べる。

orbitsAgree :: Program -> Int -> Ref -> Bool
orbitsAgree pr n r0 =
  orbit st (refBits lo r0) n == refOrbit pr lo r0 n
  where
    st = buildStep pr
    lo = layoutOf pr

-- ===== 見本の program =====

-- 直線コード: 一つの二項演算を通して返す
straight :: Int -> BinOp -> Program
straight w op = Program w 1
  [ Block "e" [IBin "r" op (Reg "a") (Reg "b")] (TRet (Reg "r")) ]

-- 比較を一つ通して返す
straightCmp :: Int -> CmpOp -> Program
straightCmp w op = Program w 1
  [ Block "e" [ICmp "r" op (Reg "a") (Reg "b")] (TRet (Reg "r")) ]

-- 分岐と phi を含む program。
--   e:  %c = icmp ult %a, %b ; br %c, t, f
--   t:  br m
--   f:  br m
--   m:  %y = phi [%a, t], [%b, f] ; ret %y
-- 小さい方を返す。pc_prev を読む phi の検査になる
minProg :: Int -> Program
minProg w = Program w 1
  [ Block "e" [ICmp "c" CUlt (Reg "a") (Reg "b")] (TBrIf (Reg "c") "t" "f")
  , Block "t" [] (TBr "m")
  , Block "f" [] (TBr "m")
  , Block "m" [IPhi "y" [(Reg "a", "t"), (Reg "b", "f")]] (TRet (Reg "y"))
  ]

-- ループ。a を 0 になるまで 1 ずつ減らし、その回数を数えて返す。
--   e:  br l
--   l:  %z = icmp eq %n, 0 ; br %z, x, s
--   s:  %n = sub %n, 1 ; %k = add %k, 1 ; br l
--   x:  ret %k
-- 単調停止フラグと omega 読みの検査になる
countDown :: Int -> Program
countDown w = Program w 1
  [ Block "e" [] (TBr "l")
  , Block "l" [ICmp "z" CEq (Reg "n") (Imm 0)] (TBrIf (Reg "z") "x" "s")
  , Block "s" [ IBin "n" OSub (Reg "n") (Imm 1)
              , IBin "k" OAdd (Reg "k") (Imm 1) ] (TBr "l")
  , Block "x" [] (TRet (Reg "k"))
  ]

-- メモリ。書いてから読み直して返す
memProg :: Int -> Program
memProg w = Program w 2
  [ Block "e" [ IStore (Reg "a") (Reg "b")
              , ILoad "y" (Reg "a") ] (TRet (Reg "y")) ]

-- 初期頂点を作る補助
withRegs :: [(String, Int)] -> Ref
withRegs rs = refInit { rRegs = rs }

-- ===== .ll の字面から通す見本 =====
--
-- minProg と同じものを LLVM IR の字面で書く。読み取りが同じ抽象構文へ落ちる
-- ことと、そこから作った系が参照機械と一致することを合わせて確かめる。

minText :: String
minText = concatMap (++ "\n")
  [ "define i3 @min(i3 %a, i3 %b) {"
  , "e:"
  , "  %c = icmp ult i3 %a, %b"
  , "  br i1 %c, label %t, label %f"
  , "t:"
  , "  br label %m"
  , "f:"
  , "  br label %m"
  , "m:"
  , "  %y = phi i3 [ %a, %t ], [ %b, %f ]"
  , "  ret i3 %y"
  , "}"
  ]

-- SSA を守った数え下げ。ループの入口で phi が二本立つ
countText :: String
countText = concatMap (++ "\n")
  [ "define i3 @count(i3 %n0) {"
  , "e:"
  , "  br label %l"
  , "l:"
  , "  %n = phi i3 [ %n0, %e ], [ %n1, %s ]"
  , "  %k = phi i3 [ 0, %e ], [ %k1, %s ]"
  , "  %z = icmp eq i3 %n, 0"
  , "  br i1 %z, label %x, label %s"
  , "s:"
  , "  %n1 = sub nsw i3 %n, 1"
  , "  %k1 = add nsw i3 %k, 1"
  , "  br label %l"
  , "x:"
  , "  ret i3 %k"
  , "}"
  ]

-- 表に無い命令。読み取りは黙って飛ばさずに誤りを上げる
unknownText :: String
unknownText = "define i8 @f(i8 %a) {\ne:\n  %r = udiv i8 %a, 2\n  ret i8 %r\n}\n"

-- ===== ドキュメント主張の実行可能証明 =====

selfcheck :: [(String, Bool)]
selfcheck =
  -- §2 ビット演算。項数は表のとおり 1 / 3 / 2 になる
  [ ("(§2 ビット演算): and / or / xor の項数は 1 / 3 / 2",
      anfSize (headAnf (andBits [p0] [q0])) == 1
      && anfSize (headAnf (orBits [p0] [q0])) == 3
      && anfSize (headAnf (xorBits [p0] [q0])) == 2)
  , ("(R1): or の正規形が NormalizedBool のメビウス係数と一致する",
      sort (anfTerms (headAnf (orBits [p0] [q0]))) == sort [[0], [1], [0, 1]]
      && [ NB.anfBit 2 NB.orFun t | t <- [1, 2, 3] ] == [1, 1, 1]
      -- 四頂点すべてで真理値表と一致する
      && and [ evalAnf (\i -> if i == 0 then x else y) (headAnf (orBits [p0] [q0]))
                 == fromInteger (NB.orFun (x + 2 * y))
             | x <- [0, 1], y <- [0, 1] ])
  , ("(§6): 桁上がり c_k の平坦展開は 2^k − 1 項で、表の上限 2^k を満たす",
      carrySizes == [1, 3, 7]
      && and [ n <= shiftL 1 k | (k, n) <- zip [1 :: Int ..] carrySizes ])
  -- 定理 4.3。二項演算・比較を全頂点で突き合わせる
  , ("(定理4.3): and / or / xor の軌道が全頂点で一致する",
      all (twoArg 3) [OAnd, OOr, OXor])
  , ("(定理4.3): add / sub / mul の軌道が全頂点で一致する",
      all (twoArg 3) [OAdd, OSub, OMul])
  , ("(定理4.3): icmp eq / ne / ult / slt の軌道が全頂点で一致する",
      all (twoCmp 3) [CEq, CNe, CUlt, CSlt])
  , ("(定理4.3): 定数シフト shl / lshr / ashr が全頂点で一致する",
      and [ orbitsAgree (shiftProg 3 op c) 2 (withRegs [("a", a)])
          | op <- [SShl, SLshr, SAshr], c <- [0 .. 3], a <- [0 .. 7] ])
  , ("(定理4.3): 変数シフトのマルチプレクサが全頂点で一致する",
      and [ orbitsAgree (shiftVarProg 3 op) 2 (withRegs [("a", a), ("s", s)])
          | op <- [SShl, SLshr, SAshr], a <- [0 .. 7], s <- [0 .. 7] ])
  , ("(定理4.3): select / zext / sext / trunc が全頂点で一致する",
      and [ orbitsAgree (convProg 3) 2 (withRegs [("a", a), ("b", b), ("c", c)])
          | a <- [0 .. 7], b <- [0 .. 7], c <- [0 .. 1] ])
  -- §2 制御フロー
  , ("(定理4.3): 分岐と phi（pc_prev の読み）が全頂点で一致する",
      and [ orbitsAgree (minProg 3) 5 (withRegs [("a", a), ("b", b)])
          | a <- [0 .. 7], b <- [0 .. 7] ])
  , ("(定理4.3): switch の多分岐マルチプレクサが全頂点で一致する",
      and [ orbitsAgree (switchProg 3) 4 (withRegs [("a", a)]) | a <- [0 .. 7] ])
  -- §2 メモリ
  , ("(定理4.3): store のあと load が同じ語を返す（a = 2 の窓）",
      and [ orbitsAgree (memProg 3) 3 (withRegs [("a", a), ("b", b)])
          | a <- [0 .. 7], b <- [0 .. 7] ])
  -- §3 停止フラグと omega 読み
  , ("(§3): 停止フラグは単調非減少で、停止 config は遷移の不動点になる",
      and [ monotone (orbit (buildStep (countDown 3)) (refBits (layoutOf (countDown 3))
                                                        (withRegs [("n", n)])) 24)
          | n <- [0 .. 7] ])
  , ("(定理4.3): ループの軌道が最後まで一致する",
      and [ orbitsAgree (countDown 3) 24 (withRegs [("n", n)]) | n <- [0 .. 7] ])
  , ("(§3): omega 読みが数え上げた回数を返す",
      [ omegaRead (buildStep (countDown 3))
                  (refBits (layoutOf (countDown 3)) (withRegs [("n", n)])) 40
      | n <- [0 .. 7] ] == [ Just n | n <- [0 .. 7] ])
  -- §6 負荷の台帳
  , ("(§6): icmp eq は積 w 因子の 1 本。平坦展開は 3^w 項、次数は w になる",
      anfDegree (cmpEq (varsAt 0 3) (varsAt 3 3)) == 3
      && anfSize (cmpEq (varsAt 0 3) (varsAt 3 3)) == 27)
  , ("(§6): 提示形の大きさは共有ノードの総項数で読める",
      sysSize (stSys (buildStep (straight 3 OAdd))) > 0
      && sysSize (stSys (buildStep (straight 3 OMul)))
           > sysSize (stSys (buildStep (straight 3 OAdd))))
  -- 定理 4.2（全域性）。表にある命令だけからなる program は必ず系になる
  , ("(定理4.2): 表の命令だけで書いた program は例外なく系へ写る",
      all (\pg -> length (stNext (buildStep pg)) == lTotal (layoutOf pg))
          [ straight 3 OMul, minProg 3, countDown 3, memProg 3, switchProg 3 ])
  -- §4.1 手順 1。.ll の字面から同じ抽象構文へ落ちる
  , (".ll の字面が手で組んだ program と同じ抽象構文へ落ちる",
      readLL 1 minText == Right (minProg 3))
  , ("(定理4.3): 字面から通した最小値 program の軌道が一致する",
      case readLL 1 minText of
        Right pg -> and [ orbitsAgree pg 5 (withRegs [("a", a), ("b", b)])
                        | a <- [0 .. 7], b <- [0 .. 7] ]
        Left _   -> False)
  , ("(定理4.3): SSA を守ったループ（phi 二本）の omega 読みが数え上げと合う",
      case readLL 1 countText of
        Right pg ->
          [ omegaRead (buildStep pg) (refBits (layoutOf pg) (withRegs [("n0", n)])) 60
          | n <- [0 .. 7] ] == [ Just n | n <- [0 .. 7] ]
          && and [ orbitsAgree pg 30 (withRegs [("n0", n)]) | n <- [0 .. 7] ]
        Left _ -> False)
  , ("(§4.1 手順2): 表に無い命令は黙って飛ばさず誤りとして上がる",
      case readLL 1 unknownText of
        Left _  -> True
        Right _ -> False)
  ]
  where
    p0 = anfVar 0
    q0 = anfVar 1
    varsAt at n = [ anfVar (at + k) | k <- [0 .. n - 1] ]

    -- 幅 3 の加算器の桁上がりを平坦化した項数
    carrySizes =
      let sys0 = emptySys 6
          (_, sysA) = addBits sys0 anfZero (varsAt 0 3) (varsAt 3 3)
          Sys _ ns = sysA
      in [ anfSize (flattenSys sysA e) | (k, e) <- zip [0 :: Int ..] ns, odd k ]

    twoArg w op = and [ orbitsAgree (straight w op) 2 (withRegs [("a", a), ("b", b)])
                      | a <- [0 .. shiftL 1 w - 1], b <- [0 .. shiftL 1 w - 1] ]
    twoCmp w op = and [ orbitsAgree (straightCmp w op) 2 (withRegs [("a", a), ("b", b)])
                      | a <- [0 .. shiftL 1 w - 1], b <- [0 .. shiftL 1 w - 1] ]

    monotone xs = and (zipWith le xs (drop 1 xs))
      where
        lo = layoutOf (countDown 3)
        le x y = idxInt x (lHaltAt lo) <= idxInt y (lHaltAt lo)

shiftProg :: Int -> ShiftOp -> Int -> Program
shiftProg w op c = Program w 1
  [ Block "e" [IShiftC "r" op (Reg "a") c] (TRet (Reg "r")) ]

shiftVarProg :: Int -> ShiftOp -> Program
shiftVarProg w op = Program w 1
  [ Block "e" [IShiftV "r" op (Reg "a") (Reg "s")] (TRet (Reg "r")) ]

-- select と型変換をひとまとめに通す
convProg :: Int -> Program
convProg w = Program w 1
  [ Block "e" [ ISel "s" (Reg "c") (Reg "a") (Reg "b")
              , IZext "z" (Reg "s") 2
              , ISext "x" (Reg "z") 2
              , ITrunc "t" (Reg "x") 2
              ] (TRet (Reg "t")) ]

switchProg :: Int -> Program
switchProg w = Program w 1
  [ Block "e" [] (TSwitch (Reg "a") [(1, "p"), (2, "q")] "d")
  , Block "p" [] (TRet (Imm 5))
  , Block "q" [] (TRet (Imm 6))
  , Block "d" [] (TRet (Imm 7))
  ]
