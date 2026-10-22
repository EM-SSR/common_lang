"""すべての入口へ同じ計算、観測、履歴を提供する。"""

from __future__ import annotations

import json
import threading
import uuid
from dataclasses import asdict
from datetime import datetime, timezone
from fractions import Fraction
from pathlib import Path

from .joinrank import JoinRankEngine
from .language import (ExpressionError, expression_cmn, influence_cmn,
                       parse_expression, trace_cmn, variable_names)
from .runtime import APP_DIR, CmnCompiler, EvaluationError, SharedVCPU


INPUT_BASE = 32768


def _fraction_text(value: Fraction) -> str:
    return str(value.numerator) if value.denominator == 1 else \
        "%d/%d" % (value.numerator, value.denominator)


def _read_fraction(value: object) -> Fraction:
    try:
        return Fraction(str(value))
    except (ValueError, ZeroDivisionError) as exc:
        raise ExpressionError("変数の値を整数、小数、または分数で入力してください。") from exc


class CalculatorSession:
    """共有 vCPU と連番履歴を所有する。"""

    def __init__(self, app_dir: Path = APP_DIR):
        self.app_dir = app_dir
        self.build_dir = app_dir / "build"
        self.build_dir.mkdir(parents=True, exist_ok=True)
        self.history_path = self.build_dir / "history.jsonl"
        self.session_id = str(uuid.uuid4())
        self.runtime = SharedVCPU()
        self.compiler = CmnCompiler(self.runtime, self.build_dir)
        self.joinrank_engine = JoinRankEngine(self.runtime)
        self.lock = threading.RLock()
        self.sequence = 0

    def close(self):
        self.runtime.close()

    def _addresses(self, names: tuple[str, ...]) -> dict[str, tuple[int, int]]:
        return {name: (INPUT_BASE + 2 * index, INPUT_BASE + 2 * index + 1)
                for index, name in enumerate(names)}

    def _record(self, origin: str, kind: str, request: dict,
                source: str, dictionary: str, result: dict,
                blocks: int, digest: str) -> dict:
        self.sequence += 1
        entry = {
            "session_id": self.session_id,
            "sequence": self.sequence,
            "time": datetime.now(timezone.utc).isoformat(),
            "origin": origin,
            "kind": kind,
            "request": request,
            "cmn": source,
            "dictionary": dictionary,
            "result": result,
            "vcpu_blocks": blocks,
            "image": digest,
        }
        with self.history_path.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")
        return entry

    def calculate(self, expression: str, variables: dict[str, object] | None = None,
                  origin: str = "共通") -> dict:
        with self.lock:
            names = variable_names(expression)
            values = variables or {}
            addresses = self._addresses(names)
            parsed = parse_expression(expression, addresses)
            fractions = {name: _read_fraction(values[name]) for name in names
                         if name in values}
            missing = [name for name in names if name not in fractions]
            if missing:
                raise ExpressionError("変数の値がありません: " + ", ".join(missing))
            seed = {}
            for name, value in fractions.items():
                numerator, denominator = addresses[name]
                seed[numerator] = value.numerator
                seed[denominator] = value.denominator
            program = expression_cmn(parsed)
            source = program.source
            compiled = self.compiler.compile(source, program.literals)
            words = max(1 << 16, compiled.need + 4096,
                        max(seed, default=0) + 1)
            try:
                run = self.runtime.run(compiled.image, words, seed=seed, head=8)
            except EvaluationError as exc:
                raise ExpressionError("分母が 0 になったため、除算を定義できません。") from exc
            raw_numerator, raw_denominator = run.head[:2]
            if raw_denominator == 0:
                raise ExpressionError("分母が 0 になりました。")
            value = Fraction(raw_numerator, raw_denominator)
            result = {
                "value": _fraction_text(value),
                "numerator": value.numerator,
                "denominator": value.denominator,
                "raw": [raw_numerator, raw_denominator],
                "expression": parsed.normalized,
                "variables": {name: _fraction_text(fractions[name]) for name in names},
                "graph": {
                    "nodes": [asdict(node) for node in parsed.nodes],
                    "edges": [list(edge) for edge in parsed.edges],
                },
            }
            entry = self._record(origin, "式", {
                "expression": expression,
                "variables": result["variables"],
            }, source, compiled.dictionary, result, run.blocks, compiled.digest)
            return {**result, "cmn": source, "dictionary": compiled.dictionary,
                    "history": {
                "session_id": entry["session_id"],
                "sequence": entry["sequence"],
                "origin": entry["origin"],
            }, "vcpu_blocks": run.blocks, "image": compiled.digest}

    def sample(self, expression: str, start: object = "-4", end: object = "4",
               samples: int = 65, depth: int = 6, origin: str = "共通") -> dict:
        if not 2 <= samples <= 257:
            raise ExpressionError("標本数は 2 から 257 までにしてください。")
        if not 0 <= depth <= 16:
            raise ExpressionError("標本深度は 0 から 16 までにしてください。")
        left, right = _read_fraction(start), _read_fraction(end)
        if left >= right:
            raise ExpressionError("表示範囲の左端は右端より小さくしてください。")
        scale = 1 << depth
        lo = -((-left.numerator * scale) // left.denominator)
        hi = (right.numerator * scale) // right.denominator
        if lo > hi:
            raise ExpressionError("指定した深度では表示範囲に標本点がありません。")
        if samples == 2:
            indices = [lo, hi]
        else:
            indices = [lo + ((hi - lo) * index) // (samples - 1)
                       for index in range(samples)]
        indices = list(dict.fromkeys(indices))
        with self.lock:
            names = variable_names(expression)
            unsupported = [name for name in names if name != "x"]
            if unsupported:
                raise ExpressionError("関数グラフの自由変数は x だけです。")
            addresses = self._addresses(names)
            parsed = parse_expression(expression, addresses)
            program = expression_cmn(parsed)
            compiled = self.compiler.compile(program.source, program.literals)
            seeds = []
            for index in indices:
                if "x" in addresses:
                    numerator, denominator = addresses["x"]
                    x = Fraction(index, scale)
                    seeds.append({numerator: x.numerator,
                                  denominator: x.denominator})
                else:
                    seeds.append({})
            words = max(1 << 16, compiled.need + 4096,
                        max((max(seed, default=0) for seed in seeds), default=0) + 1)
            batch = self.runtime.run_many(compiled.image, words, seeds,
                                          need=compiled.need, head=8)
            points, failures = [], []
            for index, run in zip(indices, batch.lanes):
                x = Fraction(index, scale)
                if run.report != 0 or run.head[1] == 0:
                    failures.append({
                        "x": _fraction_text(x),
                        "error": "この標本点では分母が 0 になります。",
                    })
                    continue
                value = Fraction(run.head[0], run.head[1])
                points.append({"x": _fraction_text(x),
                               "y": _fraction_text(value)})
            result = {
                "expression": parsed.normalized,
                "range": [_fraction_text(left), _fraction_text(right)],
                "depth": depth,
                "points": points,
                "failures": failures,
                "execution": {
                    "lanes": len(batch.lanes),
                    "processes": batch.processes,
                    "vector_width": batch.vector_width,
                },
            }
            entry = self._record(origin, "関数標本", {
                "expression": expression,
                "range": result["range"],
                "samples": samples,
                "depth": depth,
            }, program.source, compiled.dictionary, result, 0, compiled.digest)
            return {**result, "cmn": program.source,
                    "dictionary": compiled.dictionary,
                    "history": {
                        "session_id": entry["session_id"],
                        "sequence": entry["sequence"],
                        "origin": entry["origin"],
                    }, "image": compiled.digest}

    def trace(self, word: str, origin: str = "共通") -> dict:
        with self.lock:
            program = trace_cmn(word)
            source = program.source
            compiled = self.compiler.compile(source, program.literals)
            run = self.runtime.run(compiled.image,
                                   max(4096, compiled.need + 1024), head=4)
            result = {"word": word, "endpoint": [run.head[0], run.head[1]]}
            entry = self._record(origin, "構成履歴", {"word": word}, source,
                                 compiled.dictionary, result, run.blocks,
                                 compiled.digest)
            return {**result, "cmn": source, "dictionary": compiled.dictionary,
                    "history": {
                "session_id": entry["session_id"],
                "sequence": entry["sequence"],
                "origin": entry["origin"],
            }, "vcpu_blocks": run.blocks, "image": compiled.digest}

    def influence(self, left: object, right: object, operation: str,
                  origin: str = "共通") -> dict:
        with self.lock:
            aliases = {
                "積": "star", "上限": "sup", "右残差": "right", "左残差": "left",
                "star": "star", "sup": "sup", "right": "right", "left": "left",
            }
            if operation not in aliases:
                raise ExpressionError("影響演算は積、上限、右残差、左残差から選んでください。")
            op = aliases[operation]
            a, b = _read_fraction(left), _read_fraction(right)
            program = influence_cmn(a, b, op)
            source = program.source
            compiled = self.compiler.compile(source, program.literals)
            run = self.runtime.run(compiled.image,
                                   max(4096, compiled.need + 1024), head=8)
            magnitude = Fraction(run.head[0], run.head[1])
            result = {
                "operation": op,
                "left": _fraction_text(a),
                "right": _fraction_text(b),
                "magnitude": _fraction_text(magnitude),
                "word_state": [run.head[2], run.head[3]],
                "sign": run.head[4],
            }
            entry = self._record(origin, "影響", {
                "left": result["left"], "right": result["right"],
                "operation": op,
            }, source, compiled.dictionary, result, run.blocks, compiled.digest)
            return {**result, "cmn": source, "dictionary": compiled.dictionary,
                    "history": {
                "session_id": entry["session_id"],
                "sequence": entry["sequence"],
                "origin": entry["origin"],
            }, "vcpu_blocks": run.blocks, "image": compiled.digest}

    def joinrank(self, truth_table: str, cut: int,
                 origin: str = "共通") -> dict:
        with self.lock:
            result = self.joinrank_engine.analyze(truth_table, int(cut))
            entry = self._record(origin, "接合秩", {
                "truth_table": result["truth_table"],
                "cut": result["cut"],
            }, self.joinrank_engine.source, self.joinrank_engine.dictionary,
                result, 0, self.joinrank_engine.digest)
            return {**result, "cmn": self.joinrank_engine.source,
                    "dictionary": self.joinrank_engine.dictionary,
                    "history": {
                        "session_id": entry["session_id"],
                        "sequence": entry["sequence"],
                        "origin": entry["origin"],
                    }, "image": self.joinrank_engine.digest}

    def history(self, limit: int = 100) -> list[dict]:
        if limit < 1:
            return []
        if not self.history_path.exists():
            return []
        lines = self.history_path.read_text(encoding="utf-8").splitlines()
        return [json.loads(line) for line in lines[-min(limit, 1000):]]
