"""Windows-era 16px icons drawn with Kivy canvas instructions.

Embossed like Windows 7 toolbar glyphs: a white highlight pass offset
up 1px, then the deep accent stroke. No emoji, no icon fonts, no assets.
"""
import math

from kivy.graphics import Color, Ellipse, Line
from kivy.uix.widget import Widget

from . import theme


def _pts(name, w, h):
    """Glyph geometry on a 16px grid, returned as drawable instructions."""
    cx, cy = w / 2, h / 2
    m = min(w, h) / 16.0
    out = []
    if name == "dashboard":        # gauge: arc + needle
        out.append(("arc", (cx - 6*m, cy - 6*m, 12*m, 12*m, 200, -20)))
        out.append(("line", (cx, cy, cx + 3.4*m, cy + 3.6*m)))
    elif name == "workers":        # 2x2 tiles
        for dx in (-5.2, 0.8):
            for dy in (-5.2, 0.8):
                out.append(("rect", (cx + dx*m, cy + dy*m, 4.4*m, 4.4*m, 1.0*m)))
    elif name == "tasks":          # checklist
        out.append(("line", (cx - 2*m, cy + 4*m, cx + 6*m, cy + 4*m)))
        out.append(("line", (cx - 2*m, cy, cx + 6*m, cy)))
        out.append(("line", (cx - 2*m, cy - 4*m, cx + 2*m, cy - 4*m)))
        out.append(("poly", (cx - 6*m, cy + 3*m, cx - 4.6*m, cy + 4.6*m,
                             cx - 2.6*m, cy + 2*m)))
    elif name == "logs":           # document
        out.append(("rect", (cx - 4.4*m, cy - 6.4*m, 8.8*m, 12.8*m, 1.4*m)))
        for dy in (3.2, 0.4, -2.4):
            out.append(("line", (cx - 2.6*m, cy + dy*m, cx + 2.6*m, cy + dy*m)))
    elif name == "providers":      # plug / node
        out.append(("ellipse", (cx - 4.6*m, cy - 3*m, 9.2*m, 6.4*m)))
        out.append(("line", (cx, cy + 6*m, cx, cy + 3.4*m)))
        out.append(("line", (cx, cy - 3*m, cx, cy - 5.4*m)))
    elif name == "models":         # chip
        out.append(("rect", (cx - 4*m, cy - 4*m, 8*m, 8*m, 1.4*m)))
        for d in (-2.4, 0, 2.4):
            out.append(("line", (cx + d*m, cy + 4*m, cx + d*m, cy + 6*m)))
            out.append(("line", (cx + d*m, cy - 4*m, cx + d*m, cy - 6*m)))
    elif name == "settings":       # gear
        out.append(("ellipse", (cx - 2.6*m, cy - 2.6*m, 5.2*m, 5.2*m)))
        for k in range(8):
            a = math.radians(k * 45)
            out.append(("line", (cx + math.cos(a) * 4.4*m, cy + math.sin(a) * 4.4*m,
                                 cx + math.cos(a) * 6.4*m, cy + math.sin(a) * 6.4*m)))
    elif name == "diagnostics":    # pulse
        out.append(("poly", (cx - 6*m, cy, cx - 2.6*m, cy, cx - 1*m, cy + 4.6*m,
                             cx + 1.6*m, cy - 4.6*m, cx + 3.2*m, cy, cx + 6*m, cy)))
    return out


class Icon(Widget):
    def __init__(self, name, **kwargs):
        kwargs.setdefault("size_hint", (None, None))
        kwargs.setdefault("size", (16, 16))
        super().__init__(**kwargs)
        self.name = name
        self.bind(pos=self.repaint, size=self.repaint)
        self.repaint()

    def repaint(self, *_a):
        self.canvas.clear()
        x0, y0 = self.pos
        with self.canvas:
            for pass_i, (col, off) in enumerate(
                    ((theme.hx("#ffffff", 150), 0.8), (theme.c("accent_lo"), 0.0))):
                Color(*col)
                for kind, g in _pts(self.name, self.width, self.height):
                    ox, oy = x0, y0 + off
                    if kind == "line":
                        Line(points=(g[0] + ox, g[1] + oy, g[2] + ox, g[3] + oy),
                             width=1.6, cap="round")
                    elif kind == "poly":
                        Line(points=[v + (ox if i % 2 == 0 else oy)
                                     for i, v in enumerate(g)],
                             width=1.6, cap="round", joint="round")
                    elif kind == "ellipse":
                        Line(ellipse=(g[0] + ox, g[1] + oy, g[2], g[3]),
                             width=1.5)
                    elif kind == "arc":
                        Line(ellipse=(g[0] + ox, g[1] + oy, g[2], g[3],
                                      g[4], g[5]), width=1.6, cap="round")
                    elif kind == "rect":
                        Line(rounded_rectangle=(g[0] + ox, g[1] + oy,
                                                g[2], g[3], g[4]), width=1.5)