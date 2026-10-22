# 全域計算と停止性層（Totality.hs）

仕様: 04_全域計算と停止性.md

## 整形式項と全域能（定理3.1）

```haskell
data Term
  = TAtom Chamber            -- 原子チェンバー
  | TSeq Term Term           -- C₁ ; C₂
  | TTensor Term Term        -- ⊗
  | TOmega Prim Value Value  -- Ω_a[F;x₀]: (F, x₀, a)
termSer   :: Term -> String          -- 有限の直列化
evalTerm  :: Term -> [Value] -> Maybe [Value]
mkOmega   :: Prim -> Value -> Maybe Term
```

Ω_a[F;x₀] の集積境界 a は、反復を回す代わりに **F の解析**で確定する:

- `omegaAccum PBeta x₀ = Just ω` — β(x)=(x+1)/2 の不動点方程式 x=(x+1)/2 の解
- 周期系（PNeg や PUnit の巡回）は点への収束閉包を持たないため `Nothing`
  を返し、その閉じ方は §6 の有限状態判定が担う

検証の要点: β 軌道の 40 段の有限反復がどれも ω に到達しない一方で、
Ω 項は **厳密に** VDyad (1,0) を返す。また Ω の直列化長は軌道展開数によらず
一定であり、明示的に展開した項より小さい（定理3.1「展開する必要はない」）。

## 有限状態系の停止判定（§6 定理6.1）

```haskell
decideFsm :: [Int] -> (Int -> Int) -> [Int] -> Int -> FsmVerdict
-- FsmVerdict = Halted t | Periodic j t
```

鳩の巣原理により、状態数 N の系では高々 N+1 歩の歩行で停止か周期かが確定する。
検証コードは三つを確認する: 停止機械の時刻報告、周期機械の非停止確定と
再出現区間の妥当性、複数の遷移関数に対する判定ステップ数の上限 N+1。

## 線形・アフィン反復（§7）

```haskell
type Aff = (Rat, Rat)        -- x ↦ L·x + b を (L,b) で持つ
compA, applyA ::             -- 合成と適用
affPow       :: Aff -> Int -> Aff    -- 二乗法 O(log k)
solveFix     :: Rat -> Rat -> Ratio2 -- x* = b/(1−L)（L ≠ 1）
```

Rat は Ratio2（生の分数）。既約化しないため、等値比較は必ず交叉乗算 `eqR` を
使うこと。素朴な `==` は同じ有理数の別表現を別物として扱う（過去に失敗した
テストはこのせいである）。

検証: affPow A 7 と 7 回合成の一致（二乗法の正しさ）、10 段反復の値と
閉じた式 b(1−L¹⁰)/(1−L) の厳密一致、固定点の不動性。

## 実装詳細

1. 自己写像 F は data SelfF = SBeta | SAff QQ QQ で表す。SBeta の集積境界は
   ω = 1（定理1.2 の一次方程式解）、SAff l b の集積境界は x* = b/(1−l) を
   QQ（Integer 分子分母）の厳密演算で解く。0 ≤ l < 1 の縮小条件を満たす
   場合のみ閉包値を返す。
2. applySelf は F を実際に走らせる。Ω の Eval は集積境界値そのものを返すため、
   有限反復が決して到達しない値を厳密に返すことができる。

