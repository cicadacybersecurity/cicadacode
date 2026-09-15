"""ExplorerNav - the Windows Explorer / Control Panel task pane (2.5 pass).

Aero sidebar: pale blue glass gradient, luminous selected item with accent
edge and soft shadow, visible hover reaction, caption separators. The item
stack lives in a fixed-content inner box pinned by AnchorLayout(anchor_y=
"top") - top-aligned by construction; unused space stays BELOW the items.
"""
from kivy.uix.anchorlayout import AnchorLayout
from kivy.uix.behaviors import ButtonBehavior
from kivy.uix.boxlayout import BoxLayout

from .. import theme
from ..icons import Icon
from .aero import Hover, L, hrule, paint_bg, paint_border, vspacer


class NavItem(ButtonBehavior, BoxLayout, Hover):
    def __init__(self, key, label, on_select, **kwargs):
        kwargs.setdefault("orientation", "horizontal")
        kwargs.setdefault("size_hint_y", None)
        kwargs.setdefault("height", theme.H_NAV_ITEM)
        kwargs.setdefault("spacing", 8)
        kwargs.setdefault("padding", (18, 0, 8, 0))
        BoxLayout.__init__(self, **kwargs)
        ButtonBehavior.__init__(self)
        Hover.__init__(self)
        self.key = key
        self._on_select = on_select
        self.selected = False
        self.add_widget(Icon(key))
        self.label = L(label, size=theme.FS_NAV, color="link")
        self.add_widget(self.label)
        self.bind(pos=self.repaint, size=self.repaint)
        self.repaint()

    def on_release(self):
        self._on_select(self.key)

    def set_selected(self, value):
        self.selected = value
        self.repaint()

    def repaint(self, *_a):
        if self.selected:
            # luminous Aero selection: blue gradient, accent edge, soft shadow
            paint_bg(self, tex=theme.vgrad("nav_sel_top", "nav_sel_bot", 24),
                     shadow=True, shadow_alpha=45, shadow_dy=2, shadow_grow=2)
            paint_border(self, None)
            from kivy.graphics import Color, Rectangle
            self.canvas.after.clear()
            with self.canvas.after:
                Color(*theme.c("accent"))
                Rectangle(pos=(self.x, self.y), size=(3, self.height))
                Color(*theme.c("glass_line", 150))
                Rectangle(pos=(self.x + 3, self.top - 1),
                          size=(self.width - 3, 1))
            self.label.color = theme.c("sel_text")
            self.label.bold = True
        elif self.hovered:
            paint_bg(self, color=theme.c("nav_hover"))
            paint_border(self, None)
            from kivy.graphics import Color, Rectangle
            self.canvas.after.clear()
            with self.canvas.after:
                Color(*theme.c("glass_line", 120))
                Rectangle(pos=(self.x, self.top - 1), size=(self.width, 1))
            self.label.color = theme.c("text")
            self.label.bold = False
        else:
            paint_bg(self, color=(0, 0, 0, 0))
            paint_border(self, None)
            self.label.color = theme.c("link")
            self.label.bold = False


class ExplorerNav(BoxLayout):
    """Full-height Aero pane; item stack pinned to the TOP via AnchorLayout."""

    def __init__(self, groups, on_select, **kwargs):
        kwargs.setdefault("orientation", "horizontal")
        kwargs.setdefault("size_hint_x", None)
        kwargs.setdefault("width", theme.NAV_WIDTH)
        kwargs.setdefault("spacing", 0)
        super().__init__(**kwargs)
        self._items = {}
        self._on_select = on_select

        anchor = AnchorLayout(anchor_y="top", anchor_x="left")
        inner = BoxLayout(orientation="vertical", spacing=0,
                          padding=(0, 6, 0, 6), size_hint_y=None)
        inner.bind(minimum_height=inner.setter("height"))
        for caption, entries in groups:
            inner.add_widget(L(caption.upper(), size=theme.FS_NAV_CAPTION,
                               bold=True, color="text_faint",
                               size_hint_y=None,
                               height=theme.H_NAV_CAPTION, padding=(14, 0)))
            inner.add_widget(hrule())
            inner.add_widget(vspacer(3))
            for key, label in entries:
                item = NavItem(key, label, self._select)
                self._items[key] = item
                inner.add_widget(item)
            inner.add_widget(vspacer(8))
        anchor.add_widget(inner)
        self.add_widget(anchor)
        self.bind(pos=self.repaint, size=self.repaint)
        self.repaint()

    def _select(self, key):
        self.select(key)
        self._on_select(key)

    def select(self, key):
        for k, item in self._items.items():
            item.set_selected(k == key)

    def repaint(self, *_a):
        paint_bg(self, tex=theme.vgrad("navpane_top", "navpane_bot"))
        paint_border(self, None)
        from kivy.graphics import Color, Rectangle
        self.canvas.after.clear()
        with self.canvas.after:
            Color(*theme.c("border_lo"))
            Rectangle(pos=(self.right - 1, self.y), size=(1, self.height))
            Color(*theme.c("glass_line", 110))
            Rectangle(pos=(self.x, self.y), size=(1, self.height))