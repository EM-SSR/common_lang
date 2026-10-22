# -*- coding: utf-8 -*-
"""前向き一回を段の表へ組む。lane は隠れ次元の添字になる。

`walk.nest` の一段が出すのは

$$\\text{値}=\\sum_{j<K} M\\bigl[\\,\\text{係数の先頭}+j\\,\\bigr]\\cdot M\\bigl[\\,\\text{入力の先頭}+j\\,\\bigr]
\\;+\\;M\\bigl[\\,\\text{引きの先頭}+\\text{引きの添字}\\,\\bigr]$$

と、フラグ $\\bigl[\\,M[b]\\le M[a]\\,\\bigr]$。表の一段は九語で、項の数 $K$ は走時の値になる。

## 置き場の決め

| 種 | どこ | 誰のものか |
|---|---|---|
| 共有の枠 | 共有メモリ | 全 lane で一つ。中間のベクトル、係数、表 |
| lane の枠 | lane の作業領域 | lane ごとに違う。自分の行の先頭番地など |

一段の書き込み先が共有メモリなら、そこが接合点になって grid 全体の足並みが揃う。

## 線形の段

$y_h=\\sum_k W[h,k]x[k]$ は、係数の先頭を **lane の枠**（$W$ の行の先頭）、入力の先頭を
**共有の枠**（$x$ の先頭）に置いた一段で書ける。出す枠も lane ごとに違う位置を指す。

## 縮約の段

平均や和のように lane をまたぐものは、全 lane が同じ内積を走らせる。無駄に見えるが
分岐が無いので足並みが揃い、共有メモリの読みは cache に乗る。
"""


class Sheet(object):
    """枠を配り、九語の段を並べる。走らせるのは `lane.Joint`。"""

    HEAD = 9

    def __init__(self, lanes):
        self.lanes = lanes
        self.shared = []          # 共有メモリへ置く値（None は走時に埋める）
        self.per = []             # lane ごとの語（(lane 数,) の並び）
        self.rows = []            # 段
        self.const = {}
        self._zero = None
        self._zero_at = None

    # -- 枠 --
    def sh(self, values):
        """共有の枠を len(values) 語ぶん取る。返りは先頭の枠番号。"""
        head = len(self.shared)
        self.shared.extend(int(v) for v in values)
        return head

    def sh_room(self, n):
        """共有の枠を n 語ぶん空けて取る。"""
        return self.sh([0] * n)

    def lane_word(self, values):
        """lane ごとに違う語を一つ取る。values は lane 数ぶんの並び。"""
        self.per.append(list(int(v) for v in values))
        return -len(self.per)          # 負の番号は lane の枠を指す

    def imm(self, v):
        v = int(v)
        if v not in self.const:
            self.const[v] = self.sh([v])
        return self.const[v]

    @property
    def zero(self):
        if self._zero is None:
            self._zero = self.imm(0)
        return self._zero

    @property
    def zero_at(self):
        """「零の在る番地」の枠。引きを使わない段がここを指す。"""
        if self._zero_at is None:
            self._zero_at = self.sh([0])       # 走らせる前に零の枠の番地を入れる
        return self._zero_at

    # -- 段 --
    def row(self, out, k=None, wbase=None, xbase=None,
            look=None, flag=None, less=None):
        """一段。使わない所は零へ向ける。

        `k` は項の数を持つ枠、`wbase`/`xbase` は先頭番地を持つ枠。
        """
        self.rows.append((
            out,
            k if k is not None else self.imm(1),
            wbase if wbase is not None else self.zero_at,
            xbase if xbase is not None else self.zero_at,
            look[0] if look else self.zero_at,
            look[1] if look else self.zero,
            flag if flag is not None else self.sh_room(1),
            less[0] if less else self.zero,
            less[1] if less else self.zero,
        ))
        return out

    # -- 組み立て --
    def linear(self, out, wbase, xbase, k):
        """$y=\\sum_j M[wbase+j]M[xbase+j]$。wbase は lane の枠でよい。"""
        return self.row(out, k=self.imm(k), wbase=wbase, xbase=xbase)

    def copy(self, out, src):
        """一語を写す。$1\\cdot M[src]$ の内積。"""
        ptr = self.sh([0])                        # src の番地を持つ枠（host が埋める）
        return self.row(out, k=self.imm(1), wbase=self.imm_ptr_one(), xbase=ptr), ptr

    def imm_ptr_one(self):
        """一が並ぶ帯の先頭番地を持つ枠。長い内積の係数を全部一にするのに使う。"""
        if not hasattr(self, "_ones"):
            self._ones_head = self.sh([1] * 64)
            self._ones = self.sh([0])             # 先頭番地（host が埋める）
        return self._ones

    def look(self, out, base_slot, index_slot):
        """$M[\\,M[base]+M[index]\\,]$。テーブル参照。"""
        return self.row(out, look=(base_slot, index_slot))

    def less(self, flag, a, b):
        """$[\\,M[b]\\le M[a]\\,]$ をフラグの枠へ。"""
        return self.row(self.sh_room(1), flag=flag, less=(a, b))

    # -- 表 --
    def table(self):
        """段の表（枠番号のまま）を返す。番地へ直すのは走らせる側。"""
        return [list(r) for r in self.rows]
