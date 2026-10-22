# -*- coding: utf-8 -*-
"""hash.cmn を commonc で compile して走らせる。計算は hash.cmn が全部持つ。

doc: casm.lane64.host

host がするのは三つだけ。メッセージ 12 ビットを作業領域の語 16 … 27 へ置く。image を実行台へ渡す。
出力の 8 byte を読む。byte i が、出力のビット i になる。

H(m) の定義（式）。s ∈ {0,1}^8、s_{-1} = 0。メッセージを 4 ビットずつ 3 回吸収する。

    j = 0, 1, 2:    s_b ← s_b ⊕ m_{4j+b}                           (b = 0 … 3)
                    r = 0 … 3 の各段で
                        s_{p+2} ← s_{p+2} ⊕ s_p s_{p+1}              (p = 0 … 5)
                        s_{p+3} ← s_{p+3} ⊕ s_p                      (p = 0 … 4)
                        s_r     ← s_r ⊕ 1

ビットの排他的論理和は (a − b)²、論理積は積。番地: s は 0 … 7、カウンタ P = 8、R = 9、J = 10、K = 11。
"""
import functools
import os
import tempfile

from common_vcpu import toolchain, vcpu

from ..backend import COMMONC

SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hash.cmn")
MSG = 16                                 # メッセージのビットを置く語
BITS = 12                                # メッセージのビット数
OUT = 8                                  # 出力のビット数
WORDS = (1 << 16) + 64                   # 本文のワイヤの帯（語 64 〜）の上まで


@functools.lru_cache(maxsize=1)
def _image():
    with tempfile.TemporaryDirectory() as d:
        image, _ = toolchain.compile([SOURCE], None, os.path.join(d, "hash.bin"), commonc=COMMONC)
    return vcpu.translate(vcpu.decode(image))[1]


def digest(msg):
    """H(msg) を cmn で計算する。msg は 0 … 2^12 − 1。"""
    if not 0 <= msg < 1 << BITS:
        raise ValueError("メッセージは %d ビット" % BITS)
    lane = vcpu.Lane(WORDS)
    for i in range(BITS):
        lane.M[MSG + i] = (msg >> i) & 1
    if vcpu.run_lane(_image(), lane) != 0:
        raise RuntimeError("hash.cmn が報告 42 で止まった")
    return sum(int(lane.OUT[i]) << i for i in range(OUT))
