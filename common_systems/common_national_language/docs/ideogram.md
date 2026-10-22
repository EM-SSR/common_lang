# 表意語層（Ideogram.hs）

仕様: 01_意味対象と表意語.md

## 三層の定義（§9）

| 層 | 定義 | 実装 |
|---|---|---|
| 語の意味 | `CNF(C)` | `wordChamber` の正準形そのもの。同一性は Eq |
| 可搬表現 | `ser(C)` | `wordSer` |
| 人間向け表示 | `Render(ser(C))` | `renderPlain` / `renderDecorated` |

```haskell
mkWord    :: Chamber -> Maybe Word   -- 整形式なチェンバーからだけ語が作れる
parseRendered :: String -> Maybe Word
wordEq    :: Word -> Word -> Bool    -- CNF 一致のみで決まる
```

命題1.1（表示の独立性）は検証コード入り: `renderPlain` と `renderDecorated`
は見た目が違うが、どちらも同じ語へ戻る。

## 相対アドレス（定理3.1）

個体 x の同定は、影響対象 𝐆=(G,L,w) の目印族に対する影響プロファイル

```
ĥ = (w(ℓ₀,x), …, w(ℓₙ,x))
```

で行う。**これは属性ベクトルではない。** w は 6c のタレス比＝重心座標であり、
幾何が内在的に決める量である。実行形には DagPlane.CellPt を使う:
T₁=(O,i,ij) 上の点のプロファイルは ĥ=(λ_O, λ_i, λ_ij)、拘束 Σλ=2^depth。

```haskell
sameInfluence     :: CellPt -> CellPt -> Bool   -- プロファイル一致
separationHolds   :: [(Int,Int,Int)] -> Bool    -- 分離条件 (3.1) の有限検証
```

分離条件 (3.1)（x≠y ⟹ ある ℓ で w(ℓ,x)≠w(ℓ,y)）の下で A_L(x)=ĥ は単射。
検証コードは「異なる点は異なるプロファイル」「同一プロファイルなら同一座標」
の両方向を確認する。

**備考（過去の誤りの記録）**: かつてこの層に `Profile=[Int]` の属性ベクトル
（第0成分=赤、…）と apple/stone の名詞宇宙を実装していた。これは仕様が
明示的に拒絶する列挙への落下であり、削除した。

## 概念チェンバー（§4〜§5 — 実装済み）

概念とはチェンバー C:X→𝒬 であって、個体の列挙でも特徴関数でもない。
記述による同定 D≡apple ⟺ CNF(C_D)=CNF(C_apple) は、両側のチェンバーが
構成できるようになって初めてインスタンスを持つ。

概念チェンバーは ConceptChamber として実装した。成分は (Modality, Chamber) の対であり、
各成分チェンバーは整合度ワイヤを受け取り整合度を返す既存原始文字の合成である。
統合 C_identify の中身は ⋆（starDyad）であり、𝒬-豊穣の論理積として成分を畳む。
現在コードが表明しているのは語彙の閉包だけである:

```haskell
usesOnlyPrimitives :: Chamber -> Bool
primitiveStageVocabulary :: [String]   -- id, i, j, neg, beta, fold, add のみ
```

## 整形式と真偽の分離（§7）

`wellFormed` はポート型の接合だけを見る。観測は別である:

```haskell
observationOf :: Chamber -> [Value] -> Maybe Bool   -- VBit 出力を φ∂ 的に読む
```

検証: fold 語に零を流すと整形式かつ観測非真。β;fold 語に正の二進数を流すと
観測真。同じ語でも入力により観測は変わる——真偽は文単独ではなく
文と対象の対で決まる。中性子星上の牧場のような反実仮想も、
型が合う限り正確に記述できるのはこの分離のためである。

## 語彙は有限へ閉じない（命題8.1）

原始文字は 8 個だが、逐次合成により i の累乗語 C, C;C, … が作れる。検証:

1. 直列化はどの累乗でも異なる（経路保持——i⁴ で値が恒等に戻っても
   履歴は CNF に残る）。
2. 実行値は数学側と一致: i² の累乗語の実行 == negateUP ∘ applyI。

