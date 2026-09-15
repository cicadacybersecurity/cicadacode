"""Dashboard page - fleet overview on the common Page frame.

Proportional composition: Fleet status / Providers+Recent runs / Worker
events share the content column by size_hint_y weights; tables scroll
internally and show a centered empty state. The page polls only while
visible (on_activate/on_deactivate).
"""
from kivy.clock import Clock
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.gridlayout import GridLayout

from .. import theme
from ..components.aero import L
from ..components.aero_panel import AeroGroup, Page
from ..components.aero_table import AeroTable


class DashboardPage(Page):
    def __init__(self, workers, journal, registry, opencode, config, **kwargs):
        super().__init__("CICADA Agent Fleet",
                         "Agent fleet overview - everything here is live",
                         **kwargs)
        self.workers = workers
        self.journal = journal
        self.registry = registry
        self.opencode = opencode
        self.config = config
        self._timer = None

        # Fleet Status: three prominent stats + default model
        fleet = AeroGroup("Fleet status", weight=3)
        stats = GridLayout(cols=3, spacing=18)
        self._stats = {}
        for caption in ("Workers online", "Workers busy", "Workers failed"):
            cell = BoxLayout(orientation="vertical")
            cell.add_widget(L(caption, size=theme.FS_SECTION,
                              color="text_dim", align="center",
                              size_hint_y=None, height=24))
            val = L("-", size=theme.FS_STAT, bold=True, align="center")
            self._stats[caption] = val
            cell.add_widget(val)
            stats.add_widget(cell)
        fleet.content.add_widget(stats)
        model_row = BoxLayout(size_hint_y=None, height=30, spacing=6)
        model_row.add_widget(L("Default model:", size=theme.FS_NORMAL,
                               color="text_dim", size_hint_x=None, width=170))
        self.val_model = L("-", size=theme.FS_NORMAL, bold=True)
        model_row.add_widget(self.val_model)
        fleet.content.add_widget(model_row)
        self.content.add_widget(fleet)

        # Providers | Recent Runs: equal horizontal split, flexes vertically
        mid = BoxLayout(orientation="horizontal", spacing=theme.PAGE_SPACING,
                        size_hint_y=4)
        prov = AeroGroup("Providers", weight=1)
        self.prov_table = AeroTable(["Provider", "API key", "Models"],
                                    weights=[2, 3, 2])
        prov.content.add_widget(self.prov_table)
        mid.add_widget(prov)
        runs = AeroGroup("Recent runs", weight=1)
        self.runs = AeroTable(["Run", "Mode", "Status", "Updated"],
                              weights=[1, 1, 1, 2], empty_text="No recent runs")
        runs.content.add_widget(self.runs)
        mid.add_widget(runs)
        self.content.add_widget(mid)

        # Worker Events: the deep section; many events scroll inside
        events = AeroGroup("Worker events", weight=5)
        self.events = AeroTable(["Time", "Worker", "Event"],
                                weights=[1, 1, 4], empty_text="No worker events")
        events.content.add_widget(self.events)
        self.content.add_widget(events)

    # -- lifecycle ------------------------------------------------------------
    def on_activate(self):
        self.refresh()
        if self._timer is None:
            self._timer = Clock.schedule_interval(
                lambda _dt: self.refresh(),
                int(self.config["general"]["refresh_interval_sec"]))

    def on_deactivate(self):
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None

    # -- data ------------------------------------------------------------------
    def refresh(self):
        ws = list(self.workers.workers.values())
        up = sum(1 for w in ws if w.state in ("idle", "running"))
        busy = sum(1 for w in ws if w.state == "running")
        failed = sum(1 for w in ws if w.state in ("failed", "unreachable"))
        self._stats["Workers online"].text = str(up) + " / " + str(len(ws))
        self._stats["Workers busy"].text = str(busy)
        self._stats["Workers failed"].text = str(failed)
        self.val_model.text = str(self.config.get("default_model", "-")).split("/")[-1]

        self.prov_table.set_rows(
            [[p.display_name, p.masked_key(),
              str(len(p.models)) + " models"] for p in self.registry.all()])

        self.runs.set_rows(
            [[str(r.get("id", "")), str(r.get("mode", "")),
              ("pill", str(r.get("status", "pending")), str(r.get("status", ""))),
              str(r.get("updated", ""))[:19]]
             for r in self.journal.list_runs(limit=8)])

        events = []
        for w in ws:
            for entry in w.log[-8:]:
                events.append((entry["t"], w.name, entry["sev"], entry["msg"]))
        events.sort(reverse=True)
        self.events.set_rows(
            [[t, name, ("pill", "failed", msg[:80]) if sev == "error" else msg]
             for t, name, sev, msg in events[:30]])