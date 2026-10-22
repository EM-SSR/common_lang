"""MCP のスキーマと道具呼出しを通す統合試験。"""

import tempfile
import unittest
from pathlib import Path

try:
    from mcp import Client
except ImportError:
    Client = None

from calculator.mcp_server import create_server
from calculator.runtime import APP_DIR
from calculator.session import CalculatorSession


@unittest.skipIf(Client is None, "MCP SDK 2 がありません。")
class McpTest(unittest.IsolatedAsyncioTestCase):
    async def test_calculate_and_shared_history(self):
        with tempfile.TemporaryDirectory(dir=APP_DIR / "build") as temp:
            session = CalculatorSession(Path(temp))
            try:
                async with Client(create_server(session)) as client:
                    reply = await client.call_tool(
                        "calculate", {"expression": "1/2 + 1/3"})
                    self.assertEqual(reply.structured_content["value"], "5/6")
                    influence = await client.call_tool("calculate_influence", {
                        "left": "1/2", "right": "3/4", "operation": "sup"})
                    self.assertEqual(influence.structured_content["magnitude"], "3/4")
                    joined = await client.call_tool("calculate_joinrank", {
                        "truth_table": "0110", "cut": 1})
                    self.assertEqual(joined.structured_content["rho"], 2)
                    session.calculate("1", origin="GUI")
                    history = await client.call_tool(
                        "calculation_history", {"limit": 4})
                    rows = history.structured_content["result"]
                    self.assertEqual([row["origin"] for row in rows],
                                     ["MCP", "MCP", "MCP", "GUI"])
                    self.assertEqual(len({row["session_id"] for row in rows}), 1)
            finally:
                session.close()


if __name__ == "__main__":
    unittest.main()
