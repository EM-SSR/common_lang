# -*- coding: utf-8 -*-
"""Qiskit バックエンド。回路を lane-qbit の image にして、shot ごとの測定座標 u0 で走らせる。

doc: casm.lane64.host

    backend = CommonQbitBackend()
    backend.run(circuit, shots=1024, seed_simulator=7).result().get_counts()
    backend.run(circuit, shots=2, initial_u0=[Fraction(1, 4), Fraction(3, 4)], memory=True)

一回の実行の結果は u0 だけで決まる（論文 3.6）。initial_u0 を渡さない実行では、seed_simulator から
62 桁の二進有理数を shot の数だけ作る（論文 3.11 の準備測度）。

オプション
    shots, seed_simulator, initial_u0, memory
    reset   リセットが測定座標にする作用の候補（circuit.image.RESET_CANDIDATES）。論文に形が無いので、
            リセットを含む回路では必ず明示する
    actions ゲートの後に測定座標へ当てる作用の候補。ゲートの名前から ("mobius", f) か ("beta", a) への辞書
            （f、a は有理数。論文 16.5、1.11）。形は論文に無いので必ず明示する。結合を零に置く（論文 14.1）なら {}
"""
import numbers
import random
import time
import uuid
import warnings
from fractions import Fraction

from qiskit.circuit import Measure, Reset
from qiskit.circuit.library import get_standard_gate_name_mapping
from qiskit.providers import BackendV2, JobStatus, JobV1, Options
from qiskit.result import Result
from qiskit.transpiler import Target

from common_vcpu import vqpu

from .circuit.gates import CounterBeta, CounterMobius, CounterTransport
from .circuit.image import ACTION_KINDS, compile_cmn
from .circuit.state import saved_state
from .circuit.transcribe import circuit_to_cmn


class CommonQbitJob(JobV1):
    """同期で走らせた結果を持つ job。"""

    def __init__(self, backend, job_id, result):
        super().__init__(backend, job_id)
        self._result = result

    def result(self):
        return self._result

    def status(self):
        return JobStatus.DONE

    def submit(self):
        return None


def _target(num_qubits):
    """作図のあるゲートだけを載せる。"""
    target = Target(num_qubits=num_qubits)
    gates = get_standard_gate_name_mapping()
    for name in vqpu.GATES + ("rx", "ry", "rz", "u"):
        target.add_instruction(gates[name])
    target.add_instruction(Measure())
    target.add_instruction(Reset())
    target.add_instruction(CounterTransport(0), name="counter_transport")
    target.add_instruction(CounterBeta(), name="counter_beta")
    target.add_instruction(CounterMobius(1), name="counter_mobius")
    try:                              # Aer の保存命令（任意の幅）。Aer が無ければ載せない
        from qiskit_aer.library import SaveDensityMatrix, SaveStatevector
        target.add_instruction(SaveStatevector, name="save_statevector")
        target.add_instruction(SaveDensityMatrix, name="save_density_matrix")
    except ImportError:
        pass
    return target


def _u0_list(shots, u0s, seed):
    if u0s is not None:
        return [Fraction(u) for u in u0s[:shots]]
    rng = random.Random(seed)
    return [Fraction(rng.getrandbits(vqpu.DEPTH), 1 << vqpu.DEPTH) for _ in range(shots)]


GATE_CODES = dict(vqpu.GATE_ID, rx=12, ry=13, rz=14)


def _action_table(actions):
    """ゲートの名前 → 候補の作用、を image の表（ゲートの番号 → (種類, p1, p2)）にする。"""
    if actions is None:
        raise ValueError("actions を明示する。ゲートの後に測定座標を動かさないなら actions={}（論文 14.1）")
    table = {}
    for name, (kind, value) in actions.items():
        v = Fraction(value)
        if kind == "mobius" and v <= 0:
            raise ValueError("メビウス作用の f は正: %s" % v)
        table[GATE_CODES[name]] = (ACTION_KINDS[kind], v.numerator, v.denominator)
    return table


def _final_measures(circ):
    """測定が回路の最後にまとまっているか（最初の測定の後は、測定と barrier だけ）。"""
    seen = False
    for inst in circ.data:
        name = inst.operation.name
        if name == "measure":
            seen = True
        elif seen and name != "barrier":
            return False
    return seen


class CommonQbitBackend(BackendV2):
    def __init__(self, max_qubits=20):
        super().__init__(name="common_qbit", backend_version="0.3.0")
        self._target = _target(max_qubits)

    @property
    def target(self):
        return self._target

    @property
    def max_circuits(self):
        return None

    @classmethod
    def _default_options(cls):
        return Options(shots=1024, seed_simulator=None, initial_u0=None, memory=False, reset=None, actions=None)

    def run(self, run_input, **options):
        circuits = run_input if isinstance(run_input, (list, tuple)) else [run_input]
        opts = dict(self.options.__dict__)
        opts.update(options)
        shots = opts["shots"]
        if not isinstance(shots, numbers.Integral):
            warnings.warn("shots は整数で渡す: %r" % (shots,), DeprecationWarning, stacklevel=2)
            shots = int(float(shots))
        t0 = time.time()
        results = [self._run_circuit(circ, shots, opts, t0) for circ in circuits]
        job_id = uuid.uuid4().hex
        ok = [r["success"] for r in results]
        res = Result.from_dict({
            "backend_name": self.name, "backend_version": self.backend_version,
            "qobj_id": job_id, "job_id": job_id, "success": all(ok),
            "status": "COMPLETED" if all(ok) else "ERROR", "results": results})
        return CommonQbitJob(self, job_id, res)

    def _run_circuit(self, circ, shots, opts, t0):
        header = {"name": circ.name, "n_qubits": circ.num_qubits, "memory_slots": circ.num_clbits,
                  "creg_sizes": [[r.name, r.size] for r in circ.cregs],
                  "qreg_sizes": [[r.name, r.size] for r in circ.qregs]}
        text, clbits, angles, saves = circuit_to_cmn(circ)
        image, exports = compile_cmn(text, circ.num_qubits, opts["reset"], angles, _action_table(opts["actions"]))
        counts, memory, first = {}, [], None
        for report, out, h, _cl in vqpu.run(image, _u0_list(shots, opts["initial_u0"], opts["seed_simulator"])):
            if report not in ("ok", "end"):
                raise RuntimeError("lane-qbit の実行が失敗を報告した: %s" % report)
            first = h if first is None else first
            bits = [0] * circ.num_clbits
            for k, cb in enumerate(clbits):
                bits[cb] = out[k]
            key = hex(sum(b << j for j, b in enumerate(bits)))
            counts[key] = counts.get(key, 0) + 1
            memory.append(key)
        data = {"counts": counts, "counter": {"h": first}}
        branches = [rec[2] for rec in first if rec[0] == "V"]
        for (label, kind, _qubits), (nq, states), bi in zip(saves, exports, branches):
            data[label] = saved_state(kind, nq, states[bi], circ.num_qubits)
        if opts["memory"]:
            data["memory"] = memory
        return {"shots": shots, "success": True, "data": data, "header": header,
                "metadata": {"method": opts.get("method", "statevector"), "measure_sampling": _final_measures(circ)},
                "time_taken": time.time() - t0}
