# -*- coding: utf-8 -*-
"""lane64 の JAX lockstep 実行台（実験版）。

CUDA 版（gvcpu.py）は thread=lane で lane ごとに発散分岐する。XLA は per-thread の
発散制御を持てないので、ここでは全 lane を同じ一歩で進める lockstep に直す。意味は
vcpu.py の Interp（式 2.1, 3.1, 3.2, 3.3）と同じ: lane ごとの pc が命令を辿る。組の
併合（式 3.3）は実行順の最適化であって意味に入らないので、lane ごとの一歩で足りる。

  語は int32。ℤ ではなく 32 bit に丸める。値が 32 bit に収まる image のみを対象にする
  （milestone）。1024 bit の limb 版は次の段。
  動かない lane は命令を HALT に落として退け、散布は動かない値の書き戻しで塞ぐ。
  PUT（OUT）はまだ持たない。watch で語を読む道だけを用意する。
"""

import time

import numpy as np
import jax
import jax.numpy as jnp

HALT, MAT, ADD, MUL, NEG, EQ, LT, JMP, LD, ST, OK, KO, PUT = range(13)
LANDMARKS = 256


def run_jax(prog, W, words, budget=1 << 20, unroll=1):
    """lockstep で image を W lane 分だけ走らせる。

    prog は vcpu.decode の欄の組の並び。戻りは (報告, M, 歩数)。報告は -1 = None、
    0 = OK、42 = KO。Interp と同じく、語番号が範囲を外れた lane はそこで止まる。
    unroll は while の一回で進める歩数。TPU 実測では 1 が一番速かった（v5e-1、
    eratosthenes 素の実行: unroll=1 で 0.357s / unroll=8 で 2.065s。体を大きくするほど
    悪い。1歩あたりの scatter/gather の重さが支配で、回し代は支配ではない）。
    R は画像が触る幅（欄 a,b,c の上限、nreg）だけ持ち、M の書き戻しは ST のある歩
    だけに絞る（書き戻しは意味的には no-op だが散布自体が重い）。
    """
    tab = np.array([list(p) for p in prog], dtype=np.int32)
    if tab.ndim != 2 or tab.shape[1] != 7:
        raise ValueError('prog は (op, a, b, c, sb, sc, im) の並びであること')
    d_prog = jnp.asarray(tab)
    n = d_prog.shape[0]
    row = jnp.arange(W)

    # 画像が実際に触る R の幅だけ持つ（欄 a,b,c の上限。256 は LANDMARKS の上限）
    nreg = int(min(LANDMARKS, max(8, int(tab[:, 1:4].max()) + 1)))

    R0 = jnp.zeros((W, nreg), dtype=jnp.int32)
    M0 = jnp.zeros((W, words), dtype=jnp.int32)
    pc0 = jnp.zeros((W,), dtype=jnp.int32)
    rep0 = jnp.full((W,), -1, dtype=jnp.int32)
    run0 = jnp.ones((W,), dtype=jnp.bool_)
    i0 = jnp.zeros((), dtype=jnp.int32)

    def cond(carry):
        _R, _M, _pc, _rep, run, i = carry
        return run.any() & (i < budget)

    def body(carry):
        R, M, pc, rep, run, i = carry
        for _ in range(unroll):
            # 歩数と pc の範囲。範囲を外れた lane は語番号の実現不能（式 50.4）で止める
            in_pc = (pc >= 0) & (pc < n)
            live = run & in_pc
            insn = d_prog[jnp.clip(pc, 0, n - 1)]   # (W, 7)
            op, a, b, c, sb, sc, im = (insn[:, k] for k in range(7))
            op = jnp.where(live, op, HALT)
            a = jnp.where(live, a % nreg, 0)
            b = jnp.where(live, b % nreg, 0)
            c = jnp.where(live, c % nreg, 0)
            sb = jnp.where(live, sb % 32, 0)
            sc = jnp.where(live, sc % 32, 0)
            im = jnp.where(live, im, 0)

            Rb = R[row, b]
            Rc = R[row, c]
            Ra = R[row, a]
            u = jnp.left_shift(Rb, sb)              # 式の R[b] << sb
            v = jnp.left_shift(Rc, sc)

            # 値の箱。どの欄でも値を一度に作って where で選ぶ（分岐を持たない）
            idx_ld = jnp.where(op == LD, Rb % words, 0)
            val_ld = M[row, idx_ld]
            val = jnp.where(op == MAT, im,
                 jnp.where(op == ADD, u + v,
                 jnp.where(op == MUL, Rb * Rc,
                 jnp.where(op == NEG, -Rb,
                 jnp.where(op == LD, val_ld, Ra)))))
            R = R.at[row, a].set(val)

            idx_st = jnp.where(op == ST, Rb % words, 0)
            val_st = jnp.where(op == ST, Rc, M[row, idx_st])
            # ST のない歩では M を書き戻さない（書き戻しは no-op だが散布自体が重い）
            M = jax.lax.cond((op == ST).any(),
                             lambda M_: M_.at[row, idx_st].set(val_st),
                             lambda M_: M_,
                             M)

            # 述語（式 3.1, 3.2）。割れ目は lane ごとの pc へそのまま落とす
            is_br = (op == EQ) | (op == LT)
            cm = jnp.where(op == EQ, u == v, u < v)
            pc_br = jnp.where(cm, pc + im, pc + 1)
            pc_next = jnp.where(op == JMP, pc + im,
                 jnp.where(is_br, pc_br, pc + 1))

            halt = (op == HALT) | (op == OK) | (op == KO)
            rep = jnp.where(op == OK, 0, jnp.where(op == KO, 42, rep))
            run = run & ~halt & in_pc
            pc = jnp.where(run, pc_next, pc)
            i = i + 1
        return (R, M, pc, rep, run, i)

    R, M, _pc, rep, _run, steps = jax.lax.while_loop(cond, body,
                                                     (R0, M0, pc0, rep0, run0, i0))
    return jax.block_until_ready((rep, M, steps))


def head_words(M, watch):
    """lane 0 の watch 語を host へ戻す（式 8.2 の置き方の読み出し）。"""
    return tuple(int(M[0, w]) for w in watch)


def run_jax_mx(prog, W, words, budget=1 << 20):
    """行列計算機の形に並べ替えた lockstep 実行台（実験版）。

    TPU の速い道は MXU（行列積）と streaming 演算で、動的番号の gather/scatter は
    遅い。そこで命令の読み出しを one-hot 行列と prog の積に、R/M の読みを one-hot
    との縮約に、書きを差分の加算に置き、動的番地をなくす。意味は run_jax と同じ。
    語は int32。prog の欄は f32 の積で読む（欄の値が 2^24 未満なら厳密）。
    """
    tab = np.array([list(p) for p in prog], dtype=np.int32)
    if tab.ndim != 2 or tab.shape[1] != 7:
        raise ValueError('prog は (op, a, b, c, sb, sc, im) の並びであること')
    nreg = int(min(LANDMARKS, max(8, int(tab[:, 1:4].max()) + 1)))
    d_prog_f = jnp.asarray(tab, dtype=jnp.float32)
    n = d_prog_f.shape[0]
    row = jnp.arange(W)

    R0 = jnp.zeros((W, nreg), dtype=jnp.int32)
    M0 = jnp.zeros((W, words), dtype=jnp.int32)
    pc0 = jnp.zeros((W,), dtype=jnp.int32)
    rep0 = jnp.full((W,), -1, dtype=jnp.int32)
    run0 = jnp.ones((W,), dtype=jnp.bool_)
    i0 = jnp.zeros((), dtype=jnp.int32)

    def cond(carry):
        _R, _M, _pc, _rep, run, i = carry
        return run.any() & (i < budget)

    def body(carry):
        R, M, pc, rep, run, i = carry
        in_pc = (pc >= 0) & (pc < n)
        live = run & in_pc
        # 命令の読み。動的 gather の代わりに one-hot と prog の積
        S = jax.nn.one_hot(jnp.clip(pc, 0, n - 1), n)
        insn = jnp.dot(S, d_prog_f).astype(jnp.int32)      # (W, 7)
        op, a, b, c, sb, sc, im = (insn[:, k] for k in range(7))
        op = jnp.where(live, op, HALT)
        # R の読み。one-hot との縮約
        eb = jax.nn.one_hot(jnp.where(live, b % nreg, 0), nreg).astype(jnp.int32)
        ec = jax.nn.one_hot(jnp.where(live, c % nreg, 0), nreg).astype(jnp.int32)
        ea = jax.nn.one_hot(jnp.where(live, a % nreg, 0), nreg).astype(jnp.int32)
        Rb = (eb * R).sum(axis=1)
        Rc = (ec * R).sum(axis=1)
        Ra = (ea * R).sum(axis=1)
        sb = jnp.where(live, sb % 32, 0)
        sc = jnp.where(live, sc % 32, 0)
        im = jnp.where(live, im, 0)
        u = jnp.left_shift(Rb, sb)
        v = jnp.left_shift(Rc, sc)
        # LD も one-hot の縮約
        idx_ld = jnp.where(op == LD, Rb % words, 0)
        el = jax.nn.one_hot(idx_ld, words).astype(jnp.int32)
        val_ld = (el * M).sum(axis=1)
        val = jnp.where(op == MAT, im,
             jnp.where(op == ADD, u + v,
             jnp.where(op == MUL, Rb * Rc,
             jnp.where(op == NEG, -Rb,
             jnp.where(op == LD, val_ld, Ra)))))
        # R の書きは散布でなく差分の加算（動かない欄の差分は零）
        wr = live & ((op == MAT) | (op == ADD) | (op == MUL) | (op == NEG) | (op == LD))
        delta = jnp.where(wr, val - Ra, 0)
        R = R + delta[:, None] * ea
        # M の書きも差分の加算。ST のない歩は丸ごと省く
        def upd(M_):
            est = jax.nn.one_hot(jnp.where(op == ST, Rb % words, 0), words).astype(jnp.int32)
            old = (est * M_).sum(axis=1)
            d = jnp.where(op == ST, Rc - old, 0)
            return M_ + d[:, None] * est
        M = jax.lax.cond((op == ST).any(), upd, lambda M_: M_, M)
        is_br = (op == EQ) | (op == LT)
        cm = jnp.where(op == EQ, u == v, u < v)
        pc_br = jnp.where(cm, pc + im, pc + 1)
        pc_next = jnp.where(op == JMP, pc + im,
             jnp.where(is_br, pc_br, pc + 1))
        halt = (op == HALT) | (op == OK) | (op == KO)
        rep = jnp.where(op == OK, 0, jnp.where(op == KO, 42, rep))
        run = run & ~halt & in_pc
        pc = jnp.where(run, pc_next, pc)
        i = i + 1
        return (R, M, pc, rep, run, i)

    R, M, _pc, rep, _run, steps = jax.lax.while_loop(cond, body,
                                                     (R0, M0, pc0, rep0, run0, i0))
    return jax.block_until_ready((rep, M, steps))


if __name__ == '__main__':
    import os
    import sys

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) or '.')
    import vcpu

    print('jax', jax.__version__, jax.devices())
    W, words = 64, 4096
    watch = (0, 2, 3)
    for name in ('dyadic_series', 'eratosthenes'):
        img = open(name + '-lane64.bin', 'rb').read()
        prog = vcpu.decode(img)

        ip = vcpu.Interp(prog, lanes=1, words=words)
        rep_ref = ip.run()[0]
        ref = tuple(int(ip.M[0][w]) for w in watch)

        t0 = time.perf_counter()
        rep, M, steps = run_jax(prog, W, words)
        t1 = time.perf_counter()
        reps = sorted(set(int(x) for x in rep))
        got = tuple(int(M[0, w]) for w in watch)
        lane0 = (int(M[0, 0]), int(M[0, 2]), int(M[0, 3]))
        ok = (reps == [rep_ref] and rep_ref == 0 and lane0 == ref)
        print('%s: CPU rep=%d head=%s / JAX %d lanes rep=%s steps=%d (%.2fs) %s'
              % (name, rep_ref, ref, W, reps, int(steps), t1 - t0,
                 'MATCH' if ok else 'MISMATCH'))