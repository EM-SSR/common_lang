# -*- coding: utf-8 -*-
"""束ねの道が翻訳器の道と同じ観測を返すか。命題 6.1 の検査。

    python test_vcpu_vec.py

見るのは三つになる。

    一致    報告と watch の語が二本の道で同じか。溢れ（int64 の巻き戻し）も見る
    配り    LaneWorkers を束ねで立てても同じ答えを返すか
    速さ    一 lane あたりの時間

produce は章そのものが重く、翻訳器の道でも一枚が終わらない。平文の側の話なので
ここでは掛けない。
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, *([os.pardir] * 3)))
sys.path.insert(0, HERE)

import lex           # noqa: E402
import toolchain     # noqa: E402
import vcpu          # noqa: E402
import vcpu_vec      # noqa: E402

KG = os.path.join(ROOT, "simulator", "kaggriculture", "still_better_than_JA", "proof")
WORDS = toolchain.WORK + 160000
A = lex.addresses(os.path.join(KG, "proof.dic"))
NDIG, NST, IDX, DIFF = A["pebobe"], A["pebobo"], A["pebopa"], A["pebopi"]
CHAPTERS = ("wither", "water", "decay", "spawn", "price", "hire", "land", "fib")


def chapters():
    return [c for c in CHAPTERS if os.path.exists(os.path.join(KG, "build", c + ".bin"))]


def seeds_of(width):
    return [{NDIG: 4, NST: width, IDX: k} for k in range(width)]


def check(name, width):
    """一致と速さを同時に見る。返りは (合うか, 束ねの秒, 翻訳器の秒)"""
    img, need = toolchain.load_file(os.path.join(KG, "build", name + ".bin"))
    prog = vcpu.decode(img)

    _s, tabv = vcpu_vec.translate(prog, wires=(64, need))
    lv = vcpu_vec.LaneVec(width, WORDS)
    for l, s in enumerate(seeds_of(width)):
        for a, v in s.items():
            lv.M[a, l] = v
    t0 = time.time()
    rep_v = list(vcpu_vec.run(tabv, lv))
    tv = time.time() - t0
    dif_v = [int(lv.M[DIFF, l]) for l in range(width)]

    _s, tab = vcpu.translate(prog, wires=(64, need))
    t0 = time.time()
    rep_s, dif_s = [], []
    for s in seeds_of(width):
        lane = vcpu.Lane(WORDS)
        for a, v in s.items():
            lane.M[a] = v
        rep_s.append(vcpu.run_lane(tab, lane))
        dif_s.append(lane.M[DIFF])
    ts = time.time() - t0

    # 観測の一致と、int64 の巻き戻しは別に見る。fib は観測が合うのに語が 2^62 を
    # 越えるので、たまたま合っているだけになる。束ねの道へは載せない
    return (rep_v == rep_s and dif_v == dif_s), lv.overflow(), tv, ts


def workers(name, total, procs, width):
    """LaneWorkers を束ねで立てても、一枚ずつと同じ答えを返すか。

    仕事が小さいと確保と process 間の受け渡しが勝つ。total を procs x width まで
    上げて、worker ひとつが width 枚を束ねる形で測る。
    """
    img, need = toolchain.load_file(os.path.join(KG, "build", name + ".bin"))
    sd = seeds_of(total)
    out = {}
    for w in (0, width):
        pool = toolchain.LaneWorkers(img, procs, need, width=w)
        pool.run(WORDS, sd[:procs], head=0, watch=(DIFF,))      # 立ち上げを外す
        t0 = time.time()
        out[w] = (pool.run(WORDS, sd, head=0, watch=(DIFF,)), time.time() - t0)
        pool.close()
    same = out[0][0] == out[width][0]
    return same, out[0][1], out[width][1]


if __name__ == "__main__":
    bad = 0
    print("命題 6.1 の突き合わせと速さ（一 lane あたり）")
    print("  %-8s %5s %10s %10s %7s  %-6s %s" % ("章", "W", "束ね秒", "翻訳器秒", "倍", "観測", "溢れ"))
    for nm in chapters():
        for w in (64, 256):
            try:
                ok, over, tv, ts = check(nm, w)
            except Exception as e:
                print("  %-8s %5d  止まった: %s" % (nm, w, type(e).__name__))
                bad += 1
                continue
            # 溢れた章は束ねの道に載せない（worker が翻訳器へ落とす）ので、
            # 観測が合うかどうかは合否に数えない
            bad += 0 if (ok or over) else 1
            print("  %-8s %5d %10.3f %10.3f %7.1f  %-6s %s"
                  % (nm, w, tv, ts, ts / tv if tv else 0,
                     "一致" if ok else "食違", "あり（翻訳器へ落とす）" if over else "無し"))

    print()
    P = min(6, os.cpu_count() or 1)
    W, nm = 256, "wither"
    print("worker を立てて %d 枚を配る（worker ひとつが %d 枚を束ねる）" % (P * W, W))
    same, ta, tb = workers(nm, P * W, P, W)
    bad += 0 if same else 1
    print("  %-8s %d 本  一枚ずつ %.3f 秒  束ね %.3f 秒  %.1f 倍  答えは %s"
          % (nm, P, ta, tb, ta / tb if tb else 0, "同じ" if same else "違う ←"))
    for p in (1, 2, 3, P):
        if p > P:
            break
        _s, _a, t = workers(nm, P * W, p, W)
        print("  %-8s %d 本  束ね %.3f 秒" % (nm, p, t))

    print()
    print("食い違い %d" % bad)
    sys.exit(1 if bad else 0)
