"""CICADA Kivy main window - coherent shell owning the entire client area.

Hierarchy:
  native OS window (Windows owns caption, min/max/close, drag)
  -> MainWindow (FloatLayout, fills the window)
     -> environment artwork painted on canvas.before (finished PNG assets
        when installed; procedural Frutiger scene as fallback)
     -> root column (fills the client area - NO floating frame, NO margin):
          body:  ExplorerNav | ContentPane(current page)
          StatusBar (live status + Day/Night toggle)

Backend services, wiring and page constructors are unchanged.
"""
from kivy.clock import Clock
from kivy.graphics import Color, Ellipse, Line, Rectangle
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.floatlayout import FloatLayout

from . import theme
from .components.aero import L, paint_bg, paint_border, repaint_walk
from .components.aero_button import AeroButton
from .components.background import BackgroundArt
from .components.chrome import StatusBar
from .components.explorer_nav import ExplorerNav
from .pages.dashboard import DashboardPage
from .pages.diagnostics import DiagnosticsPage
from .pages.logs import LogsPage
from .pages.models import ModelsPage
from .pages.providers import ProvidersPage
from .pages.settings import SettingsPage
from .pages.tasks import TasksPage
from .pages.workers import WorkersPage
from .services import compiler
from .services.config import ConfigStore
from .services.credentials import CredentialStore
from .services.journal import Journal
from .services.opencode import OpenCode, OpenCodeError
from .services.orchestrator import TaskRunner
from .services.providers import ProviderRegistry
from .services.workers import WorkerMgr

NAV = (("Dashboard", "dashboard"), ("Workers", "workers"), ("Tasks", "tasks"),
       ("Logs", "logs"), ("Providers", "providers"), ("Models", "models"),
       ("Settings", "settings"), ("Diagnostics", "diagnostics"))

def _groups():
    return (
        ("Fleet", (("dashboard", "Dashboard"), ("workers", "Workers"),
                   ("tasks", "Tasks"), ("logs", "Logs"))),
        ("Configure", (("providers", "Providers"), ("models", "Models"),
                       ("settings", "Settings"))),
        ("System", (("diagnostics", "Diagnostics"),)),
    )

class ContentPane(BoxLayout):
    """White page area filling the client space right of the nav pane -
    part of the window itself, separated by a single hairline."""

    def __init__(self, **kwargs):
        kwargs.setdefault("orientation", "vertical")
        super().__init__(**kwargs)
        self.bind(pos=self.repaint, size=self.repaint)
        self.repaint()

    def repaint(self, *_a):
        paint_bg(self, color=theme.c("content", 242))
        paint_border(self, None)
        from kivy.graphics import Color, Rectangle
        self.canvas.after.clear()
        with self.canvas.after:
            Color(*theme.c("border"))
            Rectangle(pos=(self.x, self.y), size=(1, self.height))

class MainWindow(FloatLayout):
    NAV = NAV

    def __init__(self, **kwargs):
        super().__init__(**kwargs)

        # services (unchanged)
        self.config_store = ConfigStore()
        self.config = self.config_store.load()
        self.creds = CredentialStore()
        self.registry = ProviderRegistry(self.creds, self.config)
        self.opencode = OpenCode(
            config_path=self.config["opencode"]["config_path"] or None,
            exe_path=self.config["opencode"]["exe_path"] or None,
            creds=self.creds)
        self.workers = WorkerMgr(self.opencode,
                                 port_base=self.config["workers"]["port_base"])
        self.workers.load()
        swept = self.workers.sweep_orphans()
        self.journal = Journal()
        self.journal.mark_interrupted()
        self.runner = TaskRunner(self.opencode)

        # environment: finished artwork assets when installed (cover-fit,
        # aspect-selected); the procedural scene remains as fallback
        self._bg = BackgroundArt()
        self.bind(size=self._paint_environment, pos=self._paint_environment)

        # the shell owns the ENTIRE client area: no outer margin, no frame
        root_col = BoxLayout(orientation="vertical", spacing=0)
        body = BoxLayout(orientation="horizontal", spacing=0)
        self.nav = ExplorerNav(_groups(), self._nav_selected)
        body.add_widget(self.nav)
        self._content = ContentPane()
        body.add_widget(self._content)
        root_col.add_widget(body)

        # status bar: live fleet/opencode status + the Day/Night toggle
        self.status_left = L("", size=theme.FS_DIM, color="text_dim")
        self.status_right = L("", size=theme.FS_DIM, color="text_dim",
                              size_hint_x=None, width=320, align="right")
        status = StatusBar()
        status.add_widget(self.status_left)
        status.add_widget(self.status_right)
        self.btn_mode = AeroButton(self.mode_label(), on_press_fn=self.toggle_mode)
        self.btn_mode.size_hint_x = None
        self.btn_mode.width = 84
        self.btn_mode.height = 26
        status.add_widget(self.btn_mode)
        root_col.add_widget(status)
        self.add_widget(root_col)

        # pages (unchanged wiring)
        self.pages = {
            "dashboard": DashboardPage(self.workers, self.journal, self.registry,
                                       self.opencode, self.config),
            "workers": WorkersPage(self.workers, self.config),
            "tasks": TasksPage(self.runner, self.config),
            "logs": LogsPage(self.workers, self.config),
            "providers": ProvidersPage(self.registry, self.config,
                                       self.apply_provider_changes),
            "models": ModelsPage(self.registry, self.config,
                                 self.apply_provider_changes),
            "settings": SettingsPage(self.config_store, self.config, self.creds,
                                     self.apply_settings),
            "diagnostics": DiagnosticsPage(self.opencode, self.registry,
                                           self.workers, self.config),
        }
        self._current = None
        self.goto("dashboard")

        if swept:
            self.status_left.text = ("Swept " + str(swept) +
                                     " orphaned worker(s) from the last session.")
        self._health = Clock.schedule_interval(
            lambda _dt: self._tick(),
            int(self.config["general"]["refresh_interval_sec"]))
        Clock.schedule_once(lambda _dt: self._paint_environment(), 0)
        self._tick()

    # ---------------------------------------------------------- environment
    def _paint_environment(self, *_a):
        self.canvas.before.clear()
        w, h = max(self.width, 1), max(self.height, 1)
        x, y = self.pos
        # finished artwork when installed: aspect-family selected (16:9 vs
        # 16:10 by threshold), COVER-fit - scaled until the window is fully
        # covered, excess cropped by the edges, never stretched; textures
        # are cached and only re-picked on resize/theme events
        tex = self._bg.texture(self._bg.family(w, h))
        if tex is not None:
            tw, th = self._bg.cover(tex, w, h)
            with self.canvas.before:
                Color(1, 1, 1, 1)
                Rectangle(pos=(x - (tw - w) / 2.0, y - (th - h) / 2.0),
                          size=(tw, th), texture=tex)
            return
        # procedural fallback scene (until the artwork PNGs are installed)
        with self.canvas.before:
            Color(1, 1, 1, 1)
            Rectangle(pos=(x, y), size=(w, h),
                      texture=theme.vgrad3("sky_top", "sky_mid", "sky_bot"))
            Rectangle(pos=(x, y + h - h * 0.55), size=(w * 0.5, h * 0.55),
                      texture=theme.radial("sun", 130))
            if theme.current_mode() == "aero_day":
                for cx, cy, cw, ch, a in (
                        (0.30, 0.88, 0.34, 0.10, 120), (0.62, 0.94, 0.40, 0.11, 105),
                        (0.12, 0.78, 0.26, 0.09, 90), (0.86, 0.84, 0.24, 0.08, 85)):
                    Rectangle(pos=(x + w * (cx - cw / 2), y + h * (cy - ch / 2)),
                              size=(w * cw, h * ch),
                              texture=theme.radial("cloud", a))
                Color(1, 1, 1, 1)
                Rectangle(pos=(x, y), size=(w, h * 0.16),
                          texture=theme.radial("meadow", 46))
            else:
                import random as _r
                rng = _r.Random(2007)
                Color(*theme.c("cloud", 170))
                for _i in range(38):
                    sx, sy = rng.random(), rng.random() * 0.5 + 0.45
                    r = rng.choice((1, 1, 2))
                    Ellipse(pos=(x + w * sx, y + h * sy), size=(r, r))
            for bx, by, r in ((0.07, 0.22, 40), (0.93, 0.68, 48),
                              (0.50, 0.95, 24), (0.86, 0.12, 30)):
                Color(1, 1, 1, 1)
                Rectangle(pos=(x + w * bx - r, y + h * by - r),
                          size=(r * 2, r * 2), texture=theme.radial("cloud", 55))
                Color(*theme.c("glass_line", 90))
                Line(circle=(x + w * bx, y + h * by, r), width=1.3)

    # ---------------------------------------------------------- navigation
    def goto(self, key):
        """Swap the visible page with lifecycle awareness: the outgoing page
        stops polling, the incoming page refreshes and starts polling."""
        page = self.pages[key]
        if self._current is page:
            self.nav.select(key)
            return
        if self._current is not None:
            self._current.on_deactivate()
            self._content.remove_widget(self._current)
        self._content.add_widget(page)
        self._current = page
        self.nav.select(key)
        page.on_activate()

    def _nav_selected(self, key):
        self.goto(key)

    def refresh_current(self):
        refresh = getattr(self._current, "refresh", None)
        if callable(refresh):
            refresh()
        rw = getattr(self._current, "refresh_workers", None)
        if callable(rw):
            rw()

    def refresh_all(self):
        for page in self.pages.values():
            refresh = getattr(page, "refresh", None)
            if callable(refresh):
                refresh()
        self.pages["logs"].refresh_workers()

    # ---------------------------------------------------------- day / night
    def mode_label(self):
        return "Night" if theme.current_mode() == "aero_day" else "Day"

    def toggle_mode(self):
        mode = "aero_day" if theme.current_mode() == "aero_night" else "aero_night"
        theme.set_mode(mode)  # notifies every themed stock widget + label
        theme.clear_cache()
        self.config["general"]["theme"] = mode
        self.config_store.save(self.config)
        self.btn_mode.label.text = self.mode_label()
        self._paint_environment()
        repaint_walk(self)
        for page in self.pages.values():
            repaint_walk(page)
        self._tick()

    # ---------------------------------------------------------- callbacks
    def apply_provider_changes(self):
        self.config["providers"] = self.registry.records()
        self.config_store.save(self.config)
        compiler.write_config(self.registry, self.config)

    def apply_settings(self):
        self._health.cancel()
        self._health = Clock.schedule_interval(
            lambda _dt: self._tick(),
            int(self.config["general"]["refresh_interval_sec"]))
        self.opencode = OpenCode(
            config_path=self.config["opencode"]["config_path"] or None,
            exe_path=self.config["opencode"]["exe_path"] or None,
            creds=self.creds)
        self.workers.oc = self.opencode
        self.runner.oc = self.opencode
        self.pages["diagnostics"].opencode = self.opencode
        self._tick()

    def _tick(self):
        try:
            oc = "opencode " + self.opencode.version()
        except OpenCodeError:
            oc = "opencode not found"
        running = sum(1 for w in self.workers.workers.values()
                      if w.state in ("idle", "running"))
        failed = sum(1 for w in self.workers.workers.values()
                     if w.state in ("failed", "unreachable"))
        self.status_right.text = oc + "   |   " + str(running) + " up / " + str(failed) + " failed"
        run_txt = "   |   run: " + self.runner.run["status"] if self.runner.run else ""
        self.status_left.text = ("workers: " + str(running) + " up / " +
                                 str(failed) + " failed" + run_txt +
                                 "   |   default model: " +
                                 str(self.config["default_model"]))