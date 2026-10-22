# -*- coding: utf-8 -*-
"""解法を作る標準の Transformer（torch.nn.Transformer の符号化器と復号器）。

入力は問題の行 (A_r, B_r, P_r) の並び。出力は手順の字句の列と、縮尺 c の値の平均 μ。
μ は、END を読んだあとの位置で出す。手順の全体を見てから c を決める。
"""
import numpy as np
import torch
from torch import nn
from torch.utils.checkpoint import checkpoint

from . import problem as pb
from . import syntax

T = syntax.MAX_TOKENS               # 字句の列の長さ。END を含む


class Generator(nn.Module):
    def __init__(self, d=256, heads=8, layers=6, ff=1024, context=128, recompute=False):
        """context は復号器が読める字句の最大数。モデルの幅 d とは別に決める。
        recompute が真なら、層ごとの途中結果を持たず、逆伝播のときに計算し直す（メモリを減らし、時間を増やす）。"""
        super().__init__()
        if context < T + 1:
            raise ValueError("context は %d 以上にする" % (T + 1))
        self.row = nn.Linear(2 + pb.WIDTH + 8 * pb.WIDTH, d)
        self.tok = nn.Embedding(syntax.V, d)
        self.pos = nn.Embedding(context, d)
        self.net = nn.Transformer(d, heads, layers, layers, ff, dropout=0.0, batch_first=True, norm_first=True)
        self.out = nn.Linear(d, syntax.V)
        self.attr = nn.Linear(d, 1)
        with torch.no_grad():                                  # 学習前の選び方は、乱数で手順を作るときの重みと同じにする
            self.out.weight.mul_(0.1)
            self.out.bias.copy_(torch.log(torch.tensor(syntax.prior(), dtype=torch.float32)))
        self.recompute = recompute

    def _run(self, layers, norm, x, *args, **kwargs):
        for layer in layers:
            if self.recompute and self.training and torch.is_grad_enabled():
                x = checkpoint(lambda h, layer=layer: layer(h, *args, **kwargs), x, use_reentrant=False)
            else:
                x = layer(x, *args, **kwargs)
        return norm(x) if norm is not None else x

    def encode(self, rows):
        """行 (A, B, 答えの語) を、値そのものと答えの語の周期的な特徴を並べたベクトルにして読む。"""
        freq = 2.0 ** torch.arange(4, device=rows.device)
        wave = (rows[..., 2:, None] * freq).flatten(-2)
        x = self.row(torch.cat([rows / 4.0, wave.sin(), wave.cos()], -1))
        return self._run(self.net.encoder.layers, self.net.encoder.norm, x)

    def decode(self, memory, tokens_in):
        n = tokens_in.shape[1]
        x = self.tok(tokens_in) + self.pos(torch.arange(n, device=tokens_in.device))
        mask = nn.Transformer.generate_square_subsequent_mask(n, device=tokens_in.device)
        return self._run(self.net.decoder.layers, self.net.decoder.norm, x, memory, tgt_mask=mask, tgt_is_causal=True)

    def forward(self, rows, tokens):
        """字句の列 tokens (N, T) を読ませて、各位置の次の字句のロジット (N, T, V) と μ (N,) を返す。"""
        n = tokens.shape[0]
        inp = torch.cat([torch.full((n, 1), syntax.BOS, device=tokens.device), tokens], 1)
        h = self.decode(self.encode(rows), inp)
        end = (tokens == syntax.END).float().argmax(1) + 1          # END が入力に現れる位置
        return self.out(h[:, :T]), self.attr(h[torch.arange(n, device=tokens.device), end]).squeeze(-1)


@torch.no_grad()
def sample(model, rows, greedy=False):
    """文法に合う字句の列を 1 つずつ選ぶ。返りは (字句 (N,T), 許した字句の真偽 (N,T,V), 有効な位置 (N,T))。"""
    n, dev = rows.shape[0], rows.device
    memory = model.encode(rows)
    inp = torch.full((n, 1), syntax.BOS, device=dev)
    table = syntax.TABLE
    ids = np.zeros(n, dtype=np.int64)
    done = np.zeros(n, dtype=bool)
    tokens = np.zeros((n, T), dtype=np.int64)
    masks = np.zeros((n, T, syntax.V), dtype=bool)
    valid = np.zeros((n, T), dtype=bool)
    for t in range(T):
        logits = model.out(model.decode(memory, inp)[:, -1]).float()
        masks[:, t] = table.mask[ids]
        valid[:, t] = ~done
        ml = logits.masked_fill(~torch.from_numpy(masks[:, t]).to(dev), -1e9)
        pick = ml.argmax(-1) if greedy else torch.multinomial(torch.softmax(ml, -1), 1).squeeze(1)
        pick = pick.cpu().numpy().copy()
        pick[done] = syntax.PAD
        live = ~done & (pick != syntax.END)
        done |= pick == syntax.END
        ids[live] = table.advance(ids[live], pick[live])
        tokens[:, t] = pick
        inp = torch.cat([inp, torch.from_numpy(pick).to(dev)[:, None]], 1)
        if done.all():
            break
    return torch.from_numpy(tokens), torch.from_numpy(masks), torch.from_numpy(valid)
