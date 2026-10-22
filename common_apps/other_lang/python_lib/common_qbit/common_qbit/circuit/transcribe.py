# -*- coding: utf-8 -*-
"""Qiskit の回路を .cmn の平文へ写す。

doc: commonc.lexicon plain.lexicon

回路の操作を、依存だけから決まる層へ分け、同じ層の操作を並置した平文にする。計算はしない。

  量子ビット k   原点 ma に i（zu）と j（ze）を当てた名詞ノードを kukeyi で番号にする
  ゲート         量子ビットの連鎖に続けて、ゲートの語（front の qbit.cam、g = 72〜83）
  測定           量子ビットの連鎖に続けて kukeho。結果は kukeru（古典のストア）で古典ビットへ書く
  リセット       量子ビットの連鎖に続けて kukema
  移送           量子ビットの連鎖と結果 x の連鎖に続けて kukemi
  表のゲート     表の番号の連鎖に続けて kukemu（選択）、量子ビットの連鎖に続けて kukeme（1 量子ビット）か kukemo（2）
  古典の状態     古典ビットと旗は、実行台の cl[c]。kukera が読み、kukeru が書く。プログラムの最後に
                 古典ビットを番号順に du で出力へ置く
  条件つき       述語 p = ∏(条件の原子)（kukera から作る 0 か 1。式 16.5.11 の sel と同じく分岐は使わない）を
                 kukeri（条件）で置き、次の一命令だけを実行する。実行しなかった操作は h に残らない（式 12.6）
  while          ya … yi の閉包。旗 act（反復の初めの条件）、brk（break）、cont（continue）を古典の状態に置く
  delay          kukere。待機は h に足す（式 12.2）
  initialize     全量子ビットへの initialize は、状態の設定 kukewi（u の桁を使わない。Aer と同じ）。一部の量子ビットは reset と準備のゲート
  3 量子ビット以上のユニタリ   選択（kukemu）、量子ビットごとに kukero で並びへ積み、kukewa で一括して掛ける

語の名前は 10 §4 の式 (1.2) が決める。g の 3 音節の名前は ku + [σ_3, σ_{g-60}]。
"""
from fractions import Fraction

from qiskit.circuit import Measure
from qiskit.circuit.library import RYGate, RZGate

from common_vcpu import vqpu

SYL = "kstnhmyrwgzdbp"
MEASURE_G, RESET_G, TRANSPORT_G = 84, 85, 86
SAVE_G, INDEX_G, MOBIUS_G, BETA_G, EPS_G, READ_G = 90, 91, 92, 93, 94, 95
GUARD_G, STORE_G, DELAY_G = 96, 97, 98
GATE_G = dict((name, 72 + i) for i, name in enumerate(vqpu.GATES))
ROT_G = {"rx": 87, "ry": 88, "rz": 89}       # 回転。二本目のワイヤは角の番号（host の角の表の添字）


def _syl(i):
    return SYL[i // 5] + "aiueo"[i % 5]


def word(g):
    """生成元 g（72 以降）の名前。"""
    return "ku" + _syl(3) + _syl(g - 60)


def node_word(k):
    """cell 番号が k の名詞ノードへ、原点から i（zu）と j（ze）を交互に当てる語。

    cell(w) = 2 zz(m) + ε、ノードの (m, ε) は i で (m, 1-ε)、j で (m + 1 - 2ε, 1-ε) へ動く
    （region.cam の kukeke、構成語 §7）。幅優先で最短の語を探す。
    """
    def zz(m):
        return 2 * m if m >= 0 else -2 * m - 1

    seen, queue = {(0, 0, "")}, [(0, 0, "")]
    for m, e, w in queue:
        if 2 * zz(m) + e == k:
            return w
        for letter, (m2, e2) in (("i", (m, 1 - e)), ("j", (m + 1 - 2 * e, 1 - e))):
            if w[-1:] != letter and (m2, e2, w + letter) not in seen:
                seen.add((m2, e2, w + letter))
                queue.append((m2, e2, w + letter))
    raise ValueError("cell %d へ届く語が無い" % k)


def qubit(k, prefix):
    """frontier の先頭 prefix 本を通し、その次に量子ビット k を一本立てる文。

    量子ビットは、ツイ数平面の名詞ノード（原点に i と j を当てた点）。kukeyi がその cell 番号を
    定数の箱にする。k = 0 は原点そのもの。
    """
    p = "ki " * prefix
    layers = ["%sma ka" % p]
    for letter in node_word(k):
        layers.append("%s%s ka" % (p, "zu" if letter == "i" else "ze"))
    layers.append("%s%s ka" % (p, word(INDEX_G)))
    return ", ".join(layers)


SAVES = {"save_statevector": 0, "save_density_matrix": 1, "save_stabilizer": 2}       # QV の入力: 保存する ρ の種類
NATIVE = set(GATE_G) | set(ROT_G) | {"measure", "reset", "barrier", "id", "counter_transport", "counter_mobius", "counter_beta",
                        "delay"} | set(SAVES)
BREAKS = ("break_loop", "continue_loop")
UNITS = vqpu.DELAY_UNITS


# ---- 作業台: 古典ビットの番号の続きに、旗と変数の番号を割り当てる ----

class _Ctx(object):
    def __init__(self, circ):
        self.ncl = circ.num_clbits
        self.n = self.ncl
        self.nq = circ.num_qubits
        self.vars = {}
        self.loops = []                 # 内側の繰り返しの (break の旗, continue の旗)

    def new(self):
        self.n += 1
        return self.n - 1

    def var(self, v, width):
        if v not in self.vars:
            self.vars[v] = [self.new() for _ in range(width)]
        return self.vars[v]


# ---- 古典の式を、1 ビットずつの木へ開く ----
#
# 節点: ('c', 古典の番号) ('k', 0 か 1) ('not', x) ('and', x, y) ('or', x, y) ('xor', x, y)
# 値の積み方は _node が決める。ビット演算は 1 ビットごと、比較は排他的論理和の否定の積。

def _cond_bits(circ, target, cmap):
    """条件の対象（古典ビットか古典レジスタ）の古典ビットの添字の並び（下位が先）。"""
    if hasattr(target, "size"):                      # 古典レジスタ
        return [cmap[circ.find_bit(b).index] for b in target]
    return [cmap[circ.find_bit(target).index]]       # 古典ビット


def _width(t):
    return 1 if t.__class__.__name__ == "Bool" else t.width


def _reduce(op, bits):
    acc = bits[0]
    for b in bits[1:]:
        acc = (op, acc, b)
    return acc


def _lvalue_cells(circ, e, cmap, ctx):
    from qiskit.circuit.classical import expr
    if isinstance(e, expr.Var):
        v = e.var
        if v.__class__.__name__ == "Clbit" or hasattr(v, "size"):
            return _cond_bits(circ, v, cmap)
        return ctx.var(v, _width(e.type))
    raise NotImplementedError("未対応の store の対象: %r" % (e,))


def _bits(circ, e, cmap, ctx):
    from qiskit.circuit.classical import expr
    U, B = expr.Unary.Op, expr.Binary.Op
    if isinstance(e, expr.Cast):
        b = _bits(circ, e.operand, cmap, ctx)
        w = _width(e.type)
        return [_reduce("or", b)] if w == 1 and len(b) > 1 else (b + [("k", 0)] * w)[:w]
    if isinstance(e, expr.Var):
        return [("c", c) for c in _lvalue_cells(circ, e, cmap, ctx)]
    if isinstance(e, expr.Value):
        return [("k", (int(e.value) >> i) & 1) for i in range(_width(e.type))]
    if isinstance(e, expr.Unary):
        b = _bits(circ, e.operand, cmap, ctx)
        if e.op == U.BIT_NOT:
            return [("not", x) for x in b]
        if e.op == U.LOGIC_NOT:
            return [("not", _reduce("or", b))]
    if isinstance(e, expr.Binary):
        l, r = _bits(circ, e.left, cmap, ctx), _bits(circ, e.right, cmap, ctx)
        n = max(len(l), len(r))
        l, r = (l + [("k", 0)] * n)[:n], (r + [("k", 0)] * n)[:n]
        names = {B.BIT_AND: "and", B.BIT_OR: "or", B.BIT_XOR: "xor"}
        if e.op in names:
            return [(names[e.op], x, y) for x, y in zip(l, r)]
        if e.op == B.LOGIC_AND:
            return [("and", _reduce("or", l), _reduce("or", r))]
        if e.op == B.LOGIC_OR:
            return [("or", _reduce("or", l), _reduce("or", r))]
        if e.op in (B.EQUAL, B.NOT_EQUAL):
            eq = _reduce("and", [("not", ("xor", x, y)) for x, y in zip(l, r)])
            return [eq if e.op == B.EQUAL else ("not", eq)]
    raise NotImplementedError("未対応の式: %r" % (e,))


def _node_cells(n):
    return [n[1]] if n[0] == "c" else ([] if n[0] == "k" else [c for x in n[1:] for c in _node_cells(x)])


# ---- 条件の原子 ----
#
# ('bits', 古典の番号の並び, 値, 否定か)   レジスタ（下位が先）の値が一致するか
# ('cell', 番号, 否定か)                    旗が立っているか
# ('expr', 節点, 否定か)                    1 ビットの式が真か

def _neg(a):
    return a[:-1] + (not a[-1],)


def _atom_node(a):
    if a[0] == "cell":
        n = ("c", a[1])
    elif a[0] == "bits":
        n = _reduce("and", [("c", cb) if (a[2] >> i) & 1 else ("not", ("c", cb)) for i, cb in enumerate(a[1])])
    else:
        n = a[1]
    return ("not", n) if a[-1] else n


def _atom_cells(a):
    return list(a[1]) if a[0] == "bits" else ([a[1]] if a[0] == "cell" else _node_cells(a[1]))


def _operand(e):
    """式の被演算子から、古典ビットか古典レジスタ、または整数を取り出す。"""
    from qiskit.circuit.classical import expr
    if isinstance(e, expr.Cast):
        return _operand(e.operand)
    if isinstance(e, expr.Var):
        return e.var
    if hasattr(e, "size") or e.__class__.__name__ == "Clbit":
        return e
    if isinstance(e, expr.Value):
        return int(e.value)
    raise NotImplementedError("未対応の式: %r" % (e,))


def _condition(circ, cond, cmap, ctx):
    """if_else と while の条件を、原子へ。レジスタと整数の比較は 'bits'、それ以外の式は 'expr'。"""
    from qiskit.circuit.classical import expr
    if isinstance(cond, tuple):
        if not isinstance(cond[1], int):
            raise NotImplementedError("未対応の条件: %r" % (cond,))
        return ("bits", tuple(_cond_bits(circ, cond[0], cmap)), int(cond[1]), False)
    try:
        if isinstance(cond, expr.Binary) and cond.op in (expr.Binary.Op.EQUAL, expr.Binary.Op.NOT_EQUAL):
            a, b = _operand(cond.left), _operand(cond.right)
            if isinstance(a, int):
                a, b = b, a
            if isinstance(b, int) and not isinstance(a, int):
                return ("bits", tuple(_cond_bits(circ, a, cmap)), b, cond.op == expr.Binary.Op.NOT_EQUAL)
        if isinstance(cond, expr.Unary) and cond.op == expr.Unary.Op.LOGIC_NOT:
            a = _operand(cond.operand)
            if not isinstance(a, int):
                return ("bits", tuple(_cond_bits(circ, a, cmap)), 0, False)
        if isinstance(cond, expr.Var) and (cond.var.__class__.__name__ == "Clbit" or hasattr(cond.var, "size")):
            return ("bits", tuple(_cond_bits(circ, cond.var, cmap)), 1, False)
    except NotImplementedError:
        pass
    return ("expr", _reduce("or", _bits(circ, cond, cmap, ctx)), False)


def _check_params(op):
    """標準ゲートと同じ名前の操作は、引数の数が標準ゲートと一致しなければならない。"""
    std = _standard().get(op.name)
    if std is not None and len(op.params) != len(std.params):
        raise ValueError('操作 %s の "params" is incorrect length: %d（標準は %d）' % (op.name, len(op.params), len(std.params)))


_STD = []


def _standard():
    if not _STD:
        from qiskit.circuit.library import get_standard_gate_name_mapping
        _STD.append(get_standard_gate_name_mapping())
    return _STD[0]


def _writes(circ):
    """回路（の本体）が古典の状態を書くか。条件を一度だけ読むために使う。"""
    for inst in circ.data:
        op = inst.operation
        if op.name in ("measure", "store", "while_loop", "for_loop"):
            return True
        if op.name in ("if_else", "switch_case") and any(_writes(b) for b in op.blocks):
            return True
    return False


def _uses_jump(circ):
    for inst in circ.data:
        op = inst.operation
        if op.name in BREAKS:
            return True
        if op.name in ("if_else", "switch_case") and any(_uses_jump(b) for b in op.blocks):
            return True
    return False


def _capture(atom, conds, ctx):
    """原子の値を旗へ写して返す。本体が条件の古典ビットを書き換えても、条件は一度だけ読まれる。"""
    cell = ctx.new()
    return ("store", [cell], [_atom_node(atom)], conds), ("cell", cell, False)


def flatten(circ, qmap=None, cmap=None, conds=(), ctx=None):
    """回路の命令を、語彙の中のものだけへ開く。順序は変えない。

    Qiskit の transpile は DAG を経由して独立な演算を並べ替える。Counter 量子情報論では
    操作順序が構成語 h に残る（式 1.6、12.6）ので、定義（definition）を順に開く。
    返りは次のどれかの列。
      (演算, 量子ビットの添字の並び, 古典ビットの添字の並び, 条件の並び)
      ('store', 古典の番号の並び, 節点の並び, 条件の並び)   ビットごとに書く
      ('while', 本体, 条件の原子, (act, brk), 条件の並び)
    for_loop は添字ごとに開く。break と continue は旗を立て、以降の命令を旗の否定で条件づける。
    """
    from qiskit.circuit.classical import expr
    ctx = ctx or _Ctx(circ)
    qmap = qmap if qmap is not None else list(range(circ.num_qubits))
    cmap = cmap if cmap is not None else list(range(circ.num_clbits))
    for inst in circ.data:
        op = inst.operation
        qs = [qmap[circ.find_bit(q).index] for q in inst.qubits]
        cs = [cmap[circ.find_bit(c).index] for c in inst.clbits]
        if op.name == "if_else":
            atom = _condition(circ, op.condition, cmap, ctx)
            true_body, false_body = op.params[0], op.params[1]
            if any(b is not None and _writes(b) for b in (true_body, false_body)) and atom[0] != "cell":
                st, atom = _capture(atom, conds, ctx)
                yield st
            for body, flip in ((true_body, False), (false_body, True)):
                if body is not None:
                    yield from flatten(body, qs, cs, conds + ((_neg(atom) if flip else atom),), ctx)
            continue
        if op.name == "switch_case":
            target = op.target
            tb = _bits(circ, target if isinstance(target, expr.Expr) else expr.lift(target), cmap, ctx)
            bits = tuple(n[1] if n[0] == "c" else None for n in tb)
            if None in bits or any(_writes(b) for b in op.blocks):     # 式、または本体が対象を書く: 旗へ写す
                cells = [ctx.new() for _ in tb]
                yield ("store", cells, tb, conds)
                bits = tuple(cells)
            seen = []
            for values, body in op.cases_specifier():
                vs = [v for v in values if isinstance(v, int)]
                if len(vs) != len(values):                 # default: どの値でもない
                    yield from flatten(body, qs, cs, conds + tuple(("bits", bits, v, True) for v in seen), ctx)
                    break
                if len(vs) == 1:
                    atom = ("bits", bits, vs[0], False)
                else:                                      # 一つの本体に複数の値: どれかに一致する
                    atom = ("expr", _reduce("or", [_atom_node(("bits", bits, v, False)) for v in vs]), False)
                seen.extend(vs)
                yield from flatten(body, qs, cs, conds + (atom,), ctx)
            continue
        if op.name == "for_loop":
            indexset, var, body = op.params
            jump = _uses_jump(body)
            if jump:
                brk, cont = ctx.new(), ctx.new()
                yield ("store", [brk], [("k", 0)], ())
            for i in indexset:
                inner = conds
                if jump:
                    yield ("store", [cont], [("k", 0)], ())
                    inner = conds + (("cell", brk, True), ("cell", cont, True))
                    ctx.loops.append((brk, cont))
                yield from flatten(body.assign_parameters({var: i}) if var is not None else body, qs, cs, inner, ctx)
                if jump:
                    ctx.loops.pop()
            continue
        if op.name == "while_loop":
            atom = _condition(circ, op.condition, cmap, ctx)
            body = op.params[0]
            act, brk, cont = ctx.new(), ctx.new(), ctx.new()
            yield ("store", [act], [("k", 0)], ())
            yield ("store", [brk], [("k", 0)], ())
            inner = [("store", [act], [_atom_node(atom)], conds), ("store", [cont], [("k", 0)], ())]
            ctx.loops.append((brk, cont))
            inner += list(flatten(body, qs, cs, conds + (("cell", act, False), ("cell", brk, True),
                                                         ("cell", cont, True)), ctx))
            ctx.loops.pop()
            yield ("while", inner, atom, (act, brk), conds)
            continue
        if op.name in BREAKS:
            brk, cont = ctx.loops[-1]
            yield ("store", [brk if op.name == "break_loop" else cont], [("k", 1)], conds)
            continue
        if op.name == "store":
            cells = _lvalue_cells(circ, op.lvalue, cmap, ctx)
            nodes = (_bits(circ, op.rvalue, cmap, ctx) + [("k", 0)] * len(cells))[:len(cells)]
            if any(c in cells for n in nodes for c in _node_cells(n)):      # 自分自身を読む: 先に控えへ写す
                tmp = [ctx.new() for _ in cells]
                yield ("store", tmp, nodes, conds)
                nodes = [("c", c) for c in tmp]
            yield ("store", cells, nodes, conds)
            continue
        _check_params(op)
        if op.name == "measure" and len(qs) > 1:          # 複数の量子ビットを一つにまとめた測定: 組ごとに開く
            for q, c in zip(qs, cs):
                yield Measure(), [q], [c], conds
            continue
        if op.name in NATIVE:
            yield op, qs, cs, conds
        elif op.name == "u":                              # U(θ, φ, λ) = e^{i(φ+λ)/2} Rz(φ) Ry(θ) Rz(λ)。大域位相は重みに効かない
            theta, phi, lam = op.params
            for g in (RZGate(lam), RYGate(theta), RZGate(phi)):
                yield g, qs, [], conds
        elif getattr(op, "definition", None) is not None and getattr(op, "condition", None) is None:
            yield from flatten(op.definition, qs, cs, conds, ctx)
        else:
            raise NotImplementedError("未対応の命令: %s" % op.name)


# ---- 層の部品 ----

def _q(k, w):
    """量子ビット k を立てる層の並び（各層は ka を除いた文）。w は、左に既にある量子ビットの本数。"""
    p = "ki " * w
    return [p + "ma"] + [p + ("zu" if c == "i" else "ze") for c in node_word(k)] + [p + word(INDEX_G)]


def _skip(w, token):
    return "ki " * w + token


def _num(n, w):
    """整数 n を一本立てる層の並び。32 以上は、2 倍と 1 の加算で組む（_q は n に比例して長くなる）。"""
    if n < 32:
        return _q(n, w)
    out = _q(1, w)
    for b in bin(n)[3:]:
        out += [_skip(w, "he"), _skip(w, "no")]
        if b == "1":
            out += _q(1, w + 1) + [_skip(w, "no")]
    return out


def _read(cell, w):
    """古典の状態 cl[cell] を一本立てる層。"""
    return _num(cell, w) + [_skip(w, word(READ_G))]


def _node(n, w):
    """節点の値（0 か 1）を、位置 w に一本立てる層の並び。"""
    k = n[0]
    if k == "c":
        return _read(n[1], w)
    if k == "k":
        return _q(n[1], w)
    if k == "not":                                  # 1 ⊖ x
        return _q(1, w) + _node(n[1], w + 1) + [_skip(w + 1, "ha"), _skip(w, "no")]
    if k == "and":
        return _node(n[1], w) + _node(n[2], w + 1) + [_skip(w, "ti")]
    if k == "or":                                   # 1 ⊖ (1 ⊖ x)(1 ⊖ y)
        return _node(("not", ("and", ("not", n[1]), ("not", n[2]))), w)
    if k == "xor":                                  # (x ⊖ y)^2
        return (_node(n[1], w) + _node(n[2], w + 1)
                + [_skip(w + 1, "ha"), _skip(w, "no"), _skip(w, "he"), _skip(w, "ti")])
    raise ValueError(n)


def _predicate(conds, w):
    """条件の並びの述語 p ∈ {0, 1} を作る層。作った後は w + 1 本。条件が複数あれば述語の積。"""
    return _node(_reduce("and", [_atom_node(a) for a in conds]), w)


def _guard(conds, w):
    """条件が成り立つときだけ、次の量子の命令を実行する（kukeri。一回かぎり）。"""
    return _predicate(conds, w) + [_skip(w, word(GUARD_G))] if conds else []


def _angle(angles, theta):
    """角 θ（float の値そのもの。二進有理数）を (m, e)（θ = m / 2^e）にして表へ置き、添字を返す。"""
    f = Fraction(float(theta))
    e = f.denominator.bit_length() - 1
    entry = (f.numerator, e)
    if entry not in angles:
        angles.append(entry)
    return angles.index(entry)


def _delay_code(op):
    """継続時間の符号 = 時間 × 8 + 単位の番号。整数にならない時間は、一つ小さい単位へ直す。"""
    d = Fraction(op.duration).limit_denominator(1 << 30)
    k = UNITS.index(op.unit)
    while d.denominator != 1 and 1 <= k < len(UNITS) - 1:
        d, k = d * 1000, k + 1
    return int(round(d)) * 8 + k


def _store_layers(cells, nodes, conds):
    """ビットごとの古典のストア。値を立て、条件を置き、番号を立てて kukeru。"""
    out = []
    for cell, node in zip(cells, nodes):
        out += _node(node, 0) + _guard(conds, 1) + _num(cell, 1) + [_skip(0, word(STORE_G))]
    return out


def _op_layers(op, qs, cs, tables, saves, conds):
    """一つの操作の連鎖を、層の並びで返す。

    量子ビットの語は、ノードを作る層、cell 番号にする層、ゲートの層の順に並ぶ。
    表のゲートは、選択と適用の間に機械の状態（選んだ行）を持つので、他の操作と同じ層に置かない。
    """
    name = op.name
    g = _guard(conds, 0)
    if name in SAVES:
        saves.append((op.label, SAVES[name], list(qs)))
        return _num(SAVES[name], 0) + [word(SAVE_G)]
    if name == "reset":
        return g + _q(qs[0], 0) + [word(RESET_G)]
    if name == "counter_mobius":
        f = Fraction(op.params[0]).limit_denominator(1 << 20)
        return g + _num(f.numerator, 0) + _num(f.denominator, 1) + [word(MOBIUS_G)]
    if name == "counter_beta":
        return g + [word(BETA_G)]
    if name == "delay":
        return g + _q(qs[0], 0) + _num(_delay_code(op), 1) + [word(DELAY_G)]
    if name == "counter_transport":
        out = []
        if len(op.params) > 1 and Fraction(op.params[1]) != 1:      # 部分移送の割合。分子と分母を置いてから移送する
            eps = Fraction(op.params[1]).limit_denominator(1 << 20)
            out += _num(eps.numerator, 0) + _num(eps.denominator, 1) + [word(EPS_G)]
        return out + g + _q(qs[0], 0) + _num(int(op.params[0]), 1) + [word(TRANSPORT_G)]
    if name == "measure":
        # 測って x を立て、古典ビットへ書く。条件は、測定とストアの両方に置く
        return g + _q(qs[0], 0) + [word(MEASURE_G)] + _guard(conds, 1) + _num(cs[0], 1) + [_skip(0, word(STORE_G))]
    if name in ROT_G:
        return g + _q(qs[0], 0) + _q(_angle(tables, op.params[0]), 1) + [word(ROT_G[name])]
    if name in GATE_G:
        if len(qs) == 1:
            return g + _q(qs[0], 0) + [word(GATE_G[name])]
        return g + _q(qs[0], 0) + _q(qs[1], 1) + [word(GATE_G[name])]
    raise NotImplementedError("作図の無い命令: %s" % name)


# ---- 層への分け方 ----

def _emit_segment(seg, tables, saves, nq):
    """ループを含まない命令の列を、依存（同じ量子ビット、同じ古典の番号）だけから決まる層へ分け、
    同じ層の操作を並置した行にする。

    各操作の連鎖（ノードを作る層、cell 番号にする層、ゲートの層）は、ゲートの語が走る層を
    そろえて、左から並べる。ka の数は、層の中で一番長い連鎖の長さになる。

    同じ層の箱は左から順に走る。順序は、測定以外が元の命令の順序、測定は古典ビットの降順のまとまり
    （論文 §13.3: 結果のビット列を整数へ読む順序を一つ固定する。最上位が先。式 4.17 の x = ⌊2^n u⌋）。
    """
    ops, last, pi = [], {}, 0
    for it in seg:
        if isinstance(it[0], str):                       # ストア
            _tag, cells, nodes, conds = it
            reads = [c for n in nodes for c in _node_cells(n)] + [c for a in conds for c in _atom_cells(a)]
            deps = [("c", c) for c in list(cells) + reads]
            o = {"layers": _store_layers(cells, nodes, conds), "excl": True, "meas": False, "cs": []}
        else:
            op, qs, cs, conds = it
            name = op.name
            if name == "id":
                continue
            if getattr(op, "condition", None) is not None:
                raise NotImplementedError("条件つきの命令は未対応: %s" % name)
            deps = [("q", q) for q in qs] + [("c", c) for c in list(cs) + [c for a in conds for c in _atom_cells(a)]]
            if name in SAVES or name in ("counter_beta", "set_state"):
                deps = [("q", q) for q in range(nq)]
            if name == "barrier":
                t = max([last.get(d, 0) for d in deps] + [0])
                for d in deps:
                    last[d] = t
                continue
            o = {"op": op, "qs": qs, "cs": cs, "conds": conds, "meas": name == "measure",
                 "excl": bool(conds) or name in SAVES or name in ("counter_transport", "measure")
                 or name not in NATIVE}
        t = 1 + max([last.get(d, 0) for d in deps] + [0])
        for d in deps:
            last[d] = t
        pi += 1
        o.update(t=t, pi=pi)
        ops.append(o)
    ops.sort(key=lambda o: (o["t"], o["pi"]))
    # 同じ層の中の、測定の降順の整列。測定でない排他の操作は、整列の境になる
    runs, cur = [], []
    for o in ops:
        if cur and (o["t"] != cur[-1]["t"] or (o["excl"] and not o["meas"]) or (cur[-1]["excl"] and not cur[-1]["meas"])):
            runs.append(cur)
            cur = []
        cur.append(o)
    runs.append(cur)
    ordered = []
    for run in runs:
        fm = min([o["pi"] for o in run if o["meas"]] + [1 << 60])
        run.sort(key=lambda o: (fm, 1, -o["cs"][0]) if o["meas"] else (o["pi"], 0, 0))
        ordered += run
    for o in ordered:
        if "layers" not in o:
            o["layers"] = _op_layers(o["op"], o["qs"], o["cs"], tables, saves, o["conds"])
    lines, i = [], 0
    while i < len(ordered):
        j = i + 1
        if not ordered[i]["excl"]:
            while j < len(ordered) and not ordered[j]["excl"] and ordered[j]["t"] == ordered[i]["t"]:
                j += 1
        group = ordered[i:j]
        top = max(len(o["layers"]) - 1 for o in group)
        pad = [top - (len(o["layers"]) - 1) for o in group]
        n = max(p_ + len(o["layers"]) for p_, o in zip(pad, group))
        for k in range(n):
            parts = [o["layers"][k - p_] for p_, o in zip(pad, group) if 0 <= k - p_ < len(o["layers"])]
            lines.append(" ".join(parts) + " ka")
        i = j
    return lines


def _emit_items(items, tables, saves, nq):
    """命令の列を行にする。while は ya … yi の閉包で、本体の後に「続けるか」を置いて閉じる。"""
    lines, seg = [], []
    for it in items:
        if isinstance(it[0], str) and it[0] == "while":
            lines += _emit_segment(seg, tables, saves, nq)
            seg = []
            _tag, body, atom, (act, brk), _conds = it
            lines.append("ya ka")
            lines += _emit_items(body, tables, saves, nq)
            go = ("and", ("c", act), ("and", ("not", ("c", brk)), _atom_node(atom)))      # act ∧ ¬brk ∧ 条件
            lines += [l + " ka" for l in _node(("not", go), 0) + [_skip(0, "so")]]
            lines.append("yi ka")
        else:
            seg.append(it)
    return lines + _emit_segment(seg, tables, saves, nq)


def circuit_to_cmn(circ):
    """回路を平文へ。返りは (平文, 出力される古典ビットの添字の並び, 角の表, 保存命令のラベルの並び)。

    角の表は回転の角 (m, e)（θ = m / 2^e）の並び。回転の語の二本目のワイヤが、その添字を名詞の cell 番号で持つ。

    出力は、プログラムの最後に古典ビットを番号順に du で置く。測定の結果は kukeru で古典ビットへ書かれる。
    """
    ctx = _Ctx(circ)
    tables, saves = [], []
    lines = _emit_items(list(flatten(circ, ctx=ctx)), tables, saves, circ.num_qubits)
    for c in range(circ.num_clbits):
        lines += [l + " ka" for l in _read(c, 0) + ["du"]]
    lines.append("me ka")
    return ",\n".join(lines) + "\n", list(range(circ.num_clbits)), tables, saves
