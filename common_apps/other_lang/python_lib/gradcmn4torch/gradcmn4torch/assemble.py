# -*- coding: utf-8 -*-
"""主作図（手順）を .cmn の平文に書き出す。手順は (語, 位置) の並び。

最初に D 型の入力 x_0 … x_{n-1} の n 本のワイヤがある。入力は作業領域の語 2^i に置く。
語は words.py の 61 語で、型が合う語だけを置ける。位置 k はワイヤの左端からの番号。
sw は隣り合う D の入れ替えで、he、no、ha の 8 層に書く（cmn/swap.cmn）。

深度: Dyad の値は 分子 / 2^δ で、語は分子だけを持つ。δ(深度)は手順から決まる。
δ が MAXDEPTH を越えると分子が 64 bit の語に入らないので、組み立てを止める。
微分は chain.py が局所微分箱（cmn/box/）で出す。ここは値の作図だけを書く。
"""
import os
from collections import namedtuple

from .words import D, B, OPEN, WORDS

HERE = os.path.dirname(os.path.abspath(__file__))
MAXDEPTH = 48                     # 分子は 64 bit の語に入れる。値の大きさのために 2^14 を残す

Built = namedtuple("Built", "text depths")



def _frag(name):
    with open(os.path.join(HERE, "cmn", name + ".cmn"), encoding="utf-8") as f:
        return [l.strip() for l in f if l.strip()]


_FRAG = {"swap": _frag("swap")}


def _tracked(method):
    def wrapped(self, *args):
        method(self, *args)
        self.peak = max([self.peak] + self.d)
    wrapped.__name__ = method.__name__
    return wrapped


class Wires(object):
    """ワイヤの並びと、各ワイヤの型と深度を持ち、層を一つずつ書き出す。位置は左端からの番号。"""

    def __init__(self):
        self.d = []
        self.ty = []
        self.lines = []
        self.peak = 0

    def _lay(self, pos, boxes):
        self.lines.append(" ".join(["ki"] * pos + list(boxes) + ["ka"]))

    def _frag(self, name, pos):
        self.lines.extend(" ".join(["ki"] * pos + [l]) for l in _FRAG[name])

    def _put(self, pos, count, types, depths):
        """位置 pos から count 本を、types と depths の新しいワイヤに替える。"""
        self.ty[pos:pos + count] = types
        self.d[pos:pos + count] = depths

    @_tracked
    def hu(self, pos):
        self._lay(pos, ["hu"])
        self._put(pos, 0, [D], [0])

    @_tracked
    def he(self, pos):
        self._lay(pos, ["he"])
        self._put(pos, 0, [self.ty[pos]], [self.d[pos]])

    @_tracked
    def ho(self, pos):
        self._lay(pos, ["ho"])
        self._put(pos, 1, [], [])

    @_tracked
    def ha(self, pos):
        self._lay(pos, ["ha"])

    @_tracked
    def se(self, pos):
        self._lay(pos, ["se"])
        self.d[pos] += 1

    @_tracked
    def no(self, pos):
        self._lay(pos, ["no"])
        self._put(pos, 2, [D], [max(self.d[pos:pos + 2])])

    @_tracked
    def ti(self, pos):
        self._lay(pos, ["ti"])
        self._put(pos, 2, [D], [sum(self.d[pos:pos + 2])])

    @_tracked
    def za(self, pos):
        self._lay(pos, ["za"])
        self._put(pos, 2, [D], [max(self.d[pos:pos + 2]) + 1])

    @_tracked
    def gu(self, pos):
        if self.d[pos] < 1:
            raise ValueError("gu の入力の深度が 0")
        self._lay(pos, ["gu"])
        self.d[pos] -= 1

    @_tracked
    def ge(self, pos):
        self._lay(pos, ["ge"])
        self.d[pos] = 0

    @_tracked
    def zi(self, pos):
        self._lay(pos, ["zi"])
        self._put(pos, 2, [D], [self.d[pos + 1]])

    @_tracked
    def hi(self, pos):
        self._lay(pos, ["hi"])
        self._put(pos, 2, [B], [0])

    @_tracked
    def so(self, pos):
        self._lay(pos, ["so"])
        self._put(pos, 1, [B], [0])

    @_tracked
    def mo(self, pos):
        self._lay(pos, ["mo"])
        self._put(pos, 1, [D], [0])

    @_tracked
    def swap(self, pos):
        """隣り合う 2 本の D を入れ替える。he、no、ha の組み合わせで作る。"""
        if self.ty[pos:pos + 2] != [D, D]:
            raise ValueError("sw は D どうしだけ")
        self._frag("swap", pos)
        self.d[pos:pos + 2] = [max(self.d[pos:pos + 2])] * 2

    @_tracked
    def other(self, name, pos):
        """上のどれにも当たらない語。出力は深度 0 の新しいワイヤにする。"""
        ins, outs = WORDS[name]
        self._lay(pos, [name])
        self._put(pos, len(ins), list(outs), [0] * len(outs))

    def word(self, name, pos):
        """語 name を位置 pos に置く。入力の型が合わなければ ValueError。"""
        if name not in WORDS:
            raise ValueError("知らない語: %s" % name)
        ins = WORDS[name][0]
        if self.ty[pos:pos + len(ins)] != ins or (not ins and not 0 <= pos <= len(self.ty)):
            raise ValueError("%s の入力の型か位置が合わない" % name)
        if hasattr(self, name) and name != "other":
            getattr(self, name)(pos)
        else:
            self.other(name, pos)

    def parallel(self, boxes, count):
        """同じ箱の並びを count 組、左から順に同じ層へ置く。"""
        self.lines.append(" ".join(list(boxes) * count + ["ka"]))

    @_tracked
    def halve_all(self, count):
        """左端の count 本のそれぞれに 1/2 を掛ける。全部を同じ層で行う。"""
        for boxes in (["hu", "ki"], ["he", "ki"], ["ki", "ha", "ki"], ["no", "ki"], ["se", "ki"], ["ti"]):
            self.parallel(boxes, count)
        for i in range(count):
            self.d[i] += 1

    def load(self, n, shift=0):
        """作業領域の語 1, 2, 4, … 2^(n-1) を読んで n 本のワイヤを作り、それぞれに (1/2)^shift を掛ける。

        番地は hu に se を i 回かけた値の分子 2^i になる。入力の整数 N は N / 2^shift の値になる。
        実数を 2^-shift の格子に丸めて渡すときに使う。
        """
        self.lines.append(" ".join(["hu"] * n + ["ka"]))
        for s in range(1, n):
            self.lines.append(" ".join(["ki"] * s + ["se"] * (n - s) + ["ka"]))
        self.lines.append(" ".join(["mi"] * n + ["ka"]))
        self.d, self.ty = [0] * n, [D] * n
        self.peak = max(self.peak, n)
        for _ in range(shift):
            self.halve_all(n)

    def built(self):
        """出口の語ごとの深度を付けて返す。出口になれる型は OPEN にある型。"""
        if self.peak > MAXDEPTH:
            raise OverflowError("深度 %d が MAXDEPTH=%d を越える" % (self.peak, MAXDEPTH))
        depths = []
        for t, d in zip(self.ty, self.d):
            if t not in OPEN:
                raise ValueError("型 %s は出口にできない" % t)
            depths += [d] * OPEN[t]
        return Built("\n".join(self.lines) + "\n", depths)


def _step(fr, w, k):
    """手順の 1 段を置く。"""
    if w == "sw":
        if not 0 <= k < len(fr.ty) - 1:
            raise ValueError("sw の位置")
        fr.swap(k)
    else:
        fr.word(w, k)


def check(recipe, n):
    """手順が正しいことを確かめる。返りは (各段の前の型の並び, 終わりの型の並び)。"""
    fr = Wires()
    fr.ty, fr.d = [D] * n, [0] * n
    seen = []
    for w, k in recipe:
        seen.append(list(fr.ty))
        _step(fr, w, k)
    return seen, list(fr.ty)


def value(recipe, n, shift=0):
    """値を求める作図。結果は終わりのワイヤ全部。"""
    check(recipe, n)
    fr = Wires()
    fr.load(n, shift)
    for w, k in recipe:
        _step(fr, w, k)
    return fr.built()


def layered(layers, recipe, n, shift=0):
    """生成器が書いた層の並び（音節の文字列）に、入力を読む層を前置した完全な平文。深度は手順から決まる。"""
    built = value(recipe, n, shift)
    fr = Wires()
    fr.load(n, shift)
    return Built("\n".join(fr.lines + list(layers)) + "\n", built.depths)
