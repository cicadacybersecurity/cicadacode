"""AeroTable - a Windows Vista/7 details-view table (Aero-era visual pass).

Authentic Aero list-view treatment: glossy beveled column headers with a
sort-direction glyph, a light/dark separator pair between columns, gently
alternating row washes with hairline separators, a luminous gradient hover,
a glass-blue selection with accent edge + inner highlight, a slim Aero blue
scrollbar, and a bordered body with top glass catch. All lightweight cached
textures and canvas primitives - no per-frame work.

Geometry, behaviour and API are unchanged from the previous version: the
table fills its parent (size_hint_y weight) or takes an explicit height;
rows scroll inside the ScrollView; an empty table shows a message centered
BOTH ways in the visible body; header click sorts ascending/descending.

The empty-state height binding is created ONCE in __init__ and re-synced
from _rebuild; refreshes never accumulate bindings.
"""
from kivy.uix.anchorlayout import AnchorLayout
from kivy.uix.behaviors import ButtonBehavior
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.gridlayout import GridLayout
from kivy.uix.scrollview import ScrollView

from .. import theme
from .aero import Hover, L, paint_bg, paint_border


class _Row(ButtonBehavior, BoxLayout, Hover):
    def __init__(self, table, index, **kwargs):
        kwargs.setdefault("orientation", "horizontal")
        kwargs.setdefault("size_hint_y", None)
        kwargs.setdefault("height", theme.H_TABLE_ROW)
        BoxLayout.__init__(self, **kwargs)
        ButtonBehavior.__init__(self)
        Hover.__init__(self)
        self.table = table
        self.index = index
        self.bind(pos=self.repaint, size=self.repaint)

    def on_release(self):
        self.table.select(self.index)

    def _text_cells(self, color):
        # recolor plain text cells; pill cells keep their status colour
        for cell in self.children:
            if getattr(cell, "_pill", False):
                continue
            set_color = getattr(cell, "color", None)
            if set_color is not None:
                cell.color = color

    def repaint(self, *_a):
        from kivy.graphics import Color, Line, Rectangle
        x, y, w, h = self.x, self.y, self.width, self.height
        selected = self.table.selected == self.index
        if selected:
            # Aero selection: glass-blue gradient wash, accent edge, inner
            # top highlight, thin accent outline
            paint_bg(self, tex=theme.vgrad("nav_sel_top", "nav_sel_bot", 24))
            self.canvas.after.clear()
            with self.canvas.after:
                Color(*theme.c("accent"))
                Rectangle(pos=(x, y), size=(3, h))
                Color(*theme.c("accent", 150))
                Line(rectangle=(x, y, w, h), width=1.0)
                Color(*theme.c("glass_line", 130))
                Rectangle(pos=(x + 3, self.top - 1), size=(w - 3, 1))
            self._text_cells(theme.c("sel_text"))
        elif self.hovered:
            # luminous hover: near-white -> pale blue vertical sheen
            paint_bg(self, tex=theme.vgrad("header_hi", "row_hover", 24))
            self.canvas.after.clear()
            with self.canvas.after:
                Color(*theme.c("accent", 60))
                Line(rectangle=(x, y, w, h), width=1.0)
            self._text_cells(theme.c("text"))
        else:
            # alternating wash: white / very light blue + hairline separator
            paint_bg(self, color=theme.c("row_alt" if self.index % 2 == 1
                                         else "content"))
            self.canvas.after.clear()
            with self.canvas.after:
                Color(*theme.c("group_line"))
                Rectangle(pos=(x, y), size=(w, 1))
            self._text_cells(theme.c("text"))


class _HeaderCell(ButtonBehavior, BoxLayout, Hover):
    def __init__(self, table, col, text, **kwargs):
        kwargs.setdefault("size_hint_y", None)
        kwargs.setdefault("height", theme.H_TABLE_HEADER)
        BoxLayout.__init__(self, **kwargs)
        ButtonBehavior.__init__(self)
        Hover.__init__(self)
        self.table = table
        self.col = col
        self.add_widget(L(text, size=theme.FS_HEADER, bold=True,
                          color="text", padding=(8, 0)))
        self.bind(pos=self.repaint, size=self.repaint)
        self.repaint()

    def on_release(self):
        self.table.sort_by(self.col)

    def repaint(self, *_a):
        from kivy.graphics import Color, Line, Mesh, Rectangle
        x, y, w, h = self.x, self.y, self.width, self.height
        down = getattr(self, "state", "normal") == "down"
        if down:
            # pressed column header: darker, inset
            paint_bg(self, tex=theme.vgrad("header_lo", "header_hi", 24))
        elif self.hovered or self.table._sort_col == self.col:
            # hover / active-sort: brighter Aero blue sheen
            paint_bg(self, tex=theme.vgrad("header_hi", "nav_sel_bot", 24))
        else:
            # glossy beveled header: bright top -> pale Aero blue base
            paint_bg(self, tex=theme.vgrad("header_hi", "header_lo", 24))
        self.canvas.after.clear()
        with self.canvas.after:
            # top glass catch
            Color(*theme.c("glass_line", 220))
            Rectangle(pos=(x, self.top - 1), size=(w, 1))
            # bottom edge (the header/body bevel)
            Color(*theme.c("border_lo"))
            Rectangle(pos=(x, y), size=(w, 1))
            # Vista column separator: dark line + light line pair
            Color(*theme.c("border_lo"))
            Rectangle(pos=(self.right - 1, y + 3), size=(1, h - 6))
            Color(*theme.c("glass_line", 140))
            Rectangle(pos=(self.right - 2, y + 3), size=(1, h - 6))
            # sort glyph: small Aero triangle, direction = sort order
            if self.table._sort_col == self.col:
                Color(*theme.c("accent_lo"))
                cx = self.right - 16
                cy = y + h / 2.0
                if self.table._sort_rev:  # descending: point down
                    pts = [cx - 4, cy + 2, 0, 0,
                           cx + 4, cy + 2, 0, 0,
                           cx, cy - 3, 0, 0]
                else:                      # ascending: point up
                    pts = [cx - 4, cy - 2, 0, 0,
                           cx + 4, cy - 2, 0, 0,
                           cx, cy + 3, 0, 0]
                Mesh(vertices=pts, indices=[0, 1, 2], mode="triangles")


class AeroTable(BoxLayout):
    def __init__(self, headers, weights=None, on_select=None,
                 empty_text=None, height=None, weight=1, **kwargs):
        kwargs.setdefault("orientation", "vertical")
        kwargs.setdefault("spacing", 0)
        if height is not None:
            kwargs.setdefault("size_hint_y", None)
        else:
            kwargs.setdefault("size_hint_y", weight)
        super().__init__(**kwargs)
        if height is not None:
            self.height = height
        self.headers = list(headers)
        self.weights = weights or [1] * len(headers)
        self.on_select_row = on_select
        self.empty_text = empty_text
        self.selected = -1
        self._rows = []
        self._sort_col = None
        self._sort_rev = False
        self._empty_anchor = None
        self._header = BoxLayout(size_hint_y=None, height=theme.H_TABLE_HEADER,
                                 spacing=0)
        for col, (text, weight) in enumerate(zip(self.headers, self.weights)):
            cell = _HeaderCell(self, col, text)
            cell.size_hint_x = weight
            self._header.add_widget(cell)
        self.add_widget(self._header)
        self._scroll = ScrollView()
        self._grid = GridLayout(cols=1, spacing=0, size_hint_y=None)
        self._grid.bind(minimum_height=self._grid.setter("height"))
        self._scroll.add_widget(self._grid)
        self.add_widget(self._scroll)
        # bound exactly once - refreshes only adjust the anchor's height
        self._scroll.bind(height=lambda _s, _h: self._sync_empty())
        self.bind(pos=self.repaint, size=self.repaint)
        self.repaint()

    # -- data ----------------------------------------------------------------
    def sort_by(self, col):
        if self._sort_col == col:
            self._sort_rev = not self._sort_rev
        else:
            self._sort_col, self._sort_rev = col, False
        self._rows.sort(key=lambda r: str(r[col]).lower(), reverse=self._sort_rev)
        self._rebuild()
        for cell in self._header.children:
            cell.repaint()

    def select(self, index):
        self.selected = index
        for row_widget in self._grid.children:
            repaint = getattr(row_widget, "repaint", None)
            if callable(repaint):
                repaint()
        if self.on_select_row and 0 <= index < len(self._rows):
            self.on_select_row(self._rows[index])

    def selected_row(self):
        if 0 <= self.selected < len(self._rows):
            return self._rows[self.selected]
        return None

    def set_rows(self, rows):
        """rows: list of row lists; a cell may be a string or
        ('pill', state, text) for status colouring."""
        self._rows = list(rows)
        if self._sort_col is not None:
            self._rows.sort(key=lambda r: str(r[self._sort_col]).lower(),
                            reverse=self._sort_rev)
        self._rebuild()

    # -- internals -------------------------------------------------------------
    def _sync_empty(self):
        if self._empty_anchor is not None:
            self._empty_anchor.height = max(self._scroll.height,
                                            theme.H_TABLE_ROW * 2)

    def _rebuild(self):
        self._grid.clear_widgets()
        self._empty_anchor = None
        if not self._rows and self.empty_text:
            anchor = AnchorLayout(anchor_x="center", anchor_y="center",
                                  size_hint_y=None)
            empty = L(self.empty_text, size=theme.FS_TABLE,
                      color="text_faint", align="center",
                      size_hint=(None, None), height=theme.H_TABLE_ROW)
            empty.width = 340
            anchor.add_widget(empty)
            self._empty_anchor = anchor
            self._grid.add_widget(anchor)
            self._sync_empty()
        else:
            for i, row in enumerate(self._rows):
                w = _Row(self, i)
                for value, weight in zip(row, self.weights):
                    if isinstance(value, tuple) and value and value[0] == "pill":
                        fg, _bg = theme.pill(value[1])
                        cell = L(" " + str(value[2]) + " ", size=theme.FS_HEADER,
                                 bold=True, color=fg, size_hint_x=weight,
                                 padding=(8, 0))
                        cell._pill = True  # keep status colour on select/hover
                    else:
                        cell = L(str(value), size=theme.FS_TABLE,
                                 size_hint_x=weight, padding=(8, 0))
                    w.add_widget(cell)
                w.repaint()
                self._grid.add_widget(w)

    def repaint(self, *_a):
        from kivy.graphics import Color, Rectangle
        # body: white surface with a whisper of shadow, Aero edge, glass catch
        paint_bg(self, color=theme.c("content"), shadow=True,
                 shadow_alpha=40, shadow_dy=2, shadow_grow=2)
        paint_border(self, theme.c("border"))
        with self.canvas.after:
            Color(*theme.c("glass_line", 160))
            Rectangle(pos=(self.x + 1, self.top - 1),
                      size=(self.width - 2, 1))
        # slim Aero scrollbar styling (follows Day/Night via repaint_walk)
        self._scroll.bar_width = 10
        self._scroll.bar_color = theme.c("accent", 170)
        self._scroll.bar_inactive_color = theme.c("border", 110)
        for child in self._grid.children:
            repaint = getattr(child, "repaint", None)
            if callable(repaint):
                repaint()
        for child in self._header.children:
            child.repaint()