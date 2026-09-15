"""Diagnostics page - system utility on the common Page frame.

Same read-only collector, same masked-secrets guarantee, same async
refresh. Light mono console, refresh docked in the action bar.
"""
import json
import os
import platform

from kivy.uix.boxlayout import BoxLayout

from .. import theme
from ..components.aero import L, TInput
from ..components.aero_button import AeroButton
from ..components.aero_panel import Page
from ..services.bg import run_async


def _root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class DiagnosticsPage(Page):
    def __init__(self, opencode, registry, workers, config, **kwargs):
        super().__init__("Diagnostics", "Read-only system inspector", **kwargs)
        self.opencode = opencode
        self.registry = registry
        self.workers = workers
        self.config = config

        self.view = TInput(readonly=True, multiline=True, mono=True)
        self.content.add_widget(self.view)

        bar = self.make_actions()
        bar.add_widget(AeroButton("Refresh", on_press_fn=self.refresh,
                                  size_hint_x=None, width=90))
        bar.add_widget(BoxLayout())
        self.status = L("", size=theme.FS_DIM, color="text_faint",
                        size_hint_x=None, width=260)
        bar.add_widget(self.status)

    def on_activate(self):
        self.refresh()

    def refresh(self):
        self.status.text = "collecting..."
        run_async(self._collect, on_done=self._show,
                  on_failed=lambda e: setattr(self.status, "text", e))

    def _collect(self) -> str:
        lines = []
        add = lines.append
        add("== runtime ==")
        add("python " + platform.python_version() + "   " + platform.system() +
            " " + platform.release())
        try:
            import kivy
            add("kivy " + kivy.__version__)
        except Exception:
            add("kivy: version unknown")
        add("")
        add("== opencode ==")
        try:
            add("exe: " + self.opencode.resolve_exe())
            add("version: " + self.opencode.version())
        except Exception as exc:
            add("ERROR: " + str(exc))
        add("config file: " + self.opencode.config_path)
        if os.path.isfile(self.opencode.config_path):
            try:
                with open(self.opencode.config_path, "r", encoding="utf-8-sig") as fh:
                    cfg = json.load(fh)
                add("config valid JSON: yes")
                add("providers in config: " + ", ".join(cfg.get("provider", {}).keys()))
                add("default model: " + str(cfg.get("model", "(none)")))
            except (json.JSONDecodeError, OSError) as exc:
                add("config valid JSON: NO - " + str(exc))
        else:
            add("config file: MISSING")
        add("")
        add("== providers (keys masked) ==")
        for p in self.registry.all():
            state = "enabled" if p.enabled else "disabled"
            add(p.id + "  " + state + "  key " + p.masked_key() +
                "  models " + str(len(p.models)))
        add("")
        add("== workers ==")
        if self.workers.workers:
            for name, w in self.workers.workers.items():
                add(name + "  state " + w.state + "  port " + str(w.port) +
                    "  pid " + str(w.pid) + "  model " + (w.model or "(default)") +
                    ("  error: " + w.error if w.error else ""))
        else:
            add("(none registered)")
        add("")
        add("== state directory ==")
        state = os.path.join(_root(), "state")
        for sub, label in (("runs", "run journals"), ("logs", "agent call logs"),
                           ("secrets", "encrypted key blobs")):
            path = os.path.join(state, sub)
            if os.path.isdir(path):
                add(label + ": " + str(len(os.listdir(path))) + " files")
            else:
                add(label + ": (none)")
        add("")
        add("== gui-config.json ==")
        add(json.dumps(self.config, indent=2)[:3000])
        return "\n".join(lines)

    def _show(self, text):
        self.view.text = text
        self.status.text = ""