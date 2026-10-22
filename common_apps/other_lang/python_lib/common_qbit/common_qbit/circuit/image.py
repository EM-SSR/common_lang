# -*- coding: utf-8 -*-
"""平文（.cmn）を lane-qbit の image にする。

commonc の lane-qbit 版が、量子の語を compile 時に作図する（commonc/src/qstate.cam）。host は作図の置き場、
角の表、候補の作用の表を用意し、番地を次の語に置くだけになる。

    1000 状態の置き場   1001 枝の上限      1002 量子ビットの数   1003 境界の表（image の作業領域）
    1061 リセットの候補 1062 角の表        1063 2 の冪の表       1064 その長さ
    1065 ゲートごとの候補の作用の表（0 なら無い）               1066 回転の作図に足す桁
    1067 状態の保存の書き出し場所（保存の語ごとに [NQ、NBR、枝ごとの 4·2^NQ 語]）

    置き場の大きさ   枝の上限 × 4·2^量子ビット ＋ 写像 16·枝の上限 ＋ 角の表 ＋ 2 の冪の表 ＋ 作用の表
    枝の上限         測定とリセットの数を k として 2^k（枝は測定ごとに二つへ分かれる）

回転の後の境界の桁が上界の範囲で決まらないとき、commonc は語 1095 に印を立てて止まる。host は足す桁を
増やして作図をやり直す（閉包の段を一つ深くする）。
"""
import os
import tempfile

from common_vcpu import toolchain

from .. import data_path

COMMONC = os.environ.get("COMMON_QBIT_COMMONC") or data_path("commonc_lane_qbit.bin")
TABLE_BASE = 1 << 20          # 境界の表を置く image の作業領域の番地
MAX_BRANCH_BITS = 14          # 測定とリセットの数の上限（枝は 2^14 まで）
SPLITS = ("kukeho", "kukema")  # 枝を分ける語：測定、リセット
SAVE_WORD = "kukeya"           # 状態の保存
EXTRA_DIGITS = (0, 64, 256, 1024)
UNDECIDED = 1095
N_GATE_CODES = 15

# リセットが測定座標 u にする作用の候補（論文 12.16 の R_C の u 成分。形は論文に無い）
RESET_CANDIDATES = {"consume": 1}
# ゲートの後に測定座標へ当てる作用の候補（論文 16.5 のメビウス作用、1.11 の β_a）。種類の番号
ACTION_KINDS = {"mobius": 1, "beta": 2}


class ImageError(Exception):
    pass


def _closure_digits(m, e, extra):
    """角 m / 2^e の回転の作図が使う桁 K（qstate.cam の QSROT と同じ式）。"""
    e1 = e + 1
    b = max(abs(m).bit_length() - e1, 0)
    return e1 + (3 * b + 64 + extra) + 128 + extra


def _read_saves(words, exb, count):
    """書き出し場所から、保存ごとの [枝ごとの振幅の係数の並び] と量子ビットの数を読む。"""
    out, p = [], exb
    for _ in range(count):
        nq, nbr = words[p], words[p + 1]
        p += 2
        size = 4 << nq
        out.append((nq, [list(words[p + b * size:p + (b + 1) * size]) for b in range(nbr)]))
        p += nbr * size
    return out


def _layout(nq, splits, reset, angles, actions, extra, saves, sink):
    qmax = max(nq, 1)
    nbmax = 1 << splits
    state = nbmax * (4 << qmax) + 16 * nbmax
    npow = max([256 + extra] + [_closure_digits(m, e, extra) + 8 for m, e in angles])
    export = saves * (2 + nbmax * (4 << qmax))
    where = {}

    def place(top):
        angb = top + state
        powb = angb + 2 * len(angles) + 2
        actb = powb + npow
        where["exb"] = actb + 4 * N_GATE_CODES
        words = {1000: top, 1001: nbmax, 1002: qmax, 1003: TABLE_BASE, 1061: reset,
                 1062: angb, 1063: powb, 1064: npow, 1065: actb if actions else 0, 1066: extra,
                 1067: where["exb"], 1068: 0}
        for k, (m, e) in enumerate(angles):
            words[angb + 2 * k], words[angb + 2 * k + 1] = m, e
        for code, (kind, p1, p2) in actions.items():
            words[actb + 4 * code], words[actb + 4 * code + 1], words[actb + 4 * code + 2] = kind, p1, p2
        return words

    def read(words):
        sink.extend(_read_saves(words, where["exb"], saves))

    return state + 2 * len(angles) + 2 + npow + 4 * N_GATE_CODES + export + 16, place, read


def compile_cmn(text, nq, reset=None, angles=(), actions=None):
    """平文を image にする。返りは (image の byte 列, 保存ごとの (量子ビットの数, 枝ごとの係数の並び))。

    nq は量子ビットの数、reset はリセットの候補の名前、angles は回転の角の表 (m, e) の並び、
    actions はゲートの番号から候補の作用 (種類, p1, p2) への辞書（種類は ACTION_KINDS の値）。
    """
    splits = sum(text.count(w) for w in SPLITS)
    if splits > MAX_BRANCH_BITS:
        raise ImageError("測定とリセットが %d 回ある。枝は 2^%d までしか置けない" % (splits, MAX_BRANCH_BITS))
    if "kukema" in text and reset not in RESET_CANDIDATES:
        raise ImageError("リセットの候補 reset を %s から選んで渡す" % sorted(RESET_CANDIDATES))
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "circuit.cmn")
        with open(src, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        for extra in EXTRA_DIGITS:
            saved = []
            region = _layout(nq, splits, RESET_CANDIDATES.get(reset, 0), list(angles), dict(actions or {}), extra,
                             text.count(SAVE_WORD), saved)
            try:
                image, _need = toolchain.compile([src], None, os.path.join(d, "circuit.bin"),
                                                 commonc=COMMONC, region=region)
                return image, saved
            except toolchain.CompileError as err:
                if err.words[UNDECIDED] != 1:
                    raise
    raise ImageError("境界の桁が、足す桁 %d でも決まらない" % EXTRA_DIGITS[-1])
