# -*- coding: utf-8 -*-
"""Bitcoin のジェネシスブロックのヘッダ（80 byte）を、cmn の SHA-256d で検算する。途中の状態を可視化し、雑音の中で測る。

    python tests/verify_btc.py <出力ディレクトリ> [--no-quantum] [--shots 2]

手順
  1. ヘッダ（80 byte）の SHA-256d を、sha256d_trace.cmn が計算する。途中の状態も出す
       圧縮は 3 回: 一度目の SHA-256 のブロック 0、ブロック 1、二度目の SHA-256 のブロック 0
  2. FIPS 180-4 の定義どおりの純 Python の基準（tests/sha256_reference.py）と、スケジュール W の 192 語、ラウンドごとの状態の 192 個を、
     全語で照合する。出力を hashlib と、Bitcoin が公表するジェネシスブロックのハッシュに照合し、難しさの目標 bits と比べる
  3. 圧縮ごとに、W と状態のビットを画像にする
  4. 途中の状態と出力を、lane-qbit の 256 量子ビットの移送の回路で測る。標準理論の雑音（緩和、過回転、z のずれ）と
     Counter の初期状態（z_j、メビウス結合）を重ねる。全 shot が一致するかを数える
"""
import argparse
import hashlib
import os
import struct
import sys
import time
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sha256_reference as ref                                      # noqa: E402

GENESIS = dict(version=1, prev=bytes(32),
               merkle=bytes.fromhex("3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a"),   # 内部の byte 順
               time=1231006505, bits=0x1D00FFFF, nonce=2083236893)
GENESIS_HASH = "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"      # 公表されている値（表示の byte 順）


def header(g=GENESIS):
    return struct.pack("<I", g["version"]) + g["prev"] + g["merkle"] + struct.pack("<III", g["time"], g["bits"], g["nonce"])


def target(bits):
    """難しさの目標。bits = 指数 (8 ビット) と仮数 (24 ビット)。target = 仮数 × 2^(8 (指数 − 3))。"""
    return (bits & 0xFFFFFF) << (8 * ((bits >> 24) - 3))


def pack(words):
    """語（32 ビット）の並びを、語 w のビット i が量子ビット 32 w + i になる整数へ。"""
    return sum(w << (32 * i) for i, w in enumerate(words))


LABELS = ["SHA-256 一度目 ブロック 0", "SHA-256 一度目 ブロック 1", "SHA-256 二度目 ブロック 0"]


def compare(trace, want):
    """cmn の (W、状態) の並びと、基準を全語で照合する。返りは不一致の語の数。"""
    bad = 0
    for (w, s), (w2, s2) in zip(trace, want):
        bad += sum(a != b for a, b in zip(w, w2))
        bad += sum(x != y for r1, r2 in zip(s, s2) for x, y in zip(r1, r2))
    return bad


def draw(root, comp, index, want):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
    plt.rcParams["font.family"] = ["Yu Gothic", "Meiryo", "MS Gothic", "DejaVu Sans"]          # 日本語の字形
    w, s = comp
    wb = np.array([[(x >> i) & 1 for i in range(32)] for x in w])
    sb = np.array([[(word >> i) & 1 for word in row for i in range(32)] for row in s])
    fig, ax = plt.subplots(1, 2, figsize=(16, 7), gridspec_kw={"width_ratios": [1, 8]})
    ax[0].imshow(wb, aspect="auto", cmap="Greys", interpolation="nearest")
    ax[0].set_title("スケジュール W_t（ビット 0 … 31）")
    ax[0].set_ylabel("t")
    ax[1].imshow(sb, aspect="auto", cmap="Greys", interpolation="nearest")
    for k in range(1, 8):
        ax[1].axvline(32 * k - 0.5, color="tab:red", lw=0.8)
    ax[1].set_xticks([16 + 32 * k for k in range(8)])
    ax[1].set_xticklabels(list("abcdefgh"))
    ax[1].set_title("ラウンド t = 0 … 63 の後の状態 (a … h)。各語はビット 0 … 31")
    fig.suptitle("%s（cmn。基準との不一致 %d 語）" % (LABELS[index], sum(a != b for a, b in zip(w, want[index][0]))
                                                  + sum(x != y for r1, r2 in zip(s, want[index][1]) for x, y in zip(r1, r2))))
    fig.tight_layout()
    path = os.path.join(root, "compression_%d.png" % index)
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return path


def measure(states, shots, noise, counter, label, root):
    """各状態（256 ビット）を、移送の回路で測る。返りは (回路の数、全 shot が一致した回路の数、不一致のビットの総数)。"""
    from common_qbit import CommonQbitBackend
    from common_qbit.noise import world
    from common_qbit.qpu import steer
    w = world(noise, counter)
    u0 = [Fraction(1, 3), Fraction(5, 7), Fraction(1, 11), Fraction(9, 10)][:shots]
    ok = bad = 0
    for d in states:
        counts = CommonQbitBackend().run(steer.transport_circuit(d, bits=256), shots=len(u0), initial_u0=u0, world=w,
                                         method="density_matrix").result().get_counts()
        n_ok = counts.get(format(d, "0256b"), 0)
        ok += n_ok == len(u0)
        bad += sum(n * bin(int(k, 2) ^ d).count("1") for k, n in counts.items())
    return len(states), ok, bad


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--no-quantum", action="store_true")
    ap.add_argument("--shots", type=int, default=2)
    a = ap.parse_args(argv)
    os.makedirs(a.root, exist_ok=True)
    from common_qbit.cmn import sha256d
    hdr = header()
    assert len(hdr) == 80
    t0 = time.time()
    digest, trace = sha256d.trace(hdr)
    d_ref, want = ref.sha256d_states(hdr)
    bad = compare(trace, want)
    shown = digest[::-1].hex()
    in_target = int.from_bytes(digest, "little") <= target(GENESIS["bits"])
    lines = ["# Bitcoin のジェネシスブロックの検算", "",
             "ヘッダ（80 byte）: `%s`" % hdr.hex(), "",
             "| 項目 | 値 |", "|---|---|",
             "| cmn の SHA-256d（byte を逆順に表示） | `%s` |" % shown,
             "| 公表されているブロックのハッシュ | `%s` |" % GENESIS_HASH,
             "| hashlib の SHA-256d との一致 | %s |" % ("一致" if digest == hashlib.sha256(hashlib.sha256(hdr).digest()).digest() else "不一致"),
             "| 公表値との一致 | %s |" % ("一致" if shown == GENESIS_HASH else "不一致"),
             "| 難しさの目標 bits = 0x%08x、ハッシュ ≤ 目標 | %s |" % (GENESIS["bits"], "満たす" if in_target else "満たさない"),
             "| 圧縮の数（一度目 %d ブロック、二度目 1）| %d |" % (len(trace) - 1, len(trace)),
             "| スケジュール W と途中の状態の、基準との不一致の語 | %d / %d |" % (bad, len(trace) * (64 + 64 * 8)), ""]
    for i, comp in enumerate(trace):
        draw(a.root, comp, i, want)
    lines += ["## 途中の状態", "", "圧縮ごとに、スケジュール W の 64 語と、ラウンドごとの状態 (a … h) をビットで描いた。", ""]
    lines += ["![%s](compression_%d.png)" % (LABELS[i], i) for i in range(len(trace))]
    lines.append("")
    if not a.no_quantum:
        lines += ["## 雑音の中で測る", "",
                  "途中の状態（256 ビットずつ）と出力を、256 量子ビットの移送の回路で測る。1 回路が %d shot。" % a.shots, "",
                  "| 対象 | 雑音 | Counter の初期状態 | 回路 | 全 shot が一致した回路 | 不一致のビット |", "|---|---|---|---:|---:|---:|"]
        final = [pack([int.from_bytes(digest[4 * k:4 * k + 4], "big") for k in range(8)])]
        for noise, counter in ((False, False), (True, False), (False, True), (True, True)):
            n, ok, bd = measure(final, a.shots, noise, counter, "出力", a.root)
            lines.append("| 出力 | %s | %s | %d | %d | %d |" % ("あり" if noise else "なし", "あり" if counter else "なし", n, ok, bd))
        for i, (w, s) in enumerate(trace):
            sts = [pack(r) for r in s]
            ws = [pack(w[8 * k:8 * k + 8]) for k in range(8)]
            for name, arr in (("ラウンドの状態 64 個", sts), ("スケジュール W 8 区間", ws)):
                n, ok, bd = measure(arr, a.shots, True, True, name, a.root)
                lines.append("| %s: %s | あり | あり | %d | %d | %d |" % (LABELS[i], name, n, ok, bd))
        lines.append("")
    with open(os.path.join(a.root, "Index.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines[:16]))
    print("%.0f 秒" % (time.time() - t0))
    return 0 if bad == 0 and shown == GENESIS_HASH else 1


if __name__ == "__main__":
    sys.exit(main())
