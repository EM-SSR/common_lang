{-# LANGUAGE NoImplicitPrelude #-}
module Common.Core.Proof where

import CounterConstraints
import CommonChamber (Mu (..), muS, muP, joinWith, splitOnC)
import Common.Lang.NL (FileKind (..), contentIdent, readInteger)

-- ===== proof object の永続化（仕様 §44、§32.6、docs/common-compiler/core/02）=====
-- doc: casm.proof.object casm.proof.check casm.proof.ser
--
--   𝔭 = (C₁, C₂, μ, R)                          (44.1)
--   𝔉_proof = (ν_p, ν₁, ν₂, μ, R)               (32.14)
--   R = (κ, τ, ℓ, r)、κ ∈ {n, r, c}
--
-- 検査は Check(𝔭) = 1 ⟺ ℓ = r に落ちる。Dec_A と δ_A は build 時に一度走り、
-- その出力が r として certificate へ入る。検査側は package を持たなくてよい。
-- これが「証明を compiler のログにしない」の実現形である。

data Kind
  = KNf     -- 正規形一致 certificate
  | KRaw    -- raw instruction certificate。ℓ = 符号 b、r = Enc(Dec(b))
  | KConf   -- target conformance。ℓ = 要求観測、r = 実観測
  deriving (Eq, Show)

kindC :: Kind -> String
kindC k = case k of
  KNf -> "n"; KRaw -> "r"; KConf -> "c"

kindP :: String -> Maybe Kind
kindP s = case s of
  "n" -> Just KNf; "r" -> Just KRaw; "c" -> Just KConf
  _   -> Nothing

data ProofObj = ProofObj
  { pIdent :: Integer   -- ν_p
  , pLeftI :: Integer   -- ν₁
  , pRightI :: Integer  -- ν₂
  , pMu    :: Mu
  , pKind  :: Kind
  , pTag   :: String    -- certify した式の番号。"40.1" など
  , pLhs   :: String
  , pRhs   :: String
  } deriving (Eq, Show)

-- ν₁ = H(proof, ℓ)、ν₂ = H(proof, r)、ν_p = H(proof, τ‖ℓ‖r‖μ)（02 章 式 3.1）
mkProof :: Mu -> Kind -> String -> String -> String -> ProofObj
mkProof mu k tag l0 r0 = ProofObj nu n1 n2 mu k tag l r
  where
    -- 直列化の区切りを含む正準表示（unit の ser など）が来るので、
    -- 保存する前に両辺へ同じ写像をかける。等値判定は保たれる
    l  = sanitize l0
    r  = sanitize r0
    n1 = contentIdent FProof l
    n2 = contentIdent FProof r
    nu = contentIdent FProof (tag ++ "\1" ++ l ++ "\1" ++ r ++ "\1" ++ muS mu)

-- 検査。三形式とも同じ判定に落ちる（02 章 式 2.2）
checkProof :: ProofObj -> Bool
checkProof p = pLhs p == pRhs p && pLeftI p == pRightI p

-- ===== 直列化 =====
--
-- 一行 = proof unit 一つ。ℓ と r は ; を含まない正準表示に限る

serProof :: ProofObj -> String
serProof p = joinWith ";"
  [ show (pIdent p), show (pLeftI p), show (pRightI p)
  , muS (pMu p), kindC (pKind p), pTag p, pLhs p, pRhs p ]

parseProof :: String -> Maybe ProofObj
parseProof s = case splitOnC ';' s of
  [nuS, n1S, n2S, muT, kT, tag, l, r] ->
    case (readInteger nuS, readInteger n1S, readInteger n2S, muP muT, kindP kT) of
      (Just nu, Just n1, Just n2, Just mu, Just k) ->
        Just (ProofObj nu n1 n2 mu k tag l r)
      _ -> Nothing
  _ -> Nothing

serProofs :: [ProofObj] -> String
serProofs ps = concat [ serProof p ++ "\n" | p <- ps ]

parseProofs :: String -> [Maybe ProofObj]
parseProofs s = [ parseProof l | l <- splitOnC '\n' s, not (null l) ]

-- ===== 正準表示の補助 =====
--
-- byte 列の certificate は 16 進の大文字で書く。; を含まないので直列化を壊さない

hexBytes :: [Int] -> String
hexBytes bs = concat [ [hexDigit (b `div` 16), hexDigit (b `mod` 16)] | b <- bs ]

hexDigit :: Int -> Char
hexDigit n = case drop n "0123456789ABCDEF" of
  (c : _) -> c
  []      -> '?'

-- ; を含む可能性のある正準表示を安全にする。区切りを別の記号へ写す
sanitize :: String -> String
sanitize = map sub
  where
    sub ';' = ':'
    sub '\n' = ' '
    sub c   = c
