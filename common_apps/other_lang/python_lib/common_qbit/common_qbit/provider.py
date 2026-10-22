# -*- coding: utf-8 -*-
"""Qiskit の Provider。qdk.azure.qiskit.AzureQuantumProvider と同じ形（backends、get_backend）。"""
from .backend import CommonQbitBackend


class CommonQbitProvider(object):
    name = "common_qbit"

    def backends(self, name=None, **_filters):
        found = [CommonQbitBackend()]
        return [b for b in found if name is None or b.name == name]

    def get_backend(self, name="common_qbit"):
        found = self.backends(name=name)
        if not found:
            raise KeyError("バックエンドが無い: %s" % name)
        return found[0]
