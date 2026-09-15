"""Core Kivy painting + themed stock widgets for the Aero system (2.5).

Everything visual funnels through here: cached gradient/shadow textures,
glass/border/shadow paint helpers, the label factory, and themed Aero
controls (AeroInput / AeroSpinner / AeroCheckBox) that look like Vista/7
controls rather than default Kivy widgets and re-apply their colours on
every Day/Night switch. No continuous animation anywhere.
"""
from kivy.core.window import Window
from kivy.graphics import Color, Line, Mesh, Rectangle, RoundedRectangle
from kivy.uix.checkbox import CheckBox
from kivy.uix.label import Label
from kivy.uix.spinner import Spinner
from kivy.uix.textinput import TextInput

from .. import theme


# ---------------------------------------------------------------- labels
def L(text="", size=12, color="text", bold=False, mono=False,
      align="left", **kwargs):
    """Label factory. `color` accepts a palette key (re-themed on Day/Night)
    or a concrete (r,g,b,a) tuple (used as-is, e.g. pill foregrounds)."""
    keyed = isinstance(color, str)
    lbl = Label(text=text, font_size=size, bold=bold,
                font_name=theme.MONO if mono else theme.SANS,
                color=theme.c(color) if keyed else color,
                halign=align, **kwargs)
    lbl.bind(size=lambda w, _v: setattr(w, "text_size", w.size))
    if keyed:
        theme.on_change(lambda: setattr(lbl, "color", theme.c(color)))
    return lbl


# ----------------------------------------------------------- paint helpers
def paint_bg(widget, tex=None, color=None, radius=0, shadow=False,
             shadow_alpha=70, shadow_dy=2, shadow_grow=3):
    """(Re)fill a widget's background. With shadow=True a soft cached
    drop-shadow is drawn first (offset down, slightly grown) so controls
    read as physically layered rather than flat rectangles."""
    widget.canvas.before.clear()
    with widget.canvas.before:
        if shadow:
            Color(1, 1, 1, 1)
            g = shadow_grow
            RoundedRectangle(pos=(widget.x - g, widget.y - shadow_dy - g),
                             size=(widget.width + g * 2,
                                   widget.height + g * 2),
                             radius=[radius + g],
                             texture=theme.radial("shadow", shadow_alpha))
        if tex is not None:
            Color(1, 1, 1, 1)
            if radius:
                RoundedRectangle(pos=widget.pos, size=widget.size,
                                 radius=[radius], texture=tex)
            else:
                Rectangle(pos=widget.pos, size=widget.size, texture=tex)
        elif color is not None:
            Color(*color)
            if radius:
                RoundedRectangle(pos=widget.pos, size=widget.size,
                                 radius=[radius])
            else:
                Rectangle(pos=widget.pos, size=widget.size)


def paint_border(widget, color=None, width=1.0, radius=0):
    widget.canvas.after.clear()
    if color is None:
        return
    with widget.canvas.after:
        Color(*color)
        if radius:
            Line(rounded_rectangle=(widget.x, widget.y, widget.width,
                                    widget.height, radius), width=width)
        else:
            Line(rectangle=(widget.x, widget.y, widget.width, widget.height),
                 width=width)


def top_highlight(widget, alpha=160, inset=2, radius=0):
    """1px luminous line just inside the top edge - the Aero glass sheen.
    Call after paint_border so it draws on top."""
    with widget.canvas.after:
        Color(*theme.c("glass_line", alpha))
        Line(points=(widget.x + inset + radius, widget.top - inset,
                   widget.right - inset - radius, widget.top - inset),
             width=1.0)


def repaint_walk(root):
    """Day/Night: every widget that knows how to repaint does so."""
    for widget in root.walk():
        repaint = getattr(widget, "repaint", None)
        if callable(repaint):
            repaint()


def hrule(color="group_line", height=1):
    """A 1px horizontal separator line."""
    from kivy.uix.widget import Widget
    w = Widget(size_hint_y=None, height=height)

    def _repaint(*_a):
        w.canvas.before.clear()
        with w.canvas.before:
            Color(*theme.c(color))
            Rectangle(pos=w.pos, size=w.size)
    w.bind(pos=_repaint, size=_repaint)
    w.repaint = _repaint
    _repaint()
    return w


def vspacer(h=6):
    from kivy.uix.widget import Widget
    return Widget(size_hint_y=None, height=h)


def hspacer(w=6):
    from kivy.uix.widget import Widget
    return Widget(size_hint_x=None, width=w)


# ------------------------------------------------------------- hover mixin
class Hover:
    """Adds .hovered (bool) and .repaint() call on hover change."""

    def __init__(self, *args, **kwargs):
        self.hovered = False
        super().__init__(*args, **kwargs)
        Window.bind(mouse_pos=self._on_mouse_pos)

    def _on_mouse_pos(self, _win, pos):
        if not self.get_root_window():
            return
        inside = self.collide_point(*self.to_widget(*pos))
        if inside != self.hovered:
            self.hovered = inside
            self.repaint()


# ------------------------------------------------------- Aero stock inputs
class AeroInput(TextInput):
    """Vista/7 text field: pale blue-white face, inset-style border, top
    inner shade line, and a stronger blue focus ring when focused."""

    def __init__(self, **kwargs):
        kwargs.setdefault("background_normal", "")
        kwargs.setdefault("background_active", "")
        kwargs.setdefault("font_size", theme.FS_TABLE)
        kwargs.setdefault("padding", (8, 7))
        super().__init__(**kwargs)
        self._apply()
        self.bind(pos=self.repaint, size=self.repaint, focus=self.repaint)
        theme.on_change(self._apply)

    def _apply(self):
        self.background_color = theme.c("input_bg")
        self.foreground_color = theme.c("text")
        self.cursor_color = theme.c("accent")
        self.hint_text_color = theme.c("text_faint")
        self.repaint()

    def repaint(self, *_a):
        self.canvas.after.clear()
        x, y, r, t = self.x, self.y, self.right, self.top
        with self.canvas.after:
            # border: accent ring when focused, subtle edge otherwise
            if self.focus:
                Color(*theme.c("focus"))
                Line(rounded_rectangle=(x - 1, y - 1, self.width + 2,
                                        self.height + 2, 3), width=1.2)
            Color(*theme.c("border_lo"))
            Line(rounded_rectangle=(x, y, self.width, self.height, 3),
                 width=1.0)
            # inset shade along the top inner edge
            Color(*theme.c("shadow", 70))
            Line(points=(x + 3, t - 1, r - 3, t - 1), width=1.0)


class AeroSpinner(Spinner):
    """Aero combo field: glass gradient face, border, and an integrated
    arrow zone on the right like a Vista combo box."""

    ARROW_W = 22

    def __init__(self, **kwargs):
        kwargs.setdefault("background_normal", "")
        kwargs.setdefault("font_size", theme.FS_TABLE)
        kwargs.setdefault("font_name", theme.SANS)
        super().__init__(**kwargs)
        self._apply()
        self.bind(pos=self.repaint, size=self.repaint, state=self.repaint)
        theme.on_change(self._apply)

    def _apply(self):
        self.background_color = (1, 1, 1, 1)  # face is painted, not tinted
        self.color = theme.c("text")
        self.repaint()

    def repaint(self, *_a):
        paint_bg(self, tex=theme.vgrad("btn_top", "btn_mid", 32), radius=3)
        self.canvas.after.clear()
        x, y, r, t = self.x, self.y, self.right, self.top
        ax = r - self.ARROW_W
        with self.canvas.after:
            Color(*theme.c("border_lo"))
            Line(rounded_rectangle=(x, y, self.width, self.height, 3),
                 width=1.0)
            # arrow zone separator
            Color(*theme.c("group_line"))
            Line(points=(ax, y + 3, ax, t - 3), width=1.0)
            # arrow glyph
            Color(*theme.c("text_dim"))
            cy = y + self.height / 2.0
            Mesh(vertices=[ax + 7, cy + 3, 0, 0,
                           ax + 15, cy + 3, 0, 0,
                           ax + 11, cy - 3, 0, 0],
                 indices=[0, 1, 2], mode="triangles")
            Color(*theme.c("glass_line", 170))
            Line(points=(x + 3, t - 1, r - 3, t - 1), width=1.0)


class AeroCheckBox(CheckBox):
    """Vista/7 check box: small beveled square, accent check mark."""

    def __init__(self, **kwargs):
        kwargs.setdefault("background_checkbox_normal", "")
        kwargs.setdefault("background_checkbox_down", "")
        kwargs.setdefault("background_radio_normal", "")
        kwargs.setdefault("background_radio_down", "")
        super().__init__(**kwargs)
        self.bind(pos=self.repaint, size=self.repaint, active=self.repaint)
        theme.on_change(self.repaint)
        self.repaint()

    def repaint(self, *_a):
        paint_bg(self, tex=theme.vgrad("btn_top", "btn_sheen", 16), radius=2)
        self.canvas.after.clear()
        x, y, w, h = self.x, self.y, self.width, self.height
        with self.canvas.after:
            Color(*theme.c("border_lo"))
            Line(rounded_rectangle=(x, y, w, h, 2), width=1.0)
            if self.active:
                Color(*theme.c("accent_lo"))
                Line(points=(x + w * 0.22, y + h * 0.5,
                             x + w * 0.42, y + h * 0.28,
                             x + w * 0.80, y + h * 0.74),
                     width=1.8, cap="round", joint="round")


# ---------------------------------- factory aliases (unchanged public API)
def TInput(multiline=False, password=False, placeholder="", text="",
           readonly=False, mono=False, **kwargs):
    """Themed text input (AeroInput) that follows Day/Night."""
    return AeroInput(multiline=multiline, password=password,
                     hint_text=placeholder, text=text, readonly=readonly,
                     font_name=theme.MONO if mono else theme.SANS, **kwargs)


def TSpinner(values=(), text="", **kwargs):
    """Themed spinner (AeroSpinner) that follows Day/Night."""
    return AeroSpinner(text=text or (values[0] if values else ""),
                       values=list(values), **kwargs)


def TCheckBox(active=False, **kwargs):
    """Themed check box (AeroCheckBox) that follows Day/Night."""
    return AeroCheckBox(active=active, **kwargs)