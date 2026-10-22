"""数式を Common のチェンバーへ写す境界。"""

from __future__ import annotations

import ast
import re
from dataclasses import dataclass
from fractions import Fraction


class ExpressionError(ValueError):
    """入力が計算機の定義域から外れたことを示す。"""


@dataclass(frozen=True)
class DExpr:
    """Common の Dyad 席へ入る式。"""

    kind: str
    value: int = 0
    left: "DExpr | None" = None
    right: "DExpr | None" = None


@dataclass(frozen=True)
class RExpr:
    """二本の Dyad 席で表す厳密有理数。"""

    numerator: DExpr
    denominator: DExpr


@dataclass(frozen=True)
class GraphNode:
    node_id: int
    label: str
    depth: int


@dataclass(frozen=True)
class ParsedExpression:
    source: str
    normalized: str
    rational: RExpr
    variables: tuple[str, ...]
    nodes: tuple[GraphNode, ...]
    edges: tuple[tuple[int, int], ...]


@dataclass(frozen=True)
class CmnProgram:
    """平文と、その平文が使う採用語彙。"""

    source: str
    literals: tuple[tuple[str, int], ...] = ()


def _const(value: int) -> DExpr:
    return DExpr("const", value=value)


def _input(address: int) -> DExpr:
    return DExpr("input", value=address)


def _binary(kind: str, left: DExpr, right: DExpr) -> DExpr:
    return DExpr(kind, left=left, right=right)


def _neg(value: DExpr) -> DExpr:
    return DExpr("neg", left=value)


def _add(a: RExpr, b: RExpr) -> RExpr:
    return RExpr(
        _binary("add", _binary("mul", a.numerator, b.denominator),
                _binary("mul", b.numerator, a.denominator)),
        _binary("mul", a.denominator, b.denominator),
    )


def _mul(a: RExpr, b: RExpr) -> RExpr:
    return RExpr(_binary("mul", a.numerator, b.numerator),
                 _binary("mul", a.denominator, b.denominator))


def _div(a: RExpr, b: RExpr) -> RExpr:
    return RExpr(_binary("mul", a.numerator, b.denominator),
                 _binary("mul", a.denominator, b.numerator))


def _power(value: RExpr, exponent: int) -> RExpr:
    if exponent == 0:
        return RExpr(_const(1), _const(1))
    if exponent < 0:
        value = RExpr(value.denominator, value.numerator)
        exponent = -exponent
    out = RExpr(_const(1), _const(1))
    for _ in range(exponent):
        out = _mul(out, value)
    return out


class _Parser:
    def __init__(self, source: str, addresses: dict[str, tuple[int, int]]):
        self.source = source
        self.addresses = addresses
        self.graph_nodes: list[GraphNode] = []
        self.graph_edges: list[tuple[int, int]] = []
        self.count = 0

    def parse(self) -> ParsedExpression:
        if not self.source.strip():
            raise ExpressionError("数式を入力してください。")
        if len(self.source) > 256:
            raise ExpressionError("数式は 256 文字以内にしてください。")
        try:
            tree = ast.parse(self.source, mode="eval")
        except SyntaxError as exc:
            raise ExpressionError("数式の構文を確認してください。") from exc
        rational, root = self.visit(tree.body, 0)
        if self.count > 80:
            raise ExpressionError("数式の要素は 80 個以内にしてください。")
        variables = tuple(sorted({n.id for n in ast.walk(tree)
                                  if isinstance(n, ast.Name)
                                  and n.id not in {"beta", "bisect"}}))
        missing = [name for name in variables if name not in self.addresses]
        if missing:
            raise ExpressionError("変数の値がありません: " + ", ".join(missing))
        return ParsedExpression(
            self.source,
            ast.unparse(tree),
            rational,
            variables,
            tuple(self.graph_nodes),
            tuple(self.graph_edges),
        )

    def mark(self, label: str, depth: int, children: tuple[int, ...] = ()) -> int:
        node_id = self.count
        self.count += 1
        self.graph_nodes.append(GraphNode(node_id, label, depth))
        self.graph_edges.extend((child, node_id) for child in children)
        return node_id

    def visit(self, node: ast.AST, depth: int) -> tuple[RExpr, int]:
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) \
                and not isinstance(node.value, bool):
            text = ast.get_source_segment(self.source, node) or str(node.value)
            if not re.fullmatch(r"(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?", text):
                raise ExpressionError("数値の表記を確認してください。")
            value = Fraction(text)
            if abs(value.numerator) > 1_000_000 or value.denominator > 1_000_000:
                raise ExpressionError("数値の分子と分母は 1000000 以下にしてください。")
            return RExpr(_const(value.numerator), _const(value.denominator)), \
                self.mark(text, depth)
        if isinstance(node, ast.Name):
            if node.id not in self.addresses:
                raise ExpressionError("変数の値がありません: " + node.id)
            numerator, denominator = self.addresses[node.id]
            return RExpr(_input(numerator), _input(denominator)), \
                self.mark(node.id, depth)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
            value, child = self.visit(node.operand, depth + 1)
            if isinstance(node.op, ast.USub):
                value = RExpr(_neg(value.numerator), value.denominator)
                label = "−"
            else:
                label = "+"
            return value, self.mark(label, depth, (child,))
        if isinstance(node, ast.BinOp):
            left, left_id = self.visit(node.left, depth + 1)
            if isinstance(node.op, ast.Pow):
                exponent = self.integer_exponent(node.right)
                exponent_id = self.mark(str(exponent), depth + 1)
                return _power(left, exponent), self.mark(
                    "べき", depth, (left_id, exponent_id))
            right, right_id = self.visit(node.right, depth + 1)
            if isinstance(node.op, ast.Add):
                value, label = _add(left, right), "+"
            elif isinstance(node.op, ast.Sub):
                value = _add(left, RExpr(_neg(right.numerator), right.denominator))
                label = "−"
            elif isinstance(node.op, ast.Mult):
                value, label = _mul(left, right), "×"
            elif isinstance(node.op, ast.Div):
                value, label = _div(left, right), "÷"
            else:
                raise ExpressionError("使用できる二項演算は +、-、*、/、** です。")
            return value, self.mark(label, depth, (left_id, right_id))
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            values = [self.visit(arg, depth + 1) for arg in node.args]
            if node.keywords:
                raise ExpressionError("関数の引数は位置で指定してください。")
            if node.func.id == "beta" and len(values) == 1:
                value = _div(_add(values[0][0], RExpr(_const(1), _const(1))),
                             RExpr(_const(2), _const(1)))
            elif node.func.id == "bisect" and len(values) == 2:
                value = _div(_add(values[0][0], values[1][0]),
                             RExpr(_const(2), _const(1)))
            else:
                raise ExpressionError("使用できる関数は beta(x) と bisect(x, a) です。")
            return value, self.mark(node.func.id, depth,
                                    tuple(item[1] for item in values))
        raise ExpressionError("数式に使用できない構文があります。")

    @staticmethod
    def integer_exponent(node: ast.AST) -> int:
        sign = 1
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
            sign = -1
            node = node.operand
        if not isinstance(node, ast.Constant) or not isinstance(node.value, int) \
                or isinstance(node.value, bool) or abs(node.value) > 8:
            raise ExpressionError("指数は -8 から 8 までの整数にしてください。")
        return sign * node.value


def variable_names(source: str) -> tuple[str, ...]:
    """数式が参照する変数名を返す。"""
    try:
        tree = ast.parse(source, mode="eval")
    except SyntaxError as exc:
        raise ExpressionError("数式の構文を確認してください。") from exc
    return tuple(sorted({node.id for node in ast.walk(tree)
                         if isinstance(node, ast.Name)
                         and node.id not in {"beta", "bisect"}}))


def parse_expression(source: str,
                     addresses: dict[str, tuple[int, int]]) -> ParsedExpression:
    """許可した数式を厳密有理式として読む。"""
    return _Parser(source, addresses).parse()


class CmnBuilder:
    """型付きの席を保ったままチェンバーの層を記述する。"""

    def __init__(self):
        self.lines: list[str] = []
        self.width = 0
        self.literal_words: dict[int, str] = {}

    def literal_word(self, value: int) -> str:
        known = self.literal_words.get(value)
        if known is not None:
            return known
        syllables = ("be", "bo", "pa", "pi", "pu", "pe", "po")
        number = len(self.literal_words)
        digits = [number % 7]
        number //= 7
        while number:
            digits.append(number % 7)
            number //= 7
        while len(digits) < 2:
            digits.append(0)
        word = "".join(syllables[index] for index in reversed(digits))
        self.literal_words[value] = word
        return word

    def layer(self, prefix: int, words: list[str], result_width: int):
        if prefix < 0 or prefix > self.width:
            raise AssertionError("チェンバー境界が一致しません。")
        self.lines.append(" ".join(["ki"] * prefix + words + ["ka"]))
        self.width = prefix + result_width

    def push_integer(self, value: int):
        self.layer(self.width, [self.literal_word(value)], 1)

    def push(self, expression: DExpr):
        if expression.kind == "const":
            self.push_integer(expression.value)
            return
        if expression.kind == "input":
            self.push_integer(expression.value)
            self.layer(self.width - 1, ["mi"], 1)
            return
        if expression.kind == "neg" and expression.left is not None:
            self.push(expression.left)
            self.layer(self.width - 1, ["ha"], 1)
            return
        if expression.kind in {"add", "mul"} \
                and expression.left is not None and expression.right is not None:
            self.push(expression.left)
            self.push(expression.right)
            self.layer(self.width - 2,
                       ["no" if expression.kind == "add" else "ti"], 1)
            return
        raise AssertionError("Dyad 式の種類が不正です。")

    def push_dyadic(self, value: Fraction):
        denominator = value.denominator
        if denominator & (denominator - 1):
            raise ExpressionError("影響量は k/2^d の形で入力してください。")
        self.push_integer(value.numerator)
        for _ in range(denominator.bit_length() - 1):
            self.push_integer(0)
            self.layer(self.width - 1, ["se"], 1)
            self.layer(self.width - 2, ["ti"], 1)

    def finish(self) -> CmnProgram:
        if not self.lines:
            raise AssertionError("チェンバーが空です。")
        self.lines[-1] = self.lines[-1][:-3]
        return CmnProgram("\n".join(self.lines) + "\n",
                          tuple((word, value)
                                for value, word in self.literal_words.items()))

    def rational(self, expression: RExpr) -> CmnProgram:
        self.push(expression.numerator)
        self.push(expression.denominator)
        self.layer(self.width - 2, ["ba"], 1)
        if self.width != 1:
            raise AssertionError("出口境界が一つに閉じていません。")
        return self.finish()


def expression_cmn(parsed: ParsedExpression) -> CmnProgram:
    """有理式を一つの Rational 席へ閉じる Common 文を返す。"""
    return CmnBuilder().rational(parsed.rational)


def trace_cmn(word: str) -> CmnProgram:
    """i と j の構成履歴を終点観測へ閉じる Common 文を返す。"""
    if not word or len(word) > 64 or any(letter not in "ij" for letter in word):
        raise ExpressionError("構成語は 1 文字から 64 文字までの i と j で書いてください。")
    lines = ["re ka"]
    lines.extend(("sa ka" if letter == "i" else "si ka") for letter in word)
    lines.append("wi")
    return CmnProgram("\n".join(lines) + "\n")


def influence_cmn(left: Fraction, right: Fraction, operation: str) -> CmnProgram:
    """二つのスカラー判断値を quantale の一つの判断値へ閉じる。"""
    words = {"star": "nu", "sup": "yu", "right": "ye", "left": "yo"}
    if operation not in words:
        raise ExpressionError("影響演算は star、sup、right、left から選んでください。")
    if not 0 <= left <= 1 or not 0 <= right <= 1:
        raise ExpressionError("影響量は 0 から 1 までにしてください。")
    builder = CmnBuilder()
    builder.push_dyadic(left)
    builder.layer(builder.width - 1, ["na"], 1)
    builder.push_dyadic(right)
    builder.layer(builder.width - 1, ["na"], 1)
    builder.layer(builder.width - 2, [words[operation]], 1)
    return builder.finish()
