"""共有計算セッションを MCP の道具として公開する。"""

from __future__ import annotations

from . import get_session


def create_server(session=None):
    """指定した共有セッションへ接続する MCP サーバーを作る。"""
    try:
        from mcp.server import MCPServer
    except ImportError as exc:
        raise RuntimeError("MCP SDK 2 が必要です。requirements.txt を適用してください。") from exc

    shared = session or get_session()
    server = MCPServer("ツイ数関数計算機")

    @server.tool()
    def calculate(expression: str,
                  variables: dict[str, str] | None = None) -> dict[str, object]:
        """Common と共有 vCPU で厳密有理式を計算する。"""
        return shared.calculate(expression, variables, origin="MCP")

    @server.tool()
    def sample_function(expression: str, start: str = "-4", end: str = "4",
                        samples: int = 65, depth: int = 6) -> dict[str, object]:
        """二進格子上で関数の標本点を厳密に計算する。"""
        return shared.sample(expression, start, end, samples, depth, origin="MCP")

    @server.tool()
    def trace_twinned(word: str) -> dict[str, object]:
        """i と j の構成履歴をツイ数平面の終点として観測する。"""
        return shared.trace(word, origin="MCP")

    @server.tool()
    def calculate_influence(left: str, right: str,
                            operation: str) -> dict[str, object]:
        """二進有理の影響量へ積、上限、右残差、左残差を適用する。"""
        return shared.influence(left, right, operation, origin="MCP")

    @server.tool()
    def calculate_joinrank(truth_table: str,
                           cut: int) -> dict[str, object]:
        """真理値表を指定した境界で分け、接合秩と分離積を観測する。"""
        return shared.joinrank(truth_table, cut, origin="MCP")

    @server.tool()
    def calculation_history(limit: int = 100) -> list[dict[str, object]]:
        """GUI と MCP が共有する直近の計算履歴を返す。"""
        return shared.history(limit)

    return server


def run(session=None):
    """stdio を使う MCP サーバーを開始する。"""
    create_server(session).run()


if __name__ == "__main__":
    run()
