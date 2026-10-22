# 05 dag 層（平面・四則演算・影響関数・DAG・拡張実験）

dag ディレクトリは「ツイ数平面とは」ディレクトリの内容を構造化した層である。
依存方向: DagPlane → DagArith / DagInfluence、CounterDag と CounterExtend は core のみ。

## DagPlane（接合多様体と正準単体）

「接合多様体としてのツイ数平面」+ 6a/6c/6d の実装。

```haskell
pO, pOne, pI, pJ, pIJ, pJI, pNIJ, pNJI :: Int   -- 正準点の頂点割当
cellsP = [q1, q2, q3, q4]                        -- 四つの正準 2-単体 (6a)
mPartialP:: [[Int]]                              -- M_∂（行=面, 列=cell）
sideOfCell :: Simplex -> Side                    -- 所属半平面は cell から導出
data CellPt = CellPt { ptCell, lamNums :: (Int,Int,Int), lamDep :: Int }
lawTotal :: CellPt -> Bool                       -- Σλ = 2^depth（6c 拘束）
mkT1Pt   :: Int -> Int -> Int -> CellPt          -- T1 内 x=(a,b) から λ を構成
xyOf     :: CellPt -> (Int,Int,Int)              -- 重心座標 → xy 分子
eqScaled :: (Int,Int,Int) -> (Int,Int,Int) -> Bool
```

- 重心座標は二進分割なので共通分母 2^depth の分子三つで正確に持つ（6d）。
- `cellVertsP` の提示順（O, 脚, 対角）は重心座標用の順序であり、boundary の
  昇順規約とは独立である。混ぜないこと。
- 接合の検証: Πi 側(Q1,Q2) と Πj 側(Q3,Q4) は M_∂ の行を共有しない。
  両者が接するのは O を通じてのみ——「Πi ⊔_ℝ Πj」が行列上に現れた形。

## DagArith（四則演算とタレス除算）

```haskell
type SCoord = (Int, Int, Int)          -- (x分子, y分子, depth): 値 = (x,y)/2^depth
addS, subS  :: SCoord -> SCoord -> SCoord   -- 平行四辺形則。経路を忘れる
typeSide    :: SCoord -> Maybe Side         -- ω 軸成分の符号で型が切替わる

data Ratio2 = Ratio Int Int | BeyondOmega   -- 比 r = n/d（生の比）
divideThales    :: Int -> Int -> Ratio2     -- d=0 は退化して ω 方向へ飛ぶ
multiplyThales  :: Ratio2 -> Ratio2 -> Ratio2
asScale         :: Ratio2 -> Maybe (Int,Int)  -- 二進比 n'/2^s への正規化
quotApply       :: Ratio2 -> SCoord -> Maybe SCoord
scaleBy         :: (Int,Int) -> SCoord -> SCoord
```

意味論:

- 加減算は座標合成であり分岐情報を持たない。ω 成分の符号が正なら Si 型、負なら
  Sj 型、0 なら実軸通過。「加算は経路を忘れる」の実装形。
- 除算 `divideThales n 0` は参照三角形の退化である。平行線の交点は有限平面に現れず、
  交わりは残余半直線の収束先 ω の方向に飛ぶ。ゼロ除算も値 `BeyondOmega` を持つ。
- 方向の乗算は CounterUnits の `applyU`（分岐語合成）が担う。ij ≠ ji は [I,J] ≠ [J,I]。

## DagInfluence（影響関数と整合条件）

```haskell
type VertMap = Int -> Int
transMatrix  :: [Int] -> [Int] -> VertMap -> [[Int]]   -- T_f[i][j] = 1 ⇔ f(v_i)=v_j
matComp      :: [[Int]] -> [[Int]] -> [[Int]]
mapVertices  :: VertMap -> Simplex -> Simplex
chainImage   :: VertMap -> Simplex -> (Int, Simplex)   -- 向き補正付き鎖像
fSharpBoundary :: VertMap -> Simplex -> [(Int, Simplex)]
```

整合条件 (⋆) の検証形:

- 遷移行列: T_{g∘f} = T_g · T_f
- 鎖写像: f♯(∂σ) = ∂(f♯σ)

**向き補正は必須**である。頂点写像を素朴に適用すると昇順規約との不整合で
f♯∂ ≠ ∂f♯ になる。`chainImage` は置換符号（反転数の偶奇）を掛けて補正する。
この補正なしに鎖写像を書いてはならない（過去に失敗したテストがある）。

影響関数の制約表（凸性→Σw=1∧w≥0、境界構造→inc∈{−1,0,1}∧∂²=0、非有界→制約なし）も
検証コードとして入っている。

## CounterDag（Level 6+: 晴れ上がり）

```haskell
data OpNode = NOrigin | NNeg NodeId | NInt NodeId | NEscI NodeId | NEscJ NodeId
            | NComp NodeId NodeId
data Dag = Dag { dagSize, dagNodes, dagAdj }   -- 接続行列: 行=親、立位ビット=子
reachesFrom :: Dag -> NodeId -> Word64         -- 子孫への推移閉包
addNode     :: OpNode -> Dag -> Maybe (Dag, NodeId)
linkNodes   :: Dag -> NodeId -> NodeId -> Maybe Dag   -- 閉路は拒否
levelSet    :: Dag -> NodeId -> [Int]          -- 祖先レベル集合
sampleDag   :: Maybe (Dag, NodeId)
```

- 合成ノード NComp の祖先レベル集合は複数要素を持つ。レベルは集合として管理し、
  単一値へ縮約しない。「Level 6+ は階層ではなく DAG」の実装形。
- ノード数は 64 以下（Word64 制約）。
- `linkNodes` は v が既に u へ到達可能なときの u→v を拒否しなければならない。

## CounterExtend（検証と拡張実験）

| 名前 | 内容 |
|---|---|
| `unitSquareLandsMinus1` | i² が単位点を H⁻ の単位点へ写す（Index.md L4 原文どおり） |
| `lineOnI`, `omegaI` | I 分岐上でも同一再帰構成が回り、ω_I が現れる |
| `zBase`, `segmentK`, `unitZ`, `applyZ` | ω_I からの第二脱出。ω 型アンカーは常に C₄ 型単位（z² = I 分岐内の反転）を生成する |
| `continuationWidth`, `continuation` | i/J を経由せず ω の先へ直進延長した場合の構成 |
| `advanceAlongLine` | 直進輸送。合成しても反転にならない（新しい単位が発生しない） |

実験B の継続幅は任意選択であり追加データである。この選択肢の非正準性が、
「直進は加算しか生成せず、脱出のみが乗算を生成する」という対比の根拠になる。
