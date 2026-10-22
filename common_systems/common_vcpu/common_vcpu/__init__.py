# -*- coding: utf-8 -*-
"""Common 言語の実行環境を python から使うためのパッケージ。

| モジュール | 役割 |
|---|---|
| `vcpu` | lane64 の image を 1 本だけ解釈する。翻訳器も持つ |
| `vcpu_vec` | numpy で複数本まとめて解釈する |
| `gvcpu` | cupy で GPU 上を大量に並列で解釈する |
| `cuvcpu` | CUDA を直接叩く版 |
| `toolchain` | `.cmn` を commonc に渡して image にする |
| `lex` | 採用語彙の表を作る |

これまで `sys.path` にディレクトリを足して `import vcpu` と書いていた場所は、

    from common_vcpu import vcpu, toolchain, gvcpu

に置き換えられる。旧いパスにはモジュールを同一視する別名だけを残してあるので、
どちらの書き方でも同じモジュールが返る。
"""

from . import lex, toolchain, vcpu  # noqa: F401

__all__ = ["vcpu", "vcpu_vec", "gvcpu", "cuvcpu", "toolchain", "lex"]


def __getattr__(name):
    """cupy や CUDA が無い環境で import が失敗しないよう、重いものは遅らせる。"""
    if name in ("gvcpu", "cuvcpu", "vcpu_vec"):
        import importlib
        mod = importlib.import_module("." + name, __name__)
        globals()[name] = mod
        return mod
    raise AttributeError(name)
