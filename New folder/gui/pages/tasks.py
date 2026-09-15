"""Tasks page - autonomous runs on the common Page frame.

Same runner, same 1s snapshot polling, same start/cancel semantics; polling
runs only while the page is visible. Tasks table and run events share the
content column proportionally.
"""
from kivy.clock import Clock
from kivy.uix.boxlayout import BoxLayout

from .. import theme
from ..components import dialogs
from ..components.aero import L, TInput
from ..components.aero_button import AeroButton
from ..components.aero_panel import AeroGroup, Page
from ..components.aero_table import AeroTable

TASK_COLS = ["#", "Task", "Status", "Attempts", "Verdict"]
TASK_WEIGHTS = [0.4, 3, 1, 0.8, 2]


class TasksPage(Page):
    def __init__(self, runner, config, **kwargs):
        super().__init__("Tasks",
                         "Autonomous run - plan, build, validate, review",
                         **kwargs)
        self.runner = runner
        self.config = config
        self._timer = None
        self._last_events = 0

        setup = AeroGroup("Run setup")  # auto-fit: fixed-height rows
        seats = self.config.get("seats", {})
        setup.content.add_widget(L(
            "planner: " + seats.get("planner", "?") +
            "    reviewer: " + seats.get("reviewer", "?") +
            "    builder: " + seats.get("builder", "?"),
            size=theme.FS_DIM, color="text_faint", size_hint_y=None, height=18))

        row = BoxLayout(size_hint_y=None, height=theme.H_FIELD, spacing=6)
        self.in_project = TInput(placeholder="project directory")
        row.add_widget(self.in_project)
        row.add_widget(AeroButton("Browse...", on_press_fn=self._browse,
                                  size_hint_x=None, width=80))
        setup.content.add_widget(row)

        self.in_objective = TInput(
            placeholder="Objective, e.g. 'add a -Since filter to report.ps1 and extend its tests'",
            multiline=True)
        self.in_objective.size_hint_y = None
        self.in_objective.height = 64
        setup.content.add_widget(self.in_objective)
        self.content.add_widget(setup)

        tasks_grp = AeroGroup("Tasks", weight=2)
        self.tasks = AeroTable(TASK_COLS, weights=TASK_WEIGHTS,
                               empty_text="No tasks yet - start a run")
        tasks_grp.content.add_widget(self.tasks)
        self.content.add_widget(tasks_grp)

        ev_grp = AeroGroup("Run events", weight=3)
        self.events = TInput(readonly=True, multiline=True, mono=True)
        ev_grp.content.add_widget(self.events)
        self.content.add_widget(ev_grp)

        bar = self.make_actions()
        self.btn_start = AeroButton("Plan + Build", accent=True,
                                    on_press_fn=self._start,
                                    size_hint_x=None, width=120)
        self.btn_cancel = AeroButton("Cancel run", on_press_fn=self._cancel,
                                     size_hint_x=None, width=104)
        self.btn_cancel.disabled = True
        bar.add_widget(self.btn_start)
        bar.add_widget(self.btn_cancel)
        bar.add_widget(BoxLayout())
        self.status = L("", size=theme.FS_DIM, color="text_faint",
                        size_hint_x=None, width=300)
        bar.add_widget(self.status)

    # -- lifecycle ------------------------------------------------------------
    def on_activate(self):
        self.refresh()
        if self._timer is None:
            self._timer = Clock.schedule_interval(lambda _dt: self.refresh(), 1)

    def on_deactivate(self):
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None

    # -- actions ------------------------------------------------------------------
    def _browse(self):
        dialogs.prompt("Project directory", "Path to the project directory:",
                       lambda text: setattr(self.in_project, "text", text))

    def _start(self):
        project = self.in_project.text.strip()
        objective = self.in_objective.text.strip()
        seats = self.config.get("seats", {})
        try:
            self.runner.start(
                project, objective,
                plan_model=seats.get("planner", ""),
                review_model=seats.get("reviewer", ""),
                builder_model=seats.get("builder", ""))
        except RuntimeError as exc:
            self._say(str(exc), "err")
            return
        self._last_events = 0
        self.events.text = ""
        self._say("run started", "warn")
        self.btn_start.disabled = True
        self.btn_cancel.disabled = False
        self.btn_start.repaint()
        self.btn_cancel.repaint()

    def _cancel(self):
        self.runner.cancel()
        self._say("cancel requested...", "warn")

    def _say(self, text, color="text_faint"):
        self.status.text = text
        self.status.color = theme.c(color)

    def refresh(self):
        snap = self.runner.snapshot()
        if snap is None:
            return
        self.tasks.set_rows(
            [[str(t.get("n", "")), t.get("title", ""),
              ("pill", t.get("status", "pending"), t.get("status", "")),
              str(t.get("attempts", "")), (t.get("verdict", "") or "")[:60]]
             for t in snap.get("tasks", [])])

        events = snap.get("events", [])
        if len(events) > self._last_events:
            for ev in events[self._last_events:]:
                line = ev.get("t", "") + "  " + ev.get("type", "")
                if ev.get("data"):
                    line += "  -  " + str(ev["data"])[:200]
                self.events.text += line + "\n"
            self._last_events = len(events)

        status = snap.get("status", "")
        if status != "running" and not self.btn_cancel.disabled:
            self.btn_start.disabled = False
            self.btn_cancel.disabled = True
            self.btn_start.repaint()
            self.btn_cancel.repaint()
            self._say("run " + status, "ok" if status == "done" else "err")