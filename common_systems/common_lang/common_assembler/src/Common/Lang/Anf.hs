{-# LANGUAGE NoImplicitPrelude #-}
module Common.Lang.Anf where

import CounterConstraints

-- ===== ビット式の一意正規形と、共有ノードを持つ系 =====
-- doc: anf.unique llvm.state rule.unique
-- 参照: docs/Common-Lang/3.LLVM-IRからCommon共通表現への変換 §2、§3
--
-- 𝔽₂ 上の多重線形式は、単項式の有限集合としてただ一つに定まる（R1）。
--
--   f(x) = ⊕_{T ∈ supp f} x^T,      x^T = ∏_{i∈T} x_i
--
-- x² = x なので単項式の積は添字集合の合併になり、⊕ は集合の対称差になる。
-- NormalizedBool は真理値表の側から同じ正規形を作る。両者が一致することを
-- selfcheck で突き合わせる。
--
-- 平坦な正規形は桁上がりで 2^k 項に達する（§6 の台帳）。だから提示形は
-- 共有ノードを持つ系 Sys の側で持ち、平坦化は検証のときだけ行う。

-- ===== 単項式と式 =====

-- 単項式 x^T。添字は昇順、重複なし
type Mono = [Int]

-- 式。単項式の集合を昇順・重複なしで持つ
newtype Anf = Anf [Mono] deriving (Eq, Show)

anfZero, anfOne :: Anf
anfZero = Anf []
anfOne  = Anf [[]]

anfVar :: Int -> Anf
anfVar i = Anf [[i]]

anfTerms :: Anf -> [Mono]
anfTerms (Anf ms) = ms

-- ⊕ = 昇順列の対称差。同じ単項式が二つ来れば消える（1 ⊕ 1 = 0）
anfXor :: Anf -> Anf -> Anf
anfXor (Anf a) (Anf b) = Anf (symDiff a b)

symDiff :: [Mono] -> [Mono] -> [Mono]
symDiff [] ys = ys
symDiff xs [] = xs
symDiff (x : xs) (y : ys)
  | x < y     = x : symDiff xs (y : ys)
  | x > y     = y : symDiff (x : xs) ys
  | otherwise = symDiff xs ys

-- 積。単項式ごとに添字集合を合併し、重複した単項式を消す
anfAnd :: Anf -> Anf -> Anf
anfAnd (Anf a) (Anf b) =
  Anf (foldl (\acc m -> symDiff acc [m]) [] [ monoUnion x y | x <- a, y <- b ])

monoUnion :: Mono -> Mono -> Mono
monoUnion [] ys = ys
monoUnion xs [] = xs
monoUnion (x : xs) (y : ys)
  | x < y     = x : monoUnion xs (y : ys)
  | x > y     = y : monoUnion (x : xs) ys
  | otherwise = x : monoUnion xs ys

-- 否定は定数 1 との ⊕（xor の定数 −1 の場合）
anfNot :: Anf -> Anf
anfNot = anfXor anfOne

anfXorAll :: [Anf] -> Anf
anfXorAll = foldl anfXor anfZero

anfAndAll :: [Anf] -> Anf
anfAndAll = foldl anfAnd anfOne

-- 項数と次数。§6 の負荷台帳がこの二つで書かれている
anfSize :: Anf -> Int
anfSize (Anf ms) = length ms

anfDegree :: Anf -> Int
anfDegree (Anf ms) = foldl max 0 (map length ms)

-- ===== 頂点での評価 =====
--
-- 頂点 𝟏_R は各変数への 0/1 の割当て。式の値は単項式の積の総和 mod 2 になる。

evalAnf :: (Int -> Int) -> Anf -> Int
evalAnf env (Anf ms) =
  foldl (\acc m -> (acc + foldl (\p i -> p * env i) 1 m) `mod` 2) 0 ms

-- ===== 指示関数 χ_α(A) =====
--
--   χ_α(A) = ∏_j (1 ⊕ A_j ⊕ α_j)
--
-- 「ビット列 A が定数列 α に一致する」の多重線形式。A の各ビットは式でよい。
-- α の桁数は A の長さで決まる。

chiOf :: [Anf] -> Int -> Anf
chiOf as alpha =
  anfAndAll [ anfNot (anfXor a (bitConst alpha k)) | (k, a) <- zip [0 ..] as ]

bitConst :: Int -> Int -> Anf
bitConst v k = if testBit v k then anfOne else anfZero

-- 定数のビット式列。幅 w で下位から並べる
constBits :: Int -> Int -> [Anf]
constBits w v = [ bitConst v k | k <- [0 .. w - 1] ]

-- ===== 共有ノードを持つ正規形の系 =====
--
-- 変数の番号は二段に分ける。
--
--   0 .. v-1     状態ビット
--   v + k        ノード k
--
-- ノード k の式は状態ビットと k より小さいノードだけを読む。だから系は
-- 非巡回であり、頂点評価は前から一度なぞるだけで済む。加算器の桁上がり
-- c_k はこのノードとして持つ。平坦化すると 2^k 項になるので、提示形は
-- 系のままにする（§2 加算と減算）。

data Sys = Sys { sVars :: Int, sNodes :: [Anf] } deriving (Eq, Show)

emptySys :: Int -> Sys
emptySys v = Sys v []

-- ノードを一つ足し、その変数番号を返す
addNode :: Anf -> Sys -> (Anf, Sys)
addNode e (Sys v ns) = (anfVar (v + length ns), Sys v (ns ++ [e]))

-- 式の列をまとめて足す。ビット幅ぶんの式を一度に置く用
addNodes :: [Anf] -> Sys -> ([Anf], Sys)
addNodes [] sys = ([], sys)
addNodes (e : es) sys =
  let (r, sys')  = addNode e sys
      (rs, sys'') = addNodes es sys'
  in (r : rs, sys'')

-- 状態ビットの割当てから全ノードの値を出す
evalSys :: Sys -> [Int] -> [Int]
evalSys (Sys v ns) bits = go ns []
  where
    go [] acc = reverse acc
    go (e : es) acc = go es (evalAnf (look acc) e : acc)
    -- acc は逆順に積んであるので、ノード k は先頭から (len-1-k) 番目になる
    look acc i
      | i < v     = idx bits i
      | otherwise = idx acc (length acc - 1 - (i - v))
    idx xs k = case drop k xs of
      (x : _) -> x
      []      -> 0

-- 系の中の式を状態ビットだけの式へ戻す。§6 の平坦展開にあたる。
-- 検証のときだけ使う。提示形はノードを持ったままになる
flattenSys :: Sys -> Anf -> Anf
flattenSys (Sys v ns) = subst
  where
    flat = build [] ns
    build acc [] = reverse acc
    build acc (e : es) = build (substWith (reverse acc) e : acc) es
    substWith done (Anf ms) =
      anfXorAll [ anfAndAll [ pick done i | i <- m ] | m <- ms ]
    pick done i
      | i < v     = anfVar i
      | otherwise = case drop (i - v) done of
          (x : _) -> x
          []      -> anfZero
    subst (Anf ms) =
      anfXorAll [ anfAndAll [ pick flat i | i <- m ] | m <- ms ]

-- 系の大きさ。提示形の項数の合計になる
sysSize :: Sys -> Int
sysSize (Sys _ ns) = foldl (\a e -> a + anfSize e) 0 ns
