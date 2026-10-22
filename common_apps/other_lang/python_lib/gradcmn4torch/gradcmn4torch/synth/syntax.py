# -*- coding: utf-8 -*-
"""生成器が書く .cmn の字句と、その文法。

生成器は音節をそのまま書く。字句は次のとおり。

    <pad> <bos> <end>   詰め物、始まり、終わり
    ka                  層を閉じる
    ki                  今の位置のワイヤを素通しして、位置を 1 つ進める
    語                  words.py の語。今の位置から入力を取り、出力をその位置に置く（位置は出力の分だけ進む）

層は左から右へ読む。層の終わりに残ったワイヤは、そのまま次の層へ渡る。最初の窓は D 型の 3 本（A、B、c）で、
終わりに残る 1 本が答えになる。型が合わない語、ワイヤの数や深度が上限を越える語、残りの語数で答えに畳めなくなる語は書けない。

ya と yi は閉包の開きと閉じで、それぞれ層に 1 つだけ置く。開いた間は、yi が B を受けて閉じたあとの型が、ya を置いたときの
型に戻る語の並びだけを書ける。me は出口を書かずに実行を閉じ、di は失敗するので、この 2 語を含む手順は答えを出さない。

文法の状態は (ワイヤの型の並び, 深度の並び, 位置, 層の中の語の数, 使った語の数, 開いた閉包の型, 層を閉じたか)。同じ状態は 1 つの番号にまとめ、
各状態で書ける字句の表と、字句を書いたあとの状態を覚える。
"""
from functools import lru_cache

import numpy as np

from .. import assemble
from ..words import OPEN, WORDS

PAD, BOS, END, KA, KI = 0, 1, 2, 3, 4
WORD_LIST = sorted(WORDS)
TOKENS = ["<pad>", "<bos>", "<end>", "ka", "ki"] + WORD_LIST
V = len(TOKENS)
INDEX = {t: i for i, t in enumerate(TOKENS)}
FIRST_WORD = 5

N_LEAF = 3          # A, B, c
MAX_WORDS = 12      # 語の数の上限
MAX_TOKENS = 76     # 終わりの字句を含む字句の数の上限。語 1 つは位置の ki を最大 4、語、ka で 6 字句になる
MAX_WIRES = 5
DEPTH_CAP = 12      # どのワイヤの深度もこれ以下
NUMERIC = {"no", "ti", "za", "ha", "se", "gu", "zi", "hi", "so", "mo", "ge"}

START = (("D",) * N_LEAF, (0,) * N_LEAF, 0, 0, 0, None, False)


def _apply(ty, d, word, pos, typeonly=False):
    """位置 pos に語を当てた後の (型の並び, 深度の並び)。当てられなければ None。"""
    fr = assemble.Wires()
    fr.ty, fr.d = list(ty), [9 if typeonly else x for x in d]
    try:
        fr.word(word, pos)
    except (ValueError, IndexError):
        return None
    return fr.ty, fr.d


@lru_cache(maxsize=None)
def _successors(ty):
    """型の並び ty に語を 1 つ置いてできる型の並び（深度は見ない）。"""
    out = set()
    for w in WORD_LIST:
        if w in ("ya", "yi"):                               # 閉包の語は、ya と yi の対としてだけ置く
            continue
        ins, outs = WORDS[w]
        for pos in range(len(ty) - len(ins) + 1):
            if list(ty[pos:pos + len(ins)]) == ins:
                nxt = ty[:pos] + tuple(outs) + ty[pos + len(ins):]
                if nxt != ty and 0 < len(nxt) <= MAX_WIRES:
                    out.add(nxt)
    return tuple(out)


@lru_cache(maxsize=None)
def _graph():
    """型の並びを点、語を 1 つ置くことを辺とした、START から行ける範囲の逆向きの辺の表。"""
    seen, todo, back = {START[0]}, [START[0]], {}
    while todo:
        ty = todo.pop()
        for nxt in _successors(ty):
            back.setdefault(nxt, []).append(ty)
            if nxt not in seen:
                seen.add(nxt)
                todo.append(nxt)
    return seen, back


def _distance(goals):
    """goals のどれかに畳むまでに置く語の最小数（幅優先）。goals に着いたあとは先へ進まない。"""
    back = _graph()[1]
    dist = {g: 0 for g in goals}
    todo = list(goals)
    for ty in todo:
        for prev in back.get(ty, ()):
            if prev not in dist:
                dist[prev] = dist[ty] + 1
                todo.append(prev)
    return dist


@lru_cache(maxsize=None)
def _fold():
    """型の並びから、答えにできる 1 本に畳むまでに置く語の最小数。"""
    return _distance([ty for ty in _graph()[0] if len(ty) == 1 and ty[0] in OPEN])


@lru_cache(maxsize=None)
def _to_loop(loop):
    """型の並びから、yi が B を受けて loop に戻せる型に着くまでに置く語の最小数。"""
    nodes = _graph()[0]
    return _distance([t for t in (loop[:i] + ("B",) + loop[i:] for i in range(len(loop) + 1)) if t in nodes])


def _feasible(ty, left):
    """型の並び ty から、left 個の語で答えにできる 1 本に畳めるか（語は好きな位置に置ける）。"""
    return _fold().get(ty, left + 1) <= left


def _loop_feasible(ty, loop, left):
    """閉包が開いている間に、left 個の語で yi が B を受けて loop に戻し、そのあと答えに畳めるか。"""
    return _to_loop(loop).get(ty, left + 1) + 1 + _fold().get(loop, left + 1) <= left


def _reachable(ty, loop, left):
    return _feasible(ty, left) if loop is None else _loop_feasible(ty, loop, left)


@lru_cache(maxsize=None)
def _has_word(state):
    """この状態から位置を進めながら、置ける語があるか（置ける位置が右にあれば、ki で進める）。"""
    ty, d, cursor, boxes, words, loop, closed = state
    return any(step_state((ty, d, c, boxes, words, loop, closed), t) is not None
               for c in range(cursor, len(ty) + 1) for t in range(FIRST_WORD, V))


def step_state(state, token):
    """字句を書いたあとの状態。書けなければ None。"""
    ty, d, cursor, boxes, words, loop, closed = state
    if token == KI:
        if cursor >= len(ty):
            return None
        nxt = (ty, d, cursor + 1, boxes, words, loop, closed)
        return nxt if boxes > 0 or _has_word(nxt) else None            # 語を 1 つも置けない位置へは進まない
    if token == KA:                                         # 語が 1 つもない層は閉じられない
        return (ty, d, 0, 0, words, loop, False) if boxes > 0 else None
    if token == END:
        ok = cursor == 0 and boxes == 0 and words > 0 and loop is None and len(ty) == 1 and ty[0] in OPEN
        return state if ok else None
    if token < FIRST_WORD or words >= MAX_WORDS or closed:
        return None
    w = TOKENS[token]
    left = MAX_WORDS - words - 1
    if w == "ya":                                           # 閉包を開く。層に 1 つだけ置き、入れ子にはしない
        if loop is not None or boxes > 0 or not _loop_feasible(ty, ty, left):
            return None
        return ty, d, cursor, boxes + 1, words + 1, ty, True
    if w == "yi":                                           # B を 1 本受けて閉じる。ya を置いたときの型に戻るときだけ
        if loop is None or boxes > 0 or cursor >= len(ty) or ty[cursor] != "B":
            return None
        nty = ty[:cursor] + ty[cursor + 1:]
        if nty != loop or not _feasible(nty, left):
            return None
        return nty, d[:cursor] + d[cursor + 1:], cursor, boxes + 1, words + 1, None, True
    r = _apply(ty, d, w, cursor)
    if r is None or len(r[0]) > MAX_WIRES or max(r[1] + [0]) > DEPTH_CAP or not _reachable(tuple(r[0]), loop, left):
        return None
    return tuple(r[0]), tuple(r[1]), cursor + len(WORDS[w][1]), boxes + 1, words + 1, loop, closed


class Table(object):
    """状態に番号を付け、状態ごとに書ける字句の表と、書いたあとの状態を覚える。"""

    def __init__(self):
        self.ids = {}
        self.states = []
        self.mask = np.zeros((1024, V), dtype=bool)
        self.next = np.full((1024, V), -1, dtype=np.int32)
        self.dead = -2                  # 書けない字句の印
        self.id_of(START)

    def id_of(self, state):
        i = self.ids.get(state)
        if i is None:
            i = self.ids[state] = len(self.states)
            self.states.append(state)
            if i >= len(self.mask):
                self.mask = np.concatenate([self.mask, np.zeros_like(self.mask)])
                self.next = np.concatenate([self.next, np.full_like(self.next, -1)])
            for t in range(V):
                if t != PAD and t != BOS:
                    self.mask[i, t] = step_state(state, t) is not None
        return i

    def advance(self, ids, tokens):
        """状態の番号の並びと字句の並びから、次の状態の番号の並びを返す。"""
        nxt = self.next[ids, tokens]
        for k in np.flatnonzero(nxt < 0):
            s = step_state(self.states[ids[k]], int(tokens[k]))
            nxt[k] = self.id_of(s) if s is not None else 0
            self.next[ids[k], tokens[k]] = nxt[k]
        return nxt


TABLE = Table()


WEIGHT = {"ho": 0.3, "du": 0.3, "mu": 0.1, "mi": 0.15, "ya": 0.15, "me": 0.01, "di": 0.01}      # 値を捨てる語、番地を使う語、報告の語は控えめに


INERT = 0.1


def _weight(token, boxes):
    """乱数で手順を作るときの、字句の選ばれやすさ。数を作る語を多めにして、答えが値を持つ型になりやすくする。"""
    if token == KA:
        return 1.0 if boxes else 0.05
    if token == KI:
        return 0.4
    if token < FIRST_WORD:
        return 1.0
    w = TOKENS[token]
    base = 3.0 if w in NUMERIC else WEIGHT.get(w, 1.0)
    return base if all(t in "DBQX" for t in WORDS[w][1]) else base * INERT        # 値を持たない型に変える語は控えめに


def prior():
    """字句ごとの選ばれやすさ（状態によらない分）。モデルの出力の偏りの初期値に使う。"""
    return np.array([_weight(t, 1) for t in range(V)])


def random_tokens(rng, target):
    """語の数がおよそ target の .cmn を、字句の列として作る。目標を過ぎたら END へ向かう。"""
    sid, tokens, words = 0, [], 0
    while len(tokens) < MAX_TOKENS - 1:
        ok = TABLE.mask[sid]
        if words >= target and ok[END]:
            return tokens + [END]
        choices = np.flatnonzero(ok)
        if len(choices) == 0:
            return None
        if words >= target:                                 # 目標の語数を過ぎたら、ワイヤを減らす語を選ぶ
            ty = TABLE.states[sid][0]
            shrink = [t for t in choices if t >= FIRST_WORD and len(TABLE.states[TABLE.advance(np.array([sid]), np.array([t]))[0]][0]) < len(ty)]
            if shrink:
                choices = np.array(shrink)
        boxes = TABLE.states[sid][3]
        weight = np.array([_weight(t, boxes) for t in choices])
        t = int(rng.choice(choices, p=weight / weight.sum()))
        words += t >= FIRST_WORD
        tokens.append(t)
        sid = int(TABLE.advance(np.array([sid]), np.array([t]))[0])
    return None


def masks_of(tokens):
    """字句の列 (N, T) の各位置で書けた字句の表 (N, T, V)。"""
    tokens = np.asarray(tokens)
    ids, out = np.zeros(len(tokens), dtype=np.int64), np.zeros(tokens.shape + (V,), dtype=bool)
    for t in range(tokens.shape[1]):
        out[:, t] = TABLE.mask[ids]
        ids = TABLE.advance(ids, tokens[:, t])
    return out


def to_recipe(tokens):
    """字句の列を、(語, 位置) の手順にする。"""
    steps, pos = [], 0
    for t in tokens:
        if t == KI:
            pos += 1
        elif t == KA:
            pos = 0
        elif t >= FIRST_WORD:
            w = TOKENS[t]
            steps.append((w, pos))
            pos += len(WORDS[w][1])
    return steps


def to_layers(tokens):
    """字句の列を .cmn の層の並び（音節の文字列）にする。"""
    lines, cur = [], []
    for t in tokens:
        if t >= KA:
            cur.append(TOKENS[t])
            if t == KA:
                lines.append(" ".join(cur))
                cur = []
    return lines
