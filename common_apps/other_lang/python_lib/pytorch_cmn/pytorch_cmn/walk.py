# -*- coding: utf-8 -*-
"""段をまたぐ受け渡しを一つの Ω 閉包に入れる。

Python の `for` で段を回すと閉包が切れる。代わりに、lane が自分の**段の表**を持つ。

    表 = [ 係数の先頭, 入力の先頭, 出す枠, 係数の先頭, 入力の先頭, 出す枠, ... ]

一段ぶんの本体は

    1. 表から三つ読む
    2. K 項を足し合わせる
    3. 出す枠へ書く（共有メモリへの書き込みが合図になり、grid 全体が揃う）
    4. 表の位置を 3 進める

で、これを `ya` … `yi` で包む。段の数だけ回ったかは、作業領域の勘定を減らして見る。
全 lane が段ごとに同じ回数だけ書くので、足並みを揃える道（`lane64_runb`）が使える。

作業領域の語:

| 語 | 中身 |
|---|---|
| `TAB` | 自分の段の表の先頭番地（共有メモリ） |
| `LEFT` | 残りの段の数 |
| `OUT`  | 見るための控え（最後に足し合わせだ値） |
"""
from . import fold

TAB = fold.ROW           # 段の表の先頭
LEFT = fold.ROW + 1      # 残りの段の数
OUT = fold.ROW + 2       # 控え

at = fold.at
ladder = fold.ladder


def _cell(ptr_word, off):
    """作業領域の語が指す先から off だけ離れた共有メモリの語を読む。"""
    w = at(ptr_word)
    if off:
        w += ladder(off) + ["acc"]
    return w + ["read"]


def body(k):
    """一段ぶん。表から三つ読んで内積、出す枠へ書き、表を進める。"""
    lines = []
    # 係数の先頭と入力の先頭を、表の 0 番と 1 番から取る
    for j in range(k):
        lines.append(" ".join(_cell(TAB, 0) + ladder(j) + ["acc", "read"]))
        lines.append(" ".join(_cell(TAB, 1) + ladder(j) + ["acc", "read"]))
        lines.append("ext" if j == 0 else "ext acc")
    # 控えへ置く（人が見るため）
    lines.append(" ".join(ladder(OUT) + ["keep"]))
    # 出す枠へ書く。共有メモリへの書き込みが接合点になる
    lines.append(" ".join(at(OUT)))
    lines.append(" ".join(_cell(TAB, 2)))           # 表の三番目が出す枠の番地
    lines.append("keep")
    # 表を三つ進める
    lines.append(" ".join(at(TAB) + ladder(3) + ["acc"] + ladder(TAB) + ["keep"]))
    # 残りを一つ減らす
    lines.append(" ".join(at(LEFT) + ["unit", "flip", "acc"] + ladder(LEFT) + ["keep"]))
    return lines


def text(k, steps=None):
    """段の表を辿る平文。`steps` を渡すとその回数だけ開いて閉じる（閉包を展開しない形）。"""
    lines = ["unit twin ext drop"]
    lines.append("open")
    lines += ["  " + s for s in body(k)]
    # フラグ: 残りが 0 以下になったら閉じる。`yi` は Bit を食うので比較の出力をそのまま渡す。
    # `X, Y, edge` = [Y ≤ X] なので、先に 0 を置いて後に残りを置く
    lines.append("  " + " ".join(["zero"] + at(LEFT) + ["edge"]))
    lines.append("shut")
    lines.append("said")
    return "\n".join(lines) + "\n"


def flat(k, steps):
    """同じ本体を steps 回並べた形。閉包の値段と突き合わせるために使う。"""
    lines = ["unit twin ext drop"]
    for _ in range(steps):
        lines += body(k)
    lines.append("said")
    return "\n".join(lines) + "\n"


# ---- どのノードも K 項の内積になる ---------------------------------------
#
# 表の一段が
#
#     [ 出す枠, w0, x0, w1, x1, ..., w_{K-1}, x_{K-1} ]
#
# で、w も x も**枠の番地**になる。だから
#
#     掛け算 a·b        K=1、(a の枠, b の枠)
#     足し算 a+b        K=2、(一の枠, a の枠), (一の枠, b の枠)
#     行列の一行        K=幅、(係数の枠, 入力の枠) を並べる
#
# が同じ本体で書ける。項が足りない段は (零の枠, 零の枠) で埋める。


def pairs(k):
    """枠の番地の対を K 組たどる本体。どのノードもこの形に落ちる。"""
    lines = []
    for j in range(k):
        lines.append(" ".join(_cell(TAB, 1 + 2 * j) + ["read"]))
        lines.append(" ".join(_cell(TAB, 2 + 2 * j) + ["read"]))
        lines.append("ext" if j == 0 else "ext acc")
    lines.append(" ".join(ladder(OUT) + ["keep"]))
    lines.append(" ".join(at(OUT)))
    lines.append(" ".join(_cell(TAB, 0)))
    lines.append("keep")
    lines.append(" ".join(at(TAB) + ladder(1 + 2 * k) + ["acc"] + ladder(TAB) + ["keep"]))
    lines.append(" ".join(at(LEFT) + ["unit", "flip", "acc"] + ladder(LEFT) + ["keep"]))
    return lines


def graph(k):
    """段の表を辿る閉包。段の数は表と勘定で決まるので、平文には出ない。"""
    return "\n".join(["unit twin ext drop", "open"]
                     + ["  " + s for s in pairs(k)]
                     + ["  " + " ".join(["zero"] + at(LEFT) + ["edge"]), "shut", "said"]) + "\n"


# ---- 内積に「テーブル参照」を一つ足す -------------------------------------------
#
# 表の一段が
#
#     [ 出す枠, 引きの先頭の枠, 引きの添字の枠, w0, x0, ..., w_{K-1}, x_{K-1} ]
#
# で、出る値は
#
#     Σ_j M[w_j] · M[x_j]  +  M[ M[引きの先頭] + M[引きの添字] ]
#
# になる。内積だけの段は、引きの先頭に「零の在る番地」を、添字に零の枠を置く。
# 引きだけの段は、係数を全部零の枠にする。分子を右へ寄せる手が無いので、$e^x$ や
# $1/\sqrt x$ は格子の引きで出す（定理 7.1 の $f_d(x)=\sum_v W_v(x)f(v)$ の、
# 格子の刻みが分子の刻みに等しい場合）。
#
# 一段の共有メモリへの書き込みは一回だけなので、足並みを揃える道がそのまま使える。

# 一段の頭: 出す枠、引きの先頭、引きの添字、フラグを出す枠、比べる二つ
STRIDE_HEAD = 6


def mixed(k):
    """内積 K 組と引き一つ。どのノードもこの形に落ちる。"""
    lines = []
    for j in range(k):
        lines.append(" ".join(_cell(TAB, STRIDE_HEAD + 2 * j) + ["read"]))
        lines.append(" ".join(_cell(TAB, STRIDE_HEAD + 2 * j + 1) + ["read"]))
        lines.append("ext" if j == 0 else "ext acc")
    # 引き: M[ M[先頭] + M[添字] ]
    lines.append(" ".join(_cell(TAB, 1) + ["read"]))
    lines.append(" ".join(_cell(TAB, 2) + ["read"]))
    lines.append("acc")
    lines.append("read")
    lines.append("acc")
    # 控えて、出す枠へ書く（共有メモリへの書き込みが接合点）
    lines.append(" ".join(ladder(OUT) + ["keep"]))
    lines.append(" ".join(at(OUT)))
    lines.append(" ".join(_cell(TAB, 0)))
    lines.append("keep")
    # 比べ: [ M[四番目] ≤ M[三番目] ] をフラグの枠へ。max と argmax がこれで書ける
    lines.append(" ".join(_cell(TAB, 4) + ["read"]))
    lines.append(" ".join(_cell(TAB, 5) + ["read"]))
    lines.append("under")
    lines.append(" ".join(ladder(OUT) + ["keep"]))
    lines.append(" ".join(at(OUT)))
    lines.append(" ".join(_cell(TAB, 3)))
    lines.append("keep")
    lines.append(" ".join(at(TAB) + ladder(STRIDE_HEAD + 2 * k) + ["acc"] + ladder(TAB) + ["keep"]))
    lines.append(" ".join(at(LEFT) + ["unit", "flip", "acc"] + ladder(LEFT) + ["keep"]))
    return lines


def board(k):
    """段の表を辿る閉包。内積と引きの両方が同じ本体で通る。"""
    return "\n".join(["unit twin ext drop", "open"]
                     + ["  " + s for s in mixed(k)]
                     + ["  " + " ".join(["zero"] + at(LEFT) + ["edge"]), "shut", "said"]) + "\n"


# ---- 入れ子: 外を段、内を項 -----------------------------------------------
#
# 表に項を並べると、表が係数より大きくなる。項は内側の閉包で回す。一段の表は
# **九語で固定**になり、項の数 K は走時の値になる。
#
#     [ 出す枠, 項の数, 係数の先頭, 入力の先頭, 引きの先頭, 引きの添字,
#       フラグの枠, 比べる二つ ]
#
# 出る値は
#
#     Σ_{j<K} M[ M[係数の先頭] + j ] · M[ M[入力の先頭] + j ]
#       + M[ M[引きの先頭] + M[引きの添字] ]
#
# フラグは [ M[比べ二] ≤ M[比べ一] ]。`ya` は本体を必ず一度は歩くので、項を持たない段も
# K=1 にして、先頭を零の枠へ向ける。

ROW9 = 9                 # 一段の語数
J = fold.ROW + 3         # 項の位置
ACC = fold.ROW + 4       # 内積の途中


def nest():
    """外を段、内を項で回す平文。項の数も段の数も表が決める。"""
    L = []
    L.append("unit twin ext drop")
    L.append("open")
    #  項の位置と途中を初期化
    L.append("  " + " ".join(["zero"] + ladder(J) + ["keep"]))
    L.append("  " + " ".join(["zero"] + ladder(ACC) + ["keep"]))
    L.append("  open")
    #  表は枠の番地を持つので、先頭の番地を取るには二度読む
    L.append("    " + " ".join(_cell(TAB, 2) + ["read"] + at(J) + ["acc", "read"]))
    L.append("    " + " ".join(_cell(TAB, 3) + ["read"] + at(J) + ["acc", "read"]))
    L.append("    ext")
    L.append("    " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("    " + " ".join(at(J) + ["unit", "acc"] + ladder(J) + ["keep"]))
    #  フラグは [ K ≤ j ]。`X, Y, edge` = [Y ≤ X] なので、先に j を置いて後に K を置く
    L.append("    " + " ".join(at(J) + _cell(TAB, 1) + ["read", "edge"]))
    L.append("  shut")
    #  引きを足す
    L.append("  " + " ".join(_cell(TAB, 4) + ["read"] + _cell(TAB, 5) + ["read", "acc", "read"]))
    L.append("  " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    #  出す枠へ（共有メモリへの書き込みが接合点）
    L.append("  " + " ".join(at(ACC)))
    L.append("  " + " ".join(_cell(TAB, 0)))
    L.append("  keep")
    #  比較のフラグ
    L.append("  " + " ".join(_cell(TAB, 7) + ["read"] + _cell(TAB, 8) + ["read", "under"]))
    L.append("  " + " ".join(ladder(OUT) + ["keep"]))
    L.append("  " + " ".join(at(OUT)))
    L.append("  " + " ".join(_cell(TAB, 6)))
    L.append("  keep")
    #  表と勘定を進める
    L.append("  " + " ".join(at(TAB) + ladder(ROW9) + ["acc"] + ladder(TAB) + ["keep"]))
    L.append("  " + " ".join(at(LEFT) + ["unit", "flip", "acc"] + ladder(LEFT) + ["keep"]))
    L.append("  " + " ".join(["zero"] + at(LEFT) + ["edge"]))
    L.append("shut")
    L.append("said")
    return "\n".join(L) + "\n"


# ---- 歩幅つきのエンジン -------------------------------------------------------
#
# 一段の表は十二語。
#
#     [ 出す先頭, 出す歩幅, 項の数, 係数の先頭, 係数の歩幅,
#       入力の先頭, 入力の歩幅, 引きの先頭, 引きの添字, フラグの先頭, 比べ一, 比べ二 ]
#
# 番地は
#
#     M[先頭] + M[歩幅]·（lane の番号） + j
#
# になる。歩幅で三通りが書ける。
#
#     線形      係数の歩幅 = K、入力の歩幅 = 0     y_h = Σ_j W[h,j]·x[j]
#     要素ごと  どちらも歩幅 1、項の数 1           y_h = a[h]·b[h]
#     縮約      どちらも歩幅 0                     全 lane が同じ和を出す
#
# lane の番号は作業領域の語 IDX に入る（host が置く）。

ROW12 = 12
IDX = fold.ROW + 5       # この lane の番号
WP = fold.ROW + 6        # 係数の位置
XP = fold.ROW + 7        # 入力の位置
OP = fold.ROW + 8        # 出す位置


def _base(off_head, off_stride, dst):
    """M[先頭] + M[歩幅]·M[IDX] を dst の語へ置く。"""
    return " ".join(_cell(TAB, off_head) + ["read"]
                    + _cell(TAB, off_stride) + ["read"] + at(IDX) + ["ext"]
                    + ["acc"] + ladder(dst) + ["keep"])


def engine():
    """歩幅つきの段を辿る閉包。外が段、内が項。"""
    L = ["unit twin ext drop", "open"]
    L.append("  " + _base(3, 4, WP))
    L.append("  " + _base(5, 6, XP))
    L.append("  " + _base(0, 1, OP))
    L.append("  " + " ".join(["zero"] + ladder(J) + ["keep"]))
    L.append("  " + " ".join(["zero"] + ladder(ACC) + ["keep"]))
    L.append("  open")
    L.append("    " + " ".join(at(WP) + at(J) + ["acc", "read"]))
    L.append("    " + " ".join(at(XP) + at(J) + ["acc", "read"]))
    L.append("    ext")
    L.append("    " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("    " + " ".join(at(J) + ["unit", "acc"] + ladder(J) + ["keep"]))
    L.append("    " + " ".join(at(J) + _cell(TAB, 2) + ["read", "edge"]))
    L.append("  shut")
    L.append("  " + " ".join(_cell(TAB, 7) + ["read"] + _cell(TAB, 8) + ["read", "acc", "read"]))
    L.append("  " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("  " + " ".join(at(ACC) + at(OP) + ["keep"]))
    L.append("  " + " ".join(_cell(TAB, 10) + ["read"] + _cell(TAB, 11) + ["read", "under"]))
    L.append("  " + " ".join(ladder(OUT) + ["keep"]))
    L.append("  " + " ".join(at(OUT) + _cell(TAB, 9) + ["read"] + at(IDX) + ["acc", "keep"]))
    L.append("  " + " ".join(at(TAB) + ladder(ROW12) + ["acc"] + ladder(TAB) + ["keep"]))
    L.append("  " + " ".join(at(LEFT) + ["unit", "flip", "acc"] + ladder(LEFT) + ["keep"]))
    L.append("  " + " ".join(["zero"] + at(LEFT) + ["edge"]))
    L += ["shut", "said"]
    return "\n".join(L) + "\n"


def engine_u(u):
    """内側を u 項ぶん展開したエンジン。

    項の数は走時の値のままで、内側の閉包は $\lceil K/u\rceil$ 回まわる。一項あたりの
    上乗せ（位置の更新・フラグ・番地の作り直し）が $1/u$ になるので、展開しない形より
    桁で速い。$K$ は $u$ の倍数にして、余りは零で埋める。

    表の一段は十二語で、三番目は**組の数** $K/u$ を持つ。
    """
    L = ["unit twin ext drop", "open"]
    L.append("  " + _base(3, 4, WP))
    L.append("  " + _base(5, 6, XP))
    L.append("  " + _base(0, 1, OP))
    L.append("  " + " ".join(["zero"] + ladder(ACC) + ["keep"]))
    L.append("  " + " ".join(_cell(TAB, 2) + ["read"] + ladder(J) + ["keep"]))   # 残りの組
    L.append("  open")
    for t in range(u):
        off = ladder(t) + ["acc"] if t else []
        L.append("    " + " ".join(at(WP) + off + ["read"]))
        L.append("    " + " ".join(at(XP) + off + ["read"]))
        L.append("    ext")
        L.append("    " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("    " + " ".join(at(WP) + ladder(u) + ["acc"] + ladder(WP) + ["keep"]))
    L.append("    " + " ".join(at(XP) + ladder(u) + ["acc"] + ladder(XP) + ["keep"]))
    L.append("    " + " ".join(at(J) + ["unit", "flip", "acc"] + ladder(J) + ["keep"]))
    L.append("    " + " ".join(["zero"] + at(J) + ["edge"]))
    L.append("  shut")
    L.append("  " + " ".join(_cell(TAB, 7) + ["read"] + _cell(TAB, 8) + ["read", "acc", "read"]))
    L.append("  " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("  " + " ".join(at(ACC) + at(OP) + ["keep"]))
    L.append("  " + " ".join(_cell(TAB, 10) + ["read"] + _cell(TAB, 11) + ["read", "under"]))
    L.append("  " + " ".join(ladder(OUT) + ["keep"]))
    L.append("  " + " ".join(at(OUT) + _cell(TAB, 9) + ["read"] + at(IDX) + ["acc", "keep"]))
    L.append("  " + " ".join(at(TAB) + ladder(ROW12) + ["acc"] + ladder(TAB) + ["keep"]))
    L.append("  " + " ".join(at(LEFT) + ["unit", "flip", "acc"] + ladder(LEFT) + ["keep"]))
    L.append("  " + " ".join(["zero"] + at(LEFT) + ["edge"]))
    L += ["shut", "said"]
    return "\n".join(L) + "\n"


# ---- 三軸の歩幅 ---------------------------------------------------------
#
# 一つの行列とベクトルの積は 1152×1152 = 1.3 M 積和しかない。lane を出力の添字だけに
# すると 1152 本で、GPU は空のまま回る。埋めるには三軸を同時に lane へ載せる。
#
#     lane ←→ ( 位置 p, 出力 h, 列の区間 b )
#
# 番地は
#
#     M[先頭] + s₁·i₁ + s₂·i₂ + s₃·i₃ + j
#
# になる。歩幅の組で三通りの形が出る。
#
#     係数   (0, H, K)      W[h, b·K + j]
#     入力   (H, 0, K)      x[p, b·K + j]
#     出す   (H·B, B, 1)    partial[p, h, b]
#
# prompt の位置を全部並べると、26 層 × 1152 出力 × 72 区間 × 512 位置 で lane は
# 数千万になる。掛け算は段の外で一度だけなので、内側の値段には乗らない。
#
# 表の一段は十八語。

ROW18 = 18
IDX1 = fold.ROW + 5
IDX2 = fold.ROW + 9
IDX3 = fold.ROW + 10
FP = fold.ROW + 11       # フラグを書く先


def _base3(head, s1, s2, s3, dst):
    """M[先頭] + Σ s_i·i_i を dst の語へ置く。段ごとに一度だけ。"""
    w = _cell(TAB, head) + ["read"]
    for off, idx in ((s1, IDX1), (s2, IDX2), (s3, IDX3)):
        w += _cell(TAB, off) + ["read"] + at(idx) + ["ext", "acc"]
    return " ".join(w + ladder(dst) + ["keep"])


def engine3(u):
    """三軸の歩幅つき、内側を u 項展開したエンジン。

    一段の表（十八語）:

        [ 出す先頭, 出す歩幅×3, 組の数, 係数の先頭, 係数の歩幅×3,
          入力の先頭, 入力の歩幅×3, 引きの先頭, 引きの添字, フラグの先頭, 比べ一, 比べ二 ]
    """
    L = ["unit twin ext drop", "open"]
    L.append("  " + _base3(5, 6, 7, 8, WP))
    L.append("  " + _base3(9, 10, 11, 12, XP))
    L.append("  " + _base3(0, 1, 2, 3, OP))
    L.append("  " + _base3(15, 1, 2, 3, FP))        # フラグは出力と同じ歩幅で置く
    L.append("  " + " ".join(["zero"] + ladder(ACC) + ["keep"]))
    L.append("  " + " ".join(_cell(TAB, 4) + ["read"] + ladder(J) + ["keep"]))
    L.append("  open")
    for t in range(u):
        off = ladder(t) + ["acc"] if t else []
        L.append("    " + " ".join(at(WP) + off + ["read"]))
        L.append("    " + " ".join(at(XP) + off + ["read"]))
        L.append("    ext")
        L.append("    " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("    " + " ".join(at(WP) + ladder(u) + ["acc"] + ladder(WP) + ["keep"]))
    L.append("    " + " ".join(at(XP) + ladder(u) + ["acc"] + ladder(XP) + ["keep"]))
    L.append("    " + " ".join(at(J) + ["unit", "flip", "acc"] + ladder(J) + ["keep"]))
    L.append("    " + " ".join(["zero"] + at(J) + ["edge"]))
    L.append("  shut")
    L.append("  " + " ".join(_cell(TAB, 13) + ["read"] + _cell(TAB, 14) + ["read", "acc", "read"]))
    L.append("  " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("  " + " ".join(at(ACC) + at(OP) + ["keep"]))
    # フラグは**そのステージの結果**としきい値を比べる。[ しきい値 ≤ 結果 ]。
    # relu はこれ 1 つで足りる（結果にフラグを掛ける段を 1 つ足すだけ）。
    L.append("  " + " ".join(at(ACC) + _cell(TAB, 16) + ["read", "under"]))
    L.append("  " + " ".join(ladder(OUT) + ["keep"]))
    L.append("  " + " ".join(at(OUT) + at(FP) + ["keep"]))
    L.append("  " + " ".join(at(TAB) + ladder(ROW18) + ["acc"] + ladder(TAB) + ["keep"]))
    L.append("  " + " ".join(at(LEFT) + ["unit", "flip", "acc"] + ladder(LEFT) + ["keep"]))
    L.append("  " + " ".join(["zero"] + at(LEFT) + ["edge"]))
    L += ["shut", "said"]
    return "\n".join(L) + "\n"


# ---- 足す項にも歩幅を持たせたエンジン -------------------------------------
#
# `engine3` の参照の項はスカラーひとつしか足せない。レーンごとに違う値を足せないと
# `a + b` が 1 ステージで書けないので、足す項にも三軸の歩幅を持たせる。
#
# 1 ステージの表は二十一語。
#
#     [ 出力の先頭, 出力の歩幅×3, 組の数,
#       係数の先頭, 係数の歩幅×3,
#       入力の先頭, 入力の歩幅×3,
#       足す項の先頭, 足す項の歩幅×3,
#       フラグの先頭, しきい値, 予備 ]
#
# 出る値は
#
#     Σ_{j<K} M[w+j]·M[x+j] + M[p]
#
# で、w・x・p・出力・フラグのアドレスはどれも 先頭 + s₁i₁ + s₂i₂ + s₃i₃ になる。
# フラグは [ しきい値 ≤ 出た値 ]。

ROW21 = 21
AP = fold.ROW + 12       # 足す項の位置


def engine4(u):
    """足す項にも歩幅を持たせた、内側 u 項展開のエンジン。"""
    L = ["unit twin ext drop", "open"]
    L.append("  " + _base3(5, 6, 7, 8, WP))
    L.append("  " + _base3(9, 10, 11, 12, XP))
    L.append("  " + _base3(13, 14, 15, 16, AP))
    L.append("  " + _base3(0, 1, 2, 3, OP))
    L.append("  " + _base3(17, 1, 2, 3, FP))        # フラグは出力と同じ歩幅
    L.append("  " + " ".join(["zero"] + ladder(ACC) + ["keep"]))
    L.append("  " + " ".join(_cell(TAB, 4) + ["read"] + ladder(J) + ["keep"]))
    L.append("  open")
    for t in range(u):
        off = ladder(t) + ["acc"] if t else []
        L.append("    " + " ".join(at(WP) + off + ["read"]))
        L.append("    " + " ".join(at(XP) + off + ["read"]))
        L.append("    ext")
        L.append("    " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("    " + " ".join(at(WP) + ladder(u) + ["acc"] + ladder(WP) + ["keep"]))
    L.append("    " + " ".join(at(XP) + ladder(u) + ["acc"] + ladder(XP) + ["keep"]))
    L.append("    " + " ".join(at(J) + ["unit", "flip", "acc"] + ladder(J) + ["keep"]))
    L.append("    " + " ".join(["zero"] + at(J) + ["edge"]))
    L.append("  shut")
    L.append("  " + " ".join(at(AP) + ["read"]))                 # 足す項
    L.append("  " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("  " + " ".join(at(ACC) + at(OP) + ["keep"]))
    L.append("  " + " ".join(at(ACC) + _cell(TAB, 18) + ["read", "under"]))
    L.append("  " + " ".join(ladder(OUT) + ["keep"]))
    L.append("  " + " ".join(at(OUT) + at(FP) + ["keep"]))
    L.append("  " + " ".join(at(TAB) + ladder(ROW21) + ["acc"] + ladder(TAB) + ["keep"]))
    L.append("  " + " ".join(at(LEFT) + ["unit", "flip", "acc"] + ladder(LEFT) + ["keep"]))
    L.append("  " + " ".join(["zero"] + at(LEFT) + ["edge"]))
    L += ["shut", "said"]
    return "\n".join(L) + "\n"


# ---- 引きの項を戻したエンジン ---------------------------------------------
#
# `engine3` は M[ M[先頭] + M[添字] ] を持っていたが、`engine4` はその枠を足す項へ
# 替えた。両方が要る。**引きが無いと e^x や 1/x を桁ごとに立てることになり、一つにつき
# 千段を越える**（`softmax` の 2004 段のうち 1738 段が桁を戻す所だった）。
#
# 一段の表は二十四語。
#
#     [ 出力の先頭, 出力の歩幅×3, 組の数,
#       係数の先頭, 係数の歩幅×3,
#       入力の先頭, 入力の歩幅×3,
#       足す項の先頭, 足す項の歩幅×3,
#       フラグの先頭, しきい値,
#       引きの表の先頭, 添字の先頭, 添字の歩幅×3 ]
#
# 出る値は
#
#     Σ_{j<K} M[w+j]·M[x+j] + M[p] + M[ g + M[t] ]
#
# で、g は表の先頭の絶対番地、t は添字の番地になる。引きを使わない段は、g に 0 の語の
# 番地を、t に 0 の語の番地を入れる。すると M[0 の語の番地 + 0] = 0 が足されるだけで
# 何も変わらない。

# ---- 桁ごとに立てるのを一つの閉包にする -----------------------------------
#
# `rshift` `recip` `isqrt` は Python の `for` で 1 bit につき 2〜4 行を表へ並べていた。
# 30 bit で 60〜120 行になり、1 行ごとに 333 命令のアドレス計算を払う。**桁を下ろす間
# アドレスは変わらない**ので、閉包の中で回せば本体だけで足りる。
#
# 三つは同じ形になる。
#
#     t = q + 2^k,   c = t·(A·t + B),   b = [ c ≤ L ],   q ← q + b·2^k
#
#              A    B        L
#     rshift   0    2^m      |x|
#     recip    0    |x|      2^{2f}
#     isqrt    1    0        |x|
#
# $L$ と $B$ は「定数 ＋ 係数×|x|」の形で表から取る。$2^k$ は引きの項で表から取る。
# 作業語しか触らないので共有領域への書き込みが起きず、グリッド全体の待ちも入らない。
# `ya` は 1 回は回るので、使わない行は最後に「使うか」0 で混ぜないようにする。

SG = fold.ROW + 15       # 符号
RR = fold.ROW + 16       # |x|
QQ = fold.ROW + 17       # 立てた桁の和
KK = fold.ROW + 18       # いま見ている桁
PP = fold.ROW + 19       # 2^k
BB = fold.ROW + 20       # その桁が立つか
PW = fold.ROW + 21       # 2^k の表の先頭
LL = fold.ROW + 22       # 比べる上限 L
BV = fold.ROW + 23       # 係数 B
TT = fold.ROW + 24       # 候補 t
CC = fold.ROW + 25       # 候補を通した値 c

# 行に沿った最大を取る閉包。$\bigvee$ は列の数だけ行を並べていた（列 k に対して 4k 行）。
# 語彙の大きさの softmax では 10^6 行になるので、閉包でなければ使えない。
#
#     m ← m + [ m ≤ x_j ]·( x_j − m )
#
# 和の閉包を遅くしないよう別に置く。使わない行では 1 回だけ回して捨てる。
MX = fold.ROW + 26       # いまの最大
J2 = fold.ROW + 27       # 最大を取る残り回数
XQ = fold.ROW + 28       # 最大を取るときの読み位置
VV = fold.ROW + 29       # 読んだ値

ROW35 = 35
# ---- 仕事の波 ----
#
# 物理の lane は GPU に同時に載る数（実測 55296）で頭打ちになる。grid 全体の待ちは
# 全 block が同時に載っていることを求めるので、これを越やせない。仕事はそれより多いので、
# **一本の lane が複数の仕事を順に持つ**。段の閉包の内側に波の閉包を入れ子にする
# （closure.nested §10.4。μ=∞ なので順は保たれる）。
#
#     i₁ ← i₁ + k·A      (k = 0, 1, ..., 波の数−1、A = 物理 lane の行数)
#
# 一つの波が一度だけ共有領域へ書くので、待ちの回数は全 lane で揃う。
I1 = fold.ROW + 30       # この波での i₁
OFF = fold.ROW + 31      # いまの波のずらし幅
WAV = fold.ROW + 32      # 残りの波の数
AWV = fold.ROW + 33      # 一波ぶんのずらし幅 A。host が置く
ROW36 = 36               # 表の 35 番がこの段の波の数
ROW33 = 33
ROW25 = 25
ROW24 = 24               # 後ろ向きの呼び名
IP = fold.ROW + 13       # 添字の番地
FLAGSINK = fold.ROW + 14 # 誰も読まないフラグの捨て先。ワーク領域なのでバリアが起きない


# ---- 表の語をそのまま値として読む ----------------------------------------
#
# `_base3` は表の語を「head を持つ語の番地」として扱い、LOAD を二回する。head は
# compile 時の定数なので一回で足りる。24 フィールド × 2 LOAD が 24 に減り、
# 足す ADD も消える（1 stage 374 命令のうち 228 がアドレス取得だった）。

def _direct(head, s1, s2, s3, dst, first=None):
    """M[表+head] + Σ M[表+s_i]·M[i_i] を dst の語へ置く。LOAD は一段だけ。"""
    w = _cell(TAB, head)
    for off, idx in ((s1, first or IDX1), (s2, IDX2), (s3, IDX3)):
        w += _cell(TAB, off) + at(idx) + ["ext", "acc"]
    return " ".join(w + ladder(dst) + ["keep"])


def _job(u):
    """一つの仕事ぶん。読む位置を出し、内積を取り、出す枠へ書く。

    $i_1$ は `I1` の語から読む。波の閉包がそこへ `IDX1 + OFF` を置く。
    """
    L = []
    L.append(_direct(5, 6, 7, 8, WP, I1))
    L.append(_direct(9, 10, 11, 12, XP, I1))
    L.append(_direct(13, 14, 15, 16, AP, I1))
    L.append(_direct(20, 21, 22, 23, IP, I1))    # 添字の番地
    L.append(_direct(0, 1, 2, 3, OP, I1))
    # フラグの番地。出力と歩幅を共有しているので、出力の番地との差から作る。
    #
    #     FP = M[表+17] + g·( M[OP] − M[表+0] )
    #
    # 表の 24 番は 0 か 1。0 なら FP は作業領域の固定語になり、**共有領域へ書かないので
    # グリッド全体の待ちが入らない**。誰も読まないフラグは 882 行中 545 行あった。
    # `_direct` を 1 本呼ぶと 80 命令、この形なら 23 命令で済む。
    L.append(" ".join(
        _cell(TAB, 17)
        + at(OP) + _cell(TAB, 0) + ["flip", "acc"]
        + _cell(TAB, 24) + ["ext", "acc"]
        + ladder(FP) + ["keep"]))
    # ---- 行に沿った最大を取る閉包。和の閉包より先に回す（XP がまだ先頭にある） ----
    L.append(" ".join(at(XP) + ladder(XQ) + ["keep"]))
    L.append(" ".join(at(XQ) + ["read"] + ladder(MX) + ["keep"]))
    L.append(" ".join(_cell(TAB, 33) + ladder(J2) + ["keep"]))
    L.append("open")
    L.append("  " + " ".join(at(XQ) + ["unit", "acc"] + ladder(XQ) + ["keep"]))
    L.append("  " + " ".join(at(XQ) + ["read"] + ladder(VV) + ["keep"]))
    L.append("  " + " ".join(at(MX) + at(VV) + at(MX) + ["under"]
                             + at(VV) + at(MX) + ["flip", "acc", "ext", "acc"]
                             + ladder(MX) + ["keep"]))
    L.append("  " + " ".join(at(J2) + ["unit", "flip", "acc"] + ladder(J2) + ["keep"]))
    L.append("  " + " ".join(["zero"] + at(J2) + ["edge"]))
    L.append("shut")
    L.append(" ".join(["zero"] + ladder(ACC) + ["keep"]))
    L.append(" ".join(_cell(TAB, 4) + ladder(J) + ["keep"]))
    L.append("open")
    for t in range(u):
        off = ladder(t) + ["acc"] if t else []
        L.append("  " + " ".join(at(WP) + off + ["read"]))
        L.append("  " + " ".join(at(XP) + off + ["read"]))
        L.append("  ext")
        L.append("  " + " ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    L.append("  " + " ".join(at(WP) + ladder(u) + ["acc"] + ladder(WP) + ["keep"]))
    L.append("  " + " ".join(at(XP) + ladder(u) + ["acc"] + ladder(XP) + ["keep"]))
    L.append("  " + " ".join(at(J) + ["unit", "flip", "acc"] + ladder(J) + ["keep"]))
    L.append("  " + " ".join(["zero"] + at(J) + ["edge"]))
    L.append("shut")
    L.append(" ".join(at(AP) + ["read"]))                      # 足す項
    L.append(" ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    # 引きの項。添字の値に表の先頭を足して、その先を読む
    L.append(" ".join(at(IP) + ["read"] + _cell(TAB, 19) + ["acc", "read"]))
    L.append(" ".join(at(ACC) + ["acc"] + ladder(ACC) + ["keep"]))
    # 行に沿った最大を使う行なら、和のかわりにそれを採る
    L.append(" ".join(at(ACC) + _cell(TAB, 34) + at(MX) + at(ACC)
                      + ["flip", "acc", "ext", "acc"] + ladder(ACC) + ["keep"]))
    # ---- 桁ごとに立てる閉包。`rshift` `recip` `isqrt` が全部これ一つ ----
    L.append(" ".join(_cell(TAB, 26) + ladder(PW) + ["keep"]))
    L.append(" ".join(at(ACC) + ["zero", "under"] + ladder(SG) + ["keep"]))
    # r = |ACC| = ACC·(2s − 1)
    L.append(" ".join(at(ACC) + at(SG) + ["twin", "acc", "unit", "flip", "acc",
                                          "ext"] + ladder(RR) + ["keep"]))
    # L = Lc + Lk·r、B = Bc + Bk·r
    L.append(" ".join(_cell(TAB, 28) + _cell(TAB, 29) + at(RR)
                      + ["ext", "acc"] + ladder(LL) + ["keep"]))
    L.append(" ".join(_cell(TAB, 30) + _cell(TAB, 31) + at(RR)
                      + ["ext", "acc"] + ladder(BV) + ["keep"]))
    L.append(" ".join(["zero"] + ladder(QQ) + ["keep"]))
    L.append(" ".join(_cell(TAB, 25) + ["unit", "flip", "acc"]
                      + ladder(KK) + ["keep"]))
    L.append("open")
    L.append("  " + " ".join(at(PW) + at(KK) + ["acc", "read"]
                             + ladder(PP) + ["keep"]))
    L.append("  " + " ".join(at(QQ) + at(PP) + ["acc"] + ladder(TT) + ["keep"]))
    L.append("  " + " ".join(at(TT) + _cell(TAB, 27) + at(TT) + ["ext"]
                             + at(BV) + ["acc", "ext"] + ladder(CC) + ["keep"]))
    L.append("  " + " ".join(at(LL) + at(CC) + ["under"] + ladder(BB) + ["keep"]))
    L.append("  " + " ".join(at(QQ) + at(BB) + at(PP) + ["ext", "acc"]
                             + ladder(QQ) + ["keep"]))
    L.append("  " + " ".join(at(KK) + ["unit", "flip", "acc"] + ladder(KK) + ["keep"]))
    # **$[k\le-1]$ で抜ける。** $[k\le0]$ だと $k=0$ の回が落ちて最下位の桁を取り
    # こぼす（$2088432287/2^{19}$ が 3983 でなく 3982 になった。2026-09-29 に踏んだ）
    L.append("  " + " ".join(["unit", "flip"] + at(KK) + ["edge"]))
    L.append("shut")
    # 符号を戻し、立てた値を使うかどうかで混ぜる
    L.append(" ".join(at(QQ) + at(SG) + ["twin", "acc", "unit", "flip", "acc",
                                         "ext"] + ladder(QQ) + ["keep"]))
    L.append(" ".join(at(ACC) + _cell(TAB, 32) + at(QQ) + at(ACC)
                      + ["flip", "acc", "ext", "acc"] + ladder(ACC) + ["keep"]))
    L.append(" ".join(at(ACC) + at(OP) + ["keep"]))
    L.append(" ".join(at(ACC) + _cell(TAB, 18) + ["under"]))
    L.append(" ".join(ladder(OUT) + ["keep"]))
    L.append(" ".join(at(OUT) + at(FP) + ["keep"]))
    return L


def engine6(u):
    """段の閉包の内側に、仕事の波の閉包を入れる。

    物理の lane は GPU に同時に載る数（実測 55296）で頭打ちになる。grid 全体の待ちが
    全 block の同居を求めるためになる。仕事はそれより多いので、一本の lane が $A$ 行ずつ
    ずらしながら複数の仕事を順に持つ。

        段 s:  OFF ← 0,  波 ← M[表+35]
               波の閉包:  i₁ ← IDX1 + OFF;  一仕事;  OFF ← OFF + A;  波 ← 波 − 1

    一つの波がちょうど一度だけ共有領域へ書くので、待ちの回数は全 lane で揃う。
    """
    L = ["unit twin ext drop", "open"]
    L.append("  " + " ".join(["zero"] + ladder(OFF) + ["keep"]))
    L.append("  " + " ".join(_cell(TAB, 35) + ladder(WAV) + ["keep"]))
    L.append("  open")
    L.append("    " + " ".join(at(IDX1) + at(OFF) + ["acc"] + ladder(I1) + ["keep"]))
    L += ["    " + x for x in _job(u)]
    L.append("    " + " ".join(at(OFF) + at(AWV) + ["acc"] + ladder(OFF) + ["keep"]))
    L.append("    " + " ".join(at(WAV) + ["unit", "flip", "acc"] + ladder(WAV) + ["keep"]))
    L.append("    " + " ".join(["zero"] + at(WAV) + ["edge"]))
    L.append("  shut")
    L.append("  " + " ".join(at(TAB) + ladder(ROW36) + ["acc"] + ladder(TAB) + ["keep"]))
    L.append("  " + " ".join(at(LEFT) + ["unit", "flip", "acc"] + ladder(LEFT) + ["keep"]))
    L.append("  " + " ".join(["zero"] + at(LEFT) + ["edge"]))
    L += ["shut", "said"]
    return "\n".join(L) + "\n"
