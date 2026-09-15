"""AeroTable - a Windows 7 details-view table (2.5 depth pass).

Beveled gradient header (click to sort) with column separators, light
alternating rows with hairline separators, luminous hover, Aero-blue
selection with an accent edge, pill cells for status, centered empty state.

Geometry: the table fills its parent (size_hint_y weight) or takes an
explicit height; rows scroll inside the ScrollView; an empty table shows a
message centered BOTH ways in the visible body - never a stack of blank
rows.

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

    def repaint(self, *_a):
        if self.table.selected == self.index:
            # Aero selection: luminous blue wash + accent edge on the left
            paint_bg(self, tex=theme.vgrad("nav_sel_top", "nav_sel_bot", 24))
            paint_border(self, None)
            from kivy.graphics import Color, Rectangle
            self.canvas.after.clear()
            with self.canvas.after:
                Color(*theme.c("accent"))
                Rectangle(pos=(self.x, self.y), size=(3, self.height))
        elif self.hovered:
            paint_bg(self, color=theme.c("row_hover"))
            paint_border(self, None)
        else:
            paint_bg(self, color=theme.c("row_alt" if self.index % 2 == 1
                                         else "content"))
            paint_border(self, None)
        # hairline row separator (not on the selected row's accent style)
        if self.table.selected != self.index:
            from kivy.graphics import Color, Rectangle
            with self.canvas.after:
                Color(*theme.c("group_line"))
                Rectangle(pos=(self.x, self.y), size=(self.width, 1))


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
        # beveled header: bright top, pale blue base, hairline separators
        paint_bg(self, tex=theme.vgrad("header_hi", "header_lo", 24))
        paint_border(self, None)
        from kivy.graphics import Color, Rectangle
        self.canvas.after.clear()
        with self.canvas.after:
            Color(*theme.c("glass_line", 200))
            Rectangle(pos=(self.x, self.top - 1), size=(self.width, 1))
            Color(*theme.c("border_lo"))
            Rectangle(pos=(self.x, self.y), size=(self.width, 1))
            Rectangle(pos=(self.right - 1, self.y), size=(1, self.height))


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
                    else:
                        cell = L(str(value), size=theme.FS_TABLE,
                                 size_hint_x=weight, padding=(8, 0))
                    w.add_widget(cell)
                w.repaint()
                self._grid.add_widget(w)

    def repaint(self, *_a):
        paint_border(self, theme.c("border"))
        for child in self._grid.children:
            repaint = getattr(child, "repaint", None)
            if callable(repaint):
                repaint()
        for child in self._header.children:
            child.repaint()