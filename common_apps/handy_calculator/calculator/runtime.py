"""commonc と lane64 image を一つの vCPU で実行する。"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import re
import sys
import threading
from dataclasses import dataclass
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1]
REPOSITORY = APP_DIR.parents[2]
VCPU_DIR = REPOSITORY / "continuous_republic" / "common_systems" / "Python_vCPU"
COMMONC_IMAGE = REPOSITORY / "builds" / "commonc" / "commonc_lane64.bin"
LEXICON_MODULE = VCPU_DIR / "lex.py"
if str(VCPU_DIR) not in sys.path:
    sys.path.insert(0, str(VCPU_DIR))
import vcpu  # noqa: E402
import toolchain  # noqa: E402

_lexicon_spec = importlib.util.spec_from_file_location("common_lexicon", LEXICON_MODULE)
if _lexicon_spec is None or _lexicon_spec.loader is None:
    raise RuntimeError("Common の採用語彙モジュールを読めません。")
common_lexicon = importlib.util.module_from_spec(_lexicon_spec)
_lexicon_spec.loader.exec_module(common_lexicon)


class CompileError(RuntimeError):
    """Common 文を lane64 image にできなかったことを示す。"""


class EvaluationError(RuntimeError):
    """lane64 image が成功報告を返さなかったことを示す。"""


@dataclass(frozen=True)
class RunResult:
    head: tuple[int, ...]
    output: bytes
    emitted: bytes | None
    blocks: int
    watched: tuple[int, ...] = ()
    report: int = 0


@dataclass(frozen=True)
class BatchRunResult:
    lanes: tuple[RunResult, ...]
    processes: int
    vector_width: int


@dataclass(frozen=True)
class CompiledCmn:
    source: str
    dictionary: str
    image: bytes
    need: int
    digest: str


class SharedVCPU:
    """GUI と MCP が共有する常駐 vCPU。"""

    def __init__(self):
        self.machine = vcpu.VCPU(procs=1, threads=1)
        self.lock = threading.RLock()
        self.processes = max(1, min(4, os.cpu_count() or 1))
        self.vector_width = 64
        self._lane_workers = None
        self._lane_image = None

    def close(self):
        with self.lock:
            self._close_lane_workers()
            self.machine.close()

    def _close_lane_workers(self):
        workers = self._lane_workers
        if workers is None:
            return
        workers.close()
        for process in workers.procs:
            if process.stdout is not None:
                process.stdout.close()
        self._lane_workers = None
        self._lane_image = None

    def run(self, image: bytes, words: int, seed: dict[int, int] | None = None,
            data: bytes | None = None, in_base: int = 64, head: int = 64,
            emit: bool = False, watch: tuple[int, ...] = ()) -> RunResult:
        with self.lock:
            lane = vcpu.Lane(words)
            if data is not None:
                lane.put_input(list(data), in_base)
            for address, value in (seed or {}).items():
                lane.M[address] = value
            table = self.machine._table(image)
            report = vcpu.run_lane(table, lane)
            if report != 0:
                raise EvaluationError("vCPU が失敗を報告しました: %s" % report)
            emitted = None
            if emit:
                base, length = lane.M[1], lane.M[2]
                if base and length:
                    emitted = bytes(value & 255
                                    for value in lane.M[base:base + length])
            return RunResult(tuple(lane.M[:head]), bytes(lane.OUT),
                             emitted, lane.blocks,
                             tuple(lane.M[address] for address in watch))

    def run_many(self, image: bytes, words: int,
                 seeds: list[dict[int, int]], need: int | None = None,
                 head: int = 8, watch: tuple[int, ...] = ()) -> BatchRunResult:
        """独立したlaneをvectorへ束ね、常駐processへ配る。"""
        if not seeds:
            return BatchRunResult((), self.processes, self.vector_width)
        with self.lock:
            identity = hashlib.sha256(image).digest()
            if self._lane_workers is None or self._lane_image != identity:
                self._close_lane_workers()
                self._lane_workers = toolchain.LaneWorkers(
                    image, self.processes, need=need, width=self.vector_width)
                self._lane_image = identity
            rows = self._lane_workers.run(words, seeds, head=head, watch=watch)
            lanes = []
            for report, values, watched in rows:
                lanes.append(RunResult(tuple(values), b"", None, 0,
                                       tuple(watched), report))
            return BatchRunResult(tuple(lanes), self.processes,
                                  self.vector_width)


class CmnCompiler:
    """Common 文を commonc の lane64 image でコンパイルする。"""

    INPUT_MULTIPLIER = 288
    WORK_BASE = 1 << 16

    def __init__(self, runtime: SharedVCPU, build_dir: Path):
        if not COMMONC_IMAGE.exists():
            raise CompileError("commonc の lane64 image がありません: "
                               + str(COMMONC_IMAGE))
        self.runtime = runtime
        self.commonc = COMMONC_IMAGE.read_bytes()
        self.build_dir = build_dir
        self.cache: dict[str, CompiledCmn] = {}

    def compile(self, source: str,
                literals: tuple[tuple[str, int], ...] = ()) -> CompiledCmn:
        dictionary = "".join("%s\t=%d\n" % item for item in literals)
        table = "".join("%s\t%s.\n" % (word, common_lexicon.spell(value))
                        for word, value in literals)
        identity = (dictionary + "\n" + source).encode("utf-8")
        digest = hashlib.sha256(identity).hexdigest()[:16]
        cached = self.cache.get(digest)
        if cached is not None and cached.source == source:
            return cached
        data = (table + source).encode("utf-8")
        syllables = len(re.findall(r"[a-z]+", table + source))
        stride = max(len(data) + 80, 4096, 2 * syllables + 80)
        base = self.INPUT_MULTIPLIER * stride
        result = self.runtime.run(
            self.commonc,
            base + len(data) + 4096,
            seed={4: stride, 130: len(table.encode("utf-8"))},
            data=data,
            in_base=base,
            head=131,
            emit=True,
        )
        if not result.emitted:
            raise CompileError("commonc が lane64 image を返しませんでした。")
        need = result.head[3]
        if need > self.WORK_BASE:
            raise CompileError("チェンバーのワイヤ数が作業領域へ達しました: %d" % need)
        compiled = CompiledCmn(source, dictionary, result.emitted, need, digest)
        self.cache[digest] = compiled
        generated = self.build_dir / "generated"
        generated.mkdir(parents=True, exist_ok=True)
        (generated / (digest + ".cmn")).write_text(source, encoding="utf-8", newline="\n")
        (generated / (digest + ".dic")).write_text(dictionary, encoding="utf-8", newline="\n")
        (generated / (digest + ".bin")).write_bytes(result.emitted)
        (generated / (digest + ".need")).write_text(str(need), encoding="ascii")
        return compiled
