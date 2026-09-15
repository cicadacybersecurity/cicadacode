"""AeroButton - the Windows 7 glossy/beveled button (2.5 depth pass).

Normal: white highlight -> saturated Aero blue -> darker bottom edge, plus a
soft drop shadow. Hover: brighter + luminous blue border. Pressed: darker,
inset, shadow reduced. Disabled: desaturated, no shadow. Accent: blue orb
with white text. All textures cached; repaint on state/hover/theme only.
"""
from kivy.uix.behaviors import ButtonBehavior
from kivy.uix.boxlayout import BoxLayout

from .. import theme
from .aero import Hover, L, paint_bg, paint_border


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

    def repaint(self, *_a):
        from kivy.graphics import Color, Line
        down = getattr(self, "state", "normal") == "down"
        if self.disabled:
            paint_bg(self, color=theme.c("surface2"), radius=3)
            paint_border(self, theme.c("border"), radius=3)
            self.label.color = theme.c("text_faint")
            return
        self.label.color = (1, 1, 1, 1) if self.accent else theme.c("text")
        if self.accent:
            top, bot = (("accent_hi", "accent") if not down
                        else ("accent", "accent_lo"))
        elif down:
            top, bot = "btn_bot", "btn_mid"   # pressed: visually pushed in
        elif self.hovered:
            top, bot = "btn_sheen", "btn_bot"  # hover: brighter, glowing
        else:
            top, bot = "btn_top", "btn_bot"
        paint_bg(self, tex=theme.vgrad(top, bot, 32), radius=3,
                 shadow=True,
                 shadow_alpha=(90 if self.accent else 60) if not down else 30,
                 shadow_dy=(1 if down else 2), shadow_grow=2)
        edge = "accent" if (self.hovered or self.accent) else "btn_edge"
        paint_border(self, theme.c(edge), radius=3)
        x, y, r, t = self.x, self.y, self.right, self.top
        with self.canvas.after:
            if not down:
                # top glass highlight + bottom inner shade = the bevel
                Color(*theme.c("glass_line", 210))
                Line(points=(x + 3, t - 1, r - 3, t - 1), width=1.0)
                Color(*theme.c("shadow", 45))
                Line(points=(x + 3, y + 1, r - 3, y + 1), width=1.0)
            else:
                # pressed: inner top shade instead of highlight
                Color(*theme.c("shadow", 80))
                Line(points=(x + 3, t - 1, r - 3, t - 1), width=1.0)
            if self.hovered and not down:
                # luminous hover glow ring just inside the border
                Color(*theme.c("accent_hi", 110))
                Line(rounded_rectangle=(x + 1, y + 1, self.width - 2,
                                        self.height - 2, 2), width=1.0)