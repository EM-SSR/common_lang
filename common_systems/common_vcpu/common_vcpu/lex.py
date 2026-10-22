# -*- coding: utf-8 -*-
"""採用語彙の表（`.dic`）を読む。見出しは be bo pa pi pu pe po の七音で綴り、中身はこの言語の文で書く。

    pepe	hu ka, he ka, no ka, he ka, no ka, he ka, no ka.
    popo	pepe ka, ki hu ka, no ka.
    pupu	=40                                   数だけの語は = で書ける（綴りは spell）

表を読むのは commonc で、この module は行を並べるだけになる（16 式 1.5: Lex ⊆ Σ* × C）。
`=N` の行は数を綴った文へ置き換えて渡す。`#` の行と空行は落とす。

辞書の語は全部 I → D で、番地を机に一つ置く。値にするのは文の中の mi、
書くのは 値 ka, 番地 ka, mu ka になる。Python が観測を語へ写すときの番地は
addresses() の表から取る。
"""

import re

LETTERS = ("be", "bo", "pa", "pi", "pu", "pe", "po")


def spell(n):
    """整数を基準の音節で綴る。二進の Horner: 上の桁から「もういちど、あわせる」で倍にし、
    桁が 1 なら「ひとつ、あわせる」を足す。"""
    if n < 0:
        return spell(-n) + ", ha ka"
    if n == 0:
        return "hu ka, he ka, ki ha ka, no ka"
    out = ["hu ka"]
    for bit in bin(n)[3:]:
        out.append("he ka, no ka")
        if bit == "1":
            out.append("ki hu ka, no ka")
    return ", ".join(out)


def spelled(name):
    return len(name) % 2 == 0 and all(name[i:i + 2] in LETTERS for i in range(0, len(name), 2))


def entries(dic):
    """(行番号, 見出し, 文) の列。# 行と空行は飛ばす。=N は綴った文にする"""
    out = []
    for n, line in enumerate(open(dic, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name, _, body = line.partition("\t")
        name, body = name.strip(), body.strip()
        if not spelled(name):
            raise ValueError("%s:%d: 見出し %s は be bo pa pi pu pe po で綴る" % (dic, n, name))
        if body.startswith("="):
            body = spell(int(body[1:])) + "."
        out.append((n, name, body))
    return out


def lexicon(dic):
    """commonc へ渡す表の文字列。一行が 見出し ⟨tab⟩ 文 ⟨改行⟩"""
    return "".join(name + "\t" + body + "\n" for _, name, body in entries(dic))


def addresses(dic):
    """数だけの語（=N）の表 {見出し: N}"""
    out = {}
    for line in open(dic, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name, _, body = line.partition("\t")
        if body.strip().startswith("="):
            out[name.strip()] = int(body.strip()[1:])
    return out


_TOKEN = re.compile(r"[a-z]+")


def expanded_syllables(dic, body):
    """表を展開した後の音節の数。commonc の配列の刻み B を決めるためだけに数える"""
    size = {}
    for _, name, text in entries(dic):
        size[name] = _count(text, size)
    return _count(body, size)


def _count(text, size):
    total = 0
    for tok in _TOKEN.findall(text):
        if tok in size:
            total += size[tok]
        else:
            total += (len(tok) + 1) // 2
    return total
