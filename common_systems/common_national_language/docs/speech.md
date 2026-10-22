# 音声符号層（Speech.hs）

仕様: 06_音声符号と誤り訂正.md

## 発音列と可逆性（§2）

```haskell
type Phone = String
type Utterance = [Phone]           -- 非可換。順序そのものが符号空間
encode :: Chamber -> Utterance     -- E_speech
decode :: Mu -> Int -> [Port] -> [Port] -> Utterance -> Maybe Chamber   -- D_speech
```

アルファベット: 原始文字タグ ＋ 構文境界 "~"（層の切れ目）＋ 無声音 "_"
（恒等ワイヤのみが流れる区間）。エンコードは frontier を走査し、
隙間を "_" へ、箱をタグへ写す。復元は `runPorts` の整形式検査を通る。

検証: `decode(encode c) == Just c`（式2.1）および
`encode i語 ≠ encode j語`、`encode ≠ reverse encode`（順序の非可換性）。

## 聴取チャネル（§3）

```haskell
type Channel = [(Phone, Phone, Integer, Int)]   -- T(p_i,p_j) = m/2^d
hearC :: Channel -> Phone -> Phone -> Dyad
```

T_hear は人間が先に数値を決めるものではなく、実測された遷移係数である。
未測定ペアは整合度 (0,0)。係数の合成は ⋆（分子積・深度和）、
上限 ⋁ は max（完備束の有限近似）。

## 編集経路を含む整合度（4.1/4.2）

```haskell
scoreAligned :: Channel -> Utterance -> Utterance -> Dyad   -- 同位置合成のみ
bestScore    :: Channel -> Dyad -> Dyad -> Utterance -> Utterance -> Dyad
                  -- delP, insP を込めた ⋁_γ T_γ（挿入・削除・置換）
```

`bestScore` は素直な再帰で経路全体の最大を取る（指数時間。
実用長では DP への書き換えが必要——既知の限界）。

検証: bestScore ≥ scoreAligned（⋁ は経路の上限であること）、
削除経路が最善になるケースの厳密値、挿入の対称ケース。

## 復号と誤り訂正

```haskell
decodeNoisy :: Channel -> Dyad -> Dyad -> [Utterance] -> Utterance -> Maybe Utterance
separatedBy :: Channel -> Dyad -> Dyad -> Dyad -> [Utterance] -> Bool
```

- 復号は語彙 V の中で T(u, observed) を最大化する語を選ぶ
- 分離条件 (5.1): u≠v なら T(u,v) ≤ ε。これを満たす語彙だけが受理される

検証される振る舞い:

1. **語彙に無い観測列**（例: ["j"] だが "j" の語は語彙に無い）が、
   チャネル経由で最も整合する語（["i"]）へ復号される——誤り訂正の本体
2. **直接一致する語が語彙にあればそれが選ばれる** — 最大整合の素朴な帰結
3. **分離された語彙は受理、混同組を含む語彙は拒否** — ε 判定の両側

## 実装詳細

1. scoreDP は (i,j) 表の遅延評価により多項式時間で動く。
2. fromCounts が実測カウント（正解数/試行数）から聴取係数を構築する。
   丸めは深度 12 の冪二進へ行い、丸め誤差は 2^{-11} 未満である。
3. ビット符号層: phoneAlphabet の各音素を 4 ビットコード + 偶パリティの
   5 ビットへ符号化し、END コードで語末を示す。単一ビット誤りは
   パリティ検査で必ず検出される（bitDecode が Nothing を返す）。
4. 発音記号: 記号は命名ではなく、原始文字レジストリの正準番号から symbolOf が自動で出す（p_k 表記）。構文境界 "~" と無声音 "_" はマーカとしてそのまま写る。
   構文境界以降のみ実装済み。ビット符号層は別の符号理論タスクである。



