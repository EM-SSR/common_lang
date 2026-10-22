# -*- coding: utf-8 -*-
"""sha256d.cmn の組版。計算は組版した .cmn が持つ。この生成器は、同じ形の文を並べるだけ。

    python -m common_qbit.cmn.gen_sha256d

SHA-256 の圧縮（sha256d.py の配列に対して）

    S ← IV
    t = 16 … 63     W_t ← σ1(W_{t-2}) + W_{t-7} + σ0(W_{t-15}) + W_{t-16}
    t = 0 … 63      T1 ← h + Σ1(e) + Ch(e,f,g) + K_t + W_t,   T2 ← Σ0(a) + Maj(a,b,c)
                    (a … h) ← (T1 + T2, a, b, c, d + T1, e, f, g)
    H ← IV + S

    Σ0 = rotr 2, 13, 22      Σ1 = rotr 6, 11, 25      σ0 = rotr 7, 18, shr 3      σ1 = rotr 17, 19, shr 10
    Ch = ef ⊕ ēg             Maj = ab + c(a ⊕ b)

SHA-256 は、メッセージのブロック b = 0 … nb − 1 について、S ← H、圧縮、H ← H + S を繰り返す（H は IV から始める）。
SHA-256d は、これを二度行う。一度目の H を MSG の最初のブロック（語 0 … 7）へ移し、語 8 = 0x80000000、語 15 = 256、
残りを 0 にして、ブロックの数を 1 にして、もう一度行う。

構成は、一つの値を作る文を ka で区切って並べる。ループは ya … yi で、状態は作業領域の語（レジスタ）が持つ。
レジスタ（語 1 … 11）: P Q R は配列を指す番地、c1 は桁のカウンタ、cr は桁上げ、s は桁ごとの和、t はラウンド、k は語の番号、
hn は SHA-256 の回数、nb はブロックの数、blk はブロックの番号。
"""
import os

from .sha256d import BASE, OFFSETS, REG

XOR = ["ki ha", "no", "he", "ti"]                 # [a, b] → (b − a)²


def num(n):
    """整数 n を一本立てる。1 から、2 倍と 1 の加算で組む。"""
    if n == 0:
        return ["hu", "hu", "ha", "no"]
    out = ["hu"]
    for b in bin(n)[3:]:
        out += ["he", "no"]
        if b == "1":
            out += ["hu", "no"]
    return out


def ld(r):
    return num(REG[r]) + ["mi"]


def st(r):
    return num(REG[r]) + ["mu"]


def inc(r, d=1):
    return ld(r) + (num(d) + ["no"] if d > 0 else ["hu", "ha", "no"]) + st(r)


def zero(r):
    return num(0) + st(r)


def at(name, add=0):
    """配列 name の先頭から add 番のセルの番地。"""
    return num(BASE + OFFSETS[name] + add)


def dyn(name, reg, mul, add=0):
    """name の先頭 + add + M[reg] × mul。"""
    return at(name, add) + ld(reg) + num(mul) + ["ti", "no"]


def loop(count, body, ctr="c1"):
    """body を count 回。閉じは [count ≤ カウンタ]。"""
    return zero(ctr) + ["ya"] + body + inc(ctr) + ld(ctr) + num(count) + ["hi", "yi"]


def setp(r, expr):
    return expr + st(r)


def plus(expr, off):
    return expr + (num(off) + ["no"] if off else [])


def clear(base, n):
    return setp("P", base) + loop(n, num(0) + ld("P") + ["mu"] + inc("P"))


def copy(dst, src, n, down=False):
    d = -1 if down else 1
    return setp("P", dst) + setp("Q", src) + loop(n, ld("Q") + ["mi"] + ld("P") + ["mu"] + inc("P", d) + inc("Q", d))


def xorpass(dst, src, count):
    body = ld("P") + ["mi"] + ld("Q") + ["mi"] + XOR + ld("P") + ["mu"] + inc("P") + inc("Q")
    return setp("P", dst) + setp("Q", src) + loop(count, body)


def rotr(dst, src, r):
    return xorpass(plus(dst, 0), plus(src, r), 32 - r) + xorpass(plus(dst, 32 - r), plus(src, 0), r)


def shr(dst, src, s):
    return xorpass(plus(dst, 0), plus(src, s), 32 - s)


def sigma(dst, src, rots, shift=None):
    t = clear(dst, 32)
    for r in rots:
        t += rotr(dst, src, r)
    if shift is not None:
        t += shr(dst, src, shift)
    return t


def _bit(i):
    return ld("Q") + (num(32 * i) + ["no"] if i else []) + ["mi"]


def ch(dst, e):
    body = (_bit(0) + _bit(1) + ["ti", "hu"] + _bit(0) + ["ha", "no"] + _bit(2) + ["ti", "no"]
            + ld("P") + ["mu"] + inc("P") + inc("Q"))
    return setp("P", dst) + setp("Q", e) + loop(32, body)


def maj(dst, a):
    body = (_bit(0) + _bit(1) + ["ti"] + _bit(2) + _bit(0) + _bit(1) + ["ha", "no", "he", "ti", "ti", "no"]
            + ld("P") + ["mu"] + inc("P") + inc("Q"))
    return setp("P", dst) + setp("Q", a) + loop(32, body)


def add32(dst, x, y):
    body = (ld("Q") + ["mi"] + ld("R") + ["mi", "no"] + ld("cr") + ["no"] + st("s")
            + ld("s") + num(2) + ["hi", "mo"] + st("cr")
            + ld("s") + ld("cr") + num(2) + ["ti", "ha", "no"] + ld("P") + ["mu"]
            + inc("P") + inc("Q") + inc("R"))
    return setp("P", dst) + setp("Q", x) + setp("R", y) + zero("cr") + loop(32, body)


def emit(array, bits):
    """配列 array の先頭から bits 個のセルを、1 セル 1 byte で出力する。"""
    return setp("P", at(array)) + loop(bits, ld("P") + ["mi", "du"] + inc("P"))


def compress(trace=False):
    """一つのブロックの圧縮。W の語 0 … 15 にブロックを置き、S に鎖の値を置いて呼ぶ。終わると H ← H + S。
    trace は途中の状態を出力する。スケジュール W の 64 語（2048 セル）、続いてラウンドごとの S（256 セル）。"""
    t = num(16) + st("t")
    sched = sigma(at("Y0"), dyn("W", "t", 32, -15 * 32), (7, 18), 3)
    sched += sigma(at("Y1"), dyn("W", "t", 32, -2 * 32), (17, 19), 10)
    sched += add32(dyn("W", "t", 32), at("Y1"), dyn("W", "t", 32, -7 * 32))
    sched += add32(dyn("W", "t", 32), dyn("W", "t", 32), at("Y0"))
    sched += add32(dyn("W", "t", 32), dyn("W", "t", 32), dyn("W", "t", 32, -16 * 32))
    t += ["ya"] + sched + inc("t") + ld("t") + num(64) + ["hi", "yi"]
    if trace:
        t += emit("W", 2048)
    t += zero("t")
    r = sigma(at("X1"), at("S", 128), (6, 11, 25))
    r += ch(at("X2"), at("S", 128))
    r += add32(at("T1"), at("S", 224), at("X1"))
    r += add32(at("T1"), at("T1"), at("X2"))
    r += add32(at("T1"), at("T1"), dyn("K", "t", 32))
    r += add32(at("T1"), at("T1"), dyn("W", "t", 32))
    r += sigma(at("X3"), at("S", 0), (2, 13, 22))
    r += maj(at("X4"), at("S", 0))
    r += add32(at("T2"), at("X3"), at("X4"))
    r += add32(at("E"), at("S", 96), at("T1"))
    r += add32(at("A"), at("T1"), at("T2"))
    r += copy(at("S", 255), at("S", 223), 224, down=True)
    r += copy(at("S", 128), at("E"), 32)
    r += copy(at("S", 0), at("A"), 32)
    if trace:
        r += emit("S", 256)
    t += ["ya"] + r + inc("t") + ld("t") + num(64) + ["hi", "yi"]
    word = lambda name: at(name) + ld("k") + num(32) + ["ti", "no"]
    t += zero("k") + ["ya"] + add32(word("H"), word("H"), word("S")) + inc("k") + ld("k") + num(8) + ["hi", "yi"]
    return t


def program(trace=False):
    """二度の SHA-256。各回で、H ← IV の後、ブロックごとに W ← MSG のブロック、S ← H、圧縮。
    trace は、圧縮ごとの途中の状態（compress）を出力し、最後に出力 256 ビットを出力する。"""
    t = zero("hn") + ["ya"]
    t += copy(at("H"), at("IV"), 256) + zero("blk") + ["ya"]
    t += copy(at("W"), at("MSG") + ld("blk") + num(512) + ["ti", "no"], 512)
    t += copy(at("S"), at("H"), 256)
    t += compress(trace)
    t += inc("blk") + ld("blk") + ld("nb") + ["hi", "yi"]
    t += copy(at("MSG"), at("H"), 256) + clear(at("MSG", 256), 256)
    t += num(1) + at("MSG", 256 + 31) + ["mu"]
    t += num(1) + at("MSG", 15 * 32 + 8) + ["mu"]
    t += num(1) + st("nb")
    t += inc("hn") + ld("hn") + num(2) + ["hi", "yi"]
    t += setp("P", at("H")) + loop(256, ld("P") + ["mi", "du"] + inc("P"))
    return t + ["me"]


def text(trace=False):
    """一つの値を作る文ごとに改行する。文は、値を書き込む mu か、ループの ya、yi、出力の du で終わる。"""
    out, line = [], []
    for x in program(trace):
        line.append(x + " ka")
        if x in ("mu", "ya", "yi", "du", "me"):
            out.append(", ".join(line) + ".")
            line = []
    return "\n".join(out) + "\n"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    for name, trace in (("sha256d.cmn", False), ("sha256d_trace.cmn", True)):
        path = os.path.join(here, name)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text(trace))
        print(path, len(program(trace)), "語")


if __name__ == "__main__":
    main()
