# -*- coding: utf-8 -*-
"""OpenAI 互換の API サーバー。backend を common に切り替えて HuggingFace を通す。

    python serve.py --model data/Qwen3.8-27b-Q6 --port 8000

    curl http://127.0.0.1:8000/v1/chat/completions -H "content-type: application/json" \
      -d '{"model":"common","messages":[{"role":"user","content":"hello"}]}'

標準ライブラリの http.server だけで立てる。追加の web framework は要らない。
"""
import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {}


def load(model_dir, compile_backend=True):
    """transformers のモデルを開き、backend を common へ切り替える。"""
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from . import backend  # noqa: F401  登録のために import する

    tok = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForCausalLM.from_pretrained(model_dir, dtype=torch.float32)
    model.eval()
    if compile_backend:
        model = torch.compile(model, backend="common")
    STATE["tok"], STATE["model"] = tok, model
    return tok, model


def generate(messages, max_new_tokens=64):
    import torch
    tok, model = STATE["tok"], STATE["model"]
    text = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    ids = tok(text, return_tensors="pt")
    with torch.no_grad():
        out = model.generate(**ids, max_new_tokens=max_new_tokens, do_sample=False)
    return tok.decode(out[0][ids["input_ids"].shape[1]:], skip_special_tokens=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            self._send(200, {"object": "list", "data": [{"id": "common", "object": "model"}]})
        elif self.path.rstrip("/") == "/health":
            self._send(200, {"ok": bool(STATE)})
        else:
            self._send(404, {"error": {"message": "no such path"}})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            self._send(404, {"error": {"message": "no such path"}})
            return
        n = int(self.headers.get("content-length", 0))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            self._send(400, {"error": {"message": "body is not JSON"}})
            return
        msgs = req.get("messages") or []
        if not isinstance(msgs, list) or not msgs:
            self._send(400, {"error": {"message": "messages is required"}})
            return
        try:
            said = generate(msgs, int(req.get("max_tokens") or 64))
        except Exception as e:                       # 走りの失敗は本文へ返す
            self._send(500, {"error": {"message": "%s: %s" % (type(e).__name__, e)}})
            return
        self._send(200, {
            "id": "cmn-%d" % time.time_ns(),
            "object": "chat.completion",
            "created": int(time.time()),
            "model": "common",
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": said}}],
        })

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--eager", action="store_true", help="backend を切り替えずに素の torch で走らせる")
    a = ap.parse_args()
    load(a.model, compile_backend=not a.eager)
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    sys.stderr.write("http://%s:%d/v1/chat/completions で待ちます\n" % (a.host, a.port))
    srv.serve_forever()


if __name__ == "__main__":
    main()
