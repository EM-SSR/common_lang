# -*- coding: utf-8 -*-
"""lane64 image → JAX 生成器（TPU ターゲット第一版）。

画像の命令列を block（直列区間）に分け、各 block を JAX の状態更新に落とし、
lax.switch で block を辿る。実行は block 単位の while。lockstep 前提
（全 lane が同じ pc 列を辿る画像 — eratosthenes など）。

使い方:
    run_fn = emit(vcpu.decode(open(image, "rb").read()), words=4096)
    rep, M, steps = run_fn(W=1024)
"""

import os
import sys

import jax
import jax.numpy as jnp

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vcpu  # noqa: E402

HALT, MAT, ADD, MUL, NEG, EQ, LT, JMP, LD, ST, OK, KO = range(12)
TERMINATORS = {HALT, EQ, LT, JMP, OK, KO}


def split_blocks(prog):
    """命令列を block に分ける。境界は (1) 終端命令の直後、(2) 分岐の飛び先。

    EQ/LT は真なら pc = i+1+im、偽なら pc = i+1。飛び先 i+1+im を block 頭に置く
    （偽の着地点 i+1 は終端直後なので既に境界になる）。返りは昇順の starts。
    """
    n = len(prog)
    bounds = {0, n}
    for i, (op, a, b, c, sb, sc, im) in enumerate(prog):
        if op in TERMINATORS and i + 1 < n:
            bounds.add(i + 1)
        if op in (EQ, LT):
            t = i + im
            if 0 <= t < n:
                bounds.add(t)
        elif op == JMP:
            t = i + im
            if 0 <= t < n:
                bounds.add(t)
    return sorted(bounds)


def lower_block(prog, lo, hi, words, nreg):
    """block [lo, hi) の直列命令 → JAX の状態更新。

    状態は (R, M, pc, rep, run, i)。R: (W, nreg)、M: (W, words)、
    pc: スカラー（lockstep）、rep/run: (W,)。
    block が終端命令で終わらない場合は素通り（pc = hi）。
    """
    def fn(state):
        R, M, pc, rep, run, i = state
        for idx in range(lo, hi):
            op, a, b, c, sb, sc, im = prog[idx]
            if op == MAT:
                R = R.at[:, a].set(jnp.asarray(im, dtype=jnp.int32))
            elif op == ADD:
                x = jnp.left_shift(R[:, b], sb)
                y = jnp.left_shift(R[:, c], sc)
                R = R.at[:, a].set(x + y)
            elif op == MUL:
                R = R.at[:, a].set(R[:, b] * R[:, c])
            elif op == NEG:
                R = R.at[:, a].set(-R[:, b])
            elif op == LD:
                oh = jnp.equal(jnp.arange(words)[None, :], R[:, b][:, None])
                v = jnp.einsum("lw,lw->l", M.astype(jnp.int32), oh.astype(jnp.int32))
                R = R.at[:, a].set(v)
            elif op == ST:
                oh = jnp.equal(jnp.arange(words)[None, :], R[:, b][:, None]).astype(jnp.int32)
                M = M + (R[:, c][:, None] - M) * oh
            elif op in (EQ, LT, JMP, OK, KO, HALT):
                pass
            else:
                raise ValueError("未知の命令 %s" % op)
        op, a, b, c, sb, sc, im = prog[hi - 1]
        if op == EQ or op == LT:
            x = jnp.left_shift(R[:, b], sb)
            y = jnp.left_shift(R[:, c], sc)
            cond = jnp.equal(x, y) if op == EQ else jnp.less(x, y)
            take = cond[0]                      # lockstep: 先頭 lane の判定
            pc = (hi - 1) + jnp.where(take, im, 1)
        elif op == JMP:
            pc = (hi - 1) + im
        elif op == OK:
            rep = jnp.zeros_like(rep)
            run = jnp.zeros_like(run)
            pc = hi
        elif op == KO:
            rep = jnp.full_like(rep, 42)
            run = jnp.zeros_like(run)
            pc = hi
        else:
            if prog[hi - 1][0] == HALT:
                run = jnp.zeros_like(run)
            pc = hi                            # 素通りまたは HALT
        pc = jnp.asarray(pc, dtype=jnp.int32)
        return (R, M, pc, rep, run, i + 1)
    return fn


def emit(prog, words=4096, nreg=10, budget=1 << 24):
    """image の命令列 → JAX 実行関数。返りは fn(W) -> (rep, M, steps)。"""
    starts = split_blocks(prog)
    blocks = [(lo, starts[k + 1] if k + 1 < len(starts) else len(prog))
              for k, lo in enumerate(starts)]
    blocks = [(lo, hi) for (lo, hi) in blocks if hi > lo]

    def block_index(pc):
        idx = jnp.searchsorted(jnp.asarray(starts[:-1], dtype=jnp.int32), pc,
                               side="right") - 1
        return jnp.clip(idx, 0, len(blocks) - 1)

    fns = [lower_block(prog, lo, hi, words, 10) for (lo, hi) in blocks]

    def run_fn(W):
        c0 = (jnp.zeros((W, 10), dtype=jnp.int32),
              jnp.zeros((W, words), dtype=jnp.int32),
              jnp.asarray(0, dtype=jnp.int32),
              jnp.full((W,), -1, dtype=jnp.int32),
              jnp.ones((W,), dtype=jnp.bool_),
              jnp.asarray(0, dtype=jnp.int32))

        def cond(c):
            return jnp.logical_and(c[4].any(), c[5] < budget)

        def body(c):
            b = block_index(c[2])
            return jax.lax.switch(b, fns, c)

        R, M, pc, rep, run, i = jax.lax.while_loop(cond, body, c0)
        return jax.block_until_ready((rep, M, i))

    return run_fn