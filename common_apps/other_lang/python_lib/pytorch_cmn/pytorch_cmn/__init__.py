# -*- coding: utf-8 -*-
"""PyTorch の backend をコモン公用語で書くパッケージ。

    import pytorch_cmn                      # backend "common" が登録される
    g = torch.compile(f, backend="common")

| モジュール | 役割 |
|---|---|
| `intent/*.cmn` | 意図の語彙。1 ファイルが 1 語 |
| `lane.py` | 語を音節へ展開し、commonc に渡して image にして走らせる |
| `walk.py` | ステージの表を辿る閉包（内積・テーブル参照・比較の三つ） |
| `plan.py` | 計算をステージの表に組む。右シフト・平方根・逆数 |
| `fold.py` | 行列とベクトルの積と、1 ワードへのパック |
| `chamber.py` | fx.Graph を平文へ落とす |
| `backend.py` | `torch.compile` の backend として登録する |
| `store.py` | GGUF の係数を番地で引く |
| `serve.py` | OpenAI 互換の API |

実行環境は `common_vcpu` パッケージを使う。`sys.path` を触らない。
"""

__all__ = ["lane", "walk", "plan", "fold", "chamber", "store"]
__version__ = "0.1.0"


def _register():
    """torch があれば backend を登録する。無ければ何もしない。"""
    try:
        from . import backend  # noqa: F401
    except ImportError:
        return None
    return backend


backend = _register()
