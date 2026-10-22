# -*- coding: utf-8 -*-
"""intent の語を音節へ開き、commonc へ渡して lane64 で走らせる。

道は一本だけになる（`.dic` を使わない）。

    intent/*.cmn ──splice──▶ 音節の平文 ──commonc_lane64.bin on vcpu──▶ image ──▶ gvcpu

`splice` は 16 式 1.6 そのもので、語が引く合成チェンバーを、書かれた層の位置へ
割り込ませる。ここでは層が一本なので、本体の文をその場へ置く操作になる。

`Joint` は一閉包の launcher。段・行・列・語が全部一つの Ω に入るので、Python 側に
`for` が出ない。合図は共有メモリへの書き込みそのもので、書いた直後に grid 全体で足並みを
揃える。全 block が同時に載っている必要があるため、lane の上限はGPU の resident thread 数
になる（RTX 5060 Ti は 36 SM × 2048 = 73 728）。
"""
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))

from common_vcpu import toolchain, vcpu   # noqa: E402

INTENT = os.path.join(HERE, "intent")

# compile の出力先。install 先が書けないことがあるので、既定は利用者のキャッシュに置く。
# `PYTORCH_CMN_BUILD` で移せる。
BUILD = os.environ.get("PYTORCH_CMN_BUILD") or os.path.join(
    os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.cache"), "pytorch_cmn", "build")

# 68 の音節。これ以外の綴りは語の名前として splice で開く
SYLLABLE = set("""
ka ki ku ke ko sa si su se so ta ti tu te to na ni nu ne no
ha hi hu he ho ma mi mu me mo ya yi yu ye yo ra ri ru re ro
wa wi wu we wo ga gi gu ge go za zi zu ze zo da di du de do ba bi bu
kukeke kukeko kukesa kukesi kukesu kukese kukeso kuketa kuketi
""".split())

_LEX = {}


def lexicon():
    """intent の各ファイルを一語として読む。注記（I→I の文）は本体から外す。"""
    if _LEX:
        return _LEX
    for fn in sorted(os.listdir(INTENT)):
        if not fn.endswith(".cmn"):
            continue
        # 注記は先頭の一文だけ。値を立てて `ho` で閉じるので I→I になり、境界を変えない
        lines = [l.strip() for l in open(os.path.join(INTENT, fn), encoding="utf-8") if l.strip()]
        if lines and lines[0].endswith("ho ka"):
            lines = lines[1:]
        _LEX[fn[:-4]] = " ".join(lines)
    return _LEX


def splice(text):
    """語の名前を本体へ開く（16 式 1.6）。音節はそのまま通す。"""
    lex = lexicon()
    out = []
    for line in text.splitlines():
        got = []
        for tok in line.replace(",", " , ").split():
            if tok in (",", "ka") or tok in SYLLABLE:
                got.append(tok)
            elif tok in lex:
                got.append(lex[tok])
            else:
                raise KeyError("intent に無い語: %s" % tok)
        out.append(" ".join(got).replace(" ,", ","))
    return "\n".join(out) + "\n"


def build(text, name="graph"):
    """平文を image へ。返りは (image, n_need, 音節の平文)。"""
    if not os.path.isdir(BUILD):
        os.makedirs(BUILD)
    src = os.path.join(BUILD, name + ".cmn")
    plain = splice(text)
    open(src, "w", encoding="utf-8", newline="\n").write(plain)
    image, need = toolchain.compile([src], None, os.path.join(BUILD, name + ".bin"))
    return image, need, plain


def walk(image, need, seed=None, words=1 << 17, watch=()):
    """一枚だけ歩かせる。演算の意味を確かめるときに使う。"""
    lane = vcpu.Lane(words)
    for k, v in (seed or {}).items():
        lane.M[k] = int(v)
    rep = vcpu.run_lane(toolchain.load(image, need), lane)
    return rep, lane.blocks, [int(lane.M[i]) for i in watch]


# ---- 一閉包の launcher ---------------------------------------------------

def resident(dev=0):
    """GPU に同時に載る thread の数。lane の上限はこれになる。"""
    import cupy as cp
    p = cp.cuda.Device(dev).attributes
    return p["MultiProcessorCount"] * p["MaxThreadsPerMultiProcessor"]


# 使い回す置き場。形が同じ層は同じ確保を使う。鍵ごとに一番大きい要求で取り、以後は
# その一部を渡す。`ARENA` を空にすると次の確保で取り直す。
ARENA = {}


def _arena(cp, tag, n):
    """`tag` の置き場を使い回す。足りなければ取り直して大きい方を残す。"""
    got = ARENA.get(tag)
    if got is None or got.size < n:
        ARENA[tag] = cp.zeros((int(n),), dtype=cp.uint64)
        return ARENA[tag][:n]
    got[:n] = 0
    return got[:n]


def free_arena():
    """使い回している置き場を放す。"""
    ARENA.clear()


class Joint(object):
    """共有メモリへ書ける道（`lane64_runb`）。段をまたぐ受け渡しが接合点になる。

    共有メモリへの Store が合図で、書いた直後に grid 全体が揃う。平文の側は「全 lane が
    段ごとに同じ回数だけ書く」形でなければならない。
    """

    def __init__(self, prog, need, work, romlo, romn, nlanes, base=None, threads=128):
        import cupy as cp
        from common_vcpu import gvcpu
        self.cp, self.g = cp, gvcpu
        cap = resident()
        if nlanes > cap:
            raise ValueError("lane がGPU に載らない（%d > %d）" % (nlanes, cap))
        self.threads = threads
        self.nblocks = (nlanes + threads - 1) // threads
        self.n = self.nblocks * threads          # 休む thread を作らない
        self.need, self.work, self.romlo = need, work, romlo
        mod = gvcpu._module(cp, 1)
        self.k_run = mod.get_function("lane64_runb")
        self.k_gather = mod.get_function("gather_s")
        prog = gvcpu.fold(prog, wires=(64, need))
        prog, self.need = gvcpu.compact(prog, (64, need), work=work)
        self.words = self.need + (romlo - work)
        self.nprog = len(prog)
        self.d_prog = cp.asarray(np.array([list(p) for p in prog], dtype=np.int64).reshape(-1))
        # **確保は 1 回。** 層ごとに取って放すと、Qwen 27B の 1 層で 3.16 GB の確保と解放が
        # 層を渡るたびに起きる。形が同じ層なら同じ置き場を使い回し、中身だけ差し替える。
        self.d_rom = _arena(cp, "rom", max(1, romn))
        self.romn = romn
        row = np.zeros((self.words,), dtype=np.uint64)
        for a, v in (base or {}).items():
            row[self.pos(a)] = int(v)
        self.d_row = cp.asarray(row)
        self.M = _arena(cp, "work", self.words * self.n)
        self._rep = self._steps = self._cnt = self._gen = None
        self._d_w = self._got = None
        self._watch_key = None
        self.reset()

    def pos(self, a):
        return a if a < self.need else a - self.work + self.need

    @property
    def M2(self):
        return self.M.reshape(self.words, self.n)

    def reset(self):
        self.M2[:, :] = self.d_row.reshape(-1, 1)

    def rom_put(self, off, vals):
        self.d_rom[off:off + len(vals)] = self.cp.asarray(np.asarray(vals, dtype=np.uint64))

    def _scratch(self):
        """走りごとの小さい並びを一度だけ取って使い回す。

        呼ぶたびに `cp.zeros` を四本取ると、走り一回につき確保と解放が四回付く。
        `influence` のように何十回も呼ぶ形では、この確保が走りそのものより重くなる。
        """
        cp = self.cp
        if self._rep is None:
            self._rep = cp.zeros((self.n,), dtype=cp.int32)
            self._steps = cp.zeros((self.n,), dtype=cp.int64)
            self._cnt = cp.zeros((1,), dtype=cp.int32)
            self._gen = cp.zeros((1,), dtype=cp.int32)
        else:
            self._rep.fill(0)
            self._steps.fill(0)
            self._cnt.fill(0)
            self._gen.fill(0)
        return self._rep, self._steps, self._cnt, self._gen

    def run(self, watch=(), budget=1 << 36):
        cp = self.cp
        rep, steps, cnt, gen = self._scratch()
        self.k_run((self.nblocks,), (self.threads,),
                   (self.d_prog, np.int32(self.nprog), self.M, np.int32(self.words),
                    np.int32(self.n), np.int64(budget), np.int32(self.need), np.int32(self.work),
                    rep, steps, self.d_rom, np.int64(self.romlo), np.int64(self.romn),
                    cnt, gen, np.int32(self.nblocks)),
                   shared_mem=self.threads * self.g.NREG_BYTES)
        W = None
        if watch:
            key = tuple(watch)
            if self._watch_key != key:
                self._watch_key = key
                self._d_w = cp.asarray(np.array([self.pos(w) for w in watch], dtype=np.int32))
                self._got = cp.zeros((self.n * len(watch),), dtype=cp.uint64)
            self.k_gather((self.nblocks,), (self.threads,),
                          (self.M, np.int32(self.n), np.int32(self.n), self._d_w,
                           np.int32(len(watch)), self._got))
            W = self._got.reshape(self.n, len(watch)).astype(cp.int64)
        return rep.get(), steps.get(), W

    def close(self):
        """この板の参照を捨てる。使い回している置き場そのものは放さない。

        `ARENA` は層をまたいで使うので、ここで消さない。全部放すなら `free_arena()`。
        """
        for k in ("M", "d_rom", "d_prog", "d_row", "_rep", "_steps",
                  "_cnt", "_gen", "_d_w", "_got"):
            setattr(self, k, None)


# ---- 箱と箱の往復を消す -------------------------------------------------
#
# 箱は値をワイヤの語へ書き、次の箱がそれを読み直す（19 §3.3）。CPU の道は
# `vcpu.translate` が block の中で値番号を付けて往復を消すが、GPU は折った命令列を
# そのまま歩くので往復が残る。直線の区間に同じ値番号付けを当てる。
#
# 消えるのは「同じ block の中で、書いた語を読み直す」対だけになる。block の境界
# （飛び先と飛びの後）で表を捨てるので、閉包をまたぐ受け渡しは残る。

_JUMPS = (5, 6, 7)


def _targets(prog):
    """ブロックの入口。ここで値の表を捨てる。

    インタプリタと同じ切り方にする。`vcpu.entries` は分岐の行き先と次の行に加えて、
    `OK` `KO` `HALT` の直後も入口にする。分岐だけを見ていると、入口をまたいで
    レジスタの別名を残してしまい、値が壊れる（2026-09-28 にこれで壊れた）。
    """
    return set(vcpu.entries([list(p) for p in prog]))



def _tighten_jumps(prog, keep):
    """落とした後の行へ飛び先を直す。落とす pass は必ずこれを通す。

    飛びが残る平文（閉包）で、この詰め直しを忘れると飛び先がずれる。直線の平文だけ
    試していると出ない穴なので、落とす pass は全部ここを経由させる。
    """
    where = {}
    for new, old in enumerate(keep):
        where[old] = new
    n = len(prog)
    nxt = {}
    run = len(keep)
    for old in range(n, -1, -1):
        nxt[old] = where.get(old, run)
        if old in where:
            run = where[old]
    out = []
    for old in keep:
        ins = list(prog[old])
        if ins[0] in _JUMPS:
            tgt = old + int(ins[6])
            ins[6] = nxt.get(max(0, min(tgt, n)), len(keep)) - where[old]
        out.append(ins)
    return out



def _live(prog, cut):
    """ブロックごとに、レジスタが定義される行と読まれる行を集める。

    LOAD を消してよいかの判定に使う。消すと、その register には**読んだ値ではなく
    アドレスが残ったまま**になる。だから別名の元が書き換わる前に、消した先の
    register を読み終えていなければならない。
    """
    n = len(prog)
    edge = sorted(set([0, n]) | set(x for x in cut if 0 < x < n))
    span = {}
    for k in range(len(edge) - 1):
        lo, hi = edge[k], edge[k + 1]
        defs, uses = {}, {}
        for i in range(lo, hi):
            op = prog[i][0]
            for f in _USE.get(op, ()):
                uses.setdefault(int(prog[i][f]), []).append(i)
            if op in _DEF:
                defs.setdefault(int(prog[i][1]), []).append(i)
        for i in range(lo, hi):
            span[i] = (lo, hi, defs, uses)
    return span


def _can_drop(span, ext, i, dst, src):
    """行 i の LOAD（先 dst、代わり src）を消してよいか。

    消すと dst には**読んだ値ではなくアドレス**が残る。以後 dst を読むところは src へ
    書き換わるので、src はそこまで同じ値を持っていなければならない。

    さらに、後の置き換えで dst 自身が別名の元になると、dst の生存が元の並びから
    数えた範囲より伸びる。伸びた分を `ext` に持ち回って足すと、1 回の走査で正しく判定
    できる（2026-09-28 にここを取り違えて、アドレスがそのまま値として読まれた）。
    """
    if i not in span:
        return False, None
    lo, hi, defs, uses = span[i]
    nd_dst = next((j for j in defs.get(dst, ()) if j > i), hi)
    # `NEG a=1, b=1` のように**同じ register を読んで書く**命令があるので、
    # 書き換える行そのものも読みとして数える（`< nd_dst` にすると取りこぼす）。
    later = [j for j in uses.get(dst, ()) if i < j <= nd_dst]
    need = max(later + [ext.get(dst, -1)]) if (later or dst in ext) else i
    nd_src = next((j for j in defs.get(src, ()) if j > i), hi)
    # 読みと書きが同じ行なら、読みが先なので古い値が見える。だから等しくても構わない。
    return (nd_src >= need), need


def forward(prog, limit=None):
    """直線の区間で、語へ書いた値を読み直す対を潰す。命令の並びを返す。"""
    prog = [list(p) for p in prog]
    cut = _targets(prog)
    span = _live(prog, cut)
    ext = {}        # register -> その値を保ち続けなければならない最後の行
    _cnt = [0]      # 置き換えた回数。limit で切って不具合の場所を挟むために数える
    imm = {}        # register -> 即値（番地として使えるもの）
    cell = {}       # 語 -> その値を持つ register
    same = {}       # register -> 同じ値を持つ別の register
    keep = []
    for i, ins in enumerate(prog):
        if i in cut:
            imm, cell, same = {}, {}, {}
        op, a, b, c = ins[0], int(ins[1]), int(ins[2]), int(ins[3])
        b2, c2 = same.get(b, b), same.get(c, c)
        _drop, _need = (False, None)
        if op == 8 and b2 in imm and imm[b2] in cell and (limit is None or _cnt[0] < limit):
            _drop, _need = _can_drop(span, ext, i, a, cell[imm[b2]])
        if _drop:                                            # LOAD。同じワードを読み直さない
            _cnt[0] += 1
            src = cell[imm[b2]]
            if src != a:
                same[a] = same.get(src, src)
                ext[src] = max(ext.get(src, -1), _need)
            imm.pop(a, None)
            _kill(a, imm, cell, same, keep=True)
            continue
        ins[2], ins[3] = b2, c2
        if op == 8 and b2 in imm:                            # 読んだ値はその register に在る
            w = imm[b2]
            _kill(a, imm, cell, same)
            cell[w] = a
            keep.append(i)
            continue
        if op == 1:                                          # SET
            _kill(a, imm, cell, same)
            imm[a] = int(ins[6])
        elif op == 9:                                        # STORE
            if b2 in imm:
                cell[imm[b2]] = c2
            else:
                cell.clear()
        elif op in _JUMPS:
            pass
        elif op in (0, 10, 11, 12):
            pass
        else:                                                # 値を作る箱
            _kill(a, imm, cell, same)
        keep.append(i)
    return _tighten_jumps(prog, keep)


def _kill(a, imm, cell, same, keep=False):
    """register a を書き換えるので、a を指していた別名と語の対応を捨てる。"""
    if not keep:
        imm.pop(a, None)
        same.pop(a, None)
    for k in [k for k, v in cell.items() if v == a]:
        del cell[k]
    for k in [k for k, v in same.items() if v == a]:
        del same[k]


def constfold(prog):
    """定数どうしの算術を即値へ畳む。

    番地は `unit` と `rung`（複製＋加算）の ladder で綴るので、literal 一つが ADD 数本に
    なる。`gvcpu.fold` も `forward` も算術は畳まないため、実行時に毎回その加算を歩く。
    engine5 の一段 347 命令のうち、アドレス取得が 288 命令だった（2026-09-28 に測った）。

    命令は (op, a, b, c, sb, sc, imm) で

        MAT  R[a] = imm
        ADD  R[a] = (R[b] << sb) + (R[c] << sc)
        MUL  R[a] = R[b] · R[c]
        NEG  R[a] = −R[b]

    畳んだ後は元の MAT が読まれなくなるので、`prune` が落とす。
    即値の欄は 8 byte の符号つきなので、収まらない値は畳まない。
    """
    LIM = 1 << 62
    prog = [list(p) for p in prog]
    cut = _targets(prog)
    const = {}
    for i, ins in enumerate(prog):
        if i in cut:
            const = {}
        op, a, b, c = ins[0], int(ins[1]), int(ins[2]), int(ins[3])
        v = None
        if op == 1:                                   # MAT。即値
            const[a] = int(ins[6])
            continue
        if op == 2 and b in const and c in const:     # ADD
            v = (const[b] << int(ins[4])) + (const[c] << int(ins[5]))
        elif op == 3 and b in const and c in const:   # MUL
            v = const[b] * const[c]
        elif op == 4 and b in const:                  # NEG
            v = -const[b]
        if v is not None and -LIM < v < LIM:
            prog[i] = [1, a, 0, 0, 0, 0, v]
            const[a] = v
            continue
        if op in _DEF:
            const.pop(a, None)
    return prog


def prune(prog):
    """読まれない register への書き込みを落とす。飛びがあるので直線の区間ごとに見る。"""
    prog = [list(p) for p in prog]
    cut = _targets(prog)
    dead = set()
    live = set(range(8))            # block の終わりでは全部生きているとみなす
    for i in range(len(prog) - 1, -1, -1):
        ins = prog[i]
        op, a, b, c = ins[0], int(ins[1]), int(ins[2]), int(ins[3])
        if i + 1 in cut or op in _JUMPS:
            live = set(range(8))
        if op in (1, 2, 3, 4, 8) and a not in live:
            dead.add(i)
            continue
        if op in (1, 2, 3, 4, 8):
            live.discard(a)
        if op in (2, 3, 5, 6):
            live.add(b); live.add(c)
        elif op in (4, 8):
            live.add(b)
        elif op == 9:
            live.add(b); live.add(c)
    if not dead:
        return prog
    return _tighten_jumps(prog, [i for i in range(len(prog)) if i not in dead])


def tighten(prog, need):
    """定数畳み・往復消し・枝落としを、変わらなくなるまで当てる。"""
    from common_vcpu import gvcpu
    last = None
    while len(prog) != last:
        last = len(prog)
        prog = gvcpu.fold(prune(sweep(forward(constfold(prog)), need)),
                          wires=(64, need))
    return prog


# register は 8 本ある（gvcpu の NREG）。commonc は 1 2 3 だけを回すので、次の箱が
# 前の箱の register を潰し、そのために語への往復が残る。生きている値を潰さないように
# 付け替えると、`forward` がその往復を消せる。定理 13.1 の単射な付け替えなので意味は同じ。

NREG = 8
_DEF = (1, 2, 3, 4, 8)                      # 値を作る op
_USE = {2: (2, 3), 3: (2, 3), 4: (2,), 5: (2, 3), 6: (2, 3), 8: (2,), 9: (2, 3)}


def rename(prog):
    """直線の区間で、値ごとに番号を振り、線形走査で register を配り直す。

    commonc は register 1 2 3 だけを回すので、次の箱が前の箱の値を潰す。潰さない
    配り方にすると `forward` が語への往復を消せる。同時に生きている値には別の
    register が当たる（式 13.2）ので、意味は変わらない（定理 13.1）。
    """
    prog = [list(p) for p in prog]
    cut = _targets(prog)
    ends = []
    for i in range(len(prog)):
        if i in cut and i:
            ends.append(i)
    ends.append(len(prog))
    out = list(prog)
    lo = 0
    for hi in ends:
        _rename_block(out, lo, hi)
        lo = hi
    return out


def _rename_block(prog, lo, hi):
    """値ごとに番号を振り、線形走査で register を配る。

    生存は register の読みだけでは決まらない。箱は値を語へ書き、次の箱がその語を
    読み直すので、**書いた語が読まれるまで**その値は生きている。ここを数えないと
    register がすぐ再利用され、`forward` が往復を消せない。
    """
    hold, imm, cellv = {}, {}, {}
    reads, defs = {}, []
    nval = 0
    for i in range(lo, hi):
        ins = prog[i]
        op, a, b, c = ins[0], int(ins[1]), int(ins[2]), int(ins[3])
        for f in _USE.get(op, ()):
            v = hold.get(int(ins[f]))
            if v is not None:
                reads[v] = i
        if op == 8 and b in imm and imm[b] in cellv:      # 語を読み直す
            v = cellv[imm[b]]
            reads[v] = max(reads.get(v, i), i)
        if op == 9:                                        # 語へ書く
            if b in imm:
                cellv[imm[b]] = hold.get(c)
            else:
                cellv.clear()
        if op in _DEF:
            nval += 1
            hold[a] = nval
            defs.append((i, a, nval))
            if op == 1:
                imm[a] = int(ins[6])
            else:
                imm.pop(a, None)
    # 配る。読まれ終わるまで register を離さない
    holder = {}
    where = {}
    for i, old, v in defs:
        for r in [r for r, u in holder.items() if reads.get(u, -1) <= i]:
            del holder[r]
        pick = next((r for r in range(1, NREG) if r not in holder), None)
        where[v] = pick if pick is not None else old
        if pick is not None:
            holder[pick] = v
    hold = {}
    at = dict((i, v) for i, r, v in defs)
    for i in range(lo, hi):
        ins = prog[i]
        op = ins[0]
        for f in _USE.get(op, ()):
            v = hold.get(int(ins[f]))
            if v is not None and v in where:
                ins[f] = where[v]
        if i in at:
            v = at[i]
            hold[int(ins[1])] = v
            ins[1] = where[v]


def press(prog, need, check=None):
    """付け替え・往復消し・枝落としを、変わらなくなるまで当てる。

    `check` に (種, 見る語) を渡すと、最適化した前と後を vcpu で一枚ずつ走らせて突き合わせる。
    合わなければ最適化する前の並びを返す。命令を削る仕事は必ずこのゲートを通す。
    """
    from common_vcpu import gvcpu
    out = gvcpu.fold(rename(constfold(prog)), wires=(64, need))
    last = None
    while len(out) != last:
        last = len(out)
        out = gvcpu.fold(prune(forward(rename(constfold(out)))), wires=(64, need))
    if check is not None and _walked(prog, need, check) != _walked(out, need, check):
        return gvcpu.fold(prune(forward(prog)), wires=(64, need))
    return out


def _walked(prog, need, check):
    """一枚だけ歩かせて、見る語の値を返す。最適化の検算に使う。"""
    seed, watch = check
    l = vcpu.Lane(1 << 17)
    for k, v in seed.items():
        l.M[k] = int(v)
    rep = vcpu.run_lane(vcpu.translate(prog, wires=(64, need))[1], l)
    return (rep, [int(l.M[w]) for w in watch])


def sweep(prog, need):
    """読まれないワイヤへの書き込みを落とす。lane ごとの語数がここで決まる。

    `gvcpu.fold` の死んだ Store の判定は記号で追う保守的なもので、往復を消した後に
    残る書き込みを取り切れない。番地が即値で分かる Load を全部数えて、そこに無い
    ワイヤへの Store を落とす。語数が減ると lane を増やせる。

    番地が即値で読めない Load が 1 つでもあれば、**何も落とさない**。`forward` が
    レジスタの別名を作ると、その Load の番地レジスタが即値に見えなくなる。そこを
    「ワイヤを読まない」と決めつけると、生きているワイヤへの Store を落として値が壊れる
    （2026-09-28 に踏んだ。`tighten` の答えが素の並びと違った）。
    """
    prog = [list(p) for p in prog]
    imm, seen = {}, set()
    for ins in prog:
        op, a, b = ins[0], int(ins[1]), int(ins[2])
        if op == 1:
            imm[a] = int(ins[6])
        elif op == 8:
            if b in imm:
                seen.add(imm[b])
            else:
                return prog          # 番地の読めない Load がある。何も落とさない
            imm.pop(a, None)
        elif op in (2, 3, 4):
            imm.pop(a, None)
    imm, keep = {}, []
    for i, ins in enumerate(prog):
        op, a, b = ins[0], int(ins[1]), int(ins[2])
        if op == 9 and b in imm and 64 <= imm[b] < need and imm[b] not in seen:
            continue                              # 誰も読まないワイヤ
        if op == 1:
            imm[a] = int(ins[6])
        elif op in (2, 3, 4, 8):
            imm.pop(a, None)
        keep.append(i)
    return _tighten_jumps(prog, keep)


def best(prog, need, check):
    """最適化と付け替えを当てて、検算が合う中で一番小さい並びを返す。

    `check` は (種, 見る語) で、最適化する前と後を vcpu で一枚ずつ走らせて突き合わせる。
    `press` と `sweep` は仮定を置くので、ゲートを通らない並びは採らない。
    """
    from common_vcpu import gvcpu
    got = gvcpu.fold(prog, wires=(64, need))
    want = _walked(got, need, check)
    cands = [tighten(got, need), press(got, need, check=check)]
    cands += [gvcpu.fold(sweep(c, need), wires=(64, need)) for c in list(cands)]
    for cand in cands:
        if _walked(cand, need, check) == want and len(cand) < len(got):
            got = cand
    return got
