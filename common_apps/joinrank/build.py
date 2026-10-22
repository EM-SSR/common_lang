# -*- coding: utf-8 -*-
"""接合秩の平文を綴じて走らせる。

道は一本（19 §7.1）。

    .dic + .cmn ──(commonc_lane64.bin on vcpu.py)──▶ lane64 image ──▶ vcpu.py

image は二つ作る。連接が合成になる（16 式 1.3）ので、綴じた並びが一本の文になる。

    joinrank   size ; anf ; rank ; factor     ρ と分離積と正規形
    anf        nvt ; anf                      正規形だけ。分離積の因子を読み直すのに使う

    ρ, p, q = joinrank(table, n, cut)

返りは接合秩と、定理 4.1 の分離積の組。

    F[α][β] = ⊕_{r<ρ} p[r][α]·q[r][β]
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, *([os.pardir] * 3)))
VCPU = os.path.join(ROOT, "continuous_republic", "common_systems", "Python_vCPU")
if VCPU not in sys.path:
    sys.path.insert(0, VCPU)

import lex        # noqa: E402
import toolchain  # noqa: E402

SRC = os.path.join(HERE, "joinrank")
DIC = os.path.join(SRC, "joinrank.dic")
OUT = os.path.join(HERE, "build")

FULL = ("size.cmn", "anf.cmn", "rank.cmn", "factor.cmn")
ANFONLY = ("nvt.cmn", "anf.cmn")

A = lex.addresses(DIC)
NIN, KUT, NAA, NBB, RHO, MSZ, NVT, OVF = (
    A["pebobe"], A["pebobo"], A["pebopa"], A["pebopi"],
    A["pebopu"], A["pebope"], A["pebopo"], A["pepabe"])
TAB, WIT, PCO, IDX, ANF = A["pepube"], A["pepupu"], A["pepupe"], A["pepupo"], A["pobepu"]
RHOMAX, STRIDE = A["pebebo"], A["pebepa"]
WORDS = toolchain.WORK + 280000

_CACHE = {}


def image(files, stem):
    """平文より新しい image が build に残っていれば、それを読む。無ければ compile する。"""
    if stem not in _CACHE:
        os.path.isdir(OUT) or os.makedirs(OUT)
        paths = [os.path.join(SRC, f) for f in files]
        out = os.path.join(OUT, stem + ".bin")
        src_t = max(os.path.getmtime(p) for p in list(paths) + [DIC])
        if os.path.exists(out + ".need") and os.path.getmtime(out) > src_t:
            _CACHE[stem] = toolchain.load_file(out)
        else:
            _CACHE[stem] = toolchain.compile(paths, DIC, out)
    return _CACHE[stem]


_TABLE = {}


def table(files, stem):
    """翻訳も一度だけ。image が大きいので、走らせるたびに訳し直すと走りより高くつく。"""
    if stem not in _TABLE:
        img, need = image(files, stem)
        _TABLE[stem] = toolchain.load(img, need)
    return _TABLE[stem]


def _run(files, stem, seed):
    return toolchain.run(table(files, stem), WORDS, seed)


def _seed(table, n, cut=None):
    s = {NIN: n}
    if cut is not None:
        s[KUT] = cut
    for v, b in enumerate(table):
        if b:
            s[TAB + v] = 1
    return s


# ===== 正規形 =====

def anf_support(table, n):
    """頂点値から正規形の台を読む。a_T = ⊕_{R⊆T} f(R)（R1 のメビウス変換）"""
    M = _run(ANFONLY, "anf", _seed(table, n))
    return [t for t in range(1 << n) if M[ANF + t]]


# ===== 接合秩 =====

def words(table, n, cut):
    return _run(FULL, "joinrank", _seed(table, n, cut))


def read(M):
    if M[OVF]:
        raise ValueError("接合秩が語の容量 %d を越えた" % (RHOMAX - 1))
    rho, na, nb = M[RHO], M[NAA], M[NBB]
    q = [[M[WIT + STRIDE * r + b] for b in range(nb)] for r in range(rho)]
    p = [[M[PCO + RHOMAX * a + r] for a in range(na)] for r in range(rho)]
    return rho, p, q


def joinrank(table, n, cut):
    return read(words(table, n, cut))


def figure(table, n, cut):
    """描画に要るものを一度にそろえる。

    anf      f の正規形の台。単項式 T は [n] の部分集合をビット列で表す
    psup[r]  p_r の台。添字は A の変数なので、そのまま [n] の番号になる
    qsup[r]  q_r の台。添字は B の変数なので、κ だけ左へずらして [n] の番号にする
    """
    M = words(table, n, cut)
    rho, p, q = read(M)
    fig = dict(n=n, cut=cut, rho=rho, p=p, q=q,
               anf=[t for t in range(1 << n) if M[ANF + t]])
    fig["psup"] = [anf_support(p[r], cut) for r in range(rho)]
    fig["qsup"] = [[s << cut for s in anf_support(q[r], n - cut)] for r in range(rho)]
    return fig
