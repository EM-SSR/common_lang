# -*- coding: utf-8 -*-
"""一つの回路を一つの job で走らせ、shot ごとの bitstring を返す。

    run_ibm     IBM の装置へ SamplerV2 で送る。job は一つだけで、途中で別の job を挟まない
    run_local   手元の装置（FakeFez の雑音つき Aer、または lane-qbit）で同じ回路を走らせる
"""
from typing import List

from qiskit import QuantumCircuit, transpile


def run_ibm(circuit: QuantumCircuit, backend_name: str, shots: int) -> List[str]:
    from qiskit_ibm_runtime import QiskitRuntimeService, SamplerV2
    backend = QiskitRuntimeService().backend(backend_name)
    isa = transpile(circuit, backend, optimization_level=0)
    job = SamplerV2(mode=backend).run([(isa, None, shots)])
    return job.result()[0].join_data().get_bitstrings()


def run_local(circuit: QuantumCircuit, device, shots: int, **options) -> List[str]:
    if hasattr(device, "target") and device.name != "common_qbit":
        circuit = transpile(circuit, device, optimization_level=0)
    return device.run(circuit, shots=shots, memory=True, **options).result().get_memory()
