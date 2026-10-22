"""式、グラフ、構成履歴を一画面で扱う GUI。"""

from __future__ import annotations

import json
import tkinter as tk
from fractions import Fraction
from tkinter import messagebox, ttk

from . import get_session
from .language import ExpressionError


class CalculatorGUI:
    def __init__(self, session=None):
        self.session = session or get_session()
        self.root = tk.Tk()
        self.root.title("ツイ数関数計算機")
        self.root.geometry("1180x760")
        self.expression = tk.StringVar(value="(x + 1) / 2")
        self.x_value = tk.StringVar(value="1/2")
        self.range_left = tk.StringVar(value="-4")
        self.range_right = tk.StringVar(value="4")
        self.trace_word = tk.StringVar(value="ij")
        self.influence_left = tk.StringVar(value="1/2")
        self.influence_right = tk.StringVar(value="3/4")
        self.influence_operation = tk.StringVar(value="積")
        self.truth_table = tk.StringVar(value="0110")
        self.join_cut = tk.StringVar(value="1")
        self.status = tk.StringVar(value="入力を待っています。")
        self._layout()
        self._refresh_history()

    def _layout(self):
        outer = ttk.Panedwindow(self.root, orient=tk.HORIZONTAL)
        outer.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)
        control = ttk.Frame(outer, padding=8)
        view = ttk.Frame(outer, padding=8)
        outer.add(control, weight=2)
        outer.add(view, weight=5)

        ttk.Label(control, text="厳密有理式").pack(anchor=tk.W)
        entry = ttk.Entry(control, textvariable=self.expression, font=("Yu Gothic UI", 13))
        entry.pack(fill=tk.X, pady=(3, 8))
        entry.bind("<Return>", lambda _event: self.calculate())

        variable_row = ttk.Frame(control)
        variable_row.pack(fill=tk.X)
        ttk.Label(variable_row, text="x =").pack(side=tk.LEFT)
        ttk.Entry(variable_row, textvariable=self.x_value, width=16).pack(side=tk.LEFT, padx=4)
        ttk.Button(variable_row, text="計算", command=self.calculate).pack(side=tk.RIGHT)

        range_row = ttk.LabelFrame(control, text="二進格子の関数グラフ", padding=7)
        range_row.pack(fill=tk.X, pady=10)
        ttk.Entry(range_row, textvariable=self.range_left, width=8).pack(side=tk.LEFT)
        ttk.Label(range_row, text=" ≤ x ≤ ").pack(side=tk.LEFT)
        ttk.Entry(range_row, textvariable=self.range_right, width=8).pack(side=tk.LEFT)
        ttk.Button(range_row, text="描画", command=self.plot).pack(side=tk.RIGHT)

        trace_row = ttk.LabelFrame(control, text="構成履歴", padding=7)
        trace_row.pack(fill=tk.X, pady=(0, 10))
        ttk.Entry(trace_row, textvariable=self.trace_word, width=16).pack(side=tk.LEFT)
        ttk.Button(trace_row, text="終点", command=self.trace).pack(side=tk.RIGHT)

        influence_row = ttk.LabelFrame(control, text="影響量", padding=7)
        influence_row.pack(fill=tk.X, pady=(0, 10))
        ttk.Entry(influence_row, textvariable=self.influence_left, width=7).pack(side=tk.LEFT)
        ttk.Combobox(influence_row, textvariable=self.influence_operation,
                     values=("積", "上限", "右残差", "左残差"),
                     state="readonly", width=7).pack(side=tk.LEFT, padx=4)
        ttk.Entry(influence_row, textvariable=self.influence_right, width=7).pack(side=tk.LEFT)
        ttk.Button(influence_row, text="評価", command=self.influence).pack(side=tk.RIGHT)

        join_row = ttk.LabelFrame(control, text="接合秩", padding=7)
        join_row.pack(fill=tk.X, pady=(0, 10))
        ttk.Label(join_row, text="表").pack(side=tk.LEFT)
        ttk.Entry(join_row, textvariable=self.truth_table, width=14).pack(
            side=tk.LEFT, padx=(3, 6))
        ttk.Label(join_row, text="κ").pack(side=tk.LEFT)
        ttk.Entry(join_row, textvariable=self.join_cut, width=3).pack(
            side=tk.LEFT, padx=3)
        ttk.Button(join_row, text="観測", command=self.joinrank).pack(side=tk.RIGHT)

        ttk.Label(control, text="共有履歴").pack(anchor=tk.W)
        self.history_list = tk.Listbox(control, height=16, font=("Yu Gothic UI", 10))
        self.history_list.pack(fill=tk.BOTH, expand=True, pady=(3, 5))
        self.history_list.bind("<<ListboxSelect>>", self.show_history)
        ttk.Label(control, textvariable=self.status, wraplength=330).pack(anchor=tk.W)

        tabs = ttk.Notebook(view)
        tabs.pack(fill=tk.BOTH, expand=True)
        plot_frame = ttk.Frame(tabs)
        graph_frame = ttk.Frame(tabs)
        join_frame = ttk.Frame(tabs)
        detail_frame = ttk.Frame(tabs)
        tabs.add(plot_frame, text="関数の軌跡")
        tabs.add(graph_frame, text="計算チェンバー")
        tabs.add(join_frame, text="接合秩")
        tabs.add(detail_frame, text="Common と観測")
        self.plot_canvas = tk.Canvas(plot_frame, background="#fbfbf7")
        self.plot_canvas.pack(fill=tk.BOTH, expand=True)
        self.graph_canvas = tk.Canvas(graph_frame, background="#f7fafc")
        self.graph_canvas.pack(fill=tk.BOTH, expand=True)
        self.join_canvas = tk.Canvas(join_frame, background="#fffdf8")
        self.join_canvas.pack(fill=tk.BOTH, expand=True)
        self.details = tk.Text(detail_frame, wrap=tk.NONE, font=("Cascadia Mono", 10))
        self.details.pack(fill=tk.BOTH, expand=True)

    def _show(self, value: dict):
        self.details.delete("1.0", tk.END)
        self.details.insert(tk.END, json.dumps(value, ensure_ascii=False, indent=2))

    def calculate(self):
        try:
            result = self.session.calculate(
                self.expression.get(), {"x": self.x_value.get()}, origin="GUI")
            self.status.set("結果: " + result["value"])
            self._show(result)
            self._draw_graph(result["graph"])
            self._refresh_history()
        except Exception as exc:
            messagebox.showerror("計算できません", str(exc))

    def plot(self):
        try:
            result = self.session.sample(self.expression.get(), self.range_left.get(),
                                         self.range_right.get(), 65, 6, origin="GUI")
            self._draw_plot(result["points"])
            self._show(result)
            self.status.set("%d 点を描画しました。" % len(result["points"]))
            self._refresh_history()
        except Exception as exc:
            messagebox.showerror("描画できません", str(exc))

    def trace(self):
        try:
            result = self.session.trace(self.trace_word.get().strip(), origin="GUI")
            self._show(result)
            self.status.set("終点: (%s, %s)" % tuple(result["endpoint"]))
            self._draw_trace(result["word"], result["endpoint"])
            self._refresh_history()
        except Exception as exc:
            messagebox.showerror("観測できません", str(exc))

    def influence(self):
        try:
            result = self.session.influence(
                self.influence_left.get(), self.influence_right.get(),
                self.influence_operation.get(), origin="GUI")
            self._show(result)
            self.status.set("影響量: " + result["magnitude"])
            self._refresh_history()
        except Exception as exc:
            messagebox.showerror("評価できません", str(exc))

    def joinrank(self):
        try:
            try:
                cut = int(self.join_cut.get())
            except ValueError as exc:
                raise ExpressionError("カットκは整数で入力してください。") from exc
            result = self.session.joinrank(
                self.truth_table.get(), cut, origin="GUI")
            self._show(result)
            self._draw_joinrank(result)
            self.status.set("接合秩: ρ = %d" % result["rho"])
            self._refresh_history()
        except Exception as exc:
            messagebox.showerror("接合秩を観測できません", str(exc))

    def _refresh_history(self):
        rows = self.session.history(200)
        self.history_rows = list(reversed(rows))
        self.history_list.delete(0, tk.END)
        for row in self.history_rows:
            summary = row["result"].get(
                "value", row["result"].get(
                    "endpoint", row["result"].get("rho", "")))
            self.history_list.insert(tk.END, "%s %s #%s  %s" % (
                row["origin"], row["kind"], row["sequence"], summary))

    def show_history(self, _event=None):
        selection = self.history_list.curselection()
        if selection:
            self._show(self.history_rows[selection[0]])

    def _draw_plot(self, points: list[dict]):
        canvas = self.plot_canvas
        canvas.delete("all")
        canvas.update_idletasks()
        width, height = max(canvas.winfo_width(), 300), max(canvas.winfo_height(), 240)
        pairs = [(float(Fraction(p["x"])), float(Fraction(p["y"]))) for p in points]
        if not pairs:
            canvas.create_text(width / 2, height / 2, text="描画できる点がありません。")
            return
        xs, ys = [p[0] for p in pairs], [p[1] for p in pairs]
        xmin, xmax = min(xs), max(xs)
        ymin, ymax = min(ys), max(ys)
        if ymin == ymax:
            ymin, ymax = ymin - 1, ymax + 1
        pad = 36
        sx = lambda x: pad + (x - xmin) * (width - 2 * pad) / max(xmax - xmin, 1e-12)
        sy = lambda y: height - pad - (y - ymin) * (height - 2 * pad) / (ymax - ymin)
        if xmin <= 0 <= xmax:
            canvas.create_line(sx(0), pad, sx(0), height - pad, fill="#8793a1")
        if ymin <= 0 <= ymax:
            canvas.create_line(pad, sy(0), width - pad, sy(0), fill="#8793a1")
        for first, second in zip(pairs, pairs[1:]):
            canvas.create_line(sx(first[0]), sy(first[1]), sx(second[0]), sy(second[1]),
                               fill="#2457c5", width=2)
        for x, y in pairs:
            canvas.create_oval(sx(x) - 2, sy(y) - 2, sx(x) + 2, sy(y) + 2,
                               fill="#163d8f", outline="")
        canvas.create_text(pad, 16, anchor=tk.W,
                           text="x: %g … %g    y: %g … %g" % (xmin, xmax, ymin, ymax))

    def _draw_graph(self, graph: dict):
        canvas = self.graph_canvas
        canvas.delete("all")
        canvas.update_idletasks()
        width = max(canvas.winfo_width(), 400)
        nodes = graph["nodes"]
        if not nodes:
            return
        depths = {}
        for node in nodes:
            depths.setdefault(node["depth"], []).append(node)
        positions = {}
        for depth, row in depths.items():
            y = 55 + depth * 90
            for index, node in enumerate(row, 1):
                x = width * index / (len(row) + 1)
                positions[node["node_id"]] = (x, y)
        for source, target in graph["edges"]:
            x1, y1 = positions[source]
            x2, y2 = positions[target]
            canvas.create_line(x1, y1, x2, y2, fill="#778899", arrow=tk.LAST)
        for node in nodes:
            x, y = positions[node["node_id"]]
            canvas.create_oval(x - 25, y - 20, x + 25, y + 20,
                               fill="#ffffff", outline="#2457c5", width=2)
            canvas.create_text(x, y, text=node["label"])

    def _draw_trace(self, word: str, endpoint: list[int]):
        canvas = self.graph_canvas
        canvas.delete("all")
        canvas.update_idletasks()
        width, height = max(canvas.winfo_width(), 400), max(canvas.winfo_height(), 300)
        center = (width / 2, height / 2)
        scale = min(width, height) / 6
        canvas.create_line(20, center[1], width - 20, center[1], fill="#8793a1")
        canvas.create_line(center[0], 20, center[0], height - 20, fill="#8793a1")
        x = center[0] + endpoint[0] * scale
        y = center[1] - endpoint[1] * scale
        canvas.create_line(center[0], center[1], x, y, fill="#b3261e", width=3,
                           arrow=tk.LAST)
        canvas.create_text(x + 8, y - 12, text="%s  (%s, %s)" %
                           (word, endpoint[0], endpoint[1]), anchor=tk.W)

    def _draw_joinrank(self, result: dict):
        canvas = self.join_canvas
        canvas.delete("all")
        canvas.update_idletasks()
        width = max(canvas.winfo_width(), 720)
        height = max(canvas.winfo_height(), 560)
        canvas.create_text(24, 20, anchor=tk.NW, font=("Yu Gothic UI", 18, "bold"),
                           text="ρ = %d    %d × %d    κ = %d" % (
                               result["rho"], result["shape"][0],
                               result["shape"][1], result["cut"]))
        canvas.create_text(width - 24, 27, anchor=tk.NE, fill="#52606d",
                           text="赤い線の本数 = 境界を渡る独立影響の最小本数")

        matrix = result["matrix"]
        rows = self._display_indices(len(matrix), 24)
        columns = self._display_indices(len(matrix[0]), 24)
        x0, y0, box_w, box_h = 28, 80, min(300, width * 0.36), 250
        cell_w, cell_h = box_w / len(columns), box_h / len(rows)
        canvas.create_text(x0, y0 - 22, anchor=tk.W,
                           text="値の行列  Fαβ")
        for display_row, row in enumerate(rows):
            for display_column, column in enumerate(columns):
                bit = matrix[row][column]
                left = x0 + display_column * cell_w
                top = y0 + display_row * cell_h
                canvas.create_rectangle(
                    left, top, left + cell_w, top + cell_h,
                    fill="#2457c5" if bit else "#eef2f6", outline="#ffffff")
        canvas.create_rectangle(x0, y0, x0 + box_w, y0 + box_h,
                                outline="#52606d")
        if len(rows) < len(matrix) or len(columns) < len(matrix[0]):
            canvas.create_text(x0, y0 + box_h + 8, anchor=tk.NW,
                               fill="#52606d", text="大きい行列は等間隔に標本表示")

        boundary = width * 0.68
        left_x, right_x = width * 0.53, width * 0.83
        top, bottom = 88, 330
        canvas.create_line(boundary, top - 10, boundary, bottom + 10,
                           fill="#7b4b27", width=3)
        canvas.create_text(boundary - 8, top - 28, anchor=tk.E, text="Πi：pᵣ")
        canvas.create_text(boundary + 8, top - 28, anchor=tk.W, text="Πj：qᵣ")
        rho = result["rho"]
        for rank in range(rho):
            y = top + (rank + 1) * (bottom - top) / (rho + 1)
            p_text = self._bit_summary(result["p"][rank])
            q_text = self._bit_summary(result["q"][rank])
            canvas.create_line(left_x + 42, y, right_x - 42, y,
                               fill="#b3261e", width=3)
            canvas.create_oval(left_x - 42, y - 18, left_x + 42, y + 18,
                               fill="#fff2f0", outline="#b3261e", width=2)
            canvas.create_oval(right_x - 42, y - 18, right_x + 42, y + 18,
                               fill="#fff2f0", outline="#b3261e", width=2)
            canvas.create_text(left_x, y, text="p%d %s" % (rank, p_text))
            canvas.create_text(right_x, y, text="q%d %s" % (rank, q_text))

        profile = result["profile"]
        chart_x0, chart_y0 = 38, height - 52
        chart_w, chart_h = width - 76, min(150, height * 0.22)
        canvas.create_text(chart_x0, chart_y0 - chart_h - 24, anchor=tk.W,
                           text="カット別の接合秩")
        max_rho = max((item["rho"] for item in profile), default=1) or 1
        step = chart_w / max(len(profile), 1)
        for index, item in enumerate(profile):
            bar_h = chart_h * item["rho"] / max_rho
            center = chart_x0 + step * (index + 0.5)
            color = "#b3261e" if item["cut"] == result["cut"] else "#5b8def"
            canvas.create_rectangle(center - step * 0.28, chart_y0 - bar_h,
                                    center + step * 0.28, chart_y0,
                                    fill=color, outline="")
            canvas.create_text(center, chart_y0 - bar_h - 10,
                               text=str(item["rho"]))
            canvas.create_text(center, chart_y0 + 12,
                               text="κ=%d" % item["cut"])
        canvas.create_line(chart_x0, chart_y0, chart_x0 + chart_w, chart_y0,
                           fill="#52606d")

    @staticmethod
    def _display_indices(size: int, limit: int) -> list[int]:
        if size <= limit:
            return list(range(size))
        return [index * (size - 1) // (limit - 1) for index in range(limit)]

    @staticmethod
    def _bit_summary(bits: list[int], limit: int = 10) -> str:
        text = "".join(str(bit) for bit in bits[:limit])
        return text if len(bits) <= limit else text + "…"

    def run(self):
        self.root.mainloop()


def run(session=None):
    CalculatorGUI(session).run()
