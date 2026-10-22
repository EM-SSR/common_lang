# -*- coding: utf-8 -*-
"""Qwen3 の graph に出てくる演算を数え、いま置ける／置けないを分ける。

Qwen3 の構造そのものを小さく作って Dynamo に通す。落ちる所を一件ずつ追うのでなく、
必要な演算を先に全部数える。重みのダウンロードは要らない。

    python -m pytorch_cmn.check.ops
"""
import collections

import torch

try:
    from .. import backend                      # noqa: F401
    from .. import chamber, graph
except ImportError:
    import pytorch_cmn.backend                  # noqa: F401
    from pytorch_cmn import chamber, graph


def tiny(layers=2, hidden=64, heads=4, kv=2, vocab=128, inter=128):
    """小さい Qwen3。構造は本物と同じで、大きさだけ小さい。"""
    from transformers import AutoConfig, AutoModelForCausalLM
    cfg = AutoConfig.for_model(
        "qwen3", hidden_size=hidden, num_hidden_layers=layers,
        num_attention_heads=heads, num_key_value_heads=kv,
        intermediate_size=inter, vocab_size=vocab, max_position_embeddings=64,
        head_dim=hidden // heads, tie_word_embeddings=False)
    torch.manual_seed(3)
    m = AutoModelForCausalLM.from_config(cfg)
    m.eval()
    return m


def graphs(model, ids):
    """Dynamo が切り出した graph を全部集める。"""
    got = []

    def peek(gm, ex):
        got.append((gm, list(ex)))
        return gm.forward

    torch.compile(model, backend=peek, dynamic=False, fullgraph=False)(ids)
    return got


def run(verbose=True):
    """実際に lowering を試して、置けた node と止まった node を出す。"""
    model = tiny()
    ids = torch.tensor([[1, 5, 9, 2]])
    gs = graphs(model, ids)
    if verbose:
        print("Dynamo が切り出した graph %d 本" % len(gs))
    miss = collections.Counter()
    for gm, ex in gs:
        low = graph.Lower(gm, ex)
        host = collections.Counter()
        for n in gm.graph.nodes:
            if n in low.host and n.op in ("call_function", "call_method"):
                host[chamber._name_of(n)] += 1
        try:
            low.emit()
            if verbose:
                print("置けた。段 %d" % len(low.B.rows))
        except Exception as e:
            # 止まった node を探す。順に辿って val に入らなかった最初のものを出す
            first = None
            for n in gm.graph.nodes:
                if n.op in ("call_function", "call_method") and n not in low.val:
                    if n in low.host:
                        continue
                    first = n
                    break
            if verbose:
                print("止まった: %s（%s）%s"
                      % (first.name if first else "?",
                         chamber._name_of(first) if first else "?",
                         str(e).replace(chr(10), " ")[:60]))
            for n in gm.graph.nodes:
                if (n.op in ("call_function", "call_method") and n not in low.val
                        and n not in low.host):
                    miss[chamber._name_of(n)] += 1
        if verbose and host:
            print("host が先に済ませた演算: %s" % dict(host))
    if verbose:
        print()
        print("**まだ置けない演算 %d 種 / %d 回**"
              % (len(miss), sum(miss.values())))
        for k, v in miss.most_common():
            print("   %-28s %d" % (k, v))
    return miss


def value(verbose=True):
    """logits を素の torch と突き合わせる。GPU は使わない（`Build.simulate`）。"""
    import numpy as np
    model = tiny()
    ids = torch.tensor([[1, 5, 9, 2]])
    with torch.no_grad():
        want = model(ids).logits
    gs = graphs(model, ids)
    if verbose:
        print("graph %d 本" % len(gs))
    for gm, ex in gs:
        low = graph.Lower(gm, ex).emit()
        mem, _ = low.B.simulate()
        outs = low.outputs()
        W = low.B.width
        for k, (h, rows, cols, d) in enumerate(outs):
            st = low._stride(cols)
            a = mem[h:h + rows * st].reshape(rows, st)[:, :cols]
            got = np.asarray(a) / float(1 << d)
            wa = np.asarray(want.reshape(-1))
            gf = got.reshape(-1)
            if gf.size != wa.size:
                print("出力 %d: 要素数が %d と %d" % (k, gf.size, wa.size))
                continue
            big = max(1.0, float(np.max(np.abs(wa))))
            err = float(np.max(np.abs(gf - wa))) / big
            print("段 %d  logits の相対の差 %.4g  （torch の幅 %.3f）"
                  % (len(low.B.rows), err, big))
            print("torch  %s" % np.round(wa[:6], 4))
            print("cmn    %s" % np.round(gf[:6], 4))
            return err
    return None


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "value":
        value()
    else:
        run()
