# 03 CounterInteger（Level 3: 対称な道と整数）

## 役割

「対称な道の正セグメントに ∂ を適用した出力が整数 1 であり、残余への再帰適用で
2, 3, … が演繹される」という Level 3 の構成を実装する。負の整数は H⁻ 側の対称点として
同時に得られる。1/2 漸減性は構成そのものから出る。

## API

```haskell
edgesOf        :: Region -> [Int]
symmetricPath  :: Int -> Int -> Region   -- 対称な道（中心 c、片側幅 w）
positiveSeg    :: Int -> Int -> Region   -- 正セグメント [c .. c+w-1]
negativeSeg    :: Int -> Int -> Region   -- 負セグメント [c-w .. c-1]
symmetricOnLine:: Int -> Int -> Bool     -- 外側(道, 正) == 負 の成立判定
cutAt          :: Region -> Int -> (Region, Region)   -- 道の切断

data CInteger = CInteger
  { orderOf   :: Int      -- 何番目に構成されたか（1 始まり）
  , pointOf   :: Int      -- 直線複体上の頂点
  , historyOf :: Region   -- O からの正セグメント鎖（構成履歴＝ビット）
  }

convergedLine  :: Int -> Int -> ([CInteger], Int)   -- (整数列, ω)
negateCInteger :: CInteger -> CInteger              -- 負の整数
fullHistory    :: [CInteger] -> Region
```

## 意味論

`convergedLine start w0` は次の再帰で整数列を構成する。

1. 残余幅 w の半分 h = w `div` 2 を新しい正セグメント [p .. p+h-1] とする。
2. 遠端点 p+h が次の整数である。∂(セグメント) は (始点, −1) と (新点, +1) を返す。
3. 残余を w − h に更新して繰り返す。w < 2 で停止し、現在点 + 残余が ω（収束先）になる。

ω は収束先として名前のみ現れる。点としては未構成であり、これは仕様である。
点として構成できるのは後続の拡張（Level 4 以降の脱出）である。

### 使用例

```
ghci> let (ints, om) = convergedLine oVertex 16
ghci> map pointOf ints
[40,44,46,47]
ghci> map (pointOf ... の間隔) -- [8,4,2,1] が正確に半減する
ghci> om
48
```

第一間隔は初期残余の半分（16/2 = 8）、以後さらに半減する。全ての構成点は
ω 未満であり、ω = 最終点 + 1 が一意に定まる。

## 不変条件（検証コードあり）

1. 第一間隔 = 初期残余の半分、以後の間隔 = 前間隔の半分。
2. 全ての構成点 < ω。
3. 正セグメントの ∂ 出力 = [(O, −1), (新点, +1)]。履歴全体でも内部頂点は相殺され、
   O と最新点だけが残る（冪零性の実効確認）。
4. 負の整数は O に関して対称な位置・対称な履歴を持つ。
   `pointOf (negateCInteger c) == 2 * oVertex - pointOf c`

## 落とし穴

- `convergedLine` の第二引数は初期残余幅であり、2 の冪を与えること想定である。
  奇数を与えると `div` の切捨てにより間隔列が厳密な半減にならない。
- 履歴は「O からその整数まで」の鎖である。途中の整数の履歴は、それ以降の整数の
  履歴の prefix にはならない（各整数が自分までのセグメント鎖を持つ）。
  共通 prefix が必要な場合は `fullHistory` を使わず自分で `combine` を切って取る。
- ω を点として扱おうとしないこと。ω が必要になるのは Level 4 の脱出構成であり、
  そこでは `omega` という名前（頂点番号）として参照される。
