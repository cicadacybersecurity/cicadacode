"""Settings page - Control Panel style form on the common Page frame.

Same keys, same save semantics, same one-click secrets migration into DPAPI
(manager\\secrets.json -> moved to .pre-dpapi). Groups are auto-fit inside a
scrollable column so the page stays correct on short windows. Apply bar is
docked at the bottom.
"""
import json
import os

from kivy.uix.boxlayout import BoxLayout

from .. import theme
from ..components.aero import L, TCheckBox, TInput, TSpinner
from ..components.aero_button import AeroButton
from ..components.aero_panel import AeroGroup, Page
from ..services.bg import run_async


def _root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _form_row(label, widget, width=None):
    row = BoxLayout(size_hint_y=None, height=theme.H_FIELD, spacing=10)
    row.add_widget(L(label, size=theme.FS_TABLE, color="text_dim",
                     size_hint_x=None, width=190))
    if width:
        widget.size_hint_x = None
        widget.width = width
    row.add_widget(widget)
    return row


class SettingsPage(Page):
    def __init__(self, config_store, config, creds, on_apply, **kwargs):
        super().__init__("Settings", "Application configuration",
                         scroll=True, **kwargs)
        self.config_store = config_store
        self.config = config
        self.creds = creds
        self.on_apply = on_apply

        gen = AeroGroup("General")
        self.refresh_sec = TInput(
            text=str(config["general"].get("refresh_interval_sec", 3)),
            placeholder="seconds")
        gen.content.add_widget(_form_row("Refresh interval (s)",
                                         self.refresh_sec, 90))
        notif_row = BoxLayout(size_hint_y=None, height=24, spacing=8)
        self.notifications = TCheckBox(
            active=bool(config["general"].get("notifications", True)),
            size_hint=(None, None), size=(20, 20))
        notif_row.add_widget(self.notifications)
        notif_row.add_widget(L("Show status notifications",
                               size=theme.FS_TABLE))
        gen.content.add_widget(notif_row)
        self.content.add_widget(gen)

        work = AeroGroup("Workers")
        self.port_base = TInput(text=str(config["workers"].get("port_base", 4310)))
        work.content.add_widget(_form_row("Worker port base", self.port_base, 110))
        self.max_workers = TSpinner(
            [str(i) for i in range(1, 9)],
            text=str(config["workers"].get("max_workers", 3)),
            size_hint=(None, None), size=(110, theme.H_FIELD))
        work.content.add_widget(_form_row("Max workers", self.max_workers))
        self.content.add_widget(work)

        oc = AeroGroup("OpenCode")
        exe_row = BoxLayout(orientation="horizontal", spacing=6)
        self.exe_path = TInput(text=config["opencode"].get("exe_path", ""),
                               placeholder="auto-detect (recommended)")
        exe_row.add_widget(self.exe_path)
        exe_row.add_widget(AeroButton("Browse...", on_press_fn=self._browse_exe,
                                      size_hint_x=None, width=80))
        oc.content.add_widget(_form_row("opencode executable", exe_row))
        self.cfg_path = TInput(text=config["opencode"].get("config_path", ""),
                               placeholder="minimax-opencode.json")
        oc.content.add_widget(_form_row("opencode config file", self.cfg_path))
        self.content.add_widget(oc)

        sec = AeroGroup("Security")
        self.dpapi_status = L("", size=theme.FS_DIM, color="text_faint",
                              size_hint_y=None, height=18)
        sec.content.add_widget(self.dpapi_status)
        self.keys_label = L("", size=theme.FS_DIM, color="text_faint",
                            size_hint_y=None, height=18)
        sec.content.add_widget(self.keys_label)
        mig = BoxLayout(size_hint_y=None, height=theme.H_BUTTON)
        mig.add_widget(AeroButton("Import keys from manager\\secrets.json",
                                  on_press_fn=self._import_legacy,
                                  size_hint_x=None, width=280))
        mig.add_widget(BoxLayout())
        sec.content.add_widget(mig)
        self.content.add_widget(sec)

        bar = self.make_actions()
        bar.add_widget(AeroButton("Apply settings", accent=True,
                                  on_press_fn=self._apply,
                                  size_hint_x=None, width=130))
        bar.add_widget(BoxLayout())
        self.status = L("", size=theme.FS_DIM, color="text_faint",
                        size_hint_x=None, width=280)
        bar.add_widget(self.status)

        self._refresh_security()

    def _browse_exe(self):
        from ..components import dialogs
        dialogs.prompt("opencode executable",
                       "Full path to opencode.exe (blank = auto-detect):",
                       lambda text: setattr(self.exe_path, "text", text))

    def _say(self, text, color="text_faint"):
        self.status.text = text
        self.status.color = theme.c(color)

    def _refresh_security(self):
        try:
            self.creds.set("__dpapi_probe__", "ok")
            self.creds.delete("__dpapi_probe__")
            self.dpapi_status.text = "Credential storage: Windows DPAPI (encrypted) - OK"
            self.dpapi_status.color = theme.c("ok")
        except Exception as exc:
            self.dpapi_status.text = "Credential storage UNAVAILABLE: " + str(exc)
            self.dpapi_status.color = theme.c("err")
        names = self.creds.names()
        if names:
            self.keys_label.text = "Stored keys: " + "   ".join(
                n + "  " + self.creds.mask(self.creds.get(n)) for n in sorted(names))
        else:
            self.keys_label.text = "Stored keys: none yet (add one on the Providers tab)"

    def _import_legacy(self):
        secrets_path = os.path.join(_root(), "manager", "secrets.json")
        if not os.path.isfile(secrets_path):
            self._say("manager\\secrets.json not found - nothing to import.", "warn")
            return

        def _do_import():
            with open(secrets_path, "r", encoding="utf-8-sig") as fh:
                data = json.load(fh)
            imported = 0
            for name, value in data.items():
                if value and isinstance(value, str) and not value.startswith("PASTE-"):
                    self.creds.set(name, value)
                    imported += 1
            backup = secrets_path + ".pre-dpapi"
            if not os.path.exists(backup):
                os.replace(secrets_path, backup)
            else:
                os.unlink(secrets_path)
            return imported

        run_async(_do_import,
                  on_done=lambda n: (self._say(
                      str(n) + " keys imported to encrypted storage; "
                      "secrets.json moved to secrets.json.pre-dpapi", "ok"),
                      self._refresh_security()),
                  on_failed=lambda e: self._say(e, "err"))

    def _apply(self):
        try:
            self.config["general"]["refresh_interval_sec"] = max(
                1, int(self.refresh_sec.text.strip() or "3"))
            self.config["workers"]["port_base"] = max(
                1024, int(self.port_base.text.strip() or "4310"))
        except ValueError:
            self._say("Refresh interval and port base must be numbers.", "err")
            return
        self.config["general"]["notifications"] = bool(self.notifications.active)
        self.config["workers"]["max_workers"] = int(self.max_workers.text)
        self.config["opencode"]["exe_path"] = self.exe_path.text.strip()
        self.config["opencode"]["config_path"] = self.cfg_path.text.strip()
        self.config_store.save(self.config)
        self.on_apply()
        self._say("settings saved", "ok")