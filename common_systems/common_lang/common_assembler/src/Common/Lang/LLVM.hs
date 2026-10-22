{-# LANGUAGE NoImplicitPrelude #-}
module Common.Lang.LLVM where

import CounterConstraints
import Common.Lang.Anf

-- ===== LLVM IR から Common 共通表現への変換 𝒯 =====
-- doc: llvm.state llvm.table step.matrix llvm.transform llvm.cost
-- 参照: docs/Common-Lang/3.LLVM-IRからCommon共通表現への変換
--
-- 仕事は一つに絞られる。任意の .ll を、Common の共通表現（縮約行列とその
-- 正規形）へ写す写像 𝒯 を定め、それが全域で意味を保つことを示す。
--
--   X' = X ⊕ (1⊕h) ⊕_B χ_{β(B)}(pc) (F_B(X) ⊕ X)        §3
--   X_t = M_step^t X_0                                     §3
--
-- 実質は §2 の命令表であり、残りは既に証明済みの同型の適用になる。
--
-- この module が持たないもの: .ll の字句解析。IR の抽象構文はここで型として
-- 置き、字面の読み取りは Common.Lang.LLVMText が担う。

-- ===== 1. 状態空間 =====
--
--   State = {0,1}^σreg × {0,1}^{8·2^a} × pc × pc_prev × h × res
--
-- 番地は下の Layout が一度だけ決める。σ は全ビット数になる。
-- メモリ窓の有限性はパラメータであり、停止する実行が触るアドレスは有限なので、
-- 十分な a を取ればこの空間の中で厳密になる。

data Layout = Layout
  { lNames  :: [String]   -- SSA 値の名前。番地は並び順で決まる
  , lWidth  :: Int        -- w: SSA 値のビット幅
  , lAddrW  :: Int        -- a: メモリ窓のアドレス幅
  , lWordW  :: Int        -- メモリ 1 語のビット幅
  , lPcW    :: Int        -- ⌈log₂|B|⌉
  , lMemAt  :: Int
  , lPcAt   :: Int
  , lPrevAt :: Int
  , lHaltAt :: Int
  , lResAt  :: Int
  , lTotal  :: Int        -- σ
  } deriving (Eq, Show)

-- ブロック数から pc の幅を出す。1 ブロックでも 1 ビットは要る
pcWidthOf :: Int -> Int
pcWidthOf n = go 1 2
  where go k cap = if cap >= n then k else go (k + 1) (cap * 2)

mkLayout :: [String] -> Int -> Int -> Int -> Int -> Layout
mkLayout names w a wordW nBlocks = Layout
  { lNames = names, lWidth = w, lAddrW = a, lWordW = wordW, lPcW = pw
  , lMemAt = memAt, lPcAt = pcAt, lPrevAt = prevAt
  , lHaltAt = haltAt, lResAt = resAt, lTotal = resAt + w }
  where
    pw     = pcWidthOf nBlocks
    memAt  = length names * w
    pcAt   = memAt + shiftL 1 a * wordW
    prevAt = pcAt + pw
    haltAt = prevAt + pw
    resAt  = haltAt + 1

-- 番地。名前が無ければ Nothing
regAt :: Layout -> String -> Maybe Int
regAt lo n = go 0 (lNames lo)
  where
    go _ [] = Nothing
    go k (x : xs) = if x == n then Just (k * lWidth lo) else go (k + 1) xs

memAtOf :: Layout -> Int -> Int
memAtOf lo alpha = lMemAt lo + alpha * lWordW lo

-- 状態ビットをそのまま読む式の列
bitsFrom :: Int -> Int -> [Anf]
bitsFrom at n = [ anfVar (at + k) | k <- [0 .. n - 1] ]

stateBits :: Layout -> [Anf]
stateBits lo = [ anfVar i | i <- [0 .. lTotal lo - 1] ]

-- ===== 2. IR の抽象構文 =====

data BinOp  = OAnd | OOr | OXor | OAdd | OSub | OMul deriving (Eq, Show)
data CmpOp  = CEq | CNe | CUlt | CSlt deriving (Eq, Show)
data ShiftOp = SShl | SLshr | SAshr deriving (Eq, Show)

data Operand = Reg String | Imm Int deriving (Eq, Show)

data Instr
  = IBin    String BinOp Operand Operand
  | IShiftC String ShiftOp Operand Int          -- 定数シフト量
  | IShiftV String ShiftOp Operand Operand      -- 変数シフト量
  | ICmp    String CmpOp Operand Operand        -- 出力は 1 ビット
  | ISel    String Operand Operand Operand      -- select(c, a, b)
  | IZext   String Operand Int                  -- 元の幅
  | ISext   String Operand Int
  | ITrunc  String Operand Int                  -- 先の幅
  | ILoad   String Operand
  | IStore  Operand Operand                     -- addr, value
  | IPhi    String [(Operand, String)]
  deriving (Eq, Show)

data Term
  = TBr     String
  | TBrIf   Operand String String
  | TSwitch Operand [(Int, String)] String
  | TRet    Operand
  deriving (Eq, Show)

data Block = Block { bName :: String, bInstrs :: [Instr], bTerm :: Term }
  deriving (Eq, Show)

data Program = Program { pWidth :: Int, pAddrW :: Int, pBlocks :: [Block] }
  deriving (Eq, Show)

blockIndex :: Program -> String -> Int
blockIndex pr nm = go 0 (pBlocks pr)
  where
    go _ [] = 0
    go k (b : bs) = if bName b == nm then k else go (k + 1) bs

-- program に現れる SSA 名を集める。番地の割当てはこの順になる。
-- 定義された名前だけでは足りない。関数引数はどの命令の出力でもないが、
-- §1 は「各 SSA 値」に番地を要求する。読まれる名前も同じ資格で数える。
namesOf :: Program -> [String]
namesOf pr = foldl add [] [ n | b <- pBlocks pr, n <- namesIn b ]
  where
    add acc n = if n `elem` acc then acc else acc ++ [n]
    namesIn b = [ n | i <- bInstrs b, n <- insNames i ] ++ termNames (bTerm b)
    insNames i = [ n | Just n <- [defOf i] ] ++ [ n | Reg n <- usesOf i ]
    termNames t = [ n | Reg n <- case t of
                          TBr _          -> []
                          TBrIf c _ _    -> [c]
                          TSwitch v _ _  -> [v]
                          TRet v         -> [v] ]
    usesOf i = case i of
      IBin _ _ a b    -> [a, b]
      IShiftC _ _ a _ -> [a]
      IShiftV _ _ a b -> [a, b]
      ICmp _ _ a b    -> [a, b]
      ISel _ c a b    -> [c, a, b]
      IZext _ a _     -> [a]
      ISext _ a _     -> [a]
      ITrunc _ a _    -> [a]
      ILoad _ a       -> [a]
      IStore a b      -> [a, b]
      IPhi _ arms     -> [ v | (v, _) <- arms ]
    defOf i = case i of
      IBin n _ _ _    -> Just n
      IShiftC n _ _ _ -> Just n
      IShiftV n _ _ _ -> Just n
      ICmp n _ _ _    -> Just n
      ISel n _ _ _    -> Just n
      IZext n _ _     -> Just n
      ISext n _ _     -> Just n
      ITrunc n _ _    -> Just n
      ILoad n _       -> Just n
      IPhi n _        -> Just n
      IStore _ _      -> Nothing

layoutOf :: Program -> Layout
layoutOf pr = mkLayout (namesOf pr) (pWidth pr) (pAddrW pr) (pWidth pr)
                       (length (pBlocks pr))

-- ===== 3. 命令の数式表（§2）=====
--
-- 各行が出力ビットの一意正規形になる。𝒯 はこの表の引き写しに過ぎない。

-- ---- ビット演算 ----
--   and: y_k = p_k q_k            1 項
--   or : y_k = p_k ⊕ q_k ⊕ p_k q_k  3 項
--   xor: y_k = p_k ⊕ q_k          2 項

andBits, orBits, xorBits :: [Anf] -> [Anf] -> [Anf]
andBits = zipWith anfAnd
xorBits = zipWith anfXor
orBits  = zipWith (\p q -> anfXorAll [p, q, anfAnd p q])

-- ---- 加算と減算 ----
--
--   s_k = p_k ⊕ q_k ⊕ c_k,  c_0 = 0,  c_{k+1} = p_k q_k ⊕ p_k c_k ⊕ q_k c_k
--
-- 桁上がりは共有ノードに置く。平坦化すると c_k は 2^k 項に達するので（§6）、
-- 提示形はノードを持ったままにする。これは
--
--   c = Nc ⊕ g,  N^w = 0  ⟹  c = ⊕_{t<w} N^t g
--
-- の冪零解消（R6、定理 6.1）を、桁の順に一度なぞった形になる。

addBits :: Sys -> Anf -> [Anf] -> [Anf] -> ([Anf], Sys)
addBits sys c0 ps qs = go sys c0 ps qs []
  where
    go s _ [] _ acc = (reverse acc, s)
    go s _ _ [] acc = (reverse acc, s)
    go s c (p : pr) (q : qr) acc =
      let (sk, s1) = addNode (anfXorAll [p, q, c]) s
          (cn, s2) = addNode (anfXorAll [anfAnd p q, anfAnd p c, anfAnd q c]) s1
      in go s2 cn pr qr (sk : acc)

-- 減算は二の補数。p − q = p ⊕ q̄ ⊕ c、c_0 = 1
subBits :: Sys -> [Anf] -> [Anf] -> ([Anf], Sys)
subBits sys ps qs = addBits sys anfOne ps (map anfNot qs)

-- ---- 乗算 ----
--
--   m^(0) = 0,  m^(j+1) = add(m^(j), shl_j(p_j·q)),  y = m^(w)
--
-- 各段が加算の閉形なので、系は w 段の入れ子になった 2w 本の方程式で閉じる。

mulBits :: Sys -> [Anf] -> [Anf] -> ([Anf], Sys)
mulBits sys ps qs = go sys 0 (replicate w anfZero)
  where
    w = length ps
    go s j acc
      | j >= w = (acc, s)
      | otherwise =
          let pj      = idxAnf ps j
              partial = shlConst w [ anfAnd pj q | q <- qs ] j
              (acc', s') = addBits s anfZero acc partial
          in go s' (j + 1) acc'

-- ---- シフト ----
--
--   shl : y_k = p_{k−c} [k ≥ c]
--   lshr: y_k = p_{k+c} [k+c < w]
--   ashr: y_k = p_{min(k+c, w−1)}

shlConst, lshrConst, ashrConst :: Int -> [Anf] -> Int -> [Anf]
shlConst w ps c  = [ if k >= c then idxAnf ps (k - c) else anfZero | k <- [0 .. w - 1] ]
lshrConst w ps c = [ if k + c < w then idxAnf ps (k + c) else anfZero | k <- [0 .. w - 1] ]
ashrConst w ps c = [ idxAnf ps (min (k + c) (w - 1)) | k <- [0 .. w - 1] ]

-- 変数シフト量はシフト量にわたるマルチプレクサになる。
--   y_k = ⊕_{c<w} χ_c(S) p_{k−c} [k ≥ c]
-- χ は共有ノードへ置くので、積は O(w) 本で済む
shiftVar :: Sys -> Int -> ShiftOp -> [Anf] -> [Anf] -> ([Anf], Sys)
shiftVar sys w op ps ss =
  let (chis, sys') = addNodes [ chiOf ss c | c <- [0 .. w - 1] ] sys
  in ( [ anfXorAll [ anfAnd (idxAnf chis c) (idxAnf (byC c) k)
                   | c <- [0 .. w - 1] ]
       | k <- [0 .. w - 1] ]
     , sys' )
  where
    byC c = case op of
      SShl  -> shlConst w ps c
      SLshr -> lshrConst w ps c
      SAshr -> ashrConst w ps c

-- ---- 比較 ----
--
--   icmp eq : z = ∏_k (1 ⊕ p_k ⊕ q_k)
--   icmp ne : z = 1 ⊕ eq
--   icmp ult: b_0 = 0, b_{k+1} = (1⊕p_k)q_k ⊕ (1⊕p_k⊕q_k)b_k, z = b_w
--
-- ult の借りは加算の桁上がりと同じ副対角構造なので、同じ冪零解消で閉じる。
-- 符号つきは最上位ビットの反転を前置して同じ式に通す。

cmpEq :: [Anf] -> [Anf] -> Anf
cmpEq ps qs = anfAndAll (zipWith (\p q -> anfNot (anfXor p q)) ps qs)

cmpUlt :: Sys -> [Anf] -> [Anf] -> (Anf, Sys)
cmpUlt sys ps qs = go sys anfZero ps qs
  where
    go s b [] _ = (b, s)
    go s b _ [] = (b, s)
    go s b (p : pr) (q : qr) =
      let (b', s') = addNode (anfXor (anfAnd (anfNot p) q)
                                     (anfAnd (anfNot (anfXor p q)) b)) s
      in go s' b' pr qr

-- 最上位ビットを反転してから ult に通す
flipTop :: [Anf] -> [Anf]
flipTop bs = case reverse bs of
  (t : rest) -> reverse (anfNot t : rest)
  []         -> []

cmpBits :: Sys -> CmpOp -> [Anf] -> [Anf] -> (Anf, Sys)
cmpBits sys op ps qs = case op of
  CEq  -> (cmpEq ps qs, sys)
  CNe  -> (anfNot (cmpEq ps qs), sys)
  CUlt -> cmpUlt sys ps qs
  CSlt -> cmpUlt sys (flipTop ps) (flipTop qs)

-- ---- 選択と型変換 ----
--
--   select(c,a,b): y_k = b_k ⊕ c(a_k ⊕ b_k)      3 項
--   zext : y_k = p_k [k < w],  0 それ以外
--   sext : y_k = p_{min(k, w−1)}
--   trunc: y_k = p_k [k < w']

selectBits :: Anf -> [Anf] -> [Anf] -> [Anf]
selectBits c = zipWith (\a b -> anfXor b (anfAnd c (anfXor a b)))

zextBits, sextBits, truncBits :: Int -> [Anf] -> Int -> [Anf]
zextBits wOut ps wIn  = [ if k < wIn then idxAnf ps k else anfZero | k <- [0 .. wOut - 1] ]
sextBits wOut ps wIn  = [ idxAnf ps (min k (wIn - 1)) | k <- [0 .. wOut - 1] ]
truncBits wOut ps wIn = [ if k < wIn then idxAnf ps k else anfZero | k <- [0 .. wOut - 1] ]

-- ---- メモリ ----
--
--   load : y_k = ⊕_α χ_α(A) m_{α,k}
--   store: m'_{α,k} = m_{α,k} ⊕ χ_α(A)(v_k ⊕ m_{α,k})
--
-- χ_α(A) は a 次の単項式へ展開されるが、共有ノードとして一度だけ作れば済む。
-- 和は実行が実際に触るアドレス集合 W の上に落ちるので、メモリというカットの
-- 接合秩は |W| で抑えられる（R4）。

-- ブロックの中で既に書き換えた語は Mem に載る。ブロックは R2 の直列合成なので、
-- 後の load は前の store の結果を読む。まだ書いていない語は状態ビットを読む
type Mem = [(Int, [Anf])]

memWord :: Layout -> Mem -> Int -> Int -> Anf
memWord lo mem al k = case lookup al mem of
  Just bs -> idxAnf bs k
  Nothing -> anfVar (memAtOf lo al + k)

addrsOf :: Layout -> [Int]
addrsOf lo = [0 .. shiftL 1 (lAddrW lo) - 1]

loadBits :: Sys -> Layout -> Mem -> [Anf] -> ([Anf], Sys)
loadBits sys lo mem as =
  let (chis, sys2) = addNodes [ chiOf (take (lAddrW lo) as) al | al <- addrsOf lo ] sys
  in ( [ anfXorAll [ anfAnd (idxAnf chis al) (memWord lo mem al k) | al <- addrsOf lo ]
       | k <- [0 .. lWordW lo - 1] ]
     , sys2 )

storeMem :: Sys -> Layout -> Mem -> [Anf] -> [Anf] -> (Mem, Sys)
storeMem sys lo mem as vs =
  let (chis, sys2) = addNodes [ chiOf (take (lAddrW lo) as) al | al <- addrsOf lo ] sys
  in ( [ ( al
         , [ let m = memWord lo mem al k
             in anfXor m (anfAnd (idxAnf chis al) (anfXor (idxAnf vs k) m))
           | k <- [0 .. lWordW lo - 1] ] )
       | al <- addrsOf lo ]
     , sys2 )


-- 添字の取り出し。範囲の外は零になる
idxAnf :: [Anf] -> Int -> Anf
idxAnf bs k = case drop k bs of
  (x : _) -> x
  []      -> anfZero

headAnf :: [Anf] -> Anf
headAnf bs = idxAnf bs 0

-- ===== 4. ブロックの直列合成 F_B（§3）=====
--
-- 基本ブロックの中身は分岐を含まない直列の命令列なので、§2 の式を R2 で順に
-- 合成した一つの多重線形写像 F_B になる。直線コードの合成は次数勾配の向きにしか
-- 進まないので、ここでは常に冪零であり展開は有限になる。
--
-- F_B は全状態ビットの次の値を返す。ブロックで書かない番地は今の値をそのまま
-- 返すので、§3 の (F_B(X) ⊕ X) が零になって消える。

-- ブロックの中で定義した値の表
type Env = [(String, [Anf])]

-- operand を読む。ブロックの中で定義済みならその式、外なら状態ビット
readOp :: Layout -> Env -> Operand -> [Anf]
readOp lo env o = case o of
  Imm v -> constBits (lWidth lo) v
  Reg n -> case lookup n env of
    Just bs -> bs
    Nothing -> case regAt lo n of
      Just at -> bitsFrom at (lWidth lo)
      Nothing -> replicate (lWidth lo) anfZero

-- 1 ビットの結果を幅 w の register へ置く。比較の出力がこの形になる
liftBit :: Int -> Anf -> [Anf]
liftBit w z = z : replicate (w - 1) anfZero

-- ブロックを通した後の姿。env は定義した値、mem は書き換えたメモリ語
data BlockOut = BlockOut
  { boSys :: Sys
  , boEnv :: Env
  , boMem :: Mem
  }

-- 一命令を通す
stepInstr :: Program -> Layout -> BlockOut -> Instr -> BlockOut
stepInstr pr lo bo ins = case ins of
  IBin n op a b -> case op of
    OAnd -> bind n (andBits (rd a) (rd b))
    OOr  -> bind n (orBits  (rd a) (rd b))
    OXor -> bind n (xorBits (rd a) (rd b))
    OAdd -> let (r, s2) = addBits sys anfZero (rd a) (rd b) in bindS n r s2
    OSub -> let (r, s2) = subBits sys (rd a) (rd b)         in bindS n r s2
    OMul -> let (r, s2) = mulBits sys (rd a) (rd b)         in bindS n r s2
  IShiftC n op a c -> bind n (shiftConst w op (rd a) c)
  IShiftV n op a b -> let (r, s2) = shiftVar sys w op (rd a) (rd b) in bindS n r s2
  ICmp n op a b    -> let (z, s2) = cmpBits sys op (rd a) (rd b)
                      in bindS n (liftBit w z) s2
  ISel n c a b     -> bind n (selectBits (headAnf (rd c)) (rd a) (rd b))
  IZext n a wIn    -> bind n (zextBits w (rd a) wIn)
  ISext n a wIn    -> bind n (sextBits w (rd a) wIn)
  ITrunc n a wOut  -> bind n (truncBits w (rd a) wOut)
  ILoad n a        -> let (r, s2) = loadBits sys lo (boMem bo) (rd a) in bindS n r s2
  IStore a v ->
    let (mem2, s2) = storeMem sys lo (boMem bo) (rd a) (rd v)
    in bo { boSys = s2, boMem = mem2 }
  -- phi は直前ブロックにわたるマルチプレクサ。pc_prev を読む
  --   y_k = XOR_i chi_{beta(B_i)}(pc_prev) v^(i)_k
  IPhi n arms -> bind n
    [ anfXorAll [ anfAnd (chiOf prevBits (blockIndex pr b)) (idxAnf (rd v) k)
                | (v, b) <- arms ]
    | k <- [0 .. w - 1] ]
  where
    w        = lWidth lo
    sys      = boSys bo
    rd       = readOp lo (boEnv bo)
    prevBits = bitsFrom (lPrevAt lo) (lPcW lo)
    bind n bs     = bo { boEnv = boEnv bo ++ [(n, bs)] }
    bindS n bs s2 = bo { boSys = s2, boEnv = boEnv bo ++ [(n, bs)] }

shiftConst :: Int -> ShiftOp -> [Anf] -> Int -> [Anf]
shiftConst w op ps c = case op of
  SShl  -> shlConst w ps c
  SLshr -> lshrConst w ps c
  SAshr -> ashrConst w ps c

-- ブロック一つの次状態 F_B(X)。
--
-- pc の更新は終端命令が決める（§2 制御フロー）。
--   br cond: pc_j <- beta^f_j XOR cond (beta^t_j XOR beta^f_j)
--   br     : pc_j <- beta_j（定数）
--   switch : chi による多分岐マルチプレクサ
--   ret v  : h <- h XOR (1 XOR h),  res_k <- res_k XOR (1 XOR h)(v_k XOR res_k)
--
-- §2 の ret の式にある chi_ret(pc) は、§3 の pc マルチプレクサが供給する。
-- chi^2 = chi なので二度掛けても値は変わらないが、系の項数が増えるだけなので
-- ここでは置かない。
--
-- pc_prev は毎段 pc を写す。phi がこれを読む。
blockNext :: Program -> Layout -> Sys -> Block -> ([Anf], Sys)
blockNext pr lo sys blk = (assemble, boSys out)
  where
    out = foldl (stepInstr pr lo) (BlockOut sys [] []) (bInstrs blk)
    w   = lWidth lo
    pw  = lPcW lo
    env = boEnv out
    mem = boMem out
    h   = anfVar (lHaltAt lo)

    pcConst nm = constBits pw (blockIndex pr nm)
    pcNext = case bTerm blk of
      TBr nm      -> pcConst nm
      TBrIf c t f ->
        let cb = headAnf (readOp lo env c)
            tb = pcConst t
            fb = pcConst f
        in [ anfXor (idxAnf fb j)
                    (anfAnd cb (anfXor (idxAnf tb j) (idxAnf fb j)))
           | j <- [0 .. pw - 1] ]
      TSwitch v arms d ->
        let vb   = readOp lo env v
            dflt = pcConst d
            hit  = anfXorAll [ chiOf vb k | (k, _) <- arms ]
        in [ anfXorAll
               ( anfAnd (anfNot hit) (idxAnf dflt j)
               : [ anfAnd (chiOf vb k) (idxAnf (pcConst nm) j) | (k, nm) <- arms ] )
           | j <- [0 .. pw - 1] ]
      TRet _ -> bitsFrom (lPcAt lo) pw   -- 停止したら pc は動かない

    hNext = case bTerm blk of
      TRet _ -> anfXor h (anfNot h)
      _      -> h

    resNext = case bTerm blk of
      TRet v ->
        let vb = readOp lo env v
            g  = anfNot h
        in [ let r = anfVar (lResAt lo + k)
             in anfXor r (anfAnd g (anfXor (idxAnf vb k) r))
           | k <- [0 .. w - 1] ]
      _ -> bitsFrom (lResAt lo) w

    -- 状態ビットを番地の順に並べ直す
    assemble = [ pick i | i <- [0 .. lTotal lo - 1] ]
    pick i
      | i < lMemAt lo =
          case lookup (nameAt (i `div` w)) env of
            Just bs -> idxAnf bs (i `mod` w)
            Nothing -> anfVar i
      | i < lPcAt lo =
          let al = (i - lMemAt lo) `div` lWordW lo
              k  = (i - lMemAt lo) `mod` lWordW lo
          in case lookup al mem of
               Just bs -> idxAnf bs k
               Nothing -> anfVar i
      | i < lPrevAt lo  = idxAnf pcNext (i - lPcAt lo)
      | i < lHaltAt lo  = anfVar (lPcAt lo + (i - lPrevAt lo))   -- pc_prev <- pc
      | i == lHaltAt lo = hNext
      | otherwise       = idxAnf resNext (i - lResAt lo)
    nameAt k = case drop k (lNames lo) of
      (n : _) -> n
      []      -> ""

-- ===== 5. ステップ行列 M_step（§3）=====
--
--   X_next = X XOR (1 XOR h) XOR_B chi_{beta(B)}(pc) (F_B(X) XOR X)
--
-- 右辺は状態ビットの多重線形式なので、ただ一つのステップ行列が対応する。
-- 実行の軌道は X_t = M_step^t X_0 という行列の冪になる。
--
-- Step は「状態ビットごとの次の値」を系のノードとして持つ形で M_step を表す。
-- 行列そのものを 2^sigma の表として持たないのは、sigma が数十でも表が置けないため。

data Step = Step
  { stLayout :: Layout
  , stSys    :: Sys      -- 共有ノードを含む系
  , stNext   :: [Anf]    -- 状態ビットごとの次の値
  }

buildStep :: Program -> Step
buildStep pr = Step lo sysF nexts
  where
    lo    = layoutOf pr
    pcB   = bitsFrom (lPcAt lo) (lPcW lo)
    h     = anfVar (lHaltAt lo)
    guard = anfNot h

    -- 各ブロックの F_B を順に作る。系は共有される
    (fbs, sys1) = foldl one ([], emptySys (lTotal lo)) (pBlocks pr)
    one (acc, s) blk = let (bs, s2) = blockNext pr lo s blk in (acc ++ [bs], s2)

    -- chi_{beta(B)}(pc) は共有ノードへ置く
    (chis, sysF) = addNodes [ chiOf pcB k | k <- [0 .. length (pBlocks pr) - 1] ] sys1

    nexts =
      [ anfXor (anfVar i)
          (anfAnd guard
            (anfXorAll [ anfAnd (idxAnf chis k) (anfXor (idxAnf fb i) (anfVar i))
                       | (k, fb) <- zip [0 ..] fbs ]))
      | i <- [0 .. lTotal lo - 1] ]

-- 一段進める。頂点の割当てを受けて次の割当てを返す
stepOnce :: Step -> [Int] -> [Int]
stepOnce st bits = [ evalAnf look e | e <- stNext st ]
  where
    nodeVals = evalSys (stSys st) bits
    v = sVars (stSys st)
    look i
      | i < v     = idxInt bits i
      | otherwise = idxInt nodeVals (i - v)

-- 軌道 X_0, X_1, ..., X_n
orbit :: Step -> [Int] -> Int -> [[Int]]
orbit st x0 n = take (n + 1) (iterate (stepOnce st) x0)

-- ===== 6. 停止と結果の読み（§3）=====
--
--   停止 <=> OR_t (e_h^T M_step^t X_0) = 1
--   結果 = e_res^T X_omega
--
-- h は一度 1 になれば以後の更新項が (1 XOR h) で消えるので単調非減少になり、
-- 停止 config が遷移の不動点になる。omega 読みはその不動点での res になる。

haltedAt :: Step -> [Int] -> Bool
haltedAt st bits = idxInt bits (lHaltAt (stLayout st)) == 1

resultAt :: Step -> [Int] -> Int
resultAt st bits =
  foldl (\acc k -> acc + shiftL (idxInt bits (lResAt lo + k)) k) 0
        [0 .. lWidth lo - 1]
  where lo = stLayout st

idxInt :: [Int] -> Int -> Int
idxInt xs k = case drop k xs of
  (x : _) -> x
  []      -> 0

-- omega 読み。単調フラグが立つまで進め、立たなければ Nothing
omegaRead :: Step -> [Int] -> Int -> Maybe Int
omegaRead st x0 budget = go budget x0
  where
    go n x
      | haltedAt st x = Just (resultAt st x)
      | n <= 0        = Nothing
      | otherwise     = go (n - 1) (stepOnce st x)
