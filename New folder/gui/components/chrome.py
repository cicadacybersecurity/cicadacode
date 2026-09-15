"""Window chrome - the one genuine chrome element: the status bar (2.5).

There is deliberately no caption bar (the native Windows title bar owns
min/max/close and dragging), no menu bar and no toolbar.
"""
from kivy.uix.boxlayout import BoxLayout

from .. import theme
from .aero import paint_bg, paint_border


class StatusBar(BoxLayout):
    """Classic Windows status bar: pale Aero gradient, hairline top border
    with a glass highlight - visually anchors the bottom of the window."""

    def __init__(self, **kwargs):
        kwargs.setdefault("orientation", "horizontal")
        kwargs.setdefault("size_hint_y", None)
        kwargs.setdefault("height", 32)
        kwargs.setdefault("padding", (10, 3))
        kwargs.setdefault("spacing", 12)
        super().__init__(**kwargs)
        self.bind(pos=self.repaint, size=self.repaint)
        self.repaint()

    def repaint(self, *_a):
        paint_bg(self, tex=theme.vgrad("header_hi", "surface2", 24))
        paint_border(self, None)
        from kivy.graphics import Color, Rectangle
        self.canvas.after.clear()
        with self.canvas.after:
            Color(*theme.c("border_lo"))
            Rectangle(pos=(self.x, self.top - 1), size=(self.width, 1))
            Color(*theme.c("glass_line", 110))
            Rectangle(pos=(self.x, self.top - 2), size=(self.width, 1))