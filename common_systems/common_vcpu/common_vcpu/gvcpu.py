# -*- coding: utf-8 -*-
"""lane64 の GPU 実行台（limb 版）。thread 一本が lane 一本になる。

仕様は docs/common-compiler/arch/20。式 (2.1) の解釈器と同じ意味を、CUDA の kernel の中で
lane ごとに走らせる。cuvcpu.py は語を bit 平面に持ち、命令一つが平面の演算の列になるので、
語が広いと launch の数で足が止まる。ここでは語を 64 bit の limb の並びで持ち、lane ごとの
thread が block を跨いで命令を辿る。分岐は thread ごとに好きに飛ぶ（mask は要らない）。

  並び   語 主。語 w の limb i、lane l は M[(w·NLIMB + i)·lanes + l] に置く。
         同じ語を読む lane の番地が連続するので、warp の memory access が一度で済む。
         lane 主に置くと lane ごとに words·NLIMB 語ずつ離れ、一命令が 32 回の転送になる
  語     NLIMB 本の limb。二の補数、little endian。既定 16 本 = 1024 bit
  landmark  R[0..7]。commonc の lane64 版は R1 R2 R3 だけを使う（back_lane64.cam の覆い）
  作業領域  lane ごとに words 語。読む語（watch）だけを host へ戻す

語の幅を越えた乗算は報告 43 で止まる。lane64 の語は ℤ なので（20 §0.3）、この道は
NLIMB·64 bit を越えた時点で core 意味論と離れる。

  run(prog, seeds, words, watch, need=None) → lane ごとの (報告, {語: 値})
"""

import numpy as np

INSN_FIELDS = 7
NREG_BYTES = 8 * 8          # shared memory へ置く register。NREG 本 × 8 byte
R_OK, R_KO, R_WIDE, R_BUDGET = 0, 42, 43, 44

SRC = r"""
#define NLIMB %(nlimb)d
#define NREG 8
typedef unsigned long long u64;
typedef long long i64;

struct Big { u64 v[NLIMB]; };

__device__ __forceinline__ void big_zero(Big &r) { for (int i = 0; i < NLIMB; i++) r.v[i] = 0; }
__device__ __forceinline__ void big_imm(Big &r, i64 x) {
    r.v[0] = (u64)x; u64 f = (x < 0) ? ~0ULL : 0ULL;
    for (int i = 1; i < NLIMB; i++) r.v[i] = f;
}
__device__ __forceinline__ bool big_neg_p(const Big &a) { return (a.v[NLIMB - 1] >> 63) != 0; }
__device__ __forceinline__ void big_add(Big &r, const Big &a, const Big &b) {
    u64 c = 0;
    for (int i = 0; i < NLIMB; i++) {
        u64 s = a.v[i] + b.v[i]; u64 c1 = (s < a.v[i]) ? 1 : 0;
        u64 t = s + c; u64 c2 = (t < s) ? 1 : 0;
        r.v[i] = t; c = c1 | c2;
    }
}
__device__ __forceinline__ void big_not(Big &r, const Big &a) { for (int i = 0; i < NLIMB; i++) r.v[i] = ~a.v[i]; }
__device__ __forceinline__ void big_negate(Big &r, const Big &a) {
    Big n; big_not(n, a); Big one; big_imm(one, 1); big_add(r, n, one);
}
__device__ __forceinline__ void big_sub(Big &r, const Big &a, const Big &b) { Big nb; big_negate(nb, b); big_add(r, a, nb); }
__device__ __forceinline__ bool big_eq(const Big &a, const Big &b) {
    for (int i = 0; i < NLIMB; i++) if (a.v[i] != b.v[i]) return false; return true;
}
__device__ __forceinline__ bool big_lt(const Big &a, const Big &b) {
    bool na = big_neg_p(a), nb = big_neg_p(b);
    if (na != nb) return na;
    for (int i = NLIMB - 1; i >= 0; i--) { if (a.v[i] != b.v[i]) return a.v[i] < b.v[i]; }
    return false;
}
__device__ __forceinline__ void big_shl(Big &r, const Big &a, int s) {
    if (s <= 0) { r = a; return; }
    int w = s / 64, bts = s %% 64;
    Big t; big_zero(t);
    for (int i = NLIMB - 1; i >= w; i--) {
        u64 hi = a.v[i - w] << bts;
        u64 lo = (bts && i - w - 1 >= 0) ? (a.v[i - w - 1] >> (64 - bts)) : 0;
        t.v[i] = hi | lo;
    }
    r = t;
}
// |a|·|b| を 2·NLIMB limb で作り、上半分が零でなければ幅を越えたとみなす
__device__ bool big_mul(Big &r, const Big &a0, const Big &b0) {
    Big a, b; bool na = big_neg_p(a0), nb = big_neg_p(b0);
    if (na) big_negate(a, a0); else a = a0;
    if (nb) big_negate(b, b0); else b = b0;
    // 上位の零の limb は掛けない。小さい数どうしなら 1 回の乗算で済む
    int la = 0, lb = 0;
    for (int i = 0; i < NLIMB; i++) { if (a.v[i]) la = i + 1; if (b.v[i]) lb = i + 1; }
    u64 acc[2 * NLIMB];
    for (int i = 0; i < 2 * NLIMB; i++) acc[i] = 0;
    for (int i = 0; i < la; i++) {
        u64 carry = 0;
        for (int j = 0; j < lb; j++) {
            u64 lo = a.v[i] * b.v[j];
            u64 hi = __umul64hi(a.v[i], b.v[j]);
            u64 s = acc[i + j] + lo; u64 c1 = (s < lo) ? 1 : 0;
            u64 t = s + carry; u64 c2 = (t < s) ? 1 : 0;
            acc[i + j] = t;
            carry = hi + c1 + c2;
        }
        int k = i + lb;
        while (carry && k < 2 * NLIMB) { u64 s = acc[k] + carry; carry = (s < carry) ? 1 : 0; acc[k] = s; k++; }
    }
    bool wide = false;
    for (int i = NLIMB; i < 2 * NLIMB; i++) if (acc[i]) wide = true;
    if (acc[NLIMB - 1] >> 63) wide = true;
    for (int i = 0; i < NLIMB; i++) r.v[i] = acc[i];
    if (na != nb) { Big t = r; big_negate(r, t); }
    return wide;
}

// 語の番地 → 詰めた並びの位置。work が 0 なら詰めない
__device__ __forceinline__ i64 slot(i64 a, int need, int work, int words) {
    if (work == 0) return (a >= 0 && a < words) ? a : -1;
    if (a >= 0 && a < need) return a;
    if (a >= work && a - work + need < words) return a - work + need;
    return -1;
}

extern "C" __global__
void lane64_run(const i64 *prog, int ninsn, u64 *M, int words, int lanes, i64 budget,
                int need, int work, int *report, i64 *steps,
                const u64 *ROM, i64 romlo, i64 romn)
{
    int lane = blockIdx.x * blockDim.x + threadIdx.x;
    if (lane >= lanes) return;
    Big R[NREG];
    int pc = 0; i64 n = 0; int rep = %(r_budget)d;
    while (n < budget) {
        n++;
        if (pc < 0 || pc >= ninsn) { rep = %(r_end)d; break; }
        const i64 *ins = prog + (size_t)pc * %(fields)d;
        int op = (int)ins[0], a = (int)ins[1], b = (int)ins[2], c = (int)ins[3];
        int sb = (int)ins[4], sc = (int)ins[5]; i64 im = ins[6];
        if (op == 0) { rep = %(r_end)d; break; }                         // HALT
        else if (op == 1) { big_imm(R[a], im); pc++; }                  // MAT
        else if (op == 2) { Big x, y; big_shl(x, R[b], sb); big_shl(y, R[c], sc); big_add(R[a], x, y); pc++; }   // ADD
        else if (op == 3) { Big t; if (big_mul(t, R[b], R[c])) { rep = %(r_wide)d; break; } R[a] = t; pc++; }  // MUL
        else if (op == 4) { Big t; big_negate(t, R[b]); R[a] = t; pc++; }   // NEG
        else if (op == 5) { Big x, y; big_shl(x, R[b], sb); big_shl(y, R[c], sc); pc += big_eq(x, y) ? (int)im : 1; }   // EQ
        else if (op == 6) { Big x, y; big_shl(x, R[b], sb); big_shl(y, R[c], sc); pc += big_lt(x, y) ? (int)im : 1; }   // LT
        else if (op == 7) { pc += (int)im; }                            // JMP
        else if (op == 8) {                                             // LD
            i64 raw = (i64)R[b].v[0];
            if (raw >= romlo) {                                         // 共有帯。lane で割らない
                i64 o = raw - romlo; if (o >= romn) { rep = %(r_end)d; break; }
                const u64 *w = ROM + (size_t)o * NLIMB;
                for (int i = 0; i < NLIMB; i++) R[a].v[i] = w[i]; pc++;
            } else {
                i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; break; }
                const u64 *w = M + ((size_t)addr * NLIMB) * (size_t)lanes + lane;
                for (int i = 0; i < NLIMB; i++) R[a].v[i] = w[(size_t)i * lanes]; pc++;
            }
        }
        else if (op == 9) {                                             // ST
            i64 raw = (i64)R[b].v[0];
            if (raw >= romlo) { rep = %(r_end)d; break; }               // 共有帯へは書けない
            i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; break; }
            u64 *w = M + ((size_t)addr * NLIMB) * (size_t)lanes + lane;
            for (int i = 0; i < NLIMB; i++) w[(size_t)i * lanes] = R[c].v[i]; pc++;
        }
        else if (op == 10) { rep = %(r_ok)d; break; }                   // OK
        else if (op == 11) { rep = %(r_ko)d; break; }                   // KO
        else if (op == 12) { pc++; }                                    // PUT（GPU では捨てる）
        else { rep = %(r_end)d; break; }
    }
    report[lane] = rep; steps[lane] = n;
}


// ===== 語が 64 bit で足りるときの道 =====
//
// Big R[NREG] は添字が命令から来るので、compiler が register に置けず local memory へ落ちる。
// (x << sb) と (y << sc) の大小を、整数として厳密に比べる（sb、sc は 0〜255）。
// commonc は比較の桁そろえを 256 − 深度 で出す。64 bit の左 shift ではそのまま溢れるので、
// 共通の桁を引いて、残る片側だけを動かす。溢れるときは、動かす側の符号が大小を決める。
__device__ __forceinline__ int cmp_sh(i64 x, int sb, i64 y, int sc) {
    int m = sb < sc ? sb : sc; sb -= m; sc -= m;
    if (sb == 0 && sc == 0) return (x > y) - (x < y);
    int flip = 1;
    if (sc > 0) { i64 t = x; x = y; y = t; sb = sc; flip = -1; }
    int r;
    if (x == 0) r = (0 > y) - (0 < y);
    else if (sb >= 63 || x > (i64)(0x7fffffffffffffffLL >> sb) || x < (i64)((-0x7fffffffffffffffLL - 1) >> sb)) r = (x > 0) - (x < 0);
    else { i64 s = x << sb; r = (s > y) - (s < y); }
    return flip * r;
}
// 一命令ごとに local への往復が入り、thread 一本の歩みが桁で遅くなる。
// 語を 64 bit に決め打てる場合は、register を shared memory の
//
//     R[k]  =  sreg[k * blockDim.x + threadIdx.x]
//
// へ置く。stride が blockDim.x なので bank が衝突せず、添字が動いても速い。
// 積が 64 bit を越えたら幅の報告で止める（意味は Big の道と同じ）。

extern "C" __global__
void lane64_run1(const i64 *prog, int ninsn, u64 *M, int words, int lanes, i64 budget,
                 int need, int work, int *report, i64 *steps,
                 const u64 *ROM, i64 romlo, i64 romn)
{
    extern __shared__ i64 sreg[];
    int lane = blockIdx.x * blockDim.x + threadIdx.x;
    if (lane >= lanes) return;
    i64 *R = sreg + threadIdx.x;
    const int rs = blockDim.x;
    int pc = 0; i64 n = 0; int rep = %(r_budget)d;
    while (n < budget) {
        n++;
        if (pc < 0 || pc >= ninsn) { rep = %(r_end)d; break; }
        const i64 *ins = prog + (size_t)pc * %(fields)d;
        int op = (int)ins[0], a = (int)ins[1], b = (int)ins[2], c = (int)ins[3];
        int sb = (int)ins[4], sc = (int)ins[5]; i64 im = ins[6];
        if (op == 0) { rep = %(r_end)d; break; }
        else if (op == 1) { R[a * rs] = im; pc++; }
        else if (op == 2) { R[a * rs] = (R[b * rs] << sb) + (R[c * rs] << sc); pc++; }
        else if (op == 3) {
            i64 x = R[b * rs], y = R[c * rs];
            u64 ux = (u64)(x < 0 ? -x : x), uy = (u64)(y < 0 ? -y : y);
            if (__umul64hi(ux, uy) || ((ux * uy) >> 63)) { rep = %(r_wide)d; break; }
            R[a * rs] = x * y; pc++;
        }
        else if (op == 4) { R[a * rs] = -R[b * rs]; pc++; }
        else if (op == 5) { pc += (cmp_sh(R[b * rs], sb, R[c * rs], sc) == 0) ? (int)im : 1; }
        else if (op == 6) { pc += (cmp_sh(R[b * rs], sb, R[c * rs], sc) < 0) ? (int)im : 1; }
        else if (op == 7) { pc += (int)im; }
        else if (op == 8) {
            i64 raw = R[b * rs];
            if (raw >= romlo) {                                         // 共有帯。lane で割らない
                i64 o = raw - romlo; if (o >= romn) { rep = %(r_end)d; break; }
                R[a * rs] = (i64)ROM[(size_t)o]; pc++;
            } else {
                i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; break; }
                R[a * rs] = (i64)M[(size_t)addr * (size_t)lanes + lane]; pc++;
            }
        }
        else if (op == 9) {
            i64 raw = R[b * rs];
            if (raw >= romlo) { rep = %(r_end)d; break; }               // 共有帯へは書けない
            i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; break; }
            M[(size_t)addr * (size_t)lanes + lane] = (u64)R[c * rs]; pc++;
        }
        else if (op == 10) { rep = %(r_ok)d; break; }
        else if (op == 11) { rep = %(r_ko)d; break; }
        else if (op == 12) { pc++; }
        else { rep = %(r_end)d; break; }
    }
    report[lane] = rep; steps[lane] = n;
}

// ===== 多数の lane が一つの仕事を分ける道 =====
//
// 段と段の間では、lane i が書いた値を lane j が読む。そのために
//
//   1. 共有帯へ書ける（既存の道は報告 45 で止める）
//   2. 書いた後に grid 全体で足並みを揃える
//
// の二つが要る。合図は「共有帯への書き込み」そのものにする。境界へ書く所が
// チェンバーの接合点なので、pc を外から指さなくて済む。全 lane が段ごとに
// ちょうど一度ずつ書く形の平文でだけ使える。
//
// 足並み揃えは世代を反転させる素朴な形。block が全部同時に載っていないと
// 止まるので、grid は device に載る数までに抑える（host 側で決める）。

__device__ __forceinline__ void gbar(int *cnt, int *gen, int nblocks)
{
    __syncthreads();
    if (threadIdx.x == 0) {
        int g = *((volatile int *)gen);
        __threadfence();
        if (atomicAdd(cnt, 1) == nblocks - 1) {
            *cnt = 0;
            __threadfence();
            atomicExch(gen, g + 1);
        } else {
            while (*((volatile int *)gen) == g) __threadfence();
        }
    }
    __syncthreads();
}

extern "C" __global__
void lane64_runb(const i64 *prog, int ninsn, u64 *M, int words, int lanes, i64 budget,
                 int need, int work, int *report, i64 *steps,
                 u64 *ROM, i64 romlo, i64 romn, int *cnt, int *gen, int nblocks)
{
    extern __shared__ i64 sregb[];
    int lane = blockIdx.x * blockDim.x + threadIdx.x;
    i64 *R = sregb + threadIdx.x;
    const int rs = blockDim.x;
    // 足並みを揃える以上、休んでいる thread を作れない。lanes は grid x block に
    // ちょうど合わせる（余りの lane は自分の席で同じ文を走らせる）。
    int pc = 0; i64 n = 0; int rep = %(r_budget)d;
    while (n < budget) {
        n++;
        if (pc < 0 || pc >= ninsn) { rep = %(r_end)d; break; }
        const i64 *ins = prog + (size_t)pc * %(fields)d;
        int op = (int)ins[0], a = (int)ins[1], b = (int)ins[2], c = (int)ins[3];
        int sb = (int)ins[4], sc = (int)ins[5]; i64 im = ins[6];
        if (op == 0) { rep = %(r_end)d; break; }
        else if (op == 1) { R[a * rs] = im; pc++; }
        else if (op == 2) { R[a * rs] = (R[b * rs] << sb) + (R[c * rs] << sc); pc++; }
        else if (op == 3) {
            i64 x = R[b * rs], y = R[c * rs];
            u64 ux = (u64)(x < 0 ? -x : x), uy = (u64)(y < 0 ? -y : y);
            if (__umul64hi(ux, uy) || ((ux * uy) >> 63)) { rep = %(r_wide)d; break; }
            R[a * rs] = x * y; pc++;
        }
        else if (op == 4) { R[a * rs] = -R[b * rs]; pc++; }
        else if (op == 5) { pc += (cmp_sh(R[b * rs], sb, R[c * rs], sc) == 0) ? (int)im : 1; }
        else if (op == 6) { pc += (cmp_sh(R[b * rs], sb, R[c * rs], sc) < 0) ? (int)im : 1; }
        else if (op == 7) { pc += (int)im; }
        else if (op == 8) {
            i64 raw = R[b * rs];
            if (raw >= romlo) {
                i64 o = raw - romlo; if (o >= romn) { rep = %(r_end)d; break; }
                R[a * rs] = (i64)ROM[(size_t)o]; pc++;
            } else {
                i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; break; }
                R[a * rs] = (i64)M[(size_t)addr * (size_t)lanes + lane]; pc++;
            }
        }
        else if (op == 9) {
            i64 raw = R[b * rs];
            if (raw >= romlo) {                    // 共有帯へ書く。ここが接合点
                i64 o = raw - romlo; if (o >= romn) { rep = %(r_end)d; break; }
                ROM[(size_t)o] = (u64)R[c * rs];
                pc++;
                __threadfence();
                gbar(cnt, gen, nblocks);
                continue;
            }
            i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; break; }
            M[(size_t)addr * (size_t)lanes + lane] = (u64)R[c * rs]; pc++;
        }
        else if (op == 10) { rep = %(r_ok)d; break; }
        else if (op == 11) { rep = %(r_ko)d; break; }
        else if (op == 12) { pc++; }
        else { rep = %(r_end)d; break; }
    }
    report[lane] = rep; steps[lane] = n;
}

// ===== warp を pc の小さい順にそろえて歩く道 =====
//
// thread ごとに好きに飛ぶと、warp の中で pc が割れた瞬間から命令が直列になり、
// 語の読みも散って memory に縛られる（電力 50 W で頭打ち）。
// 20 §6 命題 6.1: 合流は最も小さい pc から取れば足りる。warp の中で最小の pc を
// 一つ選び、そこに居る lane だけが一命令進む。分岐で割れても、後ろの lane が
// 先に追いつくので、loop の出口で自然に合流する。

extern "C" __global__
void lane64_run1_sync(const i64 *prog, int ninsn, u64 *M, int words, int lanes, i64 budget,
                      int need, int work, int *report, i64 *steps,
                      const u64 *ROM, i64 romlo, i64 romn, int stride)
{
    // stride は語の帯の中の lane の数（M2 の列数）。lanes はいま走らせる lane の数で、
    // 先頭から lanes 本だけが歩く。段を長さの順に並べておけば、短い段が終わった後の
    // 歩は先頭の生きている lane だけで済む
    extern __shared__ i64 sreg[];
    int lane = blockIdx.x * blockDim.x + threadIdx.x;
    bool alive = lane < lanes;
    i64 *R = sreg + threadIdx.x;
    const int rs = blockDim.x;
    int pc = 0; i64 n = 0; int rep = %(r_budget)d;
    bool done = !alive;
    while (true) {
        unsigned live = __ballot_sync(0xffffffffu, !done);
        if (live == 0) break;
        int mypc = done ? 0x7fffffff : pc;
        int pcmin = __reduce_min_sync(0xffffffffu, mypc);
        if (done || pc != pcmin) continue;
        n++;
        if (n > budget) { done = true; continue; }
        if (pc < 0 || pc >= ninsn) { rep = %(r_end)d; done = true; continue; }
        const i64 *ins = prog + (size_t)pc * %(fields)d;
        int op = (int)ins[0], a = (int)ins[1], b = (int)ins[2], c = (int)ins[3];
        int sb = (int)ins[4], sc = (int)ins[5]; i64 im = ins[6];
        if (op == 0) { rep = %(r_end)d; done = true; }
        else if (op == 1) { R[a * rs] = im; pc++; }
        else if (op == 2) { R[a * rs] = (R[b * rs] << sb) + (R[c * rs] << sc); pc++; }
        else if (op == 3) {
            i64 x = R[b * rs], y = R[c * rs];
            u64 ux = (u64)(x < 0 ? -x : x), uy = (u64)(y < 0 ? -y : y);
            if (__umul64hi(ux, uy) || ((ux * uy) >> 63)) { rep = %(r_wide)d; done = true; }
            else { R[a * rs] = x * y; pc++; }
        }
        else if (op == 4) { R[a * rs] = -R[b * rs]; pc++; }
        else if (op == 5) { pc += (cmp_sh(R[b * rs], sb, R[c * rs], sc) == 0) ? (int)im : 1; }
        else if (op == 6) { pc += (cmp_sh(R[b * rs], sb, R[c * rs], sc) < 0) ? (int)im : 1; }
        else if (op == 7) { pc += (int)im; }
        else if (op == 8) {
            i64 raw = R[b * rs];
            if (raw >= romlo) {
                i64 o = raw - romlo; if (o >= romn) { rep = %(r_end)d; done = true; }
                else { R[a * rs] = (i64)ROM[(size_t)o]; pc++; }
            } else {
                i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; done = true; }
                else { R[a * rs] = (i64)M[(size_t)addr * (size_t)stride + lane]; pc++; }
            }
        }
        else if (op == 9) {
            i64 raw = R[b * rs];
            if (raw >= romlo) { rep = %(r_end)d; done = true; }
            else {
                i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; done = true; }
                else { M[(size_t)addr * (size_t)stride + lane] = (u64)R[c * rs]; pc++; }
            }
        }
        else if (op == 10) { rep = %(r_ok)d; done = true; }
        else if (op == 11) { rep = %(r_ko)d; done = true; }
        else if (op == 12) { pc++; }
        else { rep = %(r_end)d; done = true; }
    }
    if (alive) { report[lane] = rep; steps[lane] = n; }
}

// ===== 1 つの仕事を block 内の lane が分ける道（広い語） =====
//
// block = 仕事一つ。共有帯（ROM）へ Store すると、それが接合点になり block 内の lane が揃う。
// lane は共有帯へ書いた回数が同じでなければならない（足並みは __syncthreads）。
// 共有帯の番地は仕事ごとに平文が決める。block をまたぐ読み書きは起きない。
extern "C" __global__
void lane64_runs(const i64 *prog, int ninsn, u64 *M, int words, int lanes, i64 budget,
                 int need, int work, int *report, i64 *steps,
                 volatile u64 *ROM, i64 romlo, i64 romn)
{
    int lane = blockIdx.x * blockDim.x + threadIdx.x;
    Big R[NREG];
    int pc = 0; i64 n = 0; int rep = %(r_budget)d;
    bool alive = lane < lanes;
    while (n < budget) {
        n++;
        if (pc < 0 || pc >= ninsn) { rep = %(r_end)d; break; }
        const i64 *ins = prog + (size_t)pc * %(fields)d;
        int op = (int)ins[0], a = (int)ins[1], b = (int)ins[2], c = (int)ins[3];
        int sb = (int)ins[4], sc = (int)ins[5]; i64 im = ins[6];
        if (op == 0) { rep = %(r_end)d; break; }
        else if (op == 1) { big_imm(R[a], im); pc++; }
        else if (op == 2) { Big x, y; big_shl(x, R[b], sb); big_shl(y, R[c], sc); big_add(R[a], x, y); pc++; }
        else if (op == 3) { Big t; if (big_mul(t, R[b], R[c])) { rep = %(r_wide)d; break; } R[a] = t; pc++; }
        else if (op == 4) { Big t; big_negate(t, R[b]); R[a] = t; pc++; }
        else if (op == 5) { Big x, y; big_shl(x, R[b], sb); big_shl(y, R[c], sc); pc += big_eq(x, y) ? (int)im : 1; }
        else if (op == 6) { Big x, y; big_shl(x, R[b], sb); big_shl(y, R[c], sc); pc += big_lt(x, y) ? (int)im : 1; }
        else if (op == 7) { pc += (int)im; }
        else if (op == 8) {
            i64 raw = (i64)R[b].v[0];
            if (raw >= romlo) {
                i64 o = raw - romlo; if (o >= romn) { rep = %(r_end)d; break; }
                volatile const u64 *w = ROM + (size_t)o * NLIMB;
                for (int i = 0; i < NLIMB; i++) R[a].v[i] = w[i]; pc++;
            } else {
                i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; break; }
                const u64 *w = M + ((size_t)addr * NLIMB) * (size_t)lanes + lane;
                for (int i = 0; i < NLIMB; i++) R[a].v[i] = w[(size_t)i * lanes]; pc++;
            }
        }
        else if (op == 9) {
            i64 raw = (i64)R[b].v[0];
            if (raw >= romlo) {                     // 共有帯へ書く。ここが接合点
                i64 o = raw - romlo; if (o >= romn) { rep = %(r_end)d; break; }
                volatile u64 *w = ROM + (size_t)o * NLIMB;
                for (int i = 0; i < NLIMB; i++) w[i] = R[c].v[i];
                pc++;
                __threadfence();
                __syncthreads();
                continue;
            }
            i64 addr = slot(raw, need, work, words); if (addr < 0) { rep = %(r_end)d; break; }
            u64 *w = M + ((size_t)addr * NLIMB) * (size_t)lanes + lane;
            for (int i = 0; i < NLIMB; i++) w[(size_t)i * lanes] = R[c].v[i]; pc++;
        }
        else if (op == 10) { rep = %(r_ok)d; break; }
        else if (op == 11) { rep = %(r_ko)d; break; }
        else if (op == 12) { pc++; }
        else { rep = %(r_end)d; break; }
    }
    if (alive) { report[lane] = rep; steps[lane] = n; }
}

extern "C" __global__
void gather(const u64 *M, int words, int lanes, const int *watch, int nwatch, u64 *out)
{
    int lane = blockIdx.x * blockDim.x + threadIdx.x;
    if (lane >= lanes) return;
    u64 *o = out + (size_t)lane * nwatch * NLIMB;
    for (int k = 0; k < nwatch; k++) {
        const u64 *w = M + ((size_t)watch[k] * NLIMB) * (size_t)lanes + lane;
        for (int i = 0; i < NLIMB; i++) o[k * NLIMB + i] = w[(size_t)i * lanes];
    }
}

// 先頭 lanes 本だけを集める。stride は帯の中の lane の数
extern "C" __global__
void gather_s(const u64 *M, int stride, int lanes, const int *watch, int nwatch, u64 *out)
{
    int lane = blockIdx.x * blockDim.x + threadIdx.x;
    if (lane >= lanes) return;
    u64 *o = out + (size_t)lane * nwatch;
    for (int k = 0; k < nwatch; k++) o[k] = M[(size_t)watch[k] * stride + lane];
}
"""

R_END = 45
_MOD = {}


# ===== block 内の即値を畳む =====
#
# commonc が出す lane64 の命令列は、番地を one の倍化と加算で組み立てる。
# CPU 側の vcpu.translate は block ごとに値を記号で追い、即値どうしの算術を
# 一つの即値へ畳む（casm.lane64.vn）。GPU の解釈器は命令を一つずつ歩くので、
# 同じ畳み込みを先に済ませておかないと、番地を綴る鎖がそのまま実行費用になる。
#
#   R1 = 1 ; R1 = R1+R1 ; ... ; R2 = R1+R3   →   R1 = 65554 の一命令
#
# block の入口で値が分かっている register は無い、として始める。分岐は畳まない。

MAT, ADD, MUL, NEG, EQ, LT, JMP, LD, ST = 1, 2, 3, 4, 5, 6, 7, 8, 9
_BR = (EQ, LT, JMP)
_TERM = (0, 10, 11)


def leaders(prog):
    """block の先頭になる命令の番号"""
    out = set([0])
    for i, ins in enumerate(prog):
        op, im = ins[0], ins[6]
        if op in _BR:
            out.add(i + int(im))
            out.add(i + 1)
        elif op in _TERM:
            out.add(i + 1)
    return sorted(a for a in out if 0 <= a < len(prog))


def _reads(ins):
    op = ins[0]
    if op in (ADD, EQ, LT, MUL):
        return (ins[2], ins[3])
    if op in (NEG, LD):
        return (ins[2],)
    if op == ST:
        return (ins[2], ins[3])
    if op == 12:
        return (ins[2],)
    return ()


def _writes(ins):
    op = ins[0]
    return ins[1] if op in (MAT, ADD, MUL, NEG, LD) else None


def _walk(prog, lo, hi, live, dead, rewrite):
    """block をひと通り追う。live には「自分の Store より前に読んだ定数番地」を集め、
    rewrite が真なら即値の算術と語への往復を畳み、dead の番地への Store を落とす。"""
    val, mem = {}, {}
    for i in range(lo, hi):
        ins = prog[i]
        if ins is None:
            continue
        op = ins[0]
        if op == MAT:
            val[ins[1]] = int(ins[6])
        elif op in (ADD, MUL, NEG):
            b, c, sb, sc = ins[2], ins[3], ins[4], ins[5]
            vb = val.get(b)
            vc = val.get(c) if op != NEG else 0
            if vb is not None and vc is not None:
                v = (vb << sb) + (vc << sc) if op == ADD else (vb * vc if op == MUL else -vb)
                if -(1 << 63) <= v < (1 << 63):          # 即値は i64。収まらない畳み込みは命令のまま残す
                    if rewrite:
                        prog[i] = [MAT, ins[1], 0, 0, 0, 0, v]
                    val[ins[1]] = v
                else:
                    val.pop(ins[1], None)
            else:
                val.pop(ins[1], None)
        elif op == LD:
            a = val.get(ins[2])
            if a is not None and a in mem:
                if rewrite:
                    prog[i] = [MAT, ins[1], 0, 0, 0, 0, mem[a]]
                val[ins[1]] = mem[a]
            else:
                if a is not None:
                    live.add(a)
                val.pop(ins[1], None)
        elif op == ST:
            a, v = val.get(ins[2]), val.get(ins[3])
            if a is None:
                mem.clear()
            elif v is None:
                mem.pop(a, None)
            else:
                mem[a] = v
            # 同じ block の Load は先に繋いでから落とす。落とすのは block を跨ぐ分だけ
            if rewrite and a is not None and a in dead:
                prog[i] = None
        else:
            w = _writes(ins)
            if w is not None:
                val.pop(w, None)


def fold(prog, wires=None):
    """block の中で値を記号で追い、即値どうしの算術と語への往復を畳む。意味は変わらない。

    lane64 の一箱は MAT・ST・LD の往復に開くので、register だけを追っても畳めない。
    定数番地への Store と、その番地からの Load を繋いで初めて鎖が一つの即値になる。
    """
    prog = [list(x) for x in prog]
    heads = leaders(prog) + [len(prog)]

    # 一巡目。block を跨いで読まれる定数番地を集める
    live = set()
    for k in range(len(heads) - 1):
        _walk(prog, heads[k], heads[k + 1], live, (), False)

    # commonc が出すワイヤの番地は定数だけで、本文の番地は WORK 以上にある。
    # だから [64, need) のうち誰も跨いで読まない番地への Store は落としてよい
    dead = set()
    if wires:
        lo, hi = wires
        dead = set(a for a in range(lo, hi) if a not in live)

    # 二巡目。畳んで、死んだ Store を落とす
    for k in range(len(heads) - 1):
        lo, hi = heads[k], heads[k + 1]
        _walk(prog, lo, hi, set(), dead, True)
    # block の中だけの死んだ書き込みを落とす
    for k in range(len(heads) - 1):
        lo, hi = heads[k], heads[k + 1]
        last, drop = {}, set()
        for i in range(lo, hi):
            ins = prog[i]
            if ins is None:
                continue
            for r in _reads(ins):
                last.pop(r, None)
            w = _writes(ins)
            if w is not None:
                if ins[0] == MAT and w in last:
                    drop.add(last[w])
                last[w] = i if ins[0] == MAT else None
                if last[w] is None:
                    last.pop(w)
        for i in drop:
            prog[i] = None
    # 落とした分だけ番号が詰まるので、分岐の変位を貼り直す
    keep = [i for i, x in enumerate(prog) if x is not None]
    newpos, n = {}, 0
    for i in range(len(prog)):
        newpos[i] = n
        if prog[i] is not None:
            n += 1
    newpos[len(prog)] = n
    out = []
    for i in keep:
        ins = list(prog[i])
        if ins[0] in _BR:
            ins[6] = newpos[min(i + int(ins[6]), len(prog))] - newpos[i]
        out.append(tuple(ins))
    return out


def compact(prog, wires, work=0):
    """ワイヤの番地を詰める。返りは (prog, 新しい need)。

    commonc の一箱はワイヤ一本を語 64 + w に取るので、image が大きいと lane ごとの
    ワイヤの帯が数万語になる。畳んだ後に生き残る番地はその一部なので、番地として
    使われている即値だけを 64 から順に付け直す。

    即値が番地か値かは block の中の使われ方で決める。MAT で置いた register が、
    上書きされるまでに LD / ST の番地としてしか使われなければ番地。値として
    使われた即値は触らない。触らない即値がワイヤの帯に残れば、need は
    その最大までしか下がらない（返りの need がそれを示す）。
    """
    lo, hi = wires
    # 二値の八箱の退避語は定数番地の最大の上に置かれ、ワイヤの帯と本文の間の穴に落ちる
    # ことがある（16 §5.3）。穴は lane に無いので、そこも一緒に詰める
    hi = max(hi, work) if work else hi
    prog = [list(x) for x in prog]
    heads = leaders(prog) + [len(prog)]
    addr_mats, keep_hi = [], lo
    for k in range(len(heads) - 1):
        a, b = heads[k], heads[k + 1]
        for i in range(a, b):
            ins = prog[i]
            if ins[0] != MAT or not (lo <= ins[6] < hi):
                continue
            reg, ok, closed = ins[1], True, False
            for j in range(i + 1, b):
                jn = prog[j]
                op = jn[0]
                if op in (LD, ST) and jn[2] == reg and not (op == ST and jn[3] == reg):
                    pass
                elif reg in _reads(jn):
                    ok = False
                    break
                if _writes(jn) == reg:
                    closed = True
                    break
            # block の外へ出る register は次の block でも番地として使われる（commonc は
            # ワイヤの番地を定数でしか作らない）。値として読まれた即値だけを残す
            if ok:
                addr_mats.append(i)
            else:
                keep_hi = max(keep_hi, ins[6] + 1)
    used = sorted(set(prog[i][6] for i in addr_mats))
    base = keep_hi
    remap = {a: base + k for k, a in enumerate(used)}
    for i in addr_mats:
        prog[i][6] = remap[prog[i][6]]
    return [tuple(x) for x in prog], base + len(used)


def _module(cp, nlimb):
    if nlimb not in _MOD:
        src = SRC % {"nlimb": nlimb, "fields": INSN_FIELDS, "r_ok": R_OK, "r_ko": R_KO,
                     "r_wide": R_WIDE, "r_budget": R_BUDGET, "r_end": R_END}
        _MOD[nlimb] = cp.RawModule(code=src, options=("-std=c++11",))
    return _MOD[nlimb]


def to_limbs(v, nlimb):
    """整数を limb の並びへ（二の補数）"""
    mask = (1 << (64 * nlimb)) - 1
    x = v & mask
    return [(x >> (64 * i)) & 0xFFFFFFFFFFFFFFFF for i in range(nlimb)]


def from_limbs(limbs, nlimb):
    x = 0
    for i, l in enumerate(limbs):
        x |= int(l) << (64 * i)
    if x >> (64 * nlimb - 1):
        x -= 1 << (64 * nlimb)
    return x


_NOROM_BUF = {}


def _NOROM(cp):
    """共有帯を使わないときに渡す一語の置き場。kernel は romlo = 2^62 で触らない"""
    if "b" not in _NOROM_BUF:
        _NOROM_BUF["b"] = cp.zeros((1,), dtype=cp.uint64)
    return _NOROM_BUF["b"]


def pack(addr, need, work):
    """語番号 → 詰めた並びの位置。kernel の slot() と同じ式（式は device 側 §slot）。"""
    if work == 0:
        return addr
    if 0 <= addr < need:
        return addr
    return addr - work + need



def run(prog, seeds, words, watch, nlimb=16, budget=1 << 26, chunk=64, need=0, work=0,
        base=None):
    """image（decode 済み）を seeds の lane 分だけ走らせる。

    seeds は lane ごとの {語: 値}、watch は host へ戻す語の並び。
    返りは lane ごとの (報告, {語: 値})。報告は 0 = tu、42 = te、43 = 幅を越えた、44 = 歩数の上限。

    base は全 lane へ同じ値を置く語（{語: 値}）。模型の表のように lane ごとに同じ物を
    渡すとき、seeds へ毎回入れると host の側だけで lane × 語 の手間になる。ここでは
    語ごとに一度だけ device の帯へ書くので、手間は語の数で済む。

    need と work を渡すと、ワイヤ（0 .. need）と本文の作業領域（work 以上）の間の穴を詰める。
    commonc の lane64 版は本文を WORK = 2^16 から置くので、詰めないと lane ごとに
    65536 語ぶんの空きを確保することになる（20 §1.2 の lane の作業領域は交わらない）。

        words = need + (本文が使う語の数)

    穴を詰めると lane あたりの領域が減り、同じ memory でより多くの lane を並べられる。
    """
    import cupy as cp
    mod = _module(cp, nlimb)
    k_run = mod.get_function("lane64_run1" if nlimb == 1 else "lane64_run")
    k_gather = mod.get_function("gather")
    prog = fold(prog)
    table = np.array([list(p) for p in prog], dtype=np.int64).reshape(-1)
    d_prog = cp.asarray(table)
    d_watch = cp.asarray(np.array([pack(w, need, work) for w in watch], dtype=np.int32))
    out = []
    for start in range(0, len(seeds), chunk):
        part = seeds[start:start + chunk]
        lanes = len(part)
        M = cp.zeros((lanes * words * nlimb,), dtype=cp.uint64)
        if base:
            for addr, v in base.items():
                a = pack(addr, need, work)
                v = int(v)
                if 0 <= v < (1 << 63):
                    M[(a * nlimb) * lanes:(a * nlimb) * lanes + lanes] = np.uint64(v)
                else:
                    for i, limb in enumerate(to_limbs(v, nlimb)):
                        if limb:
                            o = (a * nlimb + i) * lanes
                            M[o:o + lanes] = np.uint64(limb)
        idx, vals = [], []
        for l, seed in enumerate(part):
            for addr, v in seed.items():
                a = pack(addr, need, work)
                v = int(v)
                if 0 <= v < (1 << 63):
                    idx.append((a * nlimb) * lanes + l)
                    vals.append(v)
                else:
                    for i, limb in enumerate(to_limbs(v, nlimb)):
                        if limb:
                            idx.append((a * nlimb + i) * lanes + l)
                            vals.append(limb)
        if idx:
            M[cp.asarray(np.array(idx, dtype=np.int64))] = cp.asarray(np.array(vals, dtype=np.uint64))
        report = cp.zeros((lanes,), dtype=cp.int32)
        steps = cp.zeros((lanes,), dtype=cp.int64)
        threads = 128
        grid = (lanes + threads - 1) // threads
        sh = threads * NREG_BYTES if nlimb == 1 else 0
        k_run((grid,), (threads,), (d_prog, np.int32(len(prog)), M, np.int32(words), np.int32(lanes),
                                    np.int64(budget), np.int32(need), np.int32(work), report, steps,
                                    _NOROM(cp), np.int64(1 << 62), np.int64(0)),
              shared_mem=sh)
        got = cp.zeros((lanes * len(watch) * nlimb,), dtype=cp.uint64)
        if watch:
            k_gather((grid,), (threads,), (M, np.int32(words), np.int32(lanes), d_watch, np.int32(len(watch)), got))
        rep = report.get()
        raw = got.get()
        for l in range(lanes):
            vals_l = {}
            for k, w in enumerate(watch):
                o = (l * len(watch) + k) * nlimb
                vals_l[w] = from_limbs(raw[o:o + nlimb], nlimb)
            out.append((int(rep[l]), vals_l))
        del M, got
    return out


def run_shared(prog, base, lanes, words, watch, need, work, nlimb=4, budget=1 << 26,
               chunk=2048, romlo=None, romn=0):
    """lane が共有する種 base に、lane ごとの少しの語 lanes[k] を重ねて走らせる。

    語の並びは詰める: ワイヤ [0, need) をそのまま、作業領域 [work, ...) を need の後ろに置く。
    words は詰めた後の語数（need + 作業領域の幅）。平文の側の語は全部 work 以上にあるので、
    間の番地は使われない。返りは lane ごとの (報告, {語: 値})。

    romlo を渡すと、番地 [romlo, romlo + romn) は**全 lane で一枚だけ**持つ。
    読むだけの表（値段の表など）をここへ置くと、lane あたりの重さが桁で落ちる。

        lane あたりの語数 = need + (romlo - work)
        共有帯の語数     = romn

    この帯へ Store すると報告 45 で止まる。書く語を入れてはいけない。
    """
    import cupy as cp
    mod = _module(cp, nlimb)
    k_run = mod.get_function("lane64_run1" if nlimb == 1 else "lane64_run")
    k_gather = mod.get_function("gather")
    prog = fold(prog, wires=(64, need))
    table = np.array([list(p) for p in prog], dtype=np.int64).reshape(-1)
    d_prog = cp.asarray(table)
    hi = romlo if romlo is not None else (1 << 62)

    def pos(a):
        return a if a < need else a - work + need

    d_watch = cp.asarray(np.array([pos(w) for w in watch], dtype=np.int32))
    # 共有の種を一枚の並びにする。共有帯の分は別の並びへ分ける
    row = np.zeros((words * nlimb,), dtype=np.uint64)
    rom = np.zeros((max(1, romn) * nlimb,), dtype=np.uint64)
    for addr, v in base.items():
        v = int(v)
        p0 = (addr - hi) * nlimb if addr >= hi else pos(addr) * nlimb
        dst = rom if addr >= hi else row
        if 0 <= v < (1 << 63):
            dst[p0] = v
        else:
            for i, limb in enumerate(to_limbs(v, nlimb)):
                dst[p0 + i] = limb
    d_row = cp.asarray(row)
    d_rom = cp.asarray(rom)
    out = []
    for start in range(0, len(lanes), chunk):
        part = lanes[start:start + chunk]
        n = len(part)
        M = cp.repeat(d_row, n)
        idx, vals = [], []
        for l, seed in enumerate(part):
            for addr, v in seed.items():
                idx.append((pos(addr) * nlimb) * n + l)
                vals.append(int(v))
        if idx:
            M[cp.asarray(np.array(idx, dtype=np.int64))] = cp.asarray(np.array(vals, dtype=np.uint64))
        report = cp.zeros((n,), dtype=cp.int32)
        steps = cp.zeros((n,), dtype=cp.int64)
        threads = 128
        grid = (n + threads - 1) // threads
        sh = threads * NREG_BYTES if nlimb == 1 else 0
        k_run((grid,), (threads,), (d_prog, np.int32(len(prog)), M, np.int32(words), np.int32(n),
                                    np.int64(budget), np.int32(need), np.int32(work), report, steps,
                                    d_rom, np.int64(hi), np.int64(romn)),
              shared_mem=sh)
        got = cp.zeros((n * len(watch) * nlimb,), dtype=cp.uint64)
        k_gather((grid,), (threads,), (M, np.int32(words), np.int32(n), d_watch, np.int32(len(watch)), got))
        rep = report.get()
        raw = got.get().reshape(n, len(watch), nlimb)
        for l in range(n):
            out.append((int(rep[l]), dict((w, from_limbs(raw[l, k], nlimb)) for k, w in enumerate(watch))))
        del M, got
    return out



def run_sync(prog, base, lanes, words, watch, need, work, nlimb=4, budget=1 << 26,
             block=16, romlo=None, romn=0, rom_init=None):
    """block 本ごとに仕事一つ。block 内の lane が共有帯（romlo 以上）を介して分け合う。

    lanes は lane ごとの種（{語: 値}）の並びで、長さは block の倍数。共有帯 rom は全 block で一枚で、
    番地は仕事ごとに平文が分ける。返りは (lane ごとの (報告, {語: 値}), 共有帯の内容)。
    共有帯へ Store するたびに block 内で足並みが揃うので、全 lane が同じ回数だけ書くこと。
    """
    import cupy as cp
    mod = _module(cp, nlimb)
    k_run = mod.get_function("lane64_runs")
    k_gather = mod.get_function("gather")
    assert len(lanes) % block == 0
    prog = fold(prog, wires=(64, need))
    d_prog = cp.asarray(np.array([list(p) for p in prog], dtype=np.int64).reshape(-1))
    hi = romlo
    def pos(a):
        return a if a < need else a - work + need
    d_watch = cp.asarray(np.array([pos(w) for w in watch], dtype=np.int32))
    row = np.zeros((words * nlimb,), dtype=np.uint64)
    rom = np.zeros((max(1, romn) * nlimb,), dtype=np.uint64)
    for addr, v in base.items():
        v = int(v)
        dst = rom if addr >= hi else row
        p0 = (addr - hi) * nlimb if addr >= hi else pos(addr) * nlimb
        for i, limb in enumerate(to_limbs(v, nlimb)):
            dst[p0 + i] = limb
    if rom_init is not None:
        for off, v in rom_init.items():
            for i, limb in enumerate(to_limbs(int(v), nlimb)):
                rom[off * nlimb + i] = limb
    n = len(lanes)
    M = cp.repeat(cp.asarray(row), n)
    idx, vals = [], []
    for l, seed in enumerate(lanes):
        for addr, v in seed.items():
            for i, limb in enumerate(to_limbs(int(v), nlimb)):
                if limb:
                    idx.append((pos(addr) * nlimb + i) * n + l); vals.append(limb)
    if idx:
        M[cp.asarray(np.array(idx, dtype=np.int64))] = cp.asarray(np.array(vals, dtype=np.uint64))
    d_rom = cp.asarray(rom)
    report = cp.zeros((n,), dtype=cp.int32)
    steps = cp.zeros((n,), dtype=cp.int64)
    ev0, ev1 = cp.cuda.Event(), cp.cuda.Event()
    ev0.record()
    k_run((n // block,), (block,), (d_prog, np.int32(len(prog)), M, np.int32(words), np.int32(n),
                                    np.int64(budget), np.int32(need), np.int32(work), report, steps,
                                    d_rom, np.int64(hi), np.int64(romn)))
    ev1.record(); ev1.synchronize()
    run_sync.kernel_ms = cp.cuda.get_elapsed_time(ev0, ev1)      # kernel だけの経過時間（ms）
    run_sync.steps = steps.get()
    got = cp.zeros((n * len(watch) * nlimb,), dtype=cp.uint64)
    if watch:
        k_gather((n // 128 + 1,), (128,), (M, np.int32(words), np.int32(n), d_watch, np.int32(len(watch)), got))
    rep = report.get()
    raw = got.get().reshape(n, len(watch), nlimb)
    out = []
    for l in range(n):
        out.append((int(rep[l]), dict((w, from_limbs(raw[l, k], nlimb)) for k, w in enumerate(watch))))
    romv = d_rom.get().reshape(-1, nlimb)
    return out, [from_limbs(r, nlimb) for r in romv]


class Lanes(object):
    """lane の作業領域と共有帯を device に置いたまま、image を何度も流す。

    host は語を一つずつ触らない。種は (lane, 語, 値) の並びを一度に散らし、読みは
    (lane × 語) の並びを一度に集める。どちらも cupy の一手で済むので、lane の数にも
    語の数にも Python の反復が付かない。

        L = Lanes(prog, need, work, romlo, romn, nlanes, base={語: 値})
        L.put(lanes, addrs, vals)          種を散らす（三つとも同じ長さの並び）
        L.rom_put(offset, values)          共有帯の一部を書く
        rep, W = L.run(watch)              rep[lane] が報告、W[lane, k] が watch[k] の値（device）
        L.M2                               語 × lane の二次元の眺め（device）
        L.reset()                          作業領域を base の並びへ戻す

    語の並びは run_shared と同じ: ワイヤ [0, need) をそのまま、作業領域 [work, romlo) を
    need の後ろに詰める。M は語主で M2[pos(語), lane]。

    共有帯 rom は cupy の並び一枚。別の Lanes の M をそのまま rom に渡せる（rom=）ので、
    lane の畳みのように「全 lane の語を読む」kernel は、その M を共有帯として読めば書ける。
    """

    def __init__(self, prog, need, work, romlo, romn, nlanes, base=None, nlimb=1, rom=None, sync=True):
        """sync が真なら warp を pc の小さい順にそろえて歩く（lane64_run1_sync）。"""
        import cupy as cp
        self.cp = cp
        if nlimb != 1:
            raise ValueError("Lanes は 64 bit の語だけを扱う（nlimb=1）")
        self.need, self.work, self.romlo = need, work, romlo
        self.words = need + (romlo - work)
        self.n = nlanes
        mod = _module(cp, 1)
        self.sync = sync
        self.k_run = mod.get_function("lane64_run1_sync" if sync else "lane64_run1")
        self.k_gather = mod.get_function("gather_s")
        prog = fold(prog, wires=(64, need))
        prog, need = compact(prog, (64, need), work=work)
        self.need = need
        self.words = need + (romlo - work)
        self.nprog = len(prog)
        self.d_prog = cp.asarray(np.array([list(p) for p in prog], dtype=np.int64).reshape(-1))
        if rom is not None:
            self.d_rom = rom
            self.romn = int(rom.size)
        else:
            self.romn = romn
            self.d_rom = cp.zeros((max(1, romn),), dtype=cp.uint64)
        row = np.zeros((self.words,), dtype=np.uint64)
        for addr, v in (base or {}).items():
            row[self.pos(addr)] = int(v)
        self.d_row = cp.asarray(row)
        self.M = cp.zeros((self.words * nlanes,), dtype=cp.uint64)
        self.reset()

    def pos(self, a):
        return a if a < self.need else a - self.work + self.need

    @property
    def M2(self):
        return self.M.reshape(self.words, self.n)

    def reset(self):
        self.M2[:, :] = self.d_row.reshape(-1, 1)

    def put(self, lanes, addrs, vals):
        """(lane, 語, 値) の並びを一度に散らす。addrs は語番号（pos は中で当てる）。"""
        cp = self.cp
        lanes = cp.asarray(np.asarray(lanes, dtype=np.int64))
        addrs = np.asarray(addrs, dtype=np.int64)
        addrs = np.where(addrs < self.need, addrs, addrs - self.work + self.need)
        idx = cp.asarray(addrs) * self.n + lanes
        self.M[idx] = cp.asarray(np.asarray(vals, dtype=np.uint64))

    def put_block(self, addr, block):
        """語 addr から続く語の帯へ、(語数 × lane) の並びを一度に置く。block は device でも host でもよい。"""
        cp = self.cp
        b = cp.asarray(block, dtype=cp.uint64)
        self.M2[self.pos(addr):self.pos(addr) + b.shape[0], :] = b

    def get_block(self, addr, n):
        """語 addr から n 語の帯を (n × lane) で返す（device）。"""
        return self.M2[self.pos(addr):self.pos(addr) + n, :]

    def rom_put(self, offset, values):
        self.d_rom[offset:offset + len(values)] = self.cp.asarray(np.asarray(values, dtype=np.uint64))

    def launch(self, budget=1 << 36, active=None):
        """先頭 active 本の lane を走らせる kernel を投げる。完了を待たず、報告の配列 (device) を返す。現在の stream で動く。"""
        cp = self.cp
        n = self.n if active is None else min(active, self.n)
        report = cp.zeros((n,), dtype=cp.int32)
        steps = cp.zeros((n,), dtype=cp.int64)
        threads = 128
        grid = (n + threads - 1) // threads
        if self.sync:
            args = (self.d_prog, np.int32(self.nprog), self.M, np.int32(self.words), np.int32(n),
                    np.int64(budget), np.int32(self.need), np.int32(self.work), report, steps,
                    self.d_rom, np.int64(self.romlo), np.int64(self.romn), np.int32(self.n))
        else:
            if n != self.n:
                raise ValueError("先頭だけを走らせるには sync の道が要る")
            args = (self.d_prog, np.int32(self.nprog), self.M, np.int32(self.words), np.int32(n),
                    np.int64(budget), np.int32(self.need), np.int32(self.work), report, steps,
                    self.d_rom, np.int64(self.romlo), np.int64(self.romn))
        self.k_run((grid,), (threads,), args, shared_mem=threads * NREG_BYTES)
        return report

    def run(self, watch=(), budget=1 << 36, active=None):
        """先頭 active 本の lane を走らせる（省くと全部）。返りは (報告, watch の値) で、どちらも active 本ぶん。"""
        cp = self.cp
        n = self.n if active is None else min(active, self.n)
        report = self.launch(budget, active)
        W = None
        if watch:
            threads = 128
            grid = (n + threads - 1) // threads
            d_watch = cp.asarray(np.array([self.pos(w) for w in watch], dtype=np.int32))
            got = cp.zeros((n * len(watch),), dtype=cp.uint64)
            self.k_gather((grid,), (threads,), (self.M, np.int32(self.n), np.int32(n), d_watch,
                                                np.int32(len(watch)), got))
            W = got.reshape(n, len(watch)).astype(cp.int64)
        return report.get(), W
