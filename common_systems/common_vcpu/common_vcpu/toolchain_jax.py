# -*- coding: utf-8 -*-
"""image を JAX で走らせ、lane ごとの種を渡す。toolchain.py の run / LaneWorkers に対応する。

    prog = load(image, words, limbs=4, widths=None, mem_limbs=4, mem_wide=None)
    res  = run(prog, seeds)            seeds は lane ごとの {語番号: 値}（python の整数、大きくてよい）
    res.rep[l]  res.word(l, 語番号)

語は int32 の配列を並べた多倍長（limbs_jax.py）で持つ。**並べる本数は引数で決める。**

    limbs       命令の結果の既定の本数（1 本 15 bit）。4 本で 60 bit
    widths      {命令番号: 本数} または 命令番号 → 本数 を返す関数。決めた命令だけ本数を変える
    mem_limbs   作業領域の語の既定の本数
    mem_wide    {本数: [番地, ...]}。大きい値を持つ語の番地の集合ごとに本数を変える
    check       真なら、語の本数に収まらない値の書き込みを報告 43 にする

大きい値を持つ命令や語だけ本数を増やせばよい。命令の結果が本数に収まらないときは検査できないので、
本数を変えたら参照の結果と突き合わせる。

image は繰り返し（後ろ向きの分岐）の入れ子として読む。

    ・繰り返しの間の直列の区間と、一番内側の繰り返しを、それぞれ 1 つの関数として jax.jit する
    ・外側の繰り返しは python で回す
    ・前向きの分岐は、lane ごとの判定で飛び越す命令を選ぶ
    ・繰り返しの終わり方は lane ごとに違ってよい（終わった lane は止まって待つ）

コンパイルの単位が小さいので、image が大きくても、コンパイルのメモリは 1 つの区間分で済む。
"""

import os
import sys

import numpy as np
import jax
import jax.numpy as jnp

HERE = os.path.dirname(os.path.abspath(__file__))
try:                      # パッケージとして使うとき
    from . import limbs_jax as L, vcpu
except ImportError:       # このディレクトリを sys.path に入れて使うとき
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    import limbs_jax as L
    import vcpu

NREG = 10                 # jax_backend.emit と同じ
HALT, MAT, ADD, MUL, NEG, EQ, LT, JMP, LD, ST, OK, KO, PUT = range(13)
WIDE = 43                 # 報告: 語の本数に収まらない値を書いた（gvcpu の R_WIDE と同じ番号）


class Memory(object):
    """作業領域。既定の本数 mem_limbs の配列に、番地の集合ごとに本数の違う配列を添える。

    classes は {本数: [番地, ...]}。ここに挙げた語は、その本数の配列に置く（既定の配列の同じ番地は使わない）。
    大きい値を持つ語が点在していても、読み書きは「既定の配列 + 集合の数」だけの gather で済む。
    """

    def __init__(self, words, mem_limbs, classes):
        self.words, self.K = words, mem_limbs
        self.classes = []                       # (本数, 番地 → 添字 の表 (words,), 語数)
        self.np_tables = []                     # 同じ表の numpy 版（コンパイル時に定数の番地を引く）
        for k, addrs in sorted(classes.items()):
            addrs = sorted(set(int(a) for a in addrs))
            table = np.full((words,), -1, dtype=np.int32)
            table[np.asarray(addrs, dtype=np.int64)] = np.arange(len(addrs), dtype=np.int32)
            self.classes.append((k, jnp.asarray(table), len(addrs)))
            self.np_tables.append(table)
        self.KMAX = max([mem_limbs] + [k for k, _, _ in self.classes])

    def zeros(self, W):
        return [jnp.zeros((W, self.words, self.K), dtype=jnp.int32)] + \
               [jnp.zeros((W, n, k), dtype=jnp.int32) for k, _, n in self.classes]


def _from_array(part, rows, cols):
    return [part[rows, cols, j] for j in range(part.shape[2])]


def _slot(mem, addr):
    """定数の番地 addr がどの配列のどこにあるか。返りは (配列の番号, 配列の中の添字)。"""
    for ci, table in enumerate(mem.np_tables, start=1):
        i = int(table[addr])
        if i >= 0:
            return ci, i
    return 0, addr


def _load_const(M, mem, addr):
    """定数の番地の語を読む。gather を使わず、固定の位置を切り出す。"""
    if not (0 <= addr < mem.words):
        return None
    ci, i = _slot(mem, addr)
    return [M[ci][:, i, j] for j in range(M[ci].shape[2])]


def _store_const(M, mem, addr, val, act):
    """定数の番地へ書く。返りは (新しい作業領域, 本数に収まらなかった lane の印)。"""
    ci, i = _slot(mem, addr)
    k = M[ci].shape[2]
    cut = L.fit(val, k)
    lost = act & ~L.eq(L.fit(cut, len(val)), val)
    old = M[ci][:, i, :]
    new = list(M)
    new[ci] = M[ci].at[:, i, :].set(jnp.where(act[:, None], jnp.stack(cut, axis=1), old))
    return new, lost


def _load(M, mem, addr, row):
    """番地 addr（lane ごと）の語を読む。既定の配列から読み、番地の集合に入っていれば集合の配列で置き換える。"""
    ok = (addr >= 0) & (addr < mem.words)
    at = jnp.clip(addr, 0, mem.words - 1)
    out = [jnp.where(ok, x, 0) for x in _from_array(M[0], row, at)]
    for (k, table, n), part in zip(mem.classes, M[1:]):
        i = table[at]
        inside = ok & (i >= 0)
        v = _from_array(part, row, jnp.clip(i, 0, max(n - 1, 0)))
        K = max(len(v), len(out))
        out = L.where(inside, L.extend(v, K), L.extend(out, K))
    return out


def _store(M, mem, addr, val, act, row):
    """語 addr へ val を書く。返りは (新しい作業領域, 本数に収まらなかった lane の印)。"""
    ok = act & (addr >= 0) & (addr < mem.words)
    at = jnp.clip(addr, 0, mem.words - 1)
    inside_any = jnp.zeros_like(ok)
    new, lost = list(M), jnp.zeros_like(ok)
    for ci, ((k, table, n), part) in enumerate(zip(mem.classes, M[1:]), start=1):
        i = table[at]
        inside = ok & (i >= 0)
        inside_any = inside_any | inside
        j = jnp.clip(i, 0, max(n - 1, 0))
        cut = L.fit(val, k)
        lost = lost | (inside & ~L.eq(L.fit(cut, len(val)), val))
        old = part[row, j, :]
        new[ci] = part.at[row, j, :].set(jnp.where(inside[:, None], jnp.stack(cut, axis=1), old))
    main = ok & ~inside_any
    cut = L.fit(val, mem.K)
    lost = lost | (main & ~L.eq(L.fit(cut, len(val)), val))
    old = M[0][row, at, :]
    new[0] = M[0].at[row, at, :].set(jnp.where(main[:, None], jnp.stack(cut, axis=1), old))
    return new, lost


# ===== 命令の区間 =====

def _exec(prog, lo, hi, widths, mem, KR, check, R, M, rep, act0):
    """命令 [lo, hi) を、有効な lane（act0）だけで実行する。前向きの分岐は lane ごとに飛び越す。"""
    W = R.shape[0]
    row = jnp.arange(W)
    reg = {}                                              # この区間で書いた値 {番号: limbs}

    def get(r):
        if r not in reg:
            reg[r] = [R[:, r, k] for k in range(KR)]
        return reg[r]

    def put(r, val, act):
        old = get(r)
        K = max(len(val), len(old))
        reg[r] = L.where(act, L.extend(val, K), L.extend(old, K))

    act, wait = act0, {}
    cv = {}                      # 値が分かっているレジスタ {番号: python の整数}。番地を定数として扱うのに使う
    full = True                  # 前向きの分岐の内側でない（act が act0 に等しい）
    for idx in range(lo, hi):
        if idx in wait:
            act = act | wait.pop(idx)
            full = not wait
        op, a, b, c, sb, sc, im = prog[idx]
        K = widths(idx)
        if op == MAT:
            put(a, L.from_int(im, K, R[:, 0, 0]), act)
            cv[a] = im if full else None
        elif op == ADD:
            x = L.shl(get(b), sb, K) if sb else L.fit(get(b), K)
            y = L.shl(get(c), sc, K) if sc else L.fit(get(c), K)
            put(a, L.add(x, y, K), act)
            cb, cc = cv.get(b), cv.get(c)
            cv[a] = ((cb << sb) + (cc << sc)) if (full and cb is not None and cc is not None) else None
        elif op == MUL:
            put(a, L.mul(get(b), get(c), K), act)
            cv[a] = None
        elif op == NEG:
            put(a, L.fit(L.neg(L.fit(get(b), K)), K), act)
            cv[a] = -cv[b] if (full and cv.get(b) is not None) else None
        elif op == LD:
            addr = cv.get(b)
            v = _load_const(M, mem, addr) if addr is not None else None
            put(a, v if v is not None else _load(M, mem, L.low_int(get(b)), row), act)
            cv[a] = None
        elif op == ST:
            addr = cv.get(b)
            if addr is not None and 0 <= addr < mem.words:
                M, lost = _store_const(M, mem, addr, get(c), act)
            else:
                M, lost = _store(M, mem, L.low_int(get(b)), get(c), act, row)
            if check:
                rep = jnp.where(lost & (rep < 0), WIDE, rep)
        elif op in (EQ, LT, JMP):
            assert im > 0, "後ろ向きの分岐は繰り返しの終わりにだけ現れる（命令 %d）" % idx
            if op == JMP:
                cond = jnp.ones_like(act)
            else:
                x = L.shl(get(b), sb, max(len(get(b)), K) + 2) if sb else get(b)
                y = L.shl(get(c), sc, max(len(get(c)), K) + 2) if sc else get(c)
                cond = L.eq(x, y) if op == EQ else L.lt(x, y)
            t = idx + im
            wait[t] = wait.get(t, jnp.zeros_like(act)) | (act & cond)
            act = act & ~cond
            full = False
        elif op in (HALT, OK, KO, PUT):
            pass
        else:
            raise ValueError("未知の命令 %s" % op)
    if hi in wait:
        act = act | wait.pop(hi)
    assert not wait, "前向きの分岐が区間 [%d, %d) の外へ出る" % (lo, hi)
    for r, val in reg.items():
        R = R.at[:, r, :].set(jnp.stack(L.extend(val, KR)[:KR], axis=1))
    return R, M, rep


def _back_cond(prog, j, widths, KR, R):
    """繰り返しの終わりの命令 j で、戻る lane の印。"""
    op, a, b, c, sb, sc, im = prog[j]
    if op == JMP:
        return jnp.ones((R.shape[0],), dtype=jnp.bool_)
    K = widths(j)
    xb = [R[:, b, k] for k in range(KR)]
    xc = [R[:, c, k] for k in range(KR)]
    x = L.shl(xb, sb, KR + 2) if sb else xb
    y = L.shl(xc, sc, KR + 2) if sc else xc
    return L.eq(x, y) if op == EQ else L.lt(x, y)


# ===== 繰り返しの木 =====

class Node(object):
    def __init__(self, kind, lo, hi, children=None):
        self.kind, self.lo, self.hi, self.children = kind, lo, hi, children or []
        self.fn = None                     # jax.jit した関数（最初に呼ぶときに作る）


def build_tree(prog):
    """命令列を、直列の区間（straight）と繰り返し（loop）の木にする。

    後ろ向きの分岐 j（飛び先 t = j + im ≤ j）が、命令 [t, j] の繰り返しを作る。
    loop の lo は t、hi は j（終わりの命令。分岐の判定に使う）。
    """
    n = len(prog)
    loops = {}
    for j, (op, a, b, c, sb, sc, im) in enumerate(prog):
        if op in (EQ, LT, JMP) and im <= 0:
            t = j + im
            assert t not in loops, "同じ飛び先の繰り返しが二つある（命令 %d）" % t
            loops[t] = j

    def build(lo, hi):
        nodes, i = [], lo
        while i < hi:
            if i in loops and loops[i] < hi:
                j = loops[i]
                nodes.append(Node("loop", i, j, build(i, j)))
                i = j + 1
            else:
                k = i
                while k < hi and not (k in loops and loops[k] < hi):
                    k += 1
                nodes.append(Node("straight", i, k))
                i = k
        return nodes
    return build(0, n)


class Program(object):
    """開いた image。"""

    def __init__(self, image, words, limbs, widths, mem_limbs, mem_wide, check):
        self.prog = vcpu.decode(image)
        self.words = words
        if widths is None:
            self.widths = lambda i: limbs
        elif callable(widths):
            self.widths = widths
        else:
            self.widths = lambda i: widths.get(i, limbs)
        self.mem = Memory(words, mem_limbs, dict(mem_wide))
        n = len(self.prog)
        self.KR = max([self.widths(i) for i in range(n)] + [self.mem.KMAX, limbs])
        self.check = check
        self.tree = build_tree(self.prog)
        self.last_op = self.prog[-1][0] if n else HALT
        self.warmed = None

    # ---- 関数の作り方 ----
    def _straight(self, node):
        if node.fn is None:
            prog, widths, mem, KR, check = self.prog, self.widths, self.mem, self.KR, self.check

            def f(R, M, rep, act):
                return _exec(prog, node.lo, node.hi, widths, mem, KR, check, R, M, rep, act)
            node.fn = jax.jit(f, donate_argnums=(0, 1, 2))      # R, M, rep は書き換えて返す（コピーしない）
        return node.fn

    def _innermost(self, node):
        return all(c.kind == "straight" for c in node.children)

    def _loop_fn(self, node):
        """一番内側の繰り返し 1 つを lax.while_loop にした関数。返りは (R, M, rep, 抜けた lane)。"""
        if node.fn is None:
            prog, widths, mem, KR, check = self.prog, self.widths, self.mem, self.KR, self.check

            def f(R, M, rep, act0):
                def cond(c):
                    return c[3].any()

                def body(c):
                    R, M, rep, act, done = c
                    for ch in node.children:
                        R, M, rep = _exec(prog, ch.lo, ch.hi, widths, mem, KR, check, R, M, rep, act)
                    back = _back_cond(prog, node.hi, widths, KR, R)
                    return R, M, rep, act & back, done | (act & ~back)

                R, M, rep, _, done = jax.lax.while_loop(cond, body, (R, M, rep, act0, jnp.zeros_like(act0)))
                return R, M, rep, done
            node.fn = jax.jit(f, donate_argnums=(0, 1, 2))
        return node.fn

    def _back(self, node):
        key = ("back", node.hi)
        if key not in self.__dict__:
            prog, widths, KR = self.prog, self.widths, self.KR
            self.__dict__[key] = jax.jit(lambda R: _back_cond(prog, node.hi, widths, KR, R))
        return self.__dict__[key]

    def warm(self, W, workers=None):
        """lane 数 W の形で、全部の関数を並列にコンパイルしておく。run の前に一度だけ呼ぶ。"""
        from concurrent.futures import ThreadPoolExecutor
        if self.warmed == W:
            return
        S = jax.ShapeDtypeStruct
        R = S((W, NREG, self.KR), jnp.int32)
        M = [S((W, self.mem.words, self.mem.K), jnp.int32)] + [S((W, n, k), jnp.int32) for k, _, n in self.mem.classes]
        rep, act = S((W,), jnp.int32), S((W,), jnp.bool_)
        jobs = []

        def walk(nodes):
            for nd in nodes:
                if nd.kind == "straight":
                    jobs.append((nd, self._straight(nd), (R, M, rep, act)))
                elif self._innermost(nd):
                    jobs.append((nd, self._loop_fn(nd), (R, M, rep, act)))
                else:
                    jobs.append((nd, self._back(nd), (R,)))
                    walk(nd.children)
        walk(self.tree)

        def build(job):
            nd, fn, args = job
            return fn.lower(*args).compile()
        with ThreadPoolExecutor(workers or (os.cpu_count() or 4)) as ex:
            exes = list(ex.map(build, jobs))
        for (nd, fn, args), exe in zip(jobs, exes):
            if nd.kind == "loop" and not self._innermost(nd):
                nd.back_exe = exe
            else:
                nd.exe = exe
        self.warmed = W
    # ---- 実行 ----
    def run_nodes(self, nodes, R, M, rep, act):
        for node in nodes:
            R, M, rep, act = self.run_node(node, R, M, rep, act)
        return R, M, rep, act

    def run_node(self, node, R, M, rep, act):
        if node.kind == "straight":
            R, M, rep = (getattr(node, 'exe', None) or self._straight(node))(R, M, rep, act)
            return R, M, rep, act
        if self._innermost(node):
            R, M, rep, done = (getattr(node, 'exe', None) or self._loop_fn(node))(R, M, rep, act)
            return R, M, rep, done
        a, done = act, jnp.zeros_like(act)
        back = getattr(node, 'back_exe', None) or self._back(node)
        while True:
            R, M, rep, a = self.run_nodes(node.children, R, M, rep, a)
            cond = back(R)
            done = done | (a & ~cond)
            a = a & cond
            if not bool(a.any()):
                break
        return R, M, rep, done


class Result(object):
    def __init__(self, program, rep, M):
        self.program, self.rep, self.M = program, rep, M

    def word(self, lane, addr):
        """lane の語 addr を python の整数で返す。"""
        mem = self.program.mem
        for (k, table, n), part in zip(mem.classes, self.M[1:]):
            i = int(table[addr])
            if i >= 0:
                return L.to_python([int(x) for x in np.asarray(part[lane, i, :])])
        return L.to_python([int(x) for x in np.asarray(self.M[0][lane, addr, :])])


def load(image, words=4096, limbs=4, widths=None, mem_limbs=4, mem_wide=None, check=True):
    """check が真なら、語の本数に収まらない値の書き込みを報告 43 にする（本数を決めるときに使う）。"""
    return Program(image, words, limbs, widths, mem_limbs, mem_wide or {}, check)


def _put(part, lane, idx, v, k, addr):
    if not (-(1 << (L.BITS * k - 1)) <= v < (1 << (L.BITS * k - 1))):
        raise OverflowError("語 %d の種 %d が %d 本（%d bit）に収まらない" % (addr, v, k, L.BITS * k))
    w = v
    for j in range(k - 1):
        part[lane, idx, j] = w & L.MASK
        w >>= L.BITS
    part[lane, idx, k - 1] = w


def _seed_memory(program, W, seeds, base):
    """全 lane に共通の初期値 base を置いてから、lane ごとの seeds で上書きする。"""
    mem = program.mem
    tables = [np.asarray(t) for _, t, _ in mem.classes]

    def put_all(parts, lane, seed):
        for addr, v in seed.items():
            if not (0 <= addr < mem.words):
                raise IndexError("語番号 %d が作業領域（%d 語）の外" % (addr, mem.words))
            for ci, ((k, _, _), table) in enumerate(zip(mem.classes, tables), start=1):
                if table[addr] >= 0:
                    _put(parts[ci], lane, int(table[addr]), int(v), k, addr)
                    break
            else:
                _put(parts[0], lane, addr, int(v), mem.K, addr)

    one = [np.zeros((1, mem.words, mem.K), dtype=np.int32)] + \
          [np.zeros((1, n, k), dtype=np.int32) for k, _, n in mem.classes]
    put_all(one, 0, base or {})
    parts = [np.ascontiguousarray(np.broadcast_to(p, (W,) + p.shape[1:])) for p in one]
    for lane, seed in enumerate(seeds):
        put_all(parts, lane, seed)
    return [jnp.asarray(p) for p in parts]

def run(program, seeds, base=None):
    """seeds の長さだけ lane を走らせる。base は全 lane に共通の初期値（表など）。返りは Result。"""
    W = len(seeds)
    program.warm(W)                                            # 並列にコンパイルする（済んでいれば何もしない）
    R = jnp.zeros((W, NREG, program.KR), dtype=jnp.int32)
    M = _seed_memory(program, W, seeds, base)
    rep = jnp.full((W,), -1, dtype=jnp.int32)
    act = jnp.ones((W,), dtype=jnp.bool_)
    R, M, rep, act = program.run_nodes(program.tree, R, M, rep, act)
    if program.last_op == OK:                                  # 最後の命令が成功報告
        rep = jnp.where((rep < 0) & act, 0, rep)
    elif program.last_op == KO:
        rep = jnp.where((rep < 0) & act, 42, rep)
    jax.block_until_ready(rep)
    return Result(program, np.asarray(rep), M)



