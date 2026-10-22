# -*- coding: utf-8 -*-
"""SHA-256 の途中の状態を出す純 Python の基準。検算だけに使う（計算は cmn/sha256d.cmn が持つ）。

FIPS 180-4 の定義どおり。32 ビットの語で、
    Ch(e,f,g) = (e ∧ f) ⊕ (¬e ∧ g)        Maj(a,b,c) = (a ∧ b) ⊕ (a ∧ c) ⊕ (b ∧ c)
    Σ0 = ROTR²(a) ⊕ ROTR¹³(a) ⊕ ROTR²²(a)    Σ1 = ROTR⁶(e) ⊕ ROTR¹¹(e) ⊕ ROTR²⁵(e)
    σ0 = ROTR⁷(x) ⊕ ROTR¹⁸(x) ⊕ SHR³(x)      σ1 = ROTR¹⁷(x) ⊕ ROTR¹⁹(x) ⊕ SHR¹⁰(x)
    W_t = σ1(W_{t-2}) + W_{t-7} + σ0(W_{t-15}) + W_{t-16}  (mod 2^32)
"""
import struct

from common_qbit.cmn.sha256d import IV256, K256

M = 0xFFFFFFFF


def rotr(x, n):
    return ((x >> n) | (x << (32 - n))) & M


def blocks(message):
    raw = message + b"\x80"
    raw += b"\x00" * ((56 - len(raw)) % 64) + struct.pack(">Q", len(message) * 8)
    words = struct.unpack(">%dI" % (len(raw) // 4), raw)
    return [list(words[i:i + 16]) for i in range(0, len(words), 16)]


def compress(h, block):
    """返りは (新しい鎖の値, スケジュール W の 64 語, ラウンドごとの状態 (a … h) の 64 個)。"""
    w = list(block)
    for t in range(16, 64):
        s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
        s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
        w.append((s1 + w[t - 7] + s0 + w[t - 16]) & M)
    a, b, c, d, e, f, g, hh = h
    states = []
    for t in range(64):
        S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        ch = (e & f) ^ (~e & M & g)
        t1 = (hh + S1 + ch + K256[t] + w[t]) & M
        S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        maj = (a & b) ^ (a & c) ^ (b & c)
        t2 = (S0 + maj) & M
        hh, g, f, e, d, c, b, a = g, f, e, (d + t1) & M, c, b, a, (t1 + t2) & M
        states.append([a, b, c, d, e, f, g, hh])
    return [(x + y) & M for x, y in zip(h, [a, b, c, d, e, f, g, hh])], w, states


def sha256_states(message):
    h, out = list(IV256), []
    for blk in blocks(message):
        h, w, s = compress(h, blk)
        out.append((w, s))
    return h, out


def sha256d_states(message):
    """返りは (出力 32 byte, 圧縮ごとの (W, 状態) の並び)。一度目のブロックの数の圧縮、続いて二度目の 1 つ。"""
    h, out = sha256_states(message)
    digest1 = b"".join(x.to_bytes(4, "big") for x in h)
    h2, out2 = sha256_states(digest1)
    return b"".join(x.to_bytes(4, "big") for x in h2), out + out2
