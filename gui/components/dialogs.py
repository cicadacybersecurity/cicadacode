"""Aero dialogs - ONE reusable primitive with deterministic geometry,
Phase 2.5 depth pass: the dialog floats like a real Aero window.

AeroDialog gets an explicit width from its caller and an explicit height
summed from fixed-height rows in finalize(). No ModalView is ever left at
the Kivy default 100x100, and no sizing relies on minimum_height while
children remain size_hint_y=1.

message / confirm / prompt are built on it; the Providers page builds its
Add-provider form on it too - there is no second dialog implementation.
"""
import textwrap

from kivy.uix.boxlayout import BoxLayout
from kivy.uix.modalview import ModalView

from .. import theme
from .aero import L, TInput, paint_bg, paint_border, top_highlight
from .aero_button import AeroButton


class AeroDialog(ModalView):
    """Aero glass dialog: strong soft shadow, light blue gradient frame,
    luminous border, glossy buttons. Size is always explicit and
    deterministic."""

    PADDING = 14
    SPACING = 8

    def __init__(self, title, width=460, **kwargs):
        kwargs.setdefault("size_hint", (None, None))
        kwargs.setdefault("auto_dismiss", True)
        super().__init__(**kwargs)
        self.background = ""
        self.background_color = (0, 0, 0, 0)
        self.width = width
        self.col = BoxLayout(orientation="vertical",
                             padding=(16, self.PADDING),
                             spacing=self.SPACING, size_hint=(1, 1))
        self.col.bind(pos=self._repaint, size=self._repaint)
        self.add_widget(self.col)
        self.col.add_widget(L(title, size=15, bold=True,
                              size_hint_y=None, height=26))

    def add_row(self, widget, height):
        """Add a fixed-height content row. height is explicit - always."""
        widget.size_hint_y = None
        widget.height = height
        self.col.add_widget(widget)
        return widget

    def add_text(self, text, size=12, color="text_dim", chars=64):
        """Wrapped paragraph row; height derived from the wrapped line count."""
        lines = []
        for part in str(text).split("\n"):
            lines.extend(textwrap.wrap(part, chars) or [""])
        lbl = L("\n".join(lines), size=size, color=color)
        return self.add_row(lbl, 6 + 19 * len(lines))

    def add_label(self, text):
        """Small dim field caption above an input."""
        return self.add_row(L(text, size=theme.FS_DIM, color="text_dim"), 16)

    def button_row(self, buttons):
        """Right-aligned buttons: list of (text, on_press, accent)."""
        row = BoxLayout(spacing=8)
        row.add_widget(BoxLayout())
        for text, fn, accent in buttons:
            row.add_widget(AeroButton(text, accent=accent, on_press_fn=fn,
                                      size_hint_x=None, width=96))
        return self.add_row(row, theme.H_BUTTON)

    def finalize(self):
        """Set the explicit dialog height from the fixed rows, then repaint."""
        n = len(self.col.children)
        self.height = (2 * self.PADDING +
                       sum(ch.height for ch in self.col.children) +
                       self.SPACING * max(0, n - 1))
        self._repaint()
        return self

    def _repaint(self, *_a):
        # floating Aero frame: deeper shadow than in-page panels
        paint_bg(self.col, tex=theme.vgrad("header_hi", "surface2", 48),
                 radius=5, shadow=True, shadow_alpha=150, shadow_dy=6,
                 shadow_grow=12)
        paint_border(self.col, theme.c("border_lo"), radius=5)
        top_highlight(self.col, alpha=220, inset=1, radius=5)

    def open_and_return(self):
        self.open()
        return self


# ----------------------------------------------------------------- helpers
def message(title, text):
    dlg = AeroDialog(title, width=440)
    dlg.add_text(text)
    dlg.button_row([("OK", dlg.dismiss, True)])
    return dlg.finalize().open_and_return()


def confirm(title, text, on_yes):
    dlg = AeroDialog(title, width=440)
    dlg.add_text(text)

    def yes():
        dlg.dismiss()
        on_yes()

    dlg.button_row([("Yes", yes, False), ("Cancel", dlg.dismiss, False)])
    return dlg.finalize().open_and_return()


def prompt(title, label, on_ok, multiline=False):
    dlg = AeroDialog(title, width=460)
    dlg.add_text(label)
    entry = TInput(multiline=multiline)
    dlg.add_row(entry, 110 if multiline else theme.H_FIELD)

    def ok():
        text = entry.text
        dlg.dismiss()
        on_ok(text)

    dlg.button_row([("OK", ok, True), ("Cancel", dlg.dismiss, False)])
    return dlg.finalize().open_and_return()