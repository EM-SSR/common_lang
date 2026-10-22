# ハッシュの回路（sha256d）

メッセージ $m$ の出力 $d=\mathrm{SHA\text{-}256d}(m)$（256 ビット）は `cmn/sha256d.cmn` が計算する。
量子ビット $t$ が出力のビット $d_t$ である。H を全量子ビットに当て、$W_{d_t}$ を当て、全量子ビットを並列に測って古典ビット $c_t$ に入れる。

| 回路 | $W_x$ | 走らせる場所 |
|---|---|---|
| `transport` | 移送 $B_x$（`counter_transport`、$x=d_t$）。下位の量子ビットから順に当てる | lane-qbit（cmn） |
| `steer` | `sx4inv`（$d_t=0$）または `sx4`（$d_t=1$）を $N$ 回。ここでは $N=2$ | 実機 |
| `steer_isa` | `steer` を rz、sx、x へ分けた回路 | 実機（パルスの並び） |

実機の $N$ は、同定のメビウスの表から実行時に決まる。`steer` の語のゲート列を $N$ 回繰り返す。

| メッセージ | 出力 $d$ | 平文から取り出した命令が元の回路に一致 | lane-qbit で $d$ に一致した shot | 標準理論の異なる出力の数 | `transport` の命令数 | `steer_isa` の命令数 |
|---|---|---|---:|---:|---:|---:|
| Common | 7fdc87fcbaa51386bb1822a9e34ed922540d728cca271cba9fcd552bd435578f | 一致 | 16 / 16 | — | 768 | 8544 |
| Counter | 82213f4c35c12bb06d1afb8e4738cb561711b27bd8f1699731ca4fbf34b67be0 | 一致 | 16 / 16 | — | 768 | 8576 |
| Counter quantum information theory: a deterministic SHA-256d on lane-qbit, 80 by | fbca5318ee3bc44902e8641cefe8f2d2b54f294a02c7b596f34245b664deba06 | 一致 | 16 / 16 | — | 768 | 8704 |
| lane-qbit | ee36ca12f5d171325f3f16341eb37bc487fa8e7a0635020cd7224607da4342fd | 一致 | 16 / 16 | — | 768 | 8704 |

出力 $d$ は 16 進。最下位のビットが量子ビット 0。
