# -*- coding: utf-8 -*-
"""python -m common_qbit.qpu run|analyze

    run <置き場> --backend ibm:<名前>|fake|lane-qbit --shots N [--estimate K --repeat r]
        一つの回路を一つの job で走らせ、<置き場>/run.json に shot ごとの bitstring を置く
    analyze <置き場>
        <置き場>/run.json を読み、候補ごとの u0 の領域を <置き場>/report.md に置く

語は論文 9.5 の例から取る（往復回転、エコー、同じユニタリの別分解）。候補は、全部の語が f = 1 のものと、
語を一つずつ f = 2、1/2 にしたもの。
"""
import argparse
import json
import math
import os
from fractions import Fraction

from qiskit import QuantumCircuit

from .analyze import analyze, report
from .experiment import Experiment, Word, build
from .run import run_ibm, run_local


def _word(name, ops):
    qc = QuantumCircuit(1, name=name)
    for gate, args in ops:
        getattr(qc, gate)(*args, 0)
    return Word(name, qc)


WORDS = (
    _word("rz_pair", [("rz", (math.pi / 4,)), ("rz", (-math.pi / 4,))]),
    _word("echo", [("x", ()), ("x", ())]),
    _word("sx4", [("sx", ())] * 4),
)


def experiment(estimate, repeat):
    return Experiment(estimate=estimate, words=WORDS, repeat=repeat, reestimate=estimate)


def candidates():
    out = {"f=1": {}}
    for w in WORDS:
        for f in (Fraction(2), Fraction(1, 2)):
            out["%s f=%s" % (w.name, f)] = {w.name: f}
    return out


def _device(name):
    if name == "lane-qbit":
        from .. import CommonQbitBackend
        return CommonQbitBackend(), {"reset": "consume", "actions": {}}
    if name == "fake":
        from qiskit_aer import AerSimulator
        from qiskit_ibm_runtime.fake_provider import FakeFez
        return AerSimulator.from_backend(FakeFez()), {}
    raise ValueError("装置の名前: lane-qbit、fake、ibm:<名前>")


def cmd_run(args):
    exp = experiment(args.estimate, args.repeat)
    circuit = build(exp)
    if args.backend.startswith("ibm:"):
        bitstrings = run_ibm(circuit, args.backend[4:], args.shots)
    else:
        device, options = _device(args.backend)
        bitstrings = run_local(circuit, device, args.shots, **options)
    os.makedirs(args.root, exist_ok=True)
    with open(os.path.join(args.root, "run.json"), "w", encoding="utf-8") as f:
        json.dump({"backend": args.backend, "shots": args.shots, "estimate": args.estimate,
                   "repeat": args.repeat, "bitstrings": bitstrings}, f, indent=1)


def cmd_analyze(args):
    with open(os.path.join(args.root, "run.json"), encoding="utf-8") as f:
        run = json.load(f)
    exp = experiment(run["estimate"], run["repeat"])
    table = report(analyze(exp, candidates(), run["bitstrings"]))
    with open(os.path.join(args.root, "report.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("# %s、%d shot\n\n%s\n" % (run["backend"], run["shots"], table))
    print(table)


def main():
    p = argparse.ArgumentParser(prog="python -m common_qbit.qpu")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("root")
    r.add_argument("--backend", required=True)
    r.add_argument("--shots", type=int, default=16)
    r.add_argument("--estimate", type=int, default=8)
    r.add_argument("--repeat", type=int, default=4)
    a = sub.add_parser("analyze")
    a.add_argument("root")
    args = p.parse_args()
    {"run": cmd_run, "analyze": cmd_analyze}[args.cmd](args)


if __name__ == "__main__":
    main()
