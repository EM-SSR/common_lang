# -*- coding: utf-8 -*-
"""lane-qbit の image を走らせる。

doc: casm.lane64.isa

Counter 完全状態の作図（ゲート、重み、測定の境界、移送、リセット）は、commonc の lane-qbit 版
（commonc/src/qstate.cam）が compile 時に済ませる。image に残るのは、測定座標 u0 と境界の表の比較だけになる。

    測定・リセット   x = [θ_BI ≤ U0]、BI ← 2·BI + x       （u0 = U0 / 2^62。θ は image が作業領域へ置く表）
    θ = −1          compile 時に届かないと分かった枝（重み 0 の領域）。来たら失敗を報告する

一回の実行（shot）の結果は U0 だけで決まる（論文 3.6）。

命令（lane64 の op 0〜12 に足したもの）

    13 QG  ゲート。imm = ゲートの番号、b、c = 量子ビット。記録だけ
    14 QM  測定。a = 結果、b = 量子ビット、c = 境界の表の番地
    15 QR  リセット。b = 量子ビット、c = 境界の表の番地
    16 QT  移送。b = 量子ビット、c = 結果 x。記録だけ（写像の更新は compile 時）
    19 QV  状態の保存。b = 種類。枝の番号 BI を記録する（状態そのものは compile 時に書き出してある）
    20 QJ  メビウス作用 u → f u/(1 − u + f u)（論文 16.5）。記録だけ（写像の更新は compile 時）
    21 QB  β。記録だけ
    22 QE  次の移送の割合 ε。記録だけ
    23 QL  古典ビットを読む。R[a] = cl[R[b]]
    25 QD  古典ビットへ書く。cl[R[c]] = R[b]。構成語には ('C', 古典ビット, 値) を残す
    26 QY  delay。記録だけ
"""

from fractions import Fraction

try:
    from . import vcpu
except ImportError:
    import vcpu

DEPTH = 62                     # u0 の桁数。境界の表は ⌈T·2^62⌉ を持つ
GATES = ('h', 'x', 'y', 'z', 's', 'sdg', 't', 'tdg', 'sx', 'cx', 'cz', 'swap')
GATE_ID = dict((g, i) for i, g in enumerate(GATES))
DELAY_UNITS = ('dt', 's', 'ms', 'us', 'ns', 'ps')
QG, QM, QR, QT, QV, QJ, QB, QE, QL, QD, QY = 13, 14, 15, 16, 19, 20, 21, 22, 23, 25, 26
NAME = vcpu.NAME + ('QG', 'QM', 'QR', 'QT', '?', '?', 'QV', 'QJ', 'QB', 'QE', 'QL', '?', 'QD', 'QY')
RECORD = {QG: "G", QT: "T", QJ: "F", QB: "B", QE: "E", QY: "D"}


class Unreachable(Exception):
    """compile 時に届かないと決めた枝（θ = −1）に来た。重み 0 の領域へ移送した回路で起きる。"""


def disasm(prog):
    return ['%5d  %-4s a=%-3d b=%-3d c=%-3d sb=%-2d sc=%-2d imm=%d'
            % (i, NAME[op] if op < len(NAME) else '?', a, b, c, sb, sc, im)
            for i, (op, a, b, c, sb, sc, im) in enumerate(prog)]


def u0_word(u0):
    """u0 ∈ [0, 1) を U0 = u0·2^62 の整数にする。62 桁で尽きる二進有理数だけを受ける。"""
    u0 = Fraction(u0)
    U = u0 * (1 << DEPTH)
    if U.denominator != 1 or not 0 <= U < (1 << DEPTH):
        raise ValueError('u0 は 62 桁の二進有理数で [0, 1) に置く: %s' % u0)
    return int(U)


class Shot(object):
    """一回の実行。R は landmark、M は作業領域、cl は古典ビット、BI は枝の番号、h は構成語。"""

    def __init__(self, U0):
        self.U0, self.BI = U0, 0
        self.R, self.M, self.cl = [0] * 256, {}, {}
        self.out, self.h = [], []

    def split(self, table):
        """境界の表で領域を分け、枝を一段進める。"""
        th = self.M.get(table + self.BI, -1)
        if th < 0:
            raise Unreachable('枝 %d は compile 時に届かないと決まっている' % self.BI)
        x = 1 if th <= self.U0 else 0
        self.BI = 2 * self.BI + x
        return x


def run_shot(prog, U0, budget=1 << 28, shot=None):
    """image を一回走らせる。返りは (報告, Put の byte 列, 構成語 h, 古典ビット)。報告は 'ok'、'ko'、'end'。"""
    s = shot or Shot(U0)
    R, M = s.R, s.M
    pc, n = 0, len(prog)
    while pc < n:
        budget -= 1
        if budget < 0:
            raise RuntimeError('命令の上限に達した')
        op, a, b, c, sb, sc, im = prog[pc]
        pc += 1
        if op == 1:
            R[a] = im
        elif op == 2:
            R[a] = (R[b] << sb) + (R[c] << sc)
        elif op == 3:
            R[a] = R[b] * R[c]
        elif op == 4:
            R[a] = -R[b]
        elif op == 5:
            if (R[b] << sb) == (R[c] << sc):
                pc += im - 1
        elif op == 6:
            if (R[b] << sb) < (R[c] << sc):
                pc += im - 1
        elif op == 7:
            pc += im - 1
        elif op == 8:
            R[a] = M.get(R[b], 0)
        elif op == 9:
            M[R[b]] = R[c]
        elif op == 10:
            return 'ok', s.out, s.h, s.cl
        elif op == 11:
            return 'ko', s.out, s.h, s.cl
        elif op == 12:
            s.out.append(R[b] & 255)
        elif op == QM:
            q = R[b]
            x = s.split(R[c])
            R[a] = x
            s.h.append(('M', q, x))
        elif op == QR:
            s.h.append(('R', R[b], s.split(R[c])))
        elif op == QV:
            s.h.append(('V', R[b], s.BI))
        elif op == QL:
            R[a] = s.cl.get(R[b], 0)
        elif op == QD:
            s.cl[R[c]] = R[b]
            s.h.append(('C', R[c], R[b]))
        elif op in RECORD:
            s.h.append((RECORD[op], im, R[b], R[c]))
        elif op == 0:
            break
        else:
            raise NotImplementedError('lane-qbit に作図の無い命令: %s' % (NAME[op] if op < len(NAME) else op))
    return 'end', s.out, s.h, s.cl


class Observed(Shot):
    """観測された結果の列に沿って走らせ、u0 が入る領域 [lo, hi)（U0 の整数）を出す。

    測定とリセットの結果は観測から取り、境界 θ で領域を削る（論文 3.16。結果 1 なら lo ← max(lo, θ)、
    0 なら hi ← min(hi, θ)）。届かない枝（θ = −1）に入るか、領域が空になれば、その候補は観測と合わない。
    """

    def __init__(self, results):
        super().__init__(0)
        self.results, self.lo, self.hi = list(results), 0, 1 << DEPTH

    def split(self, table):
        th = self.M.get(table + self.BI, -1)
        if th < 0 or not self.results:
            raise Unreachable('観測と合わない枝 %d' % self.BI)
        x = self.results.pop(0)
        if x:
            self.lo = max(self.lo, th)
        else:
            self.hi = min(self.hi, th)
        self.BI = 2 * self.BI + x
        return x


def region(image, results):
    """観測された結果の列（測定とリセットの順）と合う u0 の領域 (lo, hi)。空なら None。"""
    obs = Observed(results)
    try:
        run_shot(vcpu.decode(image), 0, shot=obs)
    except Unreachable:
        return None
    return (obs.lo, obs.hi) if obs.lo < obs.hi else None


def regions(image, results):
    """観測されない結果（None。実機はリセットの内側の結果を返さない）を両方の側でたどった、u0 の領域の合併。
    返りは互いに素な区間 (lo, hi) の昇順の並び。空の並びなら、どの u0 とも合わない。"""
    if None not in results:
        found = region(image, results)
        return [found] if found else []
    k = results.index(None)
    out = []
    for v in (0, 1):
        out += regions(image, results[:k] + [v] + results[k + 1:])
    return _merge(sorted(out))


def _merge(intervals):
    out = []
    for lo, hi in intervals:
        if out and lo <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def run(image, u0s):
    """u0 の並びごとに一回ずつ走らせる。返りは run_shot の返りの並び。"""
    prog = vcpu.decode(image)
    return [run_shot(prog, u0_word(u)) for u in u0s]
