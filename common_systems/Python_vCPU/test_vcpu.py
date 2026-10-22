# -*- coding: utf-8 -*-
"""lane64 の実行台の検査。docs/common-compiler/arch/20 §10 の表に対応する。

  (40.1)  Dec(Enc(i)) = (i, 16)
  (30.4)  Enc(Dec(X)) = X
  (43.2)  実行の観測が意味の観測に一致する
  (21.1)  W > 1 の lane ごとの観測が W = 1 と一致する
  (6.1)   解釈器（mask 付き）と翻訳器（lane ごと）の観測が一致する

image は builds/examples と builds/common-assembler から拾う。
無ければ tools/Run.ps1 が先に compile する。

  python test_vcpu.py [image を置いた directory]
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vcpu


ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    '..', '..', '..'))

# (image の名前, 語数, 期待する報告, 期待する語, 期待する Put の byte 列)
CASES = [
    ('dyadic_series-lane64.bin', 4096, 0, {}, b''),
    ('eratosthenes-lane64.bin', 4096, 0, {0: 200, 2: 46, 3: 200}, b''),
    ('put-lane64.bin', 4096, 0, {}, b'Hi\n'),
]


def _find(name):
    for d in ('builds/examples', 'builds/common-assembler', 'builds/lane64'):
        p = os.path.join(ROOT, d, name)
        if os.path.exists(p):
            return p
    return None


def check(name, words, want_rep, want_work, want_out):
    p = _find(name)
    if p is None:
        return ['--   %s が無い' % name]
    with open(p, 'rb') as f:
        image = f.read()
    prog = vcpu.decode(image)
    msg = []

    # 式 (40.1)、(30.4)
    if vcpu.encode(prog) != image:
        msg.append('te   %s: 符号と復号が往復しない（式 40.1、30.4）' % name)

    # 翻訳器（式 43.2）
    vm = vcpu.VCPU(1)
    res = vm.run(image, lanes=1, words=words, head=8)
    rep, out, head, _em, _b = res[0]
    if rep != want_rep:
        msg.append('te   %s: 報告 %s（期待 %s）' % (name, rep, want_rep))
    for k, v in sorted(want_work.items()):
        if head[k] != v:
            msg.append('te   %s: w[%d] = %d（期待 %d）' % (name, k, head[k], v))
    if out != want_out:
        msg.append('te   %s: Put の byte 列 %r（期待 %r）' % (name, out, want_out))

    # 命題 6.1: 解釈器と一致する
    it = vcpu.Interp(prog, lanes=1, words=words)
    irep = it.run()
    if irep[0] != rep:
        msg.append('te   %s: 解釈器の報告 %s が翻訳器の %s と違う（命題 6.1）'
                   % (name, irep[0], rep))
    if bytes(it.OUT[0]) != out:
        msg.append('te   %s: 解釈器の Put が翻訳器と違う（命題 6.1）' % name)
    for k in range(8):
        if it.M[0][k] != head[k]:
            msg.append('te   %s: 解釈器の w[%d] が翻訳器と違う（命題 6.1）' % (name, k))
            break

    # 式 (21.1): lane を増やしても各 lane の観測が変わらない
    many = vm.run(image, lanes=4, words=words, head=8)
    for l, (r2, o2, h2, _e2, _b2) in enumerate(many):
        if (r2, o2, h2) != (rep, out, head):
            msg.append('te   %s: lane %d の観測が W=1 と違う（式 21.1）' % (name, l))
            break

    # 解釈器の側でも lane を増やす
    it4 = vcpu.Interp(prog, lanes=4, words=words)
    rep4 = it4.run()
    if any(r != rep for r in rep4):
        msg.append('te   %s: 解釈器を W=4 にすると報告が割れる（式 21.1）' % name)

    if not msg:
        _, _, bl = vcpu.blocks(prog)
        wide = max((max((len(l) for l in vcpu.layers(prog, b)), default=0)
                    for _pc, b, _t, _s in bl), default=0)
        msg.append('tu   %-28s 箱 %4d  block %3d  層の最大幅 %d'
                   % (name, len(prog), len(bl), wide))
    return msg


def bench():
    """常駐 pool の効き方（式 0.4）。同じ image を二度走らせて立ち上げを分ける。"""
    p = _find('eratosthenes-lane64.bin')
    if p is None:
        return ['--   bench の image が無い']
    with open(p, 'rb') as f:
        image = f.read()
    out = []
    for P in (1, os.cpu_count() or 1):
        vm = vcpu.VCPU(P)
        t0 = time.perf_counter()
        vm.run(image, lanes=P, words=4096)
        t1 = time.perf_counter()
        vm.run(image, lanes=P, words=4096)
        t2 = time.perf_counter()
        vm.close()
        out.append('     process %d  一度目 %.3f 秒（立ち上げ込み） 二度目 %.3f 秒'
                   % (P, t1 - t0, t2 - t1))
    return out


def main(argv):
    bad = 0
    for name, words, rep, work, o in CASES:
        for line in check(name, words, rep, work, o):
            print(line)
            if line.startswith('te'):
                bad += 1
    print('-- 常駐 pool --')
    for line in bench():
        print(line)
    print()
    if bad:
        print('te   %d 件が不一致' % bad)
        return 1
    print('tu   翻訳器と解釈器の観測が一致し、lane を広げても変わらない')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
