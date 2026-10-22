# チェンバー層（CommonChamber.hs）

仕様: 00_Index「共通の前提」、01_意味対象と表意語 §1〜2

チェンバーはコモン公用語の意味対象である。

```
C = ⟨(μ,d) | Γ⁻ ⇒ Λ₀;…;Λ_h ⇒ Γ⁺⟩
```

## 値とワイヤ型

ワイヤ型は「流れる値の種類」そのものであり、別の型システムを設けない。

| コンストラクタ | 中身 | 由来 |
|---|---|---|
| `VPt UnitPoint` | 分岐語上の点 | CounterUnits。単位適用 applyU が走る |
| `VCoord SCoord` | 平面座標 (x,y)/2^depth | DagArith。四則演算の層 |
| `VDyad Dyad` | 二進有理数 m/2^d | CCS / Level 3 梯子 |
| `VBit Int` | 二値フラグ | φ∂ の出力 |
| `VRefl Int` | 座標折返し。$D_4$ の八元 | 構成語 §7.1 |

`kindOf :: Value -> Port` が値からワイヤ型を返す。

## 原始文字（Prim）

原始文字は新しい記号ではなく、**積み上げた実装への参照**である。

| Prim | 呼ぶ実装 | 出典 | ポート |
|---|---|---|---|
| `PUnit op` | `applyU op` | Level 4/5 単位適用（i, j） | Unit → Unit |
| `PId` | 恒等 | Level 0-1 の道 | Unit → Unit |
| `PCoordId` | 恒等 | 同上（座標ワイヤ用） | Coord → Coord |
| `PNeg` | `negateUP` | Level 2 負化 | Unit → Unit |
| `PBeta` | `betaStep` | Level 3 の β(x)=(x+1)/2 | Dyad → Dyad |
| `PFold` | `phiPartial` | φ∂ 二値抽出（唯一の非可逆操作） | Dyad → Bit |
| `PAdd` | `addS` | 四則演算の平行四辺形則 | Coord×Coord → Coord |

`evalPrim :: Prim -> [Value] -> Maybe [Value]` が実行であり、
ポート数・ポート型が合わない入力には値を与えない。

### 圏論層（13 章 §1.1、構成語 §7、圏論 第IV部）

| Prim | 意味 | 出典 | ポート |
|---|---|---|---|
| `PTrace` | 構成履歴の入口。実軸の単位点に立つ | 圏論 定義4.1 | I → Trace |
| `PRhoM` | $\rho^-$。$i\,i$ の簡約先 | 構成語 §6.3、圏論 図4.C | Trace → Trace |
| `PRhoP` | $\rho^+$。$j\,j$ の簡約先 | 同上 | Trace → Trace |
| `PEndpoint` | 履歴を座標点として読む | 圏論 定理4.2 | Trace → Point |
| `PReflE` `PReflR` `PReflD` | $E$、$R_r$、$R_{ij}$ | 構成語 §7.1 | I → Reflection |
| `PReflC` | 折返しの合成。行列積で出す | 構成語 §7.2 | Refl×Refl → Refl |
| `PAct` | 折返しを点へ作用させる | 構成語 §7.4 | Refl×Point → Point |
| `PBetaInv` | $\beta^{-1}$。深度を一つ下げる | 構成語 §4、16 §5.1 | Dyad → Dyad |
| `PFixL` | $\Omega_a[\beta_a;x_0]=a$ を一箱で読む | 16 式 5.7、5.8 | Dyad → Dyad |
| `PTheta` | $\Theta$。$\mu$ を 1 から 0 へ落とす | 圏論 定義3.4 | Q → Bit |

八元を 2×2 の整数行列で持つので、合成は行列積になる。§7.2 の表を書き写さない。
表そのものは selfcheck が突き合わせる。

$R$ が引数付きの一箱でなく四箱に分かれているのは、平文が正準添字を書けないため
（16 §3.1）。§7.3 の生成関係が八元すべてを合成で出すので表現力は落ちない。

構成履歴の終点は、大きさを `spotOf` の絶対値、向きを `signU` から読む。
この読み方だけが $i^2=-1$、$j^2=+1$、負化の三つと同時に整合する。

$$
\operatorname{endpoint}(\varepsilon)=(v,0),
\quad
\operatorname{endpoint}(i)=(0,v),
\quad
\operatorname{endpoint}(ij)=(v,v),
\quad
\operatorname{endpoint}(ji)=(v,-v)
$$

## 層と frontier

```haskell
newtype Layer = Layer { layerAtoms :: [(Int, Atom)] }
```

- 第1成分 q は入力 frontier 上の左端位置。
- 正準形では q 昇順・非重なり。箱に覆われない位置は恒等ワイヤで通過する。
- `stepPorts :: [Port] -> Layer -> Maybe [Port]` が命題5.1 の frontier 更新。
  幅はポート列の長さから復元され、描画情報として保存しない。

## チェンバー

```haskell
data Chamber = Chamber
  { chMu  :: Mu       -- 記憶深度 M0 | M1 | MInf
  , chDep :: Int      -- 作図深度 d
  , chIn  :: [Port]   -- Γ⁻
  , chLay :: [Layer]  -- Λ₀;…;Λ_h
  , chOut :: [Port]   -- Γ⁺
  }
```

- `wellFormed c == (runPorts (chIn c) (chLay c) == Just (chOut c))`
- `evalChamber c vs` は整形式な値列を実行し、箱の中身（既存演算）を実際に走らせる。
- `cnf c` は位置を正準整列してから検査する。「並び替えれば通る構成」と
  「最初から正準な構成」は同じ正準形へ落ちる。非整形式には値を与えない。
- `ser` / `parse` は `parse(ser(C)) ≅ C` を満たす可搬表現である。

### 使用例

```
ghci> evalChamber iiWord [VPt (mkReal 32 1)]
Just [VPt (UnitPoint {branchOf = [], spotOf = 32, signU = -1})]
```

iiWord は i 操作を二回積んだ語であり、その実行は CounterUnits の
`negateUP` と完全に一致する。言語の意味論が数学の実装を呼んでいる、
というのがこの層の要点である。

## 合成

```haskell
seqC    :: Chamber -> Chamber -> Maybe Chamber   -- C₁ ; C₂（cod/dom 接合）
tensorC :: Chamber -> Chamber -> Maybe Chamber   -- ⊗（同 μ・同層数のみ）
```

tensorC は B 側の各層の位置を A 側の入力幅だけずらして接合する。
層数が違う場合は恒等層で h = max まで補ってから接合する。

## 実装詳細

1. μ は M0 | M1 | M2 | MInf の列挙であり、定義3.4 の四段格付を完全に持つ。
2. tensorC は短い側を恒等層で h = max まで補ってから接合する。
3. ser/parse は専用テキスト形式 v1（mu;dep;inPorts;layers;outPorts）であり、
   層内項目は「位置~タグ~Prim の Show」で持つ。parse ∘ ser = id を検証済み。
   原始文字辞書を介さないため、原始文字以外のタグをもつ語も往復できる。

