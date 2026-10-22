# 実機で走らせる回路

実験は三つの結果を得る。設計の全体は [CLAIMS.md](CLAIMS.md)。

| 結果 | 内容 |
|---|---|
| 確定論的計算 | ハッシュの出力 $d=H(m)$（8 ビット、または SHA-256d の 256 ビット）を、全量子ビットを並列に測った結果として得る。全 shot で全ビットが一致すれば成立する |
| 標準理論との差の検定 | C1、C2、C3、C7 |
| 論文の式の量 | $L$ 表、$\eta_W$、$\lambda_W$、構成語の差、前史の傾き、$b$、$\kappa\eta$、外部記憶 $\Omega$ の範囲 |

## 回路

| 関数 | 内容 | 回路 |
|---|---|---|
| `h_phys` | 構成語 h_phys だけが違う回路の組（C2） | 24 本。物理が同一で、仮想 rz の対の挿入と、独立な操作の記述順だけが違う組 |
| `J_g` | z_j への作用 J_g | 392 本。位相掃引で z_j=(A,B) と信号の大きさ V を読む。W を N 回当てた系列から、一回の作用 L の四成分と最大特異値を求める（C1、C4、C7） |
| `A_g` | 測定座標 u への作用 A_g | 89 本。W を N 回当てた後の |+> の測定。W と W⁻¹ の奇部分と偶部分を調べる（C6）。パルスの無い語 ab、ba の N 回（N ≤ 1024）で、構成順序だけの差を調べる。互いに違う語を M 種類（M ≤ 32）当てる整列と、整列が待機、測定とリセットの後に残るかを調べる |
| `D_g` | 作図深度への作用 D_g | 20 本。測定の回数 k を変えた後の位相掃引。M5 の設定値 b = 1/2（式 13.2）に対し、信号が縮むかを調べる（C5） |
| `X_g` | 装置状態 χ への作用 X_g | 40 本。待機時間と、隣の量子ビットの活動を変えた位相掃引（--families all のときに走る） |
| `R_C` | リセットの作用 R_C | 20 本。仮想 rz の前史（物理は同一）の後のリセット。前史なしとの差が構成語の効果（C2） |
| `sigma` | 閉包の選択 σ、測定座標の再構成 α | 5 本。同じ回路を連続して走らせた系列。隣接する shot の一致率を、離れた shot の組と比べる（C3） |
| `calibration` | 読み出しの校正 | 2 本。|0> と |1> を測り、S0 と G を決める（式 16.1）。各回の 4 か所に置く |

ハッシュの回路は、同定の結果から語と回数 $N$ を決めて作る。manifest には入らない。
回路図と OpenQASM 3 は `python -m common_qbit.qpu hash-export <ディレクトリ> --function toy|sha256d` で書き出せる（`examples/common_qbit/hash/`）。

## 実機で走らせる手順

次の二つのコマンドを、この順に、リポジトリの最上位（`build_tools` と `continuous_republic` が並ぶディレクトリ）で実行する。
`<バックエンド名>` は `ibm_fez` のような実機の名前。資格情報は `QiskitRuntimeService.save_account` で保存しておく（コマンドは資格情報を扱わない）。
instance を選ぶときだけ、`--instance <CRN>` を足す。

1. 時間の見積り。何も送らない。上限に収まらなければ、理由を表示して終わる（終了コード 2）。

```
build_tools/venv/Scripts/python -m common_qbit.qpu experiment continuous_republic/examples/common_qbit/qpu --backend ibm:<バックエンド名> --dry-run
```

2. 実行。整列、同定の段、本計算ごとの整列を、一つの Batch で続ける。装置の時間の目安は約 370 秒。

```
build_tools/venv/Scripts/python -m common_qbit.qpu experiment continuous_republic/examples/common_qbit/qpu --backend ibm:<バックエンド名>
```

### experiment の流れ

置き場は `results/ibm_<名前>_<日時>/`。三つの段を、同じ Batch の中で続ける。

| 段 | 内容 | 目安 |
|---|---|---:|
| 整列 | 全量子ビットを同時に測り、語の種類ごとの倍率と、寄せる集合の表を作る。表はこの実行の中だけで使う | 311 秒 |
| 同定の段 | C1〜C7 の回路を、互いに隣り合わない領域へ詰め込んで走らせる | 48 秒 |
| 本計算ごとの整列 | メッセージごとに、推定、準備、本計算、再推定を続ける | 9 秒 |
| 合計 | | 368 秒 |

- 目安は、1 shot を 0.3 ms、深いハッシュ回路を 1.6 ms、回路 1 本あたりの固定の時間を 0.05 秒として数える。固定の時間は実測が無い置き値。
- `--max-time` は目安の 1.2 倍（約 442 秒）以上が要る。`--budget`（既定 400 秒）を目安が越えるときも、送らない。
- 状態は start → backend → planned → state_estimation → planning → reestimation → checks → route → identify → pre_estimate → unit_planning → compute → post_estimate → executed → analysis → done。

### 引数

| 引数 | 既定 | 意味 |
|---|---|---|
| `--backend` | 必須 | `ibm:<名前>`（実機）、`sim:counter`、`sim:standard`（FakeFez の配線の仮想の装置。結果は合成） |
| `--count` | 156 | 整列する量子ビットの数（誤りが小さい順） |
| `--regions` | 8 | 同定の段で、同じ回路を複製する領域の数 |
| `--max-time` | `8m` | Batch が開いている時間の上限 |
| `--budget` | 400 | 装置の時間の目安の上限（秒） |
| `--instance` | 保存した既定 | IBM Cloud の instance（CRN） |
| `--dry-run` | | 目安だけを表示する |

### 詰め込み

heavy-hex の配線から、互いに隣り合わない（量子ビットを共有せず、間に配線が無い）結合した 2 量子ビットを、誤りの小さい順に 3 × `--regions` 組選び（整数計画）、
主な配置（main）、交換した配置 L1、L2 へ `--regions` 組ずつ分ける。ibm_fez の配線に置ける最大は 48 組。

- 同定の回路は、組の全領域へ複製して 1 本の広い回路にする。領域 1 つの shot は、全体の shot を領域の数で割った値。広い回路の時間は shot で決まり、領域の数に依らない。
- 前史の複製（omega）は L1、L2。連続する shot の一致を読む回路（順序つき）は、領域 1 つだけで、shot を分けずに走らせる。
- 結果は領域ごとに分け、足し合わせて回路ごとの記録（`r0/<id>.json`）にする。解析は、領域を足した counts を読む。領域ごとの counts は `record/raw_counts.jsonl.gz`。

### 本計算ごとの整列

本計算の単位は、1 メッセージ m の出力 d = H(m)（ビット d_t ごとに 1 量子ビット、8 メッセージで 64 量子ビット）。全メッセージを 1 本の広い回路にして、次を続ける。

1. 推定: 語なし、表の集合 S^hi、S^lo の 3 回路を測り、量子ビットごとの今の R0、R^hi、R^lo を得る。
2. 準備: cmn が、表の倍率と今の R0 から、集合 S^hi、S^lo を決め直す。
3. 本計算: H、結果 d_t へ寄せる語の集合、H H、測定。
4. 再推定: 決め直した集合で、3 回路をもう一度測る。

メッセージごとの全ビット一致と、整列の時点、推定、再推定の R は、`record/units.json` と `report.md`（本計算ごとの整列）に出る。

## 別々に走らせる場合（align と all）

整列と本計算を別のコマンドで走らせるときは、次の三つのコマンドを、この順に、リポジトリの最上位（`build_tools` と `continuous_republic` が並ぶディレクトリ）で実行する。
`<バックエンド名>` は `ibm_fez` のような実機の名前。資格情報は `QiskitRuntimeService.save_account` で保存しておく（コマンドは資格情報を扱わない）。
instance を選ぶときだけ、各コマンドに `--instance <CRN>` を足す。

1. 時間の見積り。何も走らせない。

```
build_tools/venv/Scripts/python -m common_qbit.qpu align continuous_republic/examples/common_qbit/qpu --backend ibm:<バックエンド名> --count 156 --dry-run
```

2. 整列。装置の時間を約 300 秒使う。表が `alignment/<バックエンド名>.json` に書かれる。

```
build_tools/venv/Scripts/python -m common_qbit.qpu align continuous_republic/examples/common_qbit/qpu --backend ibm:<バックエンド名> --count 156
```

3. 本計算と報告。装置の時間を約 150 秒使う。2 の表を読み、整列した量子ビットで走らせる。

```
build_tools/venv/Scripts/python -m common_qbit.qpu all continuous_republic/examples/common_qbit/qpu --backend ibm:<バックエンド名> --layout aligned --hash-form aligned --shots 1024 --rounds 1 --max-time 8m
```

### align の引数

指定が要るのは `--backend` と `--count` だけ。ほかは既定のままでよい。

| 引数 | 既定 | 意味 |
|---|---|---|
| `--backend ibm:<名前>` | `aer`（仮想の装置） | 走らせる装置。`ibm:` を付けると実機 |
| `--count` | 16 | 整列する量子ビットの数。ibm_fez は 156 個。全量子ビットを同時に測るので、増やしても装置の時間は増えない |
| `--shots` | 4096 | 1 回路あたりの shot。状態推定は 2048 ずつ二組に分けて測る |
| `--target` | 100 | 目標の倍率 T。寄せた結果の誤り率は 1/(1+T)。検証に shot が T の 10 倍（既定で 1000）要る |
| `--rounds` | 1 | 全体の繰り返し。2 にすると装置の時間も 2 倍 |
| `--types` | 160 | 語の種類の数（仮想 rz 64、x 軸のパルス 64、測定を含む語 32） |
| `--classes` | `virtual,pulse,measure` | 寄せる集合に使う語の組 |
| `--qubits` | `auto` | 物理量子ビットの番号（例 `0,1,2`）。`auto` は誤りが小さい順に `--count` 個 |
| `--max-time` | `8m` | Batch が開いている時間の上限。目安の 1.2 倍より短いと、送る前に止まる |
| `--instance` | 保存した既定 | IBM Cloud の instance（CRN） |
| `--dry-run` | | 回路数と時間の目安だけを表示する |

装置の時間は、回路数 × shot × 0.3 ms で決まり、`--count` に依らない。既定は回路 243 本、shot 995328、目安 299 秒。
`--max-time 8m`（480 秒）は目安の約 1.6 倍で、足りるかどうかは `--dry-run` が確かめる。

`align` に `--layout` は無い。どの物理量子ビットを使うかは、整列の結果として表に入る。`all` の `--layout aligned` が、その表を読む。

### all の引数（この手順で使うもの）

| 引数 | 値 | 意味 |
|---|---|---|
| `--layout aligned` | | 同定の段を、整列した量子ビットのうち結合している組で走らせる |
| `--hash-form aligned` | | ハッシュの出力のビットごとに、整列した量子ビットへ「そのビットへ寄せる語の集合」を当てる |
| `--shots 1024` | 既定 4096 | 同定の段の shot。既定のままだと装置の時間が約 4 倍になる |
| `--rounds 1` | 既定 3 | 繰り返しの回数。既定のままだと 3 倍になる |
| `--max-time 8m` | 既定 2h | 目安 150 秒の約 3 倍。短すぎれば、送る前に止まる |

`--backend` を `ibm:` なしの名前にすると、同じ手順を仮想の装置で試せる。整列の表が無いと `all` は止まるので、先に `align` を走らせる。
装置の状態が変わったら、整列を走らせ直す。表に作成の時刻がある。

## 一つのコマンドで走らせる

装置を待たせないよう、書き出し、同定の全回路、ハッシュ、報告までを一つのコマンドで続ける。IBM では全回路を一つの Batch で送り、
終わると Batch が閉じる。エラーや中断のときは、終わっていない job を取り消してから閉じる。

```
build_tools/venv/Scripts/python -m common_qbit.qpu all continuous_republic/examples/common_qbit/qpu --backend ibm:<バックエンド名> --layout auto --shots 4096 --rounds 3 --max-time 2h
```

- `--dry-run` は、何も走らせず、回路数と装置の時間の目安を表示する（同定の段は 1 shot を 0.3 ms、ハッシュ段は 1.6 ms とする。ibm_fez の実測）。
- `--max-time` が目安の 1.2 倍より短いときは、送る前に止まる。
- `--layout 0,1` は、全回路で使う物理量子ビット。`auto` は、結合した組のうち誤りが最小の組を選ぶ。結果に記録する。
- `--rounds` は繰り返しの回数（3 以上）。回ごとに回路の順序を無作為に並べ、校正を 4 か所に置く。
- `--hash toy`（既定）は、同定の後に 8 ビットのハッシュ（`cmn/hash.cmn`）を走らせる。`sha256d` は 256 ビットの SHA-256d（`cmn/sha256d.cmn`）で、
  出力を `--hash-width` ビット（IBM は既定 32）ずつの区間に分ける。`off` は走らせない。`--hash-shots` はメッセージごとの shot（既定 1024）。
- `--hash-form` は回路の形。`both`（既定）は並列と直列の両方で、二つの差が測定座標の共有の有無を示す。
  回路の大きさは `--dry-run` が表示する。
- `--families core`（既定）は判定に使う回路。`all` は待機・隣の量子ビット・順序の閉路・移送の記録も取る（装置の時間が約 2 倍）。
- `--instance <CRN>` は IBM Cloud の instance。省くと保存した既定を使う。
- 実行ごとの置き場は `results/ibm_<名前>_<日時>/`（日時は開始の時刻 `YYYYMMDD-HHMMSS`。同じ秒に二つ始めると `_2`、`_3` を付ける）。中身は次の形。

      r<回>/<id>.json        回路ごとの counts、配置、書いた時刻、job の番号（実機）
      run.json              実行の設定
      report.md, report.json 報告。末尾の「実行の記録」に、状態の遷移、job、装置の状態の前後
      record/journal.jsonl  状態の遷移と出来事（1 件ずつ書き足す。途中で止まっても、そこまでが残る）
      record/environment.json    コマンド、ソフトウェアの版、計画（全回路の id、shot、配置）
      record/backend_start.json  実行前の装置の状態（量子ビットごとの T1、T2、誤り、2 量子ビットゲート、配線、待ち行列、較正の生のデータ）
      record/backend_end.json    実行後の同じ記録（較正が実行中に変わったかは、二つの差で分かる）

  状態は start → backend → planned → identify → hash → executed → analysis → done。どこからでも failed、cancelled に移る。

## 整列の仕組み

最悪の初期状態の量子ビットを、全量子ビット同時に整列する（手順は上の「実機で走らせる手順」）。整列の表は `alignment/<装置>.json`（と `.md`。最新の表）と、
実行ごとの置き場 `alignment/<装置>_<日時>/`（`table.json`、`table.md`、`record/`）に書かれ、`all` の `--layout aligned` と `--hash-form aligned` が使う。
整列は 156 量子ビット、語の種類 160、4096 shot で、回路 243 本、装置の時間の目安が 300 秒。判定 J1〜J9（CLAIMS.md §5.1）が、整列の `.md` に出る。

- `--target` は目標の倍率 T。寄せた結果の誤り率は 1/(1+T)。検証には shot が T の 10 倍要る。
- `--layout aligned` は、同定の段を、整列した量子ビットのうち結合している組（寄せる力が大きいもの）で走らせる。
- `--hash-form aligned` は、出力のビットごとに、整列した量子ビットへ「結果 d_t へ寄せる語の集合」を当てる。`all` は三つの形を全部走らせる。
- 装置の状態が変わったら、整列を走らせ直す。表に作成の時刻がある。

同じ流れを仮想の装置で試せる。

```
build_tools/venv/Scripts/python -m common_qbit.qpu all continuous_republic/examples/common_qbit/qpu --backend aer --shots 2048 --rounds 3
```

初回のみ、次の準備が要る。

```
build_tools/venv/Scripts/python -m pip install qiskit-ibm-runtime
build_tools/venv/Scripts/python -c "from qiskit_ibm_runtime import QiskitRuntimeService as S; S.save_account(channel='ibm_cloud', token='<API キー>', instance='<instance の CRN>', set_as_default=True, overwrite=True)"
```

## 回路の語

回路は標準の量子ゲート（h、x、sx、sxdg、rz、cx、delay、reset、measure）で書く。語 $W$ は、標準の量子論では恒等になる操作列である。

| 語 | 中身 |
|---|---|
| `echo_xx` | x x |
| `sx4` | sx を 4 回 |
| `sx4inv` | sxdg を 4 回（`sx4` の逆。パルスは違う） |
| `h2` | h h |
| `cx2` | cx cx（量子ビット 0 と 1） |
| `delay512` | 512 dt の待機 |

位相掃引は Ramsey の回路である。

$$
|0\rangle\to H\to W^N\to \mathrm{rz}(\phi)\to H\to\text{測定},
\qquad
C(\phi)=\frac{P_0(\phi)-S_0}{G}
$$

標準の予言は $A=1,\ B=0$ である。位相 $\phi=0,\pi/2,\pi,3\pi/2$ の四点から $A=\tfrac12\bigl(C(0)-C(\pi)\bigr)$、$B=\tfrac12\bigl(C(\pi/2)-C(3\pi/2)\bigr)$（式 8.8、8.9）を求め、$z_j=(r,\omega)=(A,B)$ とする。
`preparation_rot` の回路は $W$ の前に $\mathrm{rz}(\pi/2)$ を置き、$z_0$ の向きが直交する二組目になる。

$W$ を $N$ 回当てたときの $z_N$ を、一回の作用 $L$ で書く（式 10.11、10.12）。

$$
z_N=L^Nz_0,\qquad L=\exp(g_0I+g_iJ_i+g_jJ_j+g_KK)
$$

論文の事前準備語（式 9.2）は $g_0=-\lambda_W$、$g_j=\eta_W$、$g_i=g_K=0$ の場合である。

## 一つずつ使う

```
python -m common_qbit.qpu export <このディレクトリ>
python -m common_qbit.qpu report <このディレクトリ> --results <このディレクトリ>/results/<バックエンド>
```

`report` の `--results` を省くと、最後に書いた実行の場所を読む。各回路のディレクトリに、`circuit.qasm`（OpenQASM 3）、
`circuit.png`（回路図）、`plan.json`（論文の式、位相、パラメータ）がある。一覧は `Index.md` と `manifest.json`。
