"""Providers page - configuration tool on the common Page frame.

Same registry, same DPAPI key handling (masked everywhere), same Add /
rotate / test / discover / enable / remove actions. The Add dialog is built
on the shared AeroDialog primitive: explicit deterministic size, no second
dialog implementation, no 100x100 ModalView collapse.
"""
from kivy.uix.boxlayout import BoxLayout

from .. import theme
from ..components import dialogs
from ..components.aero import L, TInput, TSpinner
from ..components.aero_button import AeroButton
from ..components.aero_panel import AeroGroup, Page
from ..components.aero_table import AeroTable
from ..components.dialogs import AeroDialog
from ..services.bg import run_async
from ..services.providers import PRESETS, ProviderError

COLUMNS = ["Provider", "Base URL", "API key", "Models", "Enabled"]
WEIGHTS = [2, 3, 2, 2, 1]


class AddProviderDialog:
    """Preset or custom OpenAI-compatible provider + key, tested inline.

    Built on AeroDialog: every row is fixed-height, the dialog height is
    summed explicitly in finalize() - geometry cannot collapse.
    """

    def __init__(self, registry, on_saved):
        self.registry = registry
        self.on_saved = on_saved
        self.provider = None

        dlg = AeroDialog("Add provider", width=520)
        self.dlg = dlg
        dlg.add_text("Preset or custom OpenAI-compatible endpoint",
                     size=theme.FS_DIM)

        dlg.add_label("Provider")
        self.preset = TSpinner(["MiniMax", "Cerebras",
                                "Custom (OpenAI-compatible)"], text="MiniMax")
        self.preset.bind(text=self._preset_changed)
        dlg.add_row(self.preset, theme.H_FIELD)

        dlg.add_label("Display name")
        self.name = TInput()
        dlg.add_row(self.name, theme.H_FIELD)

        dlg.add_label("Base URL")
        self.base_url = TInput()
        dlg.add_row(self.base_url, theme.H_FIELD)

        dlg.add_label("API key (stored encrypted, shown masked)")
        self.key = TInput(password=True)
        dlg.add_row(self.key, theme.H_FIELD)

        test = BoxLayout(spacing=8)
        test.add_widget(AeroButton("Test connection", on_press_fn=self._test,
                                   size_hint_x=None, width=140))
        self.result = L("", size=theme.FS_DIM, color="text_faint")
        test.add_widget(self.result)
        dlg.add_row(test, theme.H_FIELD)

        dlg.button_row([("Save", self._save, True),
                        ("Cancel", self._cancel, False)])
        dlg.finalize()
        self._preset_changed()

    def open(self):
        self.dlg.open()

    def _cancel(self):
        self.dlg.dismiss()

    def _preset_changed(self, *_a):
        text = self.preset.text
        if text == "MiniMax":
            self.name.text, self.base_url.text = "MiniMax", PRESETS["minimax"]["base_url"]
            self.name.readonly = self.base_url.readonly = True
        elif text == "Cerebras":
            self.name.text, self.base_url.text = "Cerebras", PRESETS["cerebras"]["base_url"]
            self.name.readonly = self.base_url.readonly = True
        else:
            self.name.text = self.base_url.text = ""
            self.name.readonly = self.base_url.readonly = False

    def _say(self, text, color="text_faint"):
        self.result.text = text
        self.result.color = theme.c(color)

    def _make_provider(self):
        text = self.preset.text
        if text == "MiniMax":
            return self.registry.get("minimax")
        if text == "Cerebras":
            return self.registry.get("cerebras")
        name = self.name.text.strip()
        url = self.base_url.text.strip()
        if not name or not url:
            raise ProviderError("Name and base URL are required for a custom provider.")
        return self.registry.add_custom(name, url)

    def _test(self):
        key = self.key.text.strip()
        if not key:
            self._say("Paste the API key first.", "err")
            return
        try:
            prov = self._make_provider()
        except ProviderError as exc:
            self._say(str(exc), "err")
            return
        prov.set_key(key)
        self._say("testing...", "warn")
        run_async(lambda: (prov.test_connection(), prov.discover_models()),
                  on_done=lambda r: self._say(
                      "OK - " + str(r[0]["latency_ms"]) + " ms, " +
                      str(len(r[1])) + " models discovered", "ok"),
                  on_failed=lambda e: self._say(e, "err"))

    def _save(self):
        key = self.key.text.strip()
        if not key:
            self._say("Paste the API key first.", "err")
            return
        try:
            prov = self._make_provider()
        except ProviderError as exc:
            self._say(str(exc), "err")
            return
        prov.set_key(key)
        prov.enabled = True
        self.provider = prov
        self.dlg.dismiss()
        self.on_saved(prov)


class ProvidersPage(Page):
    def __init__(self, registry, config, on_change, **kwargs):
        super().__init__("Providers",
                         "Keys are stored encrypted (Windows DPAPI) and shown "
                         "masked. Saving rewrites the opencode config "
                         "automatically.", **kwargs)
        self.registry = registry
        self.config = config
        self.on_change = on_change

        grp = AeroGroup("Configured providers", weight=1)
        self.table = AeroTable(COLUMNS, weights=WEIGHTS,
                               empty_text="No providers configured")
        grp.content.add_widget(self.table)
        self.content.add_widget(grp)

        bar = self.make_actions()
        for label, fn in (("Add provider...", self._add),
                          ("Set / rotate key...", self._set_key),
                          ("Test connection", self._test),
                          ("Discover models", self._discover),
                          ("Enable / Disable", self._toggle),
                          ("Remove custom", self._remove)):
            bar.add_widget(AeroButton(label, on_press_fn=fn,
                                      size_hint_x=None, width=140))
        bar.add_widget(BoxLayout())
        self.status = L("", size=theme.FS_DIM, color="text_faint",
                        size_hint_x=None, width=300)
        bar.add_widget(self.status)

    def on_activate(self):
        self.refresh()

    def _say(self, text, color="text_faint"):
        self.status.text = text
        self.status.color = theme.c(color)

    def _selected(self):
        row = self.table.selected_row()
        if row is None:
            self._say("Select a provider row first.")
            return None
        return self._prov_by_name(row[0])

    def _prov_by_name(self, display_name):
        for p in self.registry.all():
            if p.display_name == display_name:
                return p
        return None

    def _changed(self, msg="saved"):
        self.on_change()
        self.refresh()
        self._say(msg, "ok")

    def _add(self):
        AddProviderDialog(self.registry,
                          on_saved=lambda prov: self._changed(
                              prov.display_name +
                              " added - key stored encrypted, models on the Models tab")
                          ).open()

    def _set_key(self):
        prov = self._selected()
        if prov is None:
            return

        def save(text):
            if text.strip():
                prov.set_key(text.strip())
                self._changed("key updated for " + prov.display_name)

        dialogs.prompt("API key - " + prov.display_name,
                       "Paste the new key (stored encrypted, shown masked):", save)

    def _test(self):
        prov = self._selected()
        if prov is None:
            return
        self._say("testing " + prov.display_name + "...", "warn")
        run_async(lambda: prov.test_connection(),
                  on_done=lambda r: self._say(
                      prov.display_name + " OK - " + str(r["latency_ms"]) + " ms",
                      "ok"),
                  on_failed=lambda e: self._say(e, "err"))

    def _discover(self):
        prov = self._selected()
        if prov is None:
            return
        self._say("discovering models...", "warn")
        run_async(lambda: prov.discover_models(),
                  on_done=lambda models: self._changed(
                      str(len(models)) + " models known for " + prov.display_name),
                  on_failed=lambda e: self._say(e, "err"))

    def _toggle(self):
        prov = self._selected()
        if prov is None:
            return
        prov.enabled = not prov.enabled
        self._changed(prov.display_name +
                      (" enabled" if prov.enabled else " disabled"))

    def _remove(self):
        prov = self._selected()
        if prov is None:
            return

        def go():
            try:
                self.registry.remove(prov.id)
            except ProviderError as exc:
                self._say(str(exc), "err")
                return
            self._changed(prov.display_name + " removed")

        dialogs.confirm("Remove provider",
                        "Remove " + prov.display_name +
                        " and delete its stored key?", go)

    def refresh(self):
        self.table.set_rows(
            [[p.display_name, p.base_url, p.masked_key(),
              str(len(p.models)) + " known" if p.models else "not discovered",
              "yes" if p.enabled else "no"] for p in self.registry.all()])