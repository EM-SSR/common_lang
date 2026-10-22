# -*- coding: utf-8 -*-
"""GGUF の係数を番地で引く。テンソルという object を作らない。

`numpy.memmap` で開くだけなので、読んだ分しか RSS に載らない。段の閉包が回っている
間に必要なのはその段の係数だけで、共有メモリへは段ごとに送る。

    s = Store("data/Qwen3.8-27b-Q6/Qwen3.8-27B-Uncensored-Q6_K.gguf")
    s.shape("blk.0.ffn_gate.weight")      # 形だけ見る。読まない
    s.fit(d=1, k=8)                       # 詰めたときの byte 数と段ごとのピーク

GGUF の形式は magic "GGUF"、版、テンソルの数、メタデータの数、メタデータ、テンソルの
目録、そして揃えた本体になる。ここでは目録だけを読む。
"""
import os
import struct

MAGIC = b"GGUF"

# 型ごとの (block の要素数, block の byte 数)。llama.cpp の ggml-common.h と同じ
TYPE = {
    0: ("F32", 1, 4), 1: ("F16", 1, 2), 2: ("Q4_0", 32, 18), 3: ("Q4_1", 32, 20),
    6: ("Q5_0", 32, 22), 7: ("Q5_1", 32, 24), 8: ("Q8_0", 32, 34), 9: ("Q8_1", 32, 40),
    10: ("Q2_K", 256, 84), 11: ("Q3_K", 256, 110), 12: ("Q4_K", 256, 144),
    13: ("Q5_K", 256, 176), 14: ("Q6_K", 256, 210), 15: ("Q8_K", 256, 292),
    30: ("BF16", 1, 2),
}

_V = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


class Store(object):
    def __init__(self, path):
        if os.path.isdir(path):
            got = [f for f in sorted(os.listdir(path)) if f.endswith(".gguf")]
            if not got:
                raise IOError("gguf がありません: %s" % path)
            path = os.path.join(path, got[0])
        self.path = path
        with open(path, "rb") as f:
            self._head(f)

    # -- 目録 --
    def _read(self, f, fmt):
        n = struct.calcsize("<" + fmt)
        return struct.unpack("<" + fmt, f.read(n))

    def _str(self, f):
        (n,) = self._read(f, "Q")
        return f.read(n).decode("utf-8", "replace")

    def _val(self, f, t):
        if t == 8:
            return self._str(f)
        if t == 9:                                  # 並び
            (et,) = self._read(f, "I")
            (n,) = self._read(f, "Q")
            if et == 8:
                return [self._str(f) for _ in range(n)]
            c = _V[et]
            return list(struct.unpack("<%d%s" % (n, c), f.read(n * struct.calcsize("<" + c))))
        return self._read(f, _V[t])[0]

    def _head(self, f):
        if f.read(4) != MAGIC:
            raise IOError("GGUF ではありません: %s" % self.path)
        self.version, self.ntensor, self.nmeta = self._read(f, "IQQ")
        self.meta = {}
        for _ in range(self.nmeta):
            k = self._str(f)
            (t,) = self._read(f, "I")
            self.meta[k] = self._val(f, t)
        self.tensors = {}
        for _ in range(self.ntensor):
            name = self._str(f)
            (nd,) = self._read(f, "I")
            dims = self._read(f, "%dQ" % nd)
            (kind,) = self._read(f, "I")
            (off,) = self._read(f, "Q")
            self.tensors[name] = (tuple(dims), kind, off)
        align = int(self.meta.get("general.alignment", 32))
        pos = f.tell()
        self.base = pos + (-pos % align)

    # -- 形と byte --
    def shape(self, name):
        return self.tensors[name][0]

    def kind(self, name):
        return TYPE.get(self.tensors[name][1], ("?", 1, 1))[0]

    def count(self, name):
        n = 1
        for v in self.shape(name):
            n *= v
        return n

    def bytes_of(self, name):
        _, kind, _ = self.tensors[name]
        per, size = TYPE[kind][1], TYPE[kind][2]
        return self.count(name) // per * size

    def blocks(self):
        """段ごとのテンソル名。`blk.<番号>.` の接頭で割る。"""
        out = {}
        for name in self.tensors:
            if name.startswith("blk."):
                r = int(name.split(".")[1])
                out.setdefault(r, []).append(name)
        return out

    # -- 入るかどうか --
    def fit(self, d=1, k=8, vram=16 * (1 << 30)):
        """一語に詰めたときの byte 数。段ごとのピークと全部載せたときを両方出す。"""
        from . import fold
        b, n = fold.width(k, d)
        per = 64.0 / n                                  # 係数あたりの bit
        total = sum(self.count(t) for t in self.tensors)
        blk = self.blocks()
        peak = max((sum(self.count(t) for t in ts) for ts in blk.values()), default=0)
        other = total - sum(sum(self.count(t) for t in ts) for ts in blk.values())
        return {
            "係数の数": total,
            "段の数": len(blk),
            "bit/係数": per,
            "全部の GB": total * per / 8 / 1e9,
            "段のピーク GB": (peak + other) * per / 8 / 1e9,
            "VRAM に全部入る": total * per / 8 <= vram,
            "VRAM に段ごとなら入る": (peak + other) * per / 8 <= vram,
            "元の GGUF GB": sum(self.bytes_of(t) for t in self.tensors) / 1e9,
        }


def report(path, ds=(0, 1, 2, 3), k=8):
    s = Store(path)
    print("%s" % os.path.basename(s.path))
    print("  arch %s  テンソル %d  段 %d" % (s.meta.get("general.architecture"), s.ntensor, len(s.blocks())))
    print("  %-3s %-9s %-11s %-13s %-9s %-9s" % ("d", "bit/係数", "全部 GB", "段のピーク GB", "全部入る", "段なら入る"))
    for d in ds:
        r = s.fit(d, k)
        print("  %-3d %-9.1f %-11.1f %-13.2f %-9s %-9s"
              % (d, r["bit/係数"], r["全部の GB"], r["段のピーク GB"],
                 "入る" if r["VRAM に全部入る"] else "入らない",
                 "入る" if r["VRAM に段ごとなら入る"] else "入らない"))
    print("  元の GGUF %.1f GB" % s.fit(1, k)["元の GGUF GB"])
    return s


if __name__ == "__main__":
    import sys
    report(sys.argv[1] if len(sys.argv) > 1 else
           os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        *([os.pardir] * 4)) + "/data/Qwen3.8-27b-Q6")


# ---- Q6_K を dequantize せずに取り出す -----------------------------------
#
# 1 ブロックは 256 個の値を 210 byte で持つ（llama.cpp の `block_q6_K`）。
#
#     ql[128]  下位 4 bit      qh[64]  上位 2 bit
#     sc[16]   16 個ごとの int8 のスケール      d  ブロック全体の fp16
#
# 値は  d · sc[i//16] · q[i]  で、q は 6 bit の符号つき整数（−32〜31）になる。
# **dequantize しない。** 内積を
#
#     Σ_k W_k x_k = Σ_b d_b Σ_{g<16} sc_{b,g} Σ_{i∈g} q_{b,i} x_{k(b,g,i)}
#
# と三段に割ると、内側の 16 項は整数のままで厳密に足せる。外側だけがスケール付きの
# 内積になる。だから Common の側は整数の内積を二回やるだけで済む。

QK_K = 256
Q6_BYTES = 210


def q6_parts(raw):
    """Q6_K の byte 列から (q, sc, d) を取り出す。q は (ブロック数, 256) の int8。

    並べ替えは llama.cpp の `dequantize_row_q6_K` と同じ順にする。値の計算はしない。
    """
    import numpy as np
    b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, Q6_BYTES)
    n = b.shape[0]
    ql = b[:, :128]
    qh = b[:, 128:192]
    sc = b[:, 192:208].view(np.int8)
    d = b[:, 208:210].copy().view(np.float16).reshape(n)
    q = np.zeros((n, QK_K), dtype=np.int8)
    for half in (0, 1):                       # 128 個ずつ二回
        lo = ql[:, half * 64:(half + 1) * 64]
        hi = qh[:, half * 32:(half + 1) * 32]
        base = half * 128
        for l in range(32):
            a = lo[:, l].astype(np.int16)
            c = lo[:, l + 32].astype(np.int16)
            h = hi[:, l].astype(np.int16)
            q[:, base + l + 0] = ((a & 0xF) | (((h >> 0) & 3) << 4)) - 32
            q[:, base + l + 32] = ((c & 0xF) | (((h >> 2) & 3) << 4)) - 32
            q[:, base + l + 64] = ((a >> 4) | (((h >> 4) & 3) << 4)) - 32
            q[:, base + l + 96] = ((c >> 4) | (((h >> 6) & 3) << 4)) - 32
    return q, sc, d


def q6_value(q, sc, d):
    """取り出した三つから元の値へ戻す。**突き合わせにしか使わない。**"""
    import numpy as np
    g = np.repeat(sc.astype(np.float32), 16, axis=1)
    return (d.astype(np.float32).reshape(-1, 1) * g * q.astype(np.float32))
