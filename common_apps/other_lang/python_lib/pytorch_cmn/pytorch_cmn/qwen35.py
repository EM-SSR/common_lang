# -*- coding: utf-8 -*-
"""Qwen3.8-27B（GGUF、arch `qwen35`）を層ごとに読む。

54 GB の F16 を一度に開くと RAM に載らない。要るのは三つ。

- **config と tokenizer は GGUF の metadata から作る。** 別途ダウンロードしない。
- **重みは層ごとに読む。** `GGUFReader` は mmap なので、触った層だけがページに入る。
- **chat template も GGUF が持っている。** これを通さないとまともな返事にならない。

`qwen35` は SSM と全注意の混成で、`full_attention_interval` ごとに全注意が入る
（実物は blk.3, 7, 11, …）。transformers 側の名前は `qwen3_5`。

    from pytorch_cmn import qwen35
    src = qwen35.Source("data/Qwen3.8-27b-bf16")
    cfg, tok = src.config(), src.tokenizer()
    sd = src.layer(0)            # 層 0 の重み（HF の名前で）
"""
import glob
import os
import re

# GGUF の名前 → HF の名前。層の中だけ（`blk.N.` と `model.layers.N.` を外した形）
LAYER_MAP = {
    "attn_norm.weight": "input_layernorm.weight",
    "post_attention_norm.weight": "post_attention_layernorm.weight",
    "ffn_gate.weight": "mlp.gate_proj.weight",
    "ffn_up.weight": "mlp.up_proj.weight",
    "ffn_down.weight": "mlp.down_proj.weight",
    # SSM（線形注意）の層
    "attn_qkv.weight": "linear_attn.in_proj_qkv.weight",
    "attn_gate.weight": "linear_attn.in_proj_z.weight",
    "ssm_alpha.weight": "linear_attn.in_proj_a.weight",
    "ssm_beta.weight": "linear_attn.in_proj_b.weight",
    "ssm_a": "linear_attn.A_log",
    "ssm_dt.bias": "linear_attn.dt_bias",
    "ssm_conv1d.weight": "linear_attn.conv1d.weight",
    "ssm_norm.weight": "linear_attn.norm.weight",
    "ssm_out.weight": "linear_attn.out_proj.weight",
    # 全注意の層
    "attn_q.weight": "self_attn.q_proj.weight",
    "attn_k.weight": "self_attn.k_proj.weight",
    "attn_v.weight": "self_attn.v_proj.weight",
    "attn_output.weight": "self_attn.o_proj.weight",
    "attn_q_norm.weight": "self_attn.q_norm.weight",
    "attn_k_norm.weight": "self_attn.k_norm.weight",
}

OUTER_MAP = {
    "token_embd.weight": "model.embed_tokens.weight",
    "output_norm.weight": "model.norm.weight",
    "output.weight": "lm_head.weight",
}


class Source(object):
    """GGUF の束を一つのモデルとして読む。"""

    def __init__(self, path):
        from gguf import GGUFReader
        if os.path.isdir(path):
            files = sorted(glob.glob(os.path.join(path, "*.gguf")))
            files = [f for f in files if "mmproj" not in os.path.basename(f)]
        else:
            files = [path]
        if not files:
            raise FileNotFoundError("gguf が見つかりません: %s" % path)
        self.files = files
        self.readers = [GGUFReader(f) for f in files]
        self.meta = {}
        for r in self.readers:
            for k, f in r.fields.items():
                if k not in self.meta:
                    try:
                        self.meta[k] = f.contents()
                    except Exception:
                        pass
        self.where = {}                      # tensor の名前 → (reader, tensor)
        for r in self.readers:
            for t in r.tensors:
                self.where.setdefault(t.name, (r, t))

    def _m(self, key, default=None):
        arch = self.meta.get("general.architecture", "qwen35")
        return self.meta.get("%s.%s" % (arch, key), self.meta.get(key, default))

    def config(self):
        """GGUF の metadata から `Qwen3_5TextConfig` を作る。"""
        from transformers.models.qwen3_5.configuration_qwen3_5 import Qwen3_5TextConfig
        n = int(self._m("block_count"))
        # **層の種類は GGUF の tensor から決める。** `full_attention_interval` から
        # 数えると最後の層（nextn_predict_layers の分）を取りこぼす。実物は
        # 3, 7, 11, …, 63 に加えて 64 も全注意になる
        types = []
        for i in range(n):
            q = "blk.%d.attn_q.weight" % i
            types.append("full_attention" if q in self.where else "linear_attention")
        c = Qwen3_5TextConfig()
        c.num_hidden_layers = n
        c.hidden_size = int(self._m("embedding_length"))
        c.intermediate_size = int(self._m("feed_forward_length"))
        c.num_attention_heads = int(self._m("attention.head_count"))
        c.num_key_value_heads = int(self._m("attention.head_count_kv"))
        c.head_dim = int(self._m("attention.key_length"))
        c.rms_norm_eps = float(self._m("attention.layer_norm_rms_epsilon", 1e-6))
        c.max_position_embeddings = int(self._m("context_length"))
        c.vocab_size = len(self.meta.get("tokenizer.ggml.tokens", []))
        c.layer_types = types
        c.linear_conv_kernel_dim = int(self._m("ssm.conv_kernel", 4))
        # SSM の欄の対応（GGUF の実物の形から決めた）
        #
        #   qkv の幅 = 2·(key head)·(key 次元) + (value head)·(value 次元)
        #            = 2·16·128 + 48·128 = 10240   ← conv1d の幅と一致
        #
        # `group_count` が key head、`time_step_rank` が value head になる。
        inner = int(self._m("ssm.inner_size", 6144))
        groups = int(self._m("ssm.group_count", 16))
        state = int(self._m("ssm.state_size", 128))
        vheads = int(self._m("ssm.time_step_rank", 48))
        c.linear_num_key_heads = groups
        c.linear_key_head_dim = state
        c.linear_num_value_heads = vheads
        c.linear_value_head_dim = inner // vheads
        c.bos_token_id = int(self.meta.get("tokenizer.ggml.bos_token_id", 0))
        c.eos_token_id = int(self.meta.get("tokenizer.ggml.eos_token_id", 0))
        c.pad_token_id = int(self.meta.get("tokenizer.ggml.padding_token_id",
                                           c.bos_token_id))
        c.tie_word_embeddings = "output.weight" not in self.where
        try:
            c.rope_parameters = {"rope_type": "default",
                                 "rope_theta": float(self._m("rope.freq_base", 1e7))}
        except Exception:
            pass
        return c

    def tokenizer(self):
        """GGUF の語彙と merges から BPE を作り、chat template を付ける。"""
        from tokenizers import AddedToken, Tokenizer, decoders, models, pre_tokenizers
        from transformers import PreTrainedTokenizerFast
        toks = list(self.meta["tokenizer.ggml.tokens"])
        vocab = dict((t, i) for i, t in enumerate(toks))
        merges = [tuple(m.split(" ", 1)) if isinstance(m, str) else tuple(m)
                  for m in self.meta["tokenizer.ggml.merges"]]
        bpe = Tokenizer(models.BPE(vocab, merges, fuse_unk=False))
        bpe.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False,
                                                     use_regex=True)
        bpe.decoder = decoders.ByteLevel()
        # **制御用の token を一語として登録する。** 登録しないと `<|im_start|>` が
        # 7 個に割れて、chat template が効かなくなる。GGUF の token_type が 3 のもの
        types = list(self.meta.get("tokenizer.ggml.token_type", []))
        ctrl = [AddedToken(toks[i], special=True, normalized=False)
                for i, ty in enumerate(types) if int(ty) == 3]
        if ctrl:
            bpe.add_special_tokens(ctrl)
        t = PreTrainedTokenizerFast(tokenizer_object=bpe)
        bos = int(self.meta["tokenizer.ggml.bos_token_id"])
        eos = int(self.meta["tokenizer.ggml.eos_token_id"])
        t.bos_token, t.eos_token = toks[bos], toks[eos]
        t.pad_token = toks[int(self.meta.get("tokenizer.ggml.padding_token_id", bos))]
        ct = self.meta.get("tokenizer.chat_template")
        if ct:
            t.chat_template = ct
        return t

    def _take(self, name):
        import numpy as np
        import torch
        if name not in self.where:
            return None
        _r, t = self.where[name]
        a = np.asarray(t.data)
        # GGUF の shape は最後の軸から並ぶ
        shape = tuple(int(x) for x in reversed(t.shape))
        if a.size and a.size != int(np.prod(shape)):
            shape = (a.size,)
        v = torch.from_numpy(a.reshape(shape).copy())
        if name.endswith("ssm_conv1d.weight") and v.dim() == 2:
            v = v.unsqueeze(1)          # HF は (幅, 1, k) で持つ
        return v

    def layer(self, i):
        """層 i の重みを HF の名前で返す。触った所だけがページに入る。"""
        out = {}
        pre = "blk.%d." % i
        for name in self.where:
            if not name.startswith(pre):
                continue
            hf = LAYER_MAP.get(name[len(pre):])
            if hf is None:
                continue
            v = self._take(name)
            if v is not None:
                out["model.layers.%d.%s" % (i, hf)] = v
        return out

    def outer(self):
        """埋め込みと最後の正規化と出力。"""
        out = {}
        for g, hf in OUTER_MAP.items():
            v = self._take(g)
            if v is not None:
                out[hf] = v
        return out

    def blocks(self):
        n = 0
        for name in self.where:
            m = re.match(r"^blk\.(\d+)\.", name)
            if m:
                n = max(n, int(m.group(1)) + 1)
        return n


class Runner(object):
    """重みを層ごとに読みながらモデルを回す。

    54 GB を一度に載せない。transformers の前向きはそのまま使い、層へ入る直前に
    `GGUFReader` の mmap から重みを取り、出たら `meta` へ戻して捨てる。常駐するのは
    埋め込みと最後の正規化と出力だけになる。

        run = qwen35.Runner("data/Qwen3.8-27b-bf16")
        print(run.say("1 から 10 までの素数を挙げて。", limit=64))
    """

    def __init__(self, path, dtype=None, keep=1, verbose=True):
        import torch
        from transformers.models.qwen3_5.modeling_qwen3_5 import Qwen3_5ForCausalLM
        self.src = Source(path)
        self.cfg = self.src.config()
        # **生の重みを float32 へ上げない。** 埋め込みだけで 5 GB になって RAM が尽きる
        self.dtype = dtype or torch.bfloat16
        self.cfg.dtype = self.dtype
        self.verbose = verbose
        with torch.device("meta"):
            self.model = Qwen3_5ForCausalLM(self.cfg)
        self.model.eval()
        # 常駐するのは外側だけ
        outer = self.src.outer()
        for k in list(outer):
            v = outer[k]
            outer[k] = v if v.dtype == self.dtype else v.to(self.dtype)
        if "lm_head.weight" not in outer and self.cfg.tie_word_embeddings:
            outer["lm_head.weight"] = outer["model.embed_tokens.weight"]
        self.model.model.embed_tokens.to_empty(device="cpu")
        self.model.model.norm.to_empty(device="cpu")
        self.model.lm_head.to_empty(device="cpu")
        self.model.load_state_dict(outer, strict=False, assign=True)
        self.tok = self.src.tokenizer()
        self._arm(keep)

    def _arm(self, keep):
        """層ごとに「入る前に読む・出たら捨てる」を付ける。"""
        import torch
        layers = self.model.model.layers
        for i, lay in enumerate(layers):
            def pre(mod, args, kwargs, i=i, mod_ref=None):
                sd = self.src.layer(i)
                sd = dict((k.split("layers.%d." % i, 1)[1],
                           v if v.dtype == self.dtype else v.to(self.dtype))
                          for k, v in sd.items())
                mod.to_empty(device="cpu")
                mod.load_state_dict(sd, strict=True, assign=True)
                if self.verbose and i % 8 == 0:
                    print("  層 %d" % i, end="\r", flush=True)
                return None

            def post(mod, args, kwargs, out, i=i):
                mod.to("meta")
                return out

            lay.register_forward_pre_hook(pre, with_kwargs=True)
            lay.register_forward_hook(post, with_kwargs=True)

    def prompt(self, text, system=None):
        """chat template を通した token。**これを通さないとまともな返事にならない。**"""
        msg = ([{"role": "system", "content": system}] if system else []) + \
              [{"role": "user", "content": text}]
        s = self.tok.apply_chat_template(msg, tokenize=False, add_generation_prompt=True)
        return self.tok(s, return_tensors="pt").input_ids, s

    def say(self, text, limit=64, system=None, greedy=True):
        """一語ずつ出す。返りは出た文。"""
        import time
        import torch
        ids, shown = self.prompt(text, system)
        if self.verbose:
            print("--- 入れた文 ---\n%s" % shown[-300:])
        out = []
        t0 = time.time()
        past = None
        with torch.no_grad():
            for step in range(limit):
                r = self.model(input_ids=ids if past is None else ids[:, -1:],
                               past_key_values=past, use_cache=True)
                past = r.past_key_values
                nxt = int(torch.argmax(r.logits[0, -1])) if greedy else \
                    int(torch.multinomial(torch.softmax(r.logits[0, -1], -1), 1))
                if nxt == self.cfg.eos_token_id:
                    break
                out.append(nxt)
                ids = torch.cat([ids, torch.tensor([[nxt]])], dim=1)
                if self.verbose:
                    print("%3d 語目 %.1f 秒/語  %r"
                          % (step + 1, (time.time() - t0) / (step + 1),
                             self.tok.decode(out[-8:])), flush=True)
        return self.tok.decode(out)


# ---- Common の数へ落とす -------------------------------------------------
#
# 生の F16 を torch の tensor として持つのは Common を使っていない。値は
#
#     値 = 分子 · 2^{-F}
#
# で、深度 F は**置き場ごとに一つ**、分子だけが要素ごとに要る。実測では bf16 と同じ
# 刻み（相対誤差 2×10⁻³）に対して分子は 9 bit で足りる（F は置き場ごとに 7〜12）。
# 生の 16 bit に対して 1.8 分の 1 になる。

def depth_of(a, want=2.0 ** -8, top=24):
    """その並びに要る深度 F と分子の bit 数。`want` は許す相対誤差。"""
    import numpy as np
    v = float(np.max(np.abs(a))) if a.size else 0.0
    if v == 0.0:
        return 0, 1
    for F in range(1, top + 1):
        num = np.rint(a * (1 << F))
        if float(np.max(np.abs(num / (1 << F) - a))) / v <= want:
            return F, int(float(np.max(np.abs(num)))).bit_length() + 1
    return top, int(float(np.max(np.abs(np.rint(a * (1 << top)))))).bit_length() + 1


def numerals(a, want=2.0 ** -8):
    """並びを (深度, 分子) にする。分子は入る一番狭い整数の型で返す。"""
    import numpy as np
    F, bits = depth_of(a, want)
    num = np.rint(a * (1 << F))
    for t in (np.int8, np.int16, np.int32):
        if float(np.max(np.abs(num))) <= np.iinfo(t).max:
            return F, num.astype(t)
    return F, num.astype(np.int64)


# ---- 分子を詰めて持つ -----------------------------------------------------
#
# 実測で分子は 9 bit で足りる（bf16 と同じ刻み）。int16 に入れると 7 bit 余る。
# 下位 8 bit を byte の面に、残りを bit の面に分けると、1 要素ちょうど b bit になる。
#
#     u = 分子 + 2^{b-1} ∈ [0, 2^b),   下位 = u mod 256,   上位 = ⌊u/256⌋
#
# b = 9 なら 1 要素 9 bit = 1.125 byte。F16 の 1.78 分の 1 になる。

def pack(num, bits):
    """分子を `bits` bit ずつ詰める。返りは (下位の byte, 上位の bit, bits, 要素数)。"""
    import numpy as np
    n = np.asarray(num).reshape(-1).astype(np.int64)
    u = (n + (1 << (bits - 1))).astype(np.uint32)
    lo = (u & 255).astype(np.uint8)
    hi = (u >> 8).astype(np.uint8)
    planes = [np.packbits((hi >> k) & 1) for k in range(max(0, bits - 8))]
    return lo, (np.concatenate(planes) if planes else np.zeros((0,), np.uint8)), bits, n.size


def unpack(lo, hi, bits, size, xp=None):
    """詰めた分子を戻す。`xp` に jax.numpy を渡せば板の上で戻せる。"""
    import numpy as np
    xp = xp or np
    u = lo.astype("int64")
    m = max(0, bits - 8)
    if m:
        per = (size + 7) // 8
        for k in range(m):
            b = xp.unpackbits(hi[k * per:(k + 1) * per])[:size] if hasattr(xp, "unpackbits") \
                else np.unpackbits(np.asarray(hi[k * per:(k + 1) * per]))[:size]
            u = u + (xp.asarray(b).astype("int64") << (8 + k))
    return u - (1 << (bits - 1))


class Common(object):
    """GGUF を Common の数へ一度だけ写し、以後はその形だけを読む。

    生の F16 を毎回 materialize するのは Common を使っていない。値は

        値 = 分子 · 2^{-F}

    で、深度 F は置き場ごとに一つ、分子は 9 bit（bf16 と同じ刻み）。詰めると
    1 要素 1.125 byte になり、F16 の 1.78 分の 1 になる。

        cm = qwen35.Common(src)
        cm.build()            # 一度だけ。`<model>/common/` へ書く
        w = cm.layer(0)       # {名前: (F, 分子)}
    """

    def __init__(self, src, out=None, want=2.0 ** -8):
        self.src = src
        self.want = want
        self.out = out or os.path.join(os.path.dirname(src.files[0]), "common")

    def _path(self, i):
        return os.path.join(self.out, "blk.%d.npz" % i)

    def build(self, verbose=True):
        """全部の層を Common の数へ写す。既にある層は飛ばす。"""
        import numpy as np
        os.makedirs(self.out, exist_ok=True)
        n = self.src.blocks()
        raw = cm = 0
        for i in range(n):
            p = self._path(i)
            if os.path.exists(p):
                cm += os.path.getsize(p)
                continue
            keep = {}
            pre = "blk.%d." % i
            for name in sorted(self.src.where):
                if not name.startswith(pre):
                    continue
                hf = LAYER_MAP.get(name[len(pre):])
                if hf is None:
                    continue
                a = np.asarray(self.src.where[name][1].data, dtype=np.float32)
                raw += a.size * 2
                F, bits = depth_of(a, self.want)
                lo, hi, bits, size = pack(np.rint(a * (1 << F)), bits)
                sh = tuple(int(x) for x in reversed(self.src.where[name][1].shape))
                keep[hf + "|F"] = np.int32(F)
                keep[hf + "|b"] = np.int32(bits)
                keep[hf + "|n"] = np.int64(size)
                keep[hf + "|s"] = np.asarray(sh, dtype=np.int64)
                keep[hf + "|lo"] = lo
                keep[hf + "|hi"] = hi
                del a
            np.savez(p, **keep)
            cm += os.path.getsize(p)
            if verbose:
                print("  層 %2d / %d  ここまで %.2f GB" % (i, n, cm / 1e9), flush=True)
        if verbose and raw:
            print("生 %.1f GB → Common %.1f GB（%.2f 分の 1）"
                  % (raw / 1e9, cm / 1e9, raw / max(cm, 1)))
        return cm

    def layer(self, i, xp=None):
        """層 i を {HF の名前: (F, 分子, 形)} で返す。詰めた形から戻す。"""
        import numpy as np
        z = np.load(self._path(i))
        out = {}
        for k in z.files:
            if not k.endswith("|F"):
                continue
            nm = k[:-2]
            F = int(z[nm + "|F"]); b = int(z[nm + "|b"]); n = int(z[nm + "|n"])
            num = unpack(z[nm + "|lo"], z[nm + "|hi"], b, n, xp)
            out[nm] = (F, np.asarray(num).reshape(tuple(z[nm + "|s"])))
        return out
