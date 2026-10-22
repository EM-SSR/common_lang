# -*- coding: utf-8 -*-
"""検査用。ops.py と同じ名前の箱を、普通の torch の演算で書く（cmn の箱を使わない独立な計算）。
so と hi の境界の規則は torch_calc の Function で与える。"""
import torch

from . import torch_calc


class _F(object):
    def __init__(self, f):
        self.apply = f


Ti = _F(lambda a, b: a * b)
No = _F(lambda a, b: a + b)
Ha = _F(lambda a: -a)
Za = _F(lambda a, b: (a + b) / 2)
Gu = _F(lambda a: 2 * a - 1)
Ge = _F(lambda a: a * 0 + 1)
Dup = _F(lambda a: (a * 1, a * 1))
So = _F(torch_calc._Positive.apply)
Hi = _F(torch_calc._LessEq.apply)
Sub = _F(lambda a, b: a - b)
Eqz = _F(lambda a: 1 - torch_calc._Positive.apply(a) - torch_calc._Positive.apply(-a))
Sign = _F(lambda a: torch_calc._Positive.apply(a) - torch_calc._Positive.apply(-a))
Lin = _F(lambda h, x: 1 + h * (x - 1))
