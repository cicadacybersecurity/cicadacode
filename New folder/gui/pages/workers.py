"""Workers page - management console on the common Page frame.

Same lifecycle: add+start, stop, restart, kill (confirm), send task
(prompt), abort, refresh, timed health polls - the health poll runs only
while the page is visible. All blocking work goes through
services.bg.run_async; the table re-renders from results.
"""
from kivy.clock import Clock
from kivy.uix.boxlayout import BoxLayout

from .. import theme
from ..components import dialogs
from ..components.aero import L, TInput, TSpinner
from ..components.aero_button import AeroButton
from ..components.aero_panel import AeroGroup, Page
from ..components.aero_table import AeroTable
from ..services.bg import run_async

COLUMNS = ["Name", "State", "Port", "PID", "Model", "Agent", "Task", "Error"]
WEIGHTS = [2, 1, 1, 1, 2, 1, 3, 2]


class WorkersPage(Page):
    def __init__(self, worker_mgr, config, **kwargs):
        super().__init__("Workers", "Manage active agent workers", **kwargs)
        self.mgr = worker_mgr
        self.config = config
        self._timer = None

        grp = AeroGroup("New worker")  # auto-fit: fixed-height form rows
        form = BoxLayout(size_hint_y=None, height=theme.H_FIELD, spacing=6)
        self.in_name = TInput(placeholder="worker name (e.g. contentgen)",
                              size_hint_x=None, width=180)
        self.in_project = TInput(placeholder="project directory")
        seats = self.config.get("seats", {})
        models = sorted(m for m in {self.config.get("default_model", ""),
                                    seats.get("planner", ""),
                                    seats.get("reviewer", ""),
                                    seats.get("builder", "")} if m)
        self.in_model = TSpinner(models, size_hint_x=None, width=220)
        self.in_agent = TSpinner(["build", "plan", "review"],
                                 size_hint_x=None, width=100)
        browse = AeroButton("Browse...", on_press_fn=self._browse,
                            size_hint_x=None, width=80)
        add = AeroButton("Add + Start", accent=True, on_press_fn=self._add_start,
                         size_hint_x=None, width=110)
        for w in (self.in_name, self.in_project, browse, self.in_model,
                  self.in_agent, add):
            form.add_widget(w)
        grp.content.add_widget(form)
        self.content.add_widget(grp)

        table_grp = AeroGroup("Registered workers", weight=1)
        self.table = AeroTable(COLUMNS, weights=WEIGHTS,
                               empty_text="No workers registered")
        table_grp.content.add_widget(self.table)
        self.content.add_widget(table_grp)

        bar = self.make_actions()
        for label, fn in (("Stop", self._stop), ("Restart", self._restart),
                          ("Kill", self._kill), ("Send task...", self._send),
                          ("Abort task", self._abort), ("Refresh", self.refresh)):
            bar.add_widget(AeroButton(label, on_press_fn=fn,
                                      size_hint_x=None, width=92))
        bar.add_widget(BoxLayout())
        self.status = L("", size=theme.FS_DIM, color="text_faint",
                        size_hint_x=None, width=300)
        bar.add_widget(self.status)

    # -- lifecycle ------------------------------------------------------------
    def on_activate(self):
        self.refresh()
        if self._timer is None:
            self._timer = Clock.schedule_interval(
                lambda _dt: self._health_tick(),
                int(self.config["general"]["refresh_interval_sec"]))

    def on_deactivate(self):
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None

    # -- helpers ----------------------------------------------------------------
    def _selected(self):
        row = self.table.selected_row()
        if row is None:
            self._say("Select a worker row first.")
            return None
        return row[0]

    def _say(self, text, color="text_faint"):
        self.status.text = text
        self.status.color = theme.c(color)

    def _browse(self):
        dialogs.prompt("Project directory", "Path to the project directory:",
                       lambda text: setattr(self.in_project, "text", text))

    # -- actions ------------------------------------------------------------------
    def _add_start(self):
        name = self.in_name.text.strip()
        project = self.in_project.text.strip()
        if not name or not project:
            self._say("Name and project directory are required.", "err")
            return
        model = self.in_model.text.strip()
        agent = self.in_agent.text
        self._say("starting " + name + "...", "warn")
        run_async(lambda: self.mgr.start(name, project, model, agent),
                  on_done=lambda w: (self._say(
                      name + ": " + w.state + (" - " + w.error if w.error else ""),
                      "ok" if w.state == "idle" else "err"), self.refresh()),
                  on_failed=lambda e: self._say(e, "err"))

    def _stop(self):
        name = self._selected()
        if name:
            run_async(lambda: self.mgr.stop(name),
                      on_done=lambda w: (self._say(name + " stopped"),
                                         self.refresh()),
                      on_failed=lambda e: self._say(e, "err"))

    def _restart(self):
        name = self._selected()
        if name:
            self._say("restarting " + name + "...", "warn")
            run_async(lambda: self.mgr.restart(name),
                      on_done=lambda w: (self._say(name + ": " + w.state),
                                         self.refresh()),
                      on_failed=lambda e: self._say(e, "err"))

    def _kill(self):
        name = self._selected()
        if not name:
            return

        def go():
            run_async(lambda: self.mgr.kill(name),
                      on_done=lambda w: (self._say(name + " killed", "warn"),
                                         self.refresh()),
                      on_failed=lambda e: self._say(e, "err"))

        dialogs.confirm("Kill worker",
                        "Force kill '" + name + "'? Unsaved agent work is lost.",
                        go)

    def _send(self):
        name = self._selected()
        if not name:
            return

        def send(text):
            if not text.strip():
                return
            run_async(lambda: self.mgr.send_task(name, text),
                      on_done=lambda _r: (self._say("task sent to " + name, "ok"),
                                          self.refresh()),
                      on_failed=lambda e: self._say(e, "err"))

        dialogs.prompt("Task for " + name, "Task prompt:", send, multiline=True)

    def _abort(self):
        name = self._selected()
        if name:
            run_async(lambda: self.mgr.abort_task(name),
                      on_done=lambda _r: (self._say("abort sent to " + name,
                                                    "warn"), self.refresh()),
                      on_failed=lambda e: self._say(e, "err"))

    def _health_tick(self):
        if not self.mgr.workers:
            return
        run_async(lambda: self.mgr.health_all(), on_done=lambda _r: self.refresh())

    def refresh(self):
        self.table.set_rows(
            [[w.name, ("pill", w.state, w.state), str(w.port), str(w.pid),
              w.model, w.agent, (w.task or "")[:60], (w.error or "")[:60]]
             for w in self.mgr.workers.values()])