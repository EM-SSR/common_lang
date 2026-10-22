# -*- coding: utf-8 -*-
"""ツイ数幾何グラフを SVG へ写す。座標は Common-Lang/2 定義 4.1 そのもので、ここに計算は無い。

    r(T) = 1 - 2^-|T|                         次数が環の番号になる
    theta(T) = pi * sum_{k in T} 2^-(k+1)     二進符号が偏角になる     上半平面 Pi_i
    r(y_u) = 1/2,  theta(y_u) = -pi*u/(m+1)                          下半平面 Pi_j

辺は二種類（Common-Lang/2 §3）。

    E_star = {(T minus max T, T)}       経路を保持する。Pi_i の中の弦。直線で描く
    E_plus = {(T, y_u) : a_T = 1}       経路を忘れる。実軸を一度だけ横切って Pi_j へ降りる弧

E_plus の制御点は中点の水平方向だけへ寄せる。すると B_y(t) が t の一次式に落ちるので、

    B_y(t) = (1-t)^2 P0y + 2t(1-t)*(P0y+P1y)/2 + t^2 P1y = P0y + t*(P1y - P0y)

実軸との交点が t* = P0y / (P0y - P1y) で厳密に決まり、しかも交わるのは一度だけになる。
交点の丸はこの t* の像に置く。端点の一次補間では曲線の上に乗らない。

カット kappa の直径は偏角 theta_k = pi * 2^-kappa に立つ。

    theta(T) < theta_k  <=>  T が B に収まる

なので直径一本が [n] = A + B をそのまま平面の扇へ分ける。

分離積の重ね描き（定理 4.1）

    f(x_A, x_B) = XOR_{r<rho} p_r(x_A) * q_r(x_B)

は、p_r と q_r の台へ細い線を引き、二つの集約ノードの間に太い弦を一本渡す。
集約ノードは y_u と同じく合算の点なので半径 1/2 の近くに置く。r ごとの僅かな半径差は
重なりを避ける表示上の都合で、偏角は台の平均から出る。カットを渡る太い弦はちょうど rho 本になる。

使い方

    python draw.py --table 0110100110010110 --cut 2 --out fig.svg
    python draw.py --table ... --cut 3 --view factor --theme dark
    python draw.py --table ... --cut 2 --hide star,legend --dim 3,12
"""

import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.abspath(os.path.join(HERE, os.pardir))
if APP not in sys.path:
    sys.path.insert(0, APP)

import build  # noqa: E402

THEME = {
    "light": dict(bg="#fbfbf8", ink="#1b1b1a", ring="#cbc8bd", axis="#8d8878",
                  cut="#b45309", star="#1d4ed8", plus="#047857", node="#1b1b1a",
                  out="#6d28d9", join="#be123c", label="#55514a",
                  wedgeA="#1d4ed8", wedgeB="#047857"),
    "dark": dict(bg="#14151a", ink="#e8e6e1", ring="#3a3d47", axis="#7d8496",
                 cut="#fbbf24", star="#7dabff", plus="#4ade80", node="#e8e6e1",
                 out="#c4a3ff", join="#fb7185", label="#9aa0ad",
                 wedgeA="#7dabff", wedgeB="#4ade80"),
}

LEGEND = [
    ("環  r = 1-2^-|T|", "相互作用の次数 |T|", "ring", "ring"),
    ("青い弦  E_star", "経路の保持。角度差 pi*2^-k がどの x_k か", "star", "line"),
    ("緑の弧  E_plus", "実軸を渡る合算。丸が経路を忘れる一点", "plus", "line"),
    ("橙の直径", "R4 のカット。theta = pi*2^-kappa", "cut", "dash"),
    ("赤の細線", "p_r と q_r が読む単項式", "join", "thin"),
    ("赤の太弦", "カットを渡る独立影響。本数が接合秩", "join", "line"),
]


# ===== 座標（定義 4.1）=====

def popcount(t):
    return bin(t).count("1")


def radius(t):
    return 1.0 - 2.0 ** (-popcount(t))


def angle(t, n):
    return math.pi * sum(2.0 ** (-(k + 1)) for k in range(n) if (t >> k) & 1)


def cut_angle(cut):
    return math.pi * 2.0 ** (-cut)


def xy(r, th, R):
    return (R * r * math.cos(th), -R * r * math.sin(th))


def label_of(t, n):
    return "1" if t == 0 else "".join("x%d" % k for k in range(n) if (t >> k) & 1)


# ===== 交点。線形な汎関数 f について f(B(t)) = 0 を解く =====

def bez(p0, c, p1, t):
    u = 1.0 - t
    return (u * u * p0[0] + 2 * t * u * c[0] + t * t * p1[0],
            u * u * p0[1] + 2 * t * u * c[1] + t * t * p1[1])


def cross_at(p0, c, p1, f, eps=1e-9):
    """f は線形。f(B(t)) = a t^2 + b t + c0 の [0,1] の根のうち最初のものの像を返す"""
    f0, fc, f1 = f(p0), f(c), f(p1)
    a, b, c0 = f0 - 2.0 * fc + f1, 2.0 * (fc - f0), f0
    ts = []
    if abs(a) < eps:
        if abs(b) > eps:
            ts = [-c0 / b]
    else:
        d = b * b - 4.0 * a * c0
        if d >= 0.0:
            s = math.sqrt(d)
            ts = [(-b - s) / (2 * a), (-b + s) / (2 * a)]
    ts = [t for t in ts if -eps <= t <= 1.0 + eps]
    return bez(p0, c, p1, min(max(ts[0], 0.0), 1.0)) if ts else None


def f_axis(p):
    """実軸。Pi_i と Pi_j の共通境界"""
    return p[1]


def f_cut(th):
    """偏角 th の直径。原点を通る直線への符号つき距離"""
    dx, dy = math.cos(th), -math.sin(th)
    return lambda p: p[0] * dy - p[1] * dx


def mid_ctrl(p0, p1, h):
    """中点を水平方向へ h だけ寄せた制御点。y は中点のままなので B_y は t の一次式になる"""
    return ((p0[0] + p1[0]) / 2.0 + h, (p0[1] + p1[1]) / 2.0)


# ===== 辺 =====

def top_bit(t, n):
    return max(k for k in range(n) if (t >> k) & 1)


def star_edges(nodes, n):
    return [(t & ~(1 << top_bit(t, n)), t) for t in nodes if t]


def chain_closure(support, n):
    seen = set([0])
    for t in support:
        while t and t not in seen:
            seen.add(t)
            t &= ~(1 << top_bit(t, n))
    return sorted(seen)


# ===== SVG =====

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Canvas(object):
    def __init__(self, theme):
        self.c = THEME[theme]
        self.body = []

    def line(self, p, q, stroke, w=1.0, op=1.0, dash=None):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        self.body.append('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%s" '
                         'stroke-width="%.2f" opacity="%.3f" stroke-linecap="round"%s/>'
                         % (p[0], p[1], q[0], q[1], stroke, w, op, d))

    def circle(self, p, rr, fill, stroke=None, w=1.0, op=1.0):
        st = ' stroke="%s" stroke-width="%.2f"' % (stroke, w) if stroke else ""
        self.body.append('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s" opacity="%.3f"%s/>'
                         % (p[0], p[1], rr, fill, op, st))

    def ring(self, rr, stroke, w=0.7, op=1.0, dash=None):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        self.body.append('<circle cx="0" cy="0" r="%.2f" fill="none" stroke="%s" '
                         'stroke-width="%.2f" opacity="%.3f"%s/>' % (rr, stroke, w, op, d))

    def quad(self, p0, c, p1, stroke, w=1.4, op=1.0):
        self.body.append('<path d="M %.2f %.2f Q %.2f %.2f %.2f %.2f" fill="none" stroke="%s" '
                         'stroke-width="%.2f" opacity="%.3f" stroke-linecap="round"/>'
                         % (p0[0], p0[1], c[0], c[1], p1[0], p1[1], stroke, w, op))

    def wedge(self, R, a0, a1, fill, op):
        p0, p1 = xy(1.0, a0, R), xy(1.0, a1, R)
        big = 1 if abs(a1 - a0) > math.pi else 0
        self.body.append('<path d="M 0 0 L %.2f %.2f A %.2f %.2f 0 %d 0 %.2f %.2f Z" '
                         'fill="%s" opacity="%.3f" stroke="none"/>'
                         % (p0[0], p0[1], R, R, big, p1[0], p1[1], fill, op))

    def text(self, p, s, fill, size=11, anchor="middle", op=1.0, weight="400"):
        self.body.append('<text x="%.2f" y="%.2f" font-size="%d" font-weight="%s" fill="%s" '
                         'text-anchor="%s" opacity="%.3f" '
                         'font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace">%s</text>'
                         % (p[0], p[1], size, weight, fill, anchor, op, esc(s)))

    def render(self, w, h, vb, title):
        return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="%s" '
                'role="img" aria-label="%s">'
                '<rect x="-100000" y="-100000" width="200000" height="200000" fill="%s"/>'
                % (w, h, vb, esc(title), self.c["bg"]) + "".join(self.body) + "</svg>\n")


# ===== 図 =====

def mean_angle(sup, n, lo, hi):
    """台の偏角の平均を扇の中へ収める。台が空集合だけなら扇の真ん中に置く"""
    if not sup:
        return (lo + hi) / 2.0
    a = sum(angle(t, n) for t in sup) / float(len(sup))
    m = lo + 0.08 * (hi - lo)
    M = lo + 0.92 * (hi - lo)
    return min(max(a, m), M)


def draw(fig, opt):
    n, cut, rho, anf = fig["n"], fig["cut"], fig["rho"], fig["anf"]
    support = list(anf)
    nodes = chain_closure(support, n)
    R, c = opt.radius, THEME[opt.theme]
    hide, dim, hi, fade = set(opt.hide), set(opt.dim), set(opt.highlight), opt.fade
    cv = Canvas(opt.theme)
    thc = cut_angle(cut)
    raw_op = 0.22 if opt.view == "factor" else 1.0
    show_raw = opt.view in ("raw", "both", "factor")
    show_fac = opt.view in ("factor", "both")
    ncross = 0

    def op_of(t):
        if hi:
            return 1.0 if t in hi else fade
        return fade if t in dim else 1.0

    # 扇。カットが分ける A 側と B 側
    if "wedge" not in hide:
        cv.wedge(R, thc, math.pi, c["wedgeA"], 0.055)
        cv.wedge(R, 0.0, thc, c["wedgeB"], 0.055)

    # 環
    if "rings" not in hide:
        for k in range(n + 1):
            cv.ring(R * (1.0 - 2.0 ** (-k)), c["ring"], 0.7, 0.5)
        cv.ring(R, c["ring"], 1.1, 0.9, dash="5 4")
        cv.text((R + 10, -4), "omega", c["ring"], 11, "start")

    # 実軸
    if "axis" not in hide:
        cv.line((-R - 30, 0), (R + 30, 0), c["axis"], 1.0, 0.85)
        cv.text((-R - 34, -8), "Pi_i", c["axis"], 11, "start")
        cv.text((-R - 34, 18), "Pi_j", c["axis"], 11, "start")

    # カットの直径と扇の名
    if "cut" not in hide:
        p, q = xy(1.10, thc, R), xy(1.10, thc + math.pi, R)
        cv.line(p, q, c["cut"], 1.3, 0.95, dash="7 5")
        cv.text((p[0], p[1] - 10), "cut kappa=%d" % cut, c["cut"], 11, "middle", weight="600")
        pa = xy(1.16, (thc + math.pi) / 2.0, R)
        pb = xy(1.16, thc / 2.0, R)
        cv.text(pa, "A = " + ",".join("x%d" % k for k in range(cut)), c["wedgeA"], 11)
        cv.text(pb, "B = " + ",".join("x%d" % k for k in range(cut, n)), c["wedgeB"], 11)

    # E_star。Pi_i の中の弦。直線なので上半平面から出ない
    if show_raw and "star" not in hide:
        for a, b in star_edges(nodes, n):
            pa, pb = xy(radius(a), angle(a, n), R), xy(radius(b), angle(b, n), R)
            o = min(op_of(a), op_of(b)) * raw_op
            cv.line(pa, pb, c["star"], 1.3, o)

    # E_plus。実軸を一度だけ渡る
    yout = xy(0.5, -math.pi / 2.0, R)
    if show_raw and "output" not in hide:
        cv.circle(yout, 6.5, c["out"], op=raw_op)
        cv.text((yout[0], yout[1] + 23), "y", c["out"], 12, op=raw_op)
    if show_raw and "plus" not in hide:
        for t in support:
            pa = xy(radius(t), angle(t, n), R)
            ctl = mid_ctrl(pa, yout, 26.0 if pa[0] >= 0 else -26.0)
            o = op_of(t) * raw_op
            cv.quad(pa, ctl, yout, c["plus"], 1.5, o)
            if "crossdot" not in hide:
                x = cross_at(pa, ctl, yout, f_axis)
                if x:
                    cv.circle(x, 2.9, c["plus"], op=o)

    # 単項式ノード
    for t in nodes:
        p = xy(radius(t), angle(t, n), R)
        o = op_of(t) * (1.0 if (show_fac and t in set(sum(fig["psup"] + fig["qsup"], []))) else raw_op)
        on = t in support
        cv.circle(p, 5.0 if on else 3.0, c["node"] if on else c["bg"], c["node"], 1.1, o)
        if "labels" not in hide:
            right = angle(t, n) < math.pi / 2.0
            cv.text((p[0] + (12 if right else -12), p[1] - 9), label_of(t, n),
                    c["label"], 10, "start" if right else "end", o)

    # 分離積。p_r と q_r の台へ細線、その間に太い弦を一本
    if show_fac and "junction" not in hide and rho:
        fcut = f_cut(thc)
        for r in range(rho):
            rr = 0.40 + 0.22 * (r + 1) / (rho + 1)
            ap = mean_angle(fig["psup"][r], n, thc, math.pi)
            aq = mean_angle(fig["qsup"][r], n, 0.0, thc)
            pp, pq = xy(rr, ap, R), xy(rr, aq, R)
            for t in fig["psup"][r]:
                cv.line(xy(radius(t), angle(t, n), R), pp, c["join"], 0.8, 0.55)
            for t in fig["qsup"][r]:
                cv.line(xy(radius(t), angle(t, n), R), pq, c["join"], 0.8, 0.55)
            cv.line(pq, pp, c["join"], 2.3, 1.0)
            x = cross_at(pq, mid_ctrl(pq, pp, 0.0), pp, fcut)
            if x:
                ncross += 1
                cv.circle(x, 3.6, c["cut"], c["join"], 1.2)
            cv.circle(pp, 5.2, c["join"])
            cv.circle(pq, 5.2, c["join"])
            cv.text((pp[0], pp[1] - 11), "p%d" % r, c["join"], 10)
            cv.text((pq[0], pq[1] - 11), "q%d" % r, c["join"], 10)

    return cv, support, ncross


def compose(fig, opt):
    cv, support, ncross = draw(fig, opt)
    R, c = opt.radius, THEME[opt.theme]
    pad = 104
    left = top = -R - pad
    w = h = 2 * (R + pad)
    legend_w = 0 if "legend" in set(opt.hide) else 350

    title = opt.title or ("tsuisuu geometry graph   n=%d  kappa=%d  rho=%d"
                          % (fig["n"], fig["cut"], fig["rho"]))
    cv.text((left + 16, top + 30), title, c["ink"], 15, "start", weight="600")
    cv.text((left + 16, top + 50),
            "台 %d 点   環 %d   接合秩 rho = %d   カットを渡る太弦 %d 本"
            % (len(support), fig["n"] + 1, fig["rho"], ncross),
            c["label"], 11, "start")

    if legend_w:
        x, y = left + w + 16, top + 42
        cv.text((x, y - 16), "読み方の辞書", c["ink"], 12, "start", weight="600")
        for text, mean, key, kind in LEGEND:
            if kind == "ring":
                cv.circle((x + 11, y - 4), 9, "none", c[key], 0.9)
            elif kind == "dash":
                cv.line((x, y - 4), (x + 22, y - 4), c[key], 2.0, 1.0, dash="5 3")
            else:
                cv.line((x, y - 4), (x + 22, y - 4), c[key], 0.9 if kind == "thin" else 2.6, 1.0)
            cv.text((x + 32, y), text, c["ink"], 10, "start")
            cv.text((x + 32, y + 14), mean, c["label"], 10, "start")
            y += 34
        y += 12
        for s in ("f(x_A,x_B) = XOR_{r<rho} p_r(x_A) * q_r(x_B)",
                  "rho = rank_F2 F           定理 4.1",
                  "p_r と q_r の丸は合算の点。半径 1/2 の近く",
                  "偏角は台の平均。半径の僅差は重なり避け"):
            cv.text((x, y), s, c["label"], 10, "start")
            y += 16

    vb = "%.0f %.0f %.0f %.0f" % (left, top, w + legend_w, h)
    return cv.render(int((w + legend_w) * opt.scale), int(h * opt.scale), vb, title)


# ===== 入口 =====

def parse_table(s, hexmode, n):
    if hexmode:
        v = int(s, 16)
        return [(v >> k) & 1 for k in range(1 << n)]
    return [1 if ch == "1" else 0 for ch in s.strip()]


def parse_list(s):
    return [int(t) for t in s.split(",") if t.strip()] if s else []


def main(argv=None):
    ap = argparse.ArgumentParser(description="接合秩の図を SVG へ写す")
    ap.add_argument("--table", required=True, help="頂点値。長さ 2^n の 0/1 列。--hex なら 16 進")
    ap.add_argument("--hex", action="store_true", help="--table を 16 進で読む。--n が要る")
    ap.add_argument("--n", type=int, default=None, help="入力の数。省くと --table の長さから出す")
    ap.add_argument("--cut", type=int, required=True, help="カットの位置 kappa。A = {0..kappa-1}")
    ap.add_argument("--out", default="joinrank.svg")
    ap.add_argument("--view", choices=("raw", "factor", "both"), default="both",
                    help="raw は Phi_gr だけ、factor は分離積を主役にする")
    ap.add_argument("--radius", type=float, default=300.0)
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--theme", choices=("light", "dark"), default="light")
    ap.add_argument("--title", default=None)
    ap.add_argument("--hide", default="",
                    help="wedge,rings,axis,cut,star,plus,crossdot,junction,labels,output,legend")
    ap.add_argument("--dim", default="", help="薄くする単項式の番号。十進、カンマ区切り")
    ap.add_argument("--highlight", default="", help="ここに挙げた単項式だけを濃く出す")
    ap.add_argument("--fade", type=float, default=0.13, help="薄くしたものの不透明度")
    opt = ap.parse_args(argv)

    n = opt.n if opt.n is not None else int(round(math.log(len(opt.table.strip()), 2)))
    table = parse_table(opt.table, opt.hex, n)
    if len(table) != (1 << n):
        raise SystemExit("頂点値の長さが 2^%d と合わない: %d" % (n, len(table)))
    opt.hide = [t for t in opt.hide.split(",") if t]
    opt.dim = parse_list(opt.dim)
    opt.highlight = parse_list(opt.highlight)

    fig = build.figure(table, n, opt.cut)
    open(opt.out, "w", encoding="utf-8", newline="\n").write(compose(fig, opt))
    print("%s   n=%d kappa=%d rho=%d   台 %d 点   p_r の台 %s   q_r の台 %s"
          % (opt.out, n, opt.cut, fig["rho"], len(fig["anf"]), fig["psup"], fig["qsup"]))


if __name__ == "__main__":
    main()
