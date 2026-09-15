"""Logs page - professional light log viewer on the common Page frame.

Same polling (2s, only while visible), same think-stripping, filter, copy
and clear. The console is a light surface with dark mono text - never a
black page.
"""
import re

from kivy.clock import Clock
from kivy.core.clipboard import Clipboard
from kivy.uix.boxlayout import BoxLayout

from .. import theme
from ..components.aero import L, TInput, TSpinner
from ..components.aero_button import AeroButton
from ..components.aero_panel import AeroGroup, Page
from ..services.bg import run_async

THINK_RE = re.compile(r"(?s)<think>.*?</think>")


def _render(messages):
    out = []
    for m in messages:
        info = m.get("info", {}) if isinstance(m, dict) else {}
        role = info.get("role", "?")
        parts = m.get("parts", []) if isinstance(m, dict) else []
        text = "\n".join(p.get("text", "") for p in parts
                         if isinstance(p, dict) and p.get("type") == "text")
        text = THINK_RE.sub("", text).strip()
        if text:
            out.append((role, text))
    return out


class LogsPage(Page):
    def __init__(self, worker_mgr, config, **kwargs):
        super().__init__("Logs", "Live worker session output", **kwargs)
        self.mgr = worker_mgr
        self.config = config
        self._timer = None
        self._seen = 0
        self._full = ""

        grp = AeroGroup("Session")  # auto-fit: one fixed-height control row
        bar = BoxLayout(size_hint_y=None, height=theme.H_FIELD, spacing=6)
        bar.add_widget(L("Worker:", size=theme.FS_TABLE, size_hint_x=None,
                         width=60))
        self.combo = TSpinner([], size_hint=(None, None), size=(220, theme.H_FIELD))
        self.combo.bind(text=self._switch)
        bar.add_widget(self.combo)
        bar.add_widget(L("Filter:", size=theme.FS_TABLE, size_hint_x=None,
                         width=48))
        self.filter = TInput(placeholder="text filter...")
        self.filter.bind(text=lambda _w, _t: self._apply_filter())
        bar.add_widget(self.filter)
        bar.add_widget(AeroButton("Copy", on_press_fn=self._copy,
                                  size_hint_x=None, width=72))
        bar.add_widget(AeroButton("Clear", on_press_fn=self._clear,
                                  size_hint_x=None, width=72))
        grp.content.add_widget(bar)
        self.content.add_widget(grp)

        console_grp = AeroGroup("Output", weight=1)
        self.view = TInput(readonly=True, multiline=True, mono=True)
        console_grp.content.add_widget(self.view)
        self.content.add_widget(console_grp)

        bar = self.make_actions()
        self.status = L("", size=theme.FS_DIM, color="text_faint")
        bar.add_widget(self.status)

    # -- lifecycle ------------------------------------------------------------
    def on_activate(self):
        self.refresh_workers()
        self._poll()
        if self._timer is None:
            self._timer = Clock.schedule_interval(lambda _dt: self._poll(), 2)

    def on_deactivate(self):
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None

    # -- behavior (unchanged logic) -------------------------------------------
    def refresh_workers(self):
        current = self.combo.text
        self.combo.values = list(self.mgr.workers.keys())
        if current in self.combo.values:
            self.combo.text = current

    def _switch(self, *_a):
        self._seen = 0
        self._full = ""
        self.view.text = ""
        self._poll()

    def _clear(self):
        self._seen = 0
        self._full = ""
        self.view.text = ""

    def _copy(self):
        Clipboard.copy(self.view.text)
        self.status.text = "copied to clipboard"

    def _apply_filter(self):
        text = self.filter.text.lower()
        if not text:
            self.view.text = self._full
        else:
            self.view.text = "\n".join(
                ln for ln in self._full.split("\n") if text in ln.lower())

    def _poll(self):
        name = self.combo.text
        if not name or name not in self.mgr.workers:
            return
        run_async(lambda: self.mgr.messages(name), on_done=self._append)

    def _append(self, messages):
        if not messages:
            return
        if len(messages) < self._seen:  # session reset
            self._seen = 0
            self._full = ""
        new = messages[self._seen:]
        self._seen = len(messages)
        rows = _render(new)
        if not rows:
            return
        lines = []
        for role, text in rows:
            tag = "YOU" if role == "user" else (
                "AGENT" if role == "assistant" else role.upper())
            body = text if len(text) < 4000 else text[:4000] + "\n... (truncated)"
            lines.append("[" + tag + "]\n" + body + "\n")
        self._full += "\n".join(lines)
        self._full = self._full[-200000:]  # bounded in-memory log
        self._apply_filter()
        self.view.cursor = (0, len(self.view.text))
        self.status.text = str(self._seen) + " messages"