"""AeroButton - a native Windows Vista/7 Aero command button.

Anatomy (all cached textures + canvas primitives, painted once per state
change - no animation, no shaders):

    1. soft drop shadow (gone while pressed/disabled)
    2. glossy gradient body: near-white top -> saturated Aero blue edge
    3. upper sheen band: the Aero gloss across the top half
    4. thin blue-gray border + 1px luminous inner ring (the glass)
    5. bottom inner shade line: the bevel
    6. hover: brighter body + cyan glow halo + accent border
    7. pressed: inverted darker gradient, inner top shade, shadow retracts -
       the button visually sinks into the surface
    8. disabled: desaturated flat face, no shadow, faint text
    9. accent (default) button: full Aero-blue orb with white text

Small 3px corners throughout - Vista/7 buttons are squared-off bevels, not
modern pill buttons. Size, padding, label and on_release behaviour are
identical to the previous version.
"""
from kivy.uix.behaviors import ButtonBehavior
from kivy.uix.boxlayout import BoxLayout

from .. import theme
from .aero import Hover, L

_RADIUS = 3


class AeroButton(ButtonBehavior, BoxLayout, Hover):
    def __init__(self, text="", accent=False, on_press_fn=None, **kwargs):
        kwargs.setdefault("size_hint_y", None)
        kwargs.setdefault("height", theme.H_BUTTON)
        kwargs.setdefault("padding", (10, 0))
        BoxLayout.__init__(self, **kwargs)
        ButtonBehavior.__init__(self)
        Hover.__init__(self)
        self.accent = accent
        self._press_fn = on_press_fn
        self.label = L(text, size=theme.FS_NORMAL, bold=False,
                       color="text", align="center")
        self.add_widget(self.label)
        self.bind(pos=self.repaint, size=self.repaint, state=self.repaint)
        self.repaint()

    def on_release(self):
        if not self.disabled and self._press_fn:
            self._press_fn()

    # ------------------------------------------------------------- painting
    def repaint(self, *_a):
        from kivy.graphics import Color, Line, RoundedRectangle
        down = getattr(self, "state", "normal") == "down"
        x, y, w, h = self.x, self.y, self.width, self.height
        r = _RADIUS

        # -- resolve state -> (body gradient, border key, sheen alpha) ------
        if self.disabled:
            top = bot = "surface2"
            edge, sheen_a, glow = "border", 0.0, False
            self.label.color = theme.c("text_faint")
        elif self.accent:
            if down:
                top, bot = "accent_lo", "accent"
            elif self.hovered:
                top, bot = "accent_hi", "accent_lo"
            else:
                top, bot = "accent_hi", "accent"
            edge = "accent_lo"
            sheen_a, glow = 0.42, self.hovered and not down
            self.label.color = (1, 1, 1, 1)
        else:
            if down:
                top, bot = "btn_bot", "btn_sheen"   # sunken: darker on top
            elif self.hovered:
                top, bot = "btn_top", "btn_mid"     # brighter, glowing
            else:
                top, bot = "btn_top", "btn_bot"
            edge = "accent" if self.hovered else "btn_edge"
            sheen_a = 0.22 if down else (0.5 if self.hovered else 0.38)
            glow = self.hovered and not down
            self.label.color = theme.c("text")

        # -- canvas.before: shadow, hover halo, gradient body, sheen --------
        self.canvas.before.clear()
        with self.canvas.before:
            if not down and not self.disabled:
                Color(1, 1, 1, 1)
                RoundedRectangle(pos=(x - 2, y - 4), size=(w + 4, h + 4),
                                 radius=[r + 2],
                                 texture=theme.radial("shadow", 50))
            if glow:
                # cyan Aero hover halo bleeding just past the edges
                Color(1, 1, 1, 1)
                RoundedRectangle(pos=(x - 3, y - 3), size=(w + 6, h + 6),
                                 radius=[r + 3],
                                 texture=theme.radial("accent_hi", 95))
            Color(1, 1, 1, 1)
            RoundedRectangle(pos=(x, y), size=(w, h), radius=[r],
                             texture=theme.vgrad(top, bot, 32))
            if sheen_a > 0:
                # glossy sheen across the upper half
                Color(1, 1, 1, sheen_a)
                RoundedRectangle(pos=(x + 1, y + h * 0.5),
                                 size=(w - 2, h * 0.5 - 1), radius=[r],
                                 texture=theme.radial("cloud", 120))

        # -- canvas.after: border, luminous inner ring, bevel shades --------
        self.canvas.after.clear()
        with self.canvas.after:
            Color(*theme.c(edge))
            Line(rounded_rectangle=(x, y, w, h, r), width=1.0)
            if not self.disabled:
                # 1px luminous inner ring: the glass edge
                Color(*theme.c("glass_line",
                               120 if down else 200))
                Line(rounded_rectangle=(x + 1, y + 1, w - 2, h - 2, r - 1),
                     width=1.0)
            if down:
                # pressed: inner top shade, bottom light catch = pushed in
                Color(*theme.c("shadow", 95))
                Line(points=(x + r, self.top - 1, x + w - r, self.top - 1),
                     width=1.0)
                Color(*theme.c("glass_line", 110))
                Line(points=(x + r, y + 1, x + w - r, y + 1), width=1.0)
            elif not self.disabled:
                # resting bevel: bright top catch + darker bottom shade
                Color(*theme.c("glass_line", 235))
                Line(points=(x + r, self.top - 1, x + w - r, self.top - 1),
                     width=1.0)
                Color(*theme.c("shadow", 55))
                Line(points=(x + r, y + 1, x + w - r, y + 1), width=1.0)