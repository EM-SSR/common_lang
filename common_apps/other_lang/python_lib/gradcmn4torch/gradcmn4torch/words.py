# -*- coding: utf-8 -*-
"""Common の語の型。リファレンスの総表（cmn_lang_ref/generators/Index.md）の Γ⁻ → Γ⁺ をそのまま写す。

型の記号:  D Dyad   B Bit   P Point   T Trace   R Reflection   N Noun   Q 𝒬   G Region   C Chain   X Rational

ワイヤの列の左端から、入力の型を左から右の順に取り、出力の型を同じ位置に置く。
生成に使わない語は tu だけ。名詞の複製で、Common が禁じている。
    ya yi  閉包の開きと閉じ。対にして使い、yi は 1 本の B を受けて、0 の間は ya の層へ戻る
    me di  成功と失敗の報告。me は出口を書かずに実行を閉じ、di は失敗する。どちらも答えを出さない
    du mu  出力と書き込み。du は 1 byte を出力に送り、mu は (番地, 値) を作業領域へ書く
    mi   作業領域の読み出し。番地が入力の値の分子になり、深度 0 の値が出る
"""
D, B, P, T, R, N, Q, G, C, X = "D", "B", "P", "T", "R", "N", "Q", "G", "C", "X"

WORDS = {
    "ke": ([T], [T]), "ko": ([P], [P]), "sa": ([T], [T]), "si": ([T], [T]), "su": ([T], [T]),
    "se": ([D], [D]), "so": ([D], [B]), "ta": ([P, P], [P]), "ti": ([D, D], [D]), "te": ([N], []),
    "to": ([D, D], [Q]), "na": ([D], [Q]), "ni": ([D], [Q]), "nu": ([Q, Q], [Q]), "ne": ([Q], [B]),
    "no": ([D, D], [D]), "ha": ([D], [D]), "hi": ([D, D], [B]), "hu": ([], [D]), "he": ([D], [D, D]),
    "ho": ([D], []), "ma": ([], [N]), "mo": ([B], [D]), "yu": ([Q, Q], [Q]), "ye": ([Q, Q], [Q]),
    "yo": ([Q, Q], [Q]), "ra": ([Q, Q], [B]), "ri": ([N, N], [Q]), "ru": ([Q], [Q]), "re": ([], [T]),
    "ro": ([T], [T]), "wa": ([T], [T]), "wi": ([T], [P]), "wu": ([], [R]), "we": ([], [R]),
    "wo": ([], [R]), "ga": ([R, R], [R]), "gi": ([R, P], [P]), "gu": ([D], [D]), "ge": ([D], [D]),
    "go": ([Q], [B]), "za": ([D, D], [D]), "zi": ([D, D], [D]), "zu": ([N], [N]), "ze": ([N], [N]),
    "zo": ([N, N], [N, N]), "da": ([N, N], [N, N]), "de": ([P], [P]), "do": ([P], [P]),
    "ba": ([D, D], [X]), "bi": ([C], [C]), "bu": ([C, C], [C]), "kukeke": ([N], [G]),
    "ya": ([], []), "yi": ([B], []), "me": ([], []), "di": ([], []), "du": ([D], []), "mu": ([D, D], []),
    "mi": ([D], [D]),
    "kukeko": ([G, G], [G]), "kukesa": ([G, G], [G]), "kukesi": ([G, G], [G]), "kukesu": ([G], [C]),
    "kukese": ([G, G], [B]), "kukeso": ([G, G], [B]), "kuketa": ([G, G], [B]), "kuketi": ([G], [B]),
}

# 最後に残る 1 本が出力として開く語の数（作業領域の語 0, 1, … へ）
OPEN = {D: 1, B: 1, R: 1, P: 2, T: 4, N: 5, Q: 5, X: 2}
