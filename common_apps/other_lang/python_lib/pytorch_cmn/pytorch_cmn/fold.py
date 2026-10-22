# -*- coding: utf-8 -*-
"""列の内積を、フラグを立てずに書く。

`ya`/`yi` で反復を回すとステップ数が $2N+2$ になる（実測: N=3 で 8 歩、N=6 で 14 歩）。
内積の停止は縁で一度読めば決まる（GCLS 定理 3.2、$\\bigvee_n h_n$）ので、本体から
位置の更新とフラグが落ちる。残るのは積と和だけになる。

    y_i = ⊕_k  W_ik ⋆ x_k

行 i は lane、列 k は文の中の位置。$W$ と $x$ は共有メモリに一枚だけ置く。lane あたりの
作業領域は「自分の行の先頭番地」一語だけになる。

番地は β のラダーで綴る。$2^n$ はラダーが一段ずつ、それ以外は和で作る（定理 13.1 が
どの割当てでも意味が変わらないことを与える）。ラダーの定数は compile 時に畳まれるので、
走る側の費用には乗らない。
"""

ROW = 1 << 16          # lane の一語目。自分の行の先頭番地が入る
XPT = ROW + 1          # lane の二語目。入力の並びの先頭番地
OUT = ROW + 2          # lane の三語目。足し合わせだ答えが入る


def ladder(n):
    """番地 n を単位の倍加と和で綴る。"""
    if n == 0:
        return ["zero"]
    out = []
    for k in sorted((b for b in range(n.bit_length()) if n >> b & 1), reverse=True):
        out += ["unit"] + ["rung"] * k + (["acc"] if out else [])
    return out


def at(n):
    """番地 n の語を読む。"""
    return ladder(n) + ["read"]


def cell(base_addr, off):
    """共有メモリの (先頭番地 + off) を読む。先頭番地は lane の作業領域が持つ。"""
    w = at(base_addr)
    if off:
        w += ladder(off) + ["acc"]
    return w + ["read"]


def text(k, xbase):
    """列 k 本の内積の平文。行の先頭番地は語 ROW、入力は共有メモリの xbase から並ぶ。

    注記は I→I の文で、内積の形そのものを言う。
    """
    lines = ["unit twin ext drop"]                     # 注記。積は経路を保つ
    for j in range(k):
        lines.append(" ".join(cell(ROW, j)))
        lines.append(" ".join(at(xbase + j)))
        lines.append("ext" if j == 0 else "ext acc")
    lines.append(" ".join(ladder(OUT) + ["keep"]))
    lines.append("said")
    return "\n".join(lines) + "\n"


# ---- 一語に出力を詰める -------------------------------------------------
#
# 平文は一行も変わらない。語の中で桁を分けるだけで、一回の `ext` が出力 n 本を出す。
#
#     A_k = Σ_j (W[i_j,k] + C) · 2^{jB}
#     Σ_k A_k x_k = Σ_j ( Σ_k W[i_j,k] x_k + C Σ_k x_k ) · 2^{jB}
#
# 下駄 C = 2^d で全桁を非負にすると借りが出ない。桁が繰り上がらない条件は
#
#     B = 1 + ⌈log2( K · 2^{2d+1} )⌉,      n·B ≤ 63
#
# 詰めと解きは host の転記で、`.cmn` の側の命令は増えない。


def width(k, d, byte=False):
    """桁の幅 B と、一語に入る出力の本数 n。k は lane 一本が足し合わせる項の数。

    `byte` を立てると桁を 8 bit に揃える。すると詰めを解くのが byte の読み替えだけに
    なって、掛け算も引き算も要らない。下駄で全桁が非負になるので 8 本とも使える。
    """
    import math
    need = 1 + int(math.ceil(math.log2(k * (1 << (d + 1)) * (1 << d))))
    if byte:
        if need > 8:
            raise ValueError("桁が 8 bit に収まらない（K=%d, d=%d で %d bit 要る）" % (k, d, need))
        return 8, 8
    return need, 63 // need


def squeeze(w, d, k=None):
    """(行, 列) の係数を (lane, 列) の語へ詰める。行は n 本ずつ一語に入る。"""
    import numpy as np
    rows, cols = w.shape
    b, n = width(k or cols, d)
    lanes = rows // n
    out = np.zeros((lanes, cols), dtype=np.int64)
    for j in range(n):
        out |= (w[j::n][:lanes].astype(np.int64) + (1 << d)) << (j * b)
    return out, b, n


def loosen(word, x, d, k=None, n=None, b=None):
    """足し合わせだ語から出力を取り出す。下駄の分を引いて元へ戻す。"""
    import numpy as np
    if b is None:
        b, n = width(k or len(x), d)
    shift = (1 << d) * int(np.asarray(x).sum())
    return np.stack([((word >> (j * b)) & ((1 << b) - 1)) - shift for j in range(n)], axis=1)


def merge():
    """合わせの平文。自分の枠と、歩幅だけ離れた枠を足して、自分の枠へ戻す。

    枠の番地と歩幅は lane の作業領域が持つ（host が置く）。番地の足し算は読んだ値
    どうしの ⊕ なので、単位を綴る必要が無い。

        ROW  自分の枠の番地
        OUT  歩幅
    """
    return "\n".join([
        "unit twin acc drop",                      # 注記。番地は和で作る
        " ".join(at(ROW)) + " read",               # 自分の枠の中身
        " ".join(at(ROW)),                         # 自分の枠の番地
        " ".join(at(OUT)),                         # 歩幅
        "acc",                                     # 番地 + 歩幅
        "read",                                    # 相手の枠の中身
        "acc",                                     # 二つの和
        " ".join(at(ROW)),
        "keep",
        "said",
    ]) + "\n"


def total(m, base):
    """共有メモリの base から続く m 語を足す平文。詰めを解いた後の合わせに使う。

    積が無いので `ext` が出ない。桁の余裕は要らない（解いた後なので一語一値）。
    """
    lines = ["unit twin acc drop"]
    for j in range(m):
        lines.append(" ".join(cell(ROW, j)))
        if j:
            lines.append("acc")
    lines.append(" ".join(ladder(OUT) + ["keep"]))
    lines.append("said")
    return "\n".join(lines) + "\n"


def pair(k):
    """係数と入力を交互に置いた行を足し合わせる平文。

    lane の行は共有メモリに  [W_0, x_0, W_1, x_1, ...]  と並ぶ。列の区間ごとに x が違うので、
    固定の番地から読むのではなく、自分の行の中で隣を見る。入口の語は行の先頭番地だけ
    （語 ROW）で、出口は語 OUT になる。
    """
    lines = ["unit twin ext drop"]
    for j in range(k):
        lines.append(" ".join(cell(ROW, 2 * j)))
        lines.append(" ".join(cell(ROW, 2 * j + 1)))
        lines.append("ext" if j == 0 else "ext acc")
    lines.append(" ".join(ladder(OUT) + ["keep"]))
    lines.append("said")
    return "\n".join(lines) + "\n"


def twin_ptr(k):
    """係数と入力を別の並びから読む平文。先頭番地を二つ持つ。

    lane の語 ROW が係数の行の先頭、語 XPT が入力の区間の先頭になる。入力は列の区間
    ごとに一組だけ置けばよく、出力の組ごとに複製しない。共有メモリが半分になる。
    """
    lines = ["unit twin ext drop"]
    for j in range(k):
        lines.append(" ".join(cell(ROW, j)))
        lines.append(" ".join(cell(XPT, j)))
        lines.append("ext" if j == 0 else "ext acc")
    lines.append(" ".join(ladder(OUT) + ["keep"]))
    lines.append("said")
    return "\n".join(lines) + "\n"
