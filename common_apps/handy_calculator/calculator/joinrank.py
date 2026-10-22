"""接合秩のCommon imageを共有vCPUで観測する。"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

from .language import ExpressionError
from .runtime import REPOSITORY, SharedVCPU, common_lexicon


JOINRANK_DIR = REPOSITORY / "continuous_republic" / "common_apps" / "joinrank"
SOURCE_DIR = JOINRANK_DIR / "joinrank"
IMAGE_PATH = JOINRANK_DIR / "build" / "joinrank.bin"
NEED_PATH = JOINRANK_DIR / "build" / "joinrank.bin.need"
DICTIONARY_PATH = SOURCE_DIR / "joinrank.dic"
SOURCE_FILES = ("size.cmn", "anf.cmn", "rank.cmn", "factor.cmn")

_ADDRESS = common_lexicon.addresses(str(DICTIONARY_PATH))
NIN = _ADDRESS["pebobe"]
KUT = _ADDRESS["pebobo"]
NAA = _ADDRESS["pebopa"]
NBB = _ADDRESS["pebopi"]
RHO = _ADDRESS["pebopu"]
OVF = _ADDRESS["pepabe"]
TAB = _ADDRESS["pepube"]
WIT = _ADDRESS["pepupu"]
PCO = _ADDRESS["pepupe"]
ANF = _ADDRESS["pobepu"]
RHO_SLOTS = _ADDRESS["pebebo"]
STRIDE = _ADDRESS["pebepa"]
WORDS = (1 << 16) + 280000


@dataclass(frozen=True)
class TruthTable:
    bits: tuple[int, ...]
    variables: int


def read_truth_table(text: str) -> TruthTable:
    """0と1の頂点値を、変数x0が最下位bitになる順で読む。"""
    compact = "".join(character for character in text
                      if character not in " \t\r\n,;_|")
    if not compact or any(character not in "01" for character in compact):
        raise ExpressionError("真理値表は 0 と 1 で入力してください。")
    size = len(compact)
    if size < 4 or size > 1024 or size & (size - 1):
        raise ExpressionError("真理値表の長さは 4 から 1024 までの 2 の累乗にしてください。")
    return TruthTable(tuple(int(character) for character in compact),
                      size.bit_length() - 1)


class JoinRankEngine:
    """既存の接合秩imageを、計算機の共有実行台へ接続する。"""

    def __init__(self, runtime: SharedVCPU):
        if not IMAGE_PATH.exists() or not NEED_PATH.exists():
            raise RuntimeError("接合秩のlane64 imageがありません。")
        self.runtime = runtime
        self.image = IMAGE_PATH.read_bytes()
        self.need = int(NEED_PATH.read_text(encoding="ascii"))
        self.digest = hashlib.sha256(self.image).hexdigest()[:16]
        self.source = "\n\n".join(
            (SOURCE_DIR / name).read_text(encoding="utf-8").strip()
            for name in SOURCE_FILES) + "\n"
        self.dictionary = DICTIONARY_PATH.read_text(encoding="utf-8")

    @staticmethod
    def _seed(table: TruthTable, cut: int) -> dict[int, int]:
        seed = {NIN: table.variables, KUT: cut}
        seed.update({TAB + index: 1 for index, bit in enumerate(table.bits) if bit})
        return seed

    @staticmethod
    def _watch(table: TruthTable) -> tuple[int, ...]:
        n = table.variables
        addresses = [RHO, NAA, NBB, OVF]
        addresses.extend(ANF + index for index in range(1 << n))
        addresses.extend(WIT + STRIDE * rank + beta
                         for rank in range(RHO_SLOTS - 1)
                         for beta in range(1 << (n - 1)))
        addresses.extend(PCO + RHO_SLOTS * alpha + rank
                         for alpha in range(1 << (n - 1))
                         for rank in range(RHO_SLOTS - 1))
        return tuple(addresses)

    @staticmethod
    def _decode(table: TruthTable, cut: int,
                watch: tuple[int, ...], values: tuple[int, ...]) -> dict:
        memory = dict(zip(watch, values))
        if memory[OVF]:
            raise ExpressionError("接合秩がCommon語彙の容量8を越えました。")
        rho, na, nb = memory[RHO], memory[NAA], memory[NBB]
        q = [[memory[WIT + STRIDE * rank + beta] for beta in range(nb)]
             for rank in range(rho)]
        p = [[memory[PCO + RHO_SLOTS * alpha + rank] for alpha in range(na)]
             for rank in range(rho)]
        matrix = [[table.bits[alpha + na * beta] for beta in range(nb)]
                  for alpha in range(na)]
        reconstruction = [[sum(p[rank][alpha] * q[rank][beta]
                               for rank in range(rho)) % 2
                           for beta in range(nb)] for alpha in range(na)]
        return {
            "cut": cut,
            "rho": rho,
            "shape": [na, nb],
            "matrix": matrix,
            "p": p,
            "q": q,
            "anf_support": [index for index in range(1 << table.variables)
                            if memory[ANF + index]],
            "reconstruction_matches": reconstruction == matrix,
        }

    def analyze(self, text: str, cut: int) -> dict:
        table = read_truth_table(text)
        if cut < 1 or cut >= table.variables:
            raise ExpressionError("カットは 1 から n-1 までにしてください。")
        if table.variables - cut > 9:
            raise ExpressionError("カット右側の変数は 9 個以内にしてください。")
        cuts = list(range(1, table.variables))
        watch = self._watch(table)
        batch = self.runtime.run_many(
            self.image, WORDS, [self._seed(table, item) for item in cuts],
            need=self.need, head=8, watch=watch)
        decoded = []
        for item, lane in zip(cuts, batch.lanes):
            if lane.report != 0:
                raise ExpressionError("接合秩のCommon imageが失敗を報告しました。")
            decoded.append(self._decode(table, item, watch, lane.watched))
        selected = next(item for item in decoded if item["cut"] == cut)
        return {
            "variables": table.variables,
            "truth_table": "".join(str(bit) for bit in table.bits),
            **selected,
            "profile": [{"cut": item["cut"], "rho": item["rho"]}
                        for item in decoded],
            "execution": {
                "lanes": len(batch.lanes),
                "processes": batch.processes,
                "vector_width": batch.vector_width,
            },
        }
