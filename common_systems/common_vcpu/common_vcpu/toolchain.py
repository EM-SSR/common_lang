# -*- coding: utf-8 -*-
"""平文を綴じて commonc で lane64 の image にし、vcpu.py の lane に配って走らせる。

doc: commonc.lexicon casm.lane64.host casm.lane64.state

    image, need = compile([a.cmn, b.cmn], dic, out)   順に綴じて compile（16 式 1.3: 連接が合成）
    tab   = load(image)
    M     = run(tab, words, {8: 3})                    一枚
    heads = LaneWorkers(image, 6).run(words, seeds)    lane ごとに種を変えて配る（20 §1）

道は一本になる（19 §7.1）。

    .dic + .cmn ──(commonc_lane64.bin on vcpu.py)──▶ lane64 image ──(vcpu.py)──▶ M

commonc の image は Haskell が `.cam` から作る。この module は `.cmn` を読まない。

    common commonc_lane64.cam -t lane64 --no-sim -o builds/commonc/commonc_lane64.bin

host が commonc へ渡すもの（19 §3.1 と front.cam の割付）:

    語 0    N      入力の byte 数（表 + 本文）
    語 1    IB     入力の基底語番号
    語 4    B      配列の刻み。表を展開すると音節が byte 数より増えるので host が決める
    語 130  LEXB   表の byte 数。表は本文の前に置く

commonc の lane64 版はワイヤ w を語 64 + w に置く（19 §3.3）。本文の作業領域はその上、
WORK = 2^16 から取る。compile 後の n_need が WORK を越えたら止める。

置き場は `common_systems/Python_vCPU`。実行台（vcpu、vcpu_vec）と同じ階層に置く。
借り手は automaton、joinrank、okataduke、LTLS、Joint-Log-Former、kaggriculture の
六つで、どれか一つのために書き換えてよい module ではない。
"""

import os
import pickle
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _find_root(start):
    """`builds/commonc` を持つディレクトリを上へ探す。

    install した場所でもリポジトリの中でも同じように見つかる。環境変数
    `COMMON_ROOT` があればそれを先に使う。
    """
    env = os.environ.get("COMMON_ROOT")
    if env and os.path.isdir(os.path.join(env, "builds", "commonc")):
        return env
    here = start
    for _ in range(8):
        if os.path.isdir(os.path.join(here, "builds", "commonc")):
            return here
        up = os.path.dirname(here)
        if up == here:
            break
        here = up
    return start


ROOT = _find_root(HERE)
COMMONC = os.path.join(ROOT, "builds", "commonc", "commonc_lane64.bin")
try:                      # パッケージとして使うとき
    from . import lex, vcpu
except ImportError:       # このディレクトリを sys.path に入れて使うとき
    import lex
    import vcpu


def _vec():
    """まとめて解釈する版（`vcpu_vec`）を返す。無い環境では None を返す。

    パッケージとして install した場合と、このディレクトリを `sys.path` に足した
    場合の両方で同じモジュールが返る。
    """
    import importlib
    for name in (__name__.rsplit(".", 1)[0] + ".vcpu_vec" if "." in __name__ else None,
                 "vcpu_vec"):
        if not name:
            continue
        try:
            return importlib.import_module(name)
        except ImportError:
            continue
    return None


SEP = "\n\n"
WORK = 1 << 16          # 本文の作業領域の基底。ワイヤ（語 64 + w）の上
W_B, W_LEXB = 4, 130    # host が commonc へ書く語
IN_MUL = 288            # 入力の基底 = IN_MUL · B（back_lane64.cam: 箱あたり 112 byte）


class CompileError(Exception):
    pass


def weave(paths, dst):
    body = [open(p, encoding="utf-8").read().strip() for p in paths]
    open(dst, "w", encoding="utf-8", newline="\n").write(SEP.join(body) + "\n")
    return dst


_CC = {}


def _commonc(path=None):
    """commonc の image を翻訳して返す。path を省くと lane64 版。image ごとに一度だけ翻訳する。"""
    path = path or COMMONC
    if path not in _CC:
        if not os.path.exists(path):
            raise CompileError("commonc の image が無い: %s\n"
                               "  common <commonc の .cam> -t lane64 --no-sim -o %s" % (path, path))
        _CC[path] = vcpu.translate(vcpu.decode(open(path, "rb").read()))[1]
    return _CC[path]


def compile(paths, dic, out, commonc=None, region=None):
    """綴じて commonc で compile する。返りは (image の byte 列, n_need)。

    commonc は target ごとの commonc の image（lane-qbit なら commonc_lane_qbit.bin）。
    省くと lane64 版を使う。

    region は (語数, 割付) か (語数, 割付, 読み) の組か None。commonc の作業領域の上に語数ぶんの置き場を足し、
    割付（置き場の先頭の語番号を受けて {語番号: 値} を返す関数）の語を置いてから走らせる。読みがあれば、
    compile が通った後の作業領域を渡して呼ぶ。lane-qbit の compile 時の状態に使う。

    dic は `.dic`（見出し ⟨tab⟩ 文）か None。表の byte 数を語 130 に、刻み B を語 4 に置く。
    B は展開後の音節数から決める（配列の容量は音節数で決まる。19 §3.2）。
    """
    os.path.isdir(os.path.dirname(out)) or os.makedirs(os.path.dirname(out))
    src = weave(paths, out[:-4] + ".cmn") if len(paths) != 1 else paths[0]
    body = open(src, encoding="utf-8").read()
    table = lex.lexicon(dic) if dic else ""
    data = (table + body).encode("utf-8")
    n = len(data)
    est = lex.expanded_syllables(dic, body) if dic else n // 2
    b = max(n + 80, 4096, 2 * est + 80)
    base = IN_MUL * b
    top = base + n + 4096
    size, place, read = (tuple(region) + (None,))[:3] if region else (0, None, None)
    lane = vcpu.Lane(top + size)
    lane.put_input(list(data), base)
    lane.M[W_B] = b
    lane.M[W_LEXB] = len(table.encode("utf-8"))
    for k, v in (place(top).items() if place else ()):
        lane.M[k] = v
    rep = vcpu.run_lane(_commonc(commonc), lane)
    if rep != 0:
        err = CompileError("commonc が %s を読めない（報告 %s）" % (src, rep))
        err.words = lane.M          # 止まった時点の作業領域。lane-qbit は語 1095 に「境界の桁が決まらない」印を置く
        raise err
    imgb, nimg, need = lane.M[1], lane.M[2], lane.M[3]
    if not (imgb and nimg):
        raise CompileError("commonc が image を出さない: %s" % src)
    if need > WORK:
        raise CompileError("箱が多すぎてワイヤが作業領域に重なる（n_need %d > WORK %d）" % (need, WORK))
    image = bytes(v & 255 for v in lane.M[imgb:imgb + nimg])
    if read:
        read(lane.M)
    open(out, "wb").write(image)
    open(out + ".need", "w").write(str(need))
    return image, need


def load_file(path):
    """compile が置いた image と、その隣の n_need を読む。返りは (image, need)"""
    image = open(path, "rb").read()
    side = path + ".need"
    need = int(open(side).read()) if os.path.exists(side) else None
    return image, need


def load(image, need=None):
    """image を翻訳する。need（compile が返す n_need）を渡すと、語 64 〜 need のワイヤのうち
    他の block が読まない Store を落とす（vcpu.translate の wires）。"""
    return vcpu.translate(vcpu.decode(image), wires=(64, need) if need else None)[1]


def run(tab, words, seed):
    """一枚走らせて作業領域を返す。報告が tu でなければ例外。"""
    lane = vcpu.Lane(words)
    for k, v in seed.items():
        lane.M[k] = v
    rep = vcpu.run_lane(tab, lane)
    if rep != 0:
        raise RuntimeError("報告 %s" % rep)
    return lane.M


# ===== lane を子 process に配る =====
#
# simulator は agent を daemon の worker で走らせるので、multiprocessing.Pool が作れない。
# subprocess で立てた worker に pickle で種を送り、読む語を受け取る。
# lane の作業領域は交わらない（20 式 1.2）ので、worker ごとに一枚を使い回し、
# 走らせる前に作業領域だけを零に戻す。ワイヤの語は読む前に必ず書かれる。


def _send(f, obj):
    data = pickle.dumps(obj, protocol=pickle.HIGHEST_PROTOCOL)
    f.write(struct.pack("<Q", len(data)) + data)
    f.flush()


def _recv(f):
    head = f.read(8)
    if len(head) < 8:
        raise EOFError("worker が閉じた")
    (n,) = struct.unpack("<Q", head)
    return pickle.loads(f.read(n))


def _run_seeds(tab, lane, seeds, head, watch):
    zero = [0] * (len(lane.M) - WORK)
    res = []
    for seed in seeds:
        lane.M[WORK:] = zero
        lane.M[:64] = [0] * 64
        for k, v in seed.items():
            lane.M[k] = v
        rep = vcpu.run_lane(tab, lane)
        res.append((rep, lane.M[:head], [lane.M[w] for w in watch]))
    return res


# ===== 束ねの道（vcpu_vec）=====
#
# worker が受け取った seeds を一枚ずつではなく W 枚まとめて走らせる。命題 6.1 が
# 根拠になる。W=256 で 7.3 - 7.7 倍、process を P 本立てて式 (0.4) の P 倍が乗る。
#
# numpy が無い環境では _run_seeds へ落ちる。落ちても観測は変わらない。

def _run_seeds_vec(tabv, seeds, words, head, watch, chunk, box):
    """box は worker の寿命で使い回す LaneVec の置き場。作業領域の確保は
    語数 x W x 8 byte を触るので、seeds の組ごとに作り直すと確保だけで束ねの
    利得が消える（wither・W=256 の実測で 0.5 倍まで落ちた）。"""
    import numpy as np
    vcpu_vec = _vec()
    res = []
    for off in range(0, len(seeds), chunk):
        part = seeds[off:off + chunk]
        lv = box.get(len(part))
        if lv is None or lv.M.shape[0] != words:
            lv = vcpu_vec.LaneVec(len(part), words)
            box[len(part)] = lv
        else:
            lv.M[WORK:] = 0
            lv.M[:64] = 0
        for l, seed in enumerate(part):
            for k, v in seed.items():
                lv.M[k, l] = v
        rep = vcpu_vec.run(tabv, lv)
        if lv.overflow():
            raise OverflowError("語が int64 を越えた。束ねの道へ載せられない")
        headw = np.asarray(lv.M[:head]).T.tolist()
        watchw = [[int(lv.M[w, l]) for w in watch] for l in range(len(part))]
        res.extend(zip(rep, headw, watchw))
    return res


def worker_main():
    """子 process の本体。最初に (image, need, width) を受け取り、
    あとは (words, seeds, head, watch) を繰り返す。

    width が 0 なら一枚ずつ（翻訳器の道）、正なら W 枚ずつ束ねる。
    """
    inp, out = sys.stdin.buffer, sys.stdout.buffer
    image, need, width = _recv(inp)
    tab = load(image, need)
    tabv = None
    if width:
        try:
            vcpu_vec = _vec()
            tabv = vcpu_vec.translate(vcpu.decode(image), wires=(64, need) if need else None)[1]
        except ImportError:
            tabv = None
    lane, box = None, {}
    while True:
        try:
            words, seeds, head, watch = _recv(inp)
        except EOFError:
            return
        if tabv is not None:
            try:
                _send(out, _run_seeds_vec(tabv, seeds, words, head, watch, width, box))
                continue
            except OverflowError:
                tabv, box = None, {}   # 溢れた image は以後ずっと翻訳器の道で走らせる
        if lane is None or len(lane.M) != words:
            lane = vcpu.Lane(words)
        _send(out, _run_seeds(tab, lane, seeds, head, watch))


class LaneWorkers(object):
    """image 一つを持つ worker を procs 本立てて、lane を配る。

    返りは lane ごとの (報告, 先頭 head 語, watch の語の値)。

    width を渡すと worker の中で W 枚を束ねる（vcpu_vec）。作業領域は
    語数 x width x 8 byte を取るので、語数 225536・width 256 で 462 MB になる。
    """

    def __init__(self, image, procs, need=None, width=0):
        self.procs = []
        for _ in range(max(1, procs)):
            p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--worker"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            _send(p.stdin, (image, need, width))
            self.procs.append(p)

    def run(self, words, seeds, head=8, watch=()):
        n = len(self.procs)
        parts = [seeds[k::n] for k in range(n)]
        for p, part in zip(self.procs, parts):
            _send(p.stdin, (words, part, head, tuple(watch)))
        out = [None] * len(seeds)
        for k, p in enumerate(self.procs):
            for i, r in enumerate(_recv(p.stdout)):
                out[k + i * n] = r
        return out

    def close(self):
        for p in self.procs:
            try:
                p.stdin.close()
                p.wait(timeout=5)
            except Exception:
                p.kill()


if __name__ == "__main__" and "--worker" in sys.argv:
    worker_main()
