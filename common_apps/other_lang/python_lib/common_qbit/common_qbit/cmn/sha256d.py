# -*- coding: utf-8 -*-
"""sha256d.cmn を commonc で compile して走らせる。SHA-256 を二度かける計算は、sha256d.cmn が全部持つ。

doc: casm.lane64.host

host がするのは三つだけ。メッセージのブロック（パディング済み）、ブロックの数、定数 K と IV を、作業領域のセルへビットで置く。
image を実行台へ渡す。
出力の 256 byte（1 byte が 1 ビット）を読んで、32 byte に束ねる。

  SHA-256d(m) = SHA-256(SHA-256(m))     m の長さに制限はない（64 byte のブロックを、鎖の値 H へ順に足していく）

語は 1 ビット = 1 セルで、LSB が先。語 w のビット i は、配列の先頭から 32 w + i 番のセル。XOR は (a − b)²、AND は積、
32 ビットの足し算は桁上げの伝播（s = a + b + c、桁上げ = [2 ≤ s]、和 = s − 2 桁上げ）で、回転は番地の付け替え。
作業領域は 2^16 から上に置く（語 64 から下のワイヤの帯と交わらない）。

    配列   K 定数 64 語、W スケジュール 64 語、IV 8 語、S 状態 8 語（a … h）、H 鎖の値と出力 8 語、一時の語、
           MSG メッセージのブロック（1 ブロックが 16 語）
    置き場  BASE + OFFSETS[名前]
    レジスタ  語 1 … 11。nb はブロックの数で、host が置く

sha256d.cmn は gen_sha256d.py が組版する。
"""
import functools
import os
import struct
import tempfile

from common_vcpu import toolchain, vcpu

from ..backend import COMMONC

SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sha256d.cmn")
SOURCE_TRACE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sha256d_trace.cmn")
BASE = 1 << 16
OFFSETS = dict(K=0, W=2048, IV=4096, S=4352, H=4608, T1=4864, T2=4896, X1=4928, X2=4960, X3=4992, X4=5024,
               E=5056, A=5088, Y0=5120, Y1=5152, MSG=5248)
REG = dict(P=1, Q=2, R=3, c1=4, cr=5, s=6, t=7, k=8, hn=9, nb=10, blk=11)

K256 = (
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2)
IV256 = (0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19)


@functools.lru_cache(maxsize=2)
def _image(source=None):
    with tempfile.TemporaryDirectory() as d:
        image, _ = toolchain.compile([source or SOURCE], None, os.path.join(d, "sha256d.bin"), commonc=COMMONC)
    return vcpu.translate(vcpu.decode(image))[1]


def _put(lane, array, words):
    for w, v in enumerate(words):
        for i in range(32):
            lane.M[BASE + OFFSETS[array] + 32 * w + i] = (v >> i) & 1


def blocks(message):
    """メッセージに 0x80、0、ビット長（8 byte）を足して 64 byte の倍数にし、32 ビットの語 16 個ずつのブロックにする（大きい桁が先）。"""
    raw = message + b"\x80"
    raw += b"\x00" * ((56 - len(raw)) % 64) + struct.pack(">Q", len(message) * 8)
    words = struct.unpack(">%dI" % (len(raw) // 4), raw)
    return [words[i:i + 16] for i in range(0, len(words), 16)]


def _run(message, source=None):
    bl = blocks(message)
    lane = vcpu.Lane(BASE + OFFSETS["MSG"] + 512 * len(bl) + 64)
    _put(lane, "K", K256)
    _put(lane, "IV", IV256)
    _put(lane, "MSG", [w for b in bl for w in b])
    lane.M[REG["nb"]] = len(bl)
    if vcpu.run_lane(_image(source), lane) != 0:
        raise RuntimeError("sha256d.cmn が報告 42 で止まった")
    return [int(x) for x in lane.OUT], len(bl)


def _words(bits):
    return [sum(bits[32 * w + i] << i for i in range(32)) for w in range(len(bits) // 32)]


def digest(message):
    """SHA-256d(message) を sha256d.cmn で計算し、32 byte を返す。"""
    bits, _n = _run(message)
    return b"".join(w.to_bytes(4, "big") for w in _words(bits))


def trace(message):
    """途中の状態つきで計算する（sha256d_trace.cmn）。返りは (出力 32 byte, 圧縮ごとの [スケジュール W の 64 語, ラウンドごとの
    状態 (a … h) の 64 個])。圧縮は、SHA-256 の一度目のブロックの数、続いて二度目の 1 つ。"""
    bits, nb = _run(message, SOURCE_TRACE)
    per = 2048 + 64 * 256
    out, pos = [], 0
    for _c in range(nb + 1):
        w = _words(bits[pos:pos + 2048])
        s = [_words(bits[pos + 2048 + 256 * t:pos + 2048 + 256 * (t + 1)]) for t in range(64)]
        out.append((w, s))
        pos += per
    final = b"".join(x.to_bytes(4, "big") for x in _words(bits[pos:pos + 256]))
    return final, out
