"""Common 実行境界と共有履歴の受入試験。"""

import tempfile
import unittest
from pathlib import Path

from calculator.language import ExpressionError
from calculator.runtime import APP_DIR
from calculator.session import CalculatorSession


class CalculatorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(dir=APP_DIR / "build")
        cls.session = CalculatorSession(Path(cls.temp.name))

    @classmethod
    def tearDownClass(cls):
        cls.session.close()
        cls.temp.cleanup()

    def test_exact_arithmetic(self):
        self.assertEqual(self.session.calculate("(1 + 3) / 2")["value"], "2")
        self.assertEqual(self.session.calculate("0.1 + 0.2")["value"], "3/10")
        self.assertEqual(self.session.calculate("beta(0)")["value"], "1/2")
        intent = self.session.calculate("37 + 5")
        self.assertNotIn("hu", intent["cmn"])
        self.assertIn("=37", intent["dictionary"])

    def test_variable_and_graph(self):
        result = self.session.calculate("x * x - 1", {"x": "3/2"})
        self.assertEqual(result["value"], "5/4")
        self.assertTrue(result["graph"]["edges"])
        self.assertEqual(
            self.session.calculate("x ** -2", {"x": "2"})["value"], "1/4")

    def test_twinned_order(self):
        self.assertEqual(self.session.trace("ij")["endpoint"], [1, 1])
        self.assertEqual(self.session.trace("ji")["endpoint"], [1, -1])

    def test_influence_quantale(self):
        self.assertEqual(
            self.session.influence("1/2", "3/4", "積")["magnitude"], "3/8")
        self.assertEqual(
            self.session.influence("1/2", "3/4", "上限")["magnitude"], "3/4")
        self.assertEqual(
            self.session.influence("1/2", "1/4", "右残差")["magnitude"], "1/2")

    def test_joinrank_and_factorization(self):
        xor = self.session.joinrank("0110", 1)
        self.assertEqual(xor["rho"], 2)
        self.assertTrue(xor["reconstruction_matches"])
        self.assertEqual(xor["profile"], [{"cut": 1, "rho": 2}])

        table = "".join(str(((v >> 0) & (v >> 2) & 1) ^
                            ((v >> 1) & (v >> 3) & 1)) for v in range(16))
        profile = self.session.joinrank(table, 2)
        self.assertEqual(len(profile["profile"]), 3)
        self.assertTrue(profile["reconstruction_matches"])
        self.assertGreaterEqual(profile["execution"]["processes"], 2)

    def test_shared_history(self):
        gui = self.session.calculate("1", origin="GUI")
        mcp = self.session.calculate("2", origin="MCP")
        self.assertEqual(gui["history"]["session_id"], mcp["history"]["session_id"])
        self.assertEqual(gui["history"]["sequence"] + 1,
                         mcp["history"]["sequence"])
        self.assertEqual([row["origin"] for row in self.session.history(2)],
                         ["GUI", "MCP"])

    def test_dyadic_samples(self):
        result = self.session.sample("x / 2", "-1", "1", samples=5, depth=2)
        self.assertEqual(result["failures"], [])
        self.assertEqual(result["points"][0]["y"], "-1/2")
        self.assertEqual(result["points"][-1]["y"], "1/2")
        midpoint = next(point for point in result["points"] if point["x"] == "1/2")
        scalar = self.session.calculate("x / 2", {"x": "1/2"})
        self.assertEqual(midpoint["y"], scalar["value"])
        self.assertGreaterEqual(result["execution"]["processes"], 1)
        self.assertEqual(result["execution"]["vector_width"], 64)

    def test_domain_error(self):
        with self.assertRaises(ExpressionError):
            self.session.calculate("1 / 0")


if __name__ == "__main__":
    unittest.main()
