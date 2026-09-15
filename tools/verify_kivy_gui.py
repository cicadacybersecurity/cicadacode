"""CICADA Kivy migration verifier:  python tools\\verify_kivy_gui.py

Proves the Phase 15 migration applied correctly, on the real machine:

  A. every new Kivy file exists; the Qt pages are gone; the backend is intact
  B. every gui module compiles
  C. Kivy imports (install gate)
  D. theme logic works (palette switch, colors, pills) - no GL needed
  E. the backend constructs cleanly (ConfigStore / CredentialStore /
     ProviderRegistry / OpenCode / WorkerMgr / Journal / TaskRunner)
  F. no Qt residue: nothing under gui/ imports PySide6 except the retired
     services/runner.py (which the Kivy app never imports)
  G. widget smoke: core components construct (SKIPs gracefully without GL)
  H. LAUNCH TEST: the real app opens a window and stays up

Prints [PASS]/[FAIL]/[SKIP] per check and a summary; exit code 1 on any
FAIL so it can gate scripts.
"""
import importlib
import os
import py_compile
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
sys.path.insert(0, ROOT)

RESULTS = []


def check(name):
    """Wrap a test so it records PASS/FAIL/SKIP exactly once, when RUN."""
    def deco(fn):
        def run():
            try:
                detail = fn() or ""
                RESULTS.append(("PASS", name, detail))
            except SkipTest as skip:
                RESULTS.append(("SKIP", name, str(skip)))
            except Exception as exc:
                RESULTS.append(("FAIL", name, str(exc)[:1500]))
        return run
    return deco


class SkipTest(Exception):
    pass


EXPECTED_FILES = [
    "gui\\__init__.py", "gui\\theme.py", "gui\\icons.py", "gui\\app.py",
    "gui\\main_window.py", "gui\\services\\bg.py",
    "gui\\components\\__init__.py", "gui\\components\\aero.py",
    "gui\\components\\aero_button.py", "gui\\components\\aero_panel.py",
    "gui\\components\\explorer_nav.py", "gui\\components\\aero_table.py",
    "gui\\components\\chrome.py", "gui\\components\\dialogs.py",
    "gui\\pages\\__init__.py", "gui\\pages\\dashboard.py",
    "gui\\pages\\workers.py", "gui\\pages\\tasks.py", "gui\\pages\\logs.py",
    "gui\\pages\\providers.py", "gui\\pages\\models.py",
    "gui\\pages\\settings.py", "gui\\pages\\diagnostics.py",
]

BACKEND_FILES = [
    "gui\\services\\config.py", "gui\\services\\credentials.py",
    "gui\\services\\journal.py", "gui\\services\\opencode.py",
    "gui\\services\\orchestrator.py", "gui\\services\\providers.py",
    "gui\\services\\workers.py", "gui\\services\\compiler.py",
]


@check("A. all Kivy files present; backend intact; Qt pages removed")
def _a():
    missing = [f for f in EXPECTED_FILES if not os.path.isfile(f)]
    if missing:
        raise AssertionError("missing: " + ", ".join(missing))
    missing_backend = [f for f in BACKEND_FILES if not os.path.isfile(f)]
    if missing_backend:
        raise AssertionError("BACKEND MISSING: " + ", ".join(missing_backend))
    if os.path.isdir("gui\\ui"):
        raise AssertionError("gui\\ui still exists (Qt pages not removed)")
    if not os.path.isfile("gui_legacy\\app.py"):
        raise SkipTest("gui_legacy\\app.py absent - the archived Qt GUI is optional; the Kivy GUI is primary")
    return str(len(EXPECTED_FILES)) + " kivy files, " + str(len(BACKEND_FILES)) + " backend files"


@check("B. every gui module compiles")
def _b():
    import glob
    bad = []
    for path in glob.glob("gui\\**\\*.py", recursive=True):
        try:
            py_compile.compile(path, doraise=True)
        except Exception as exc:
            bad.append(path + ": " + str(exc)[:120])
    if bad:
        raise AssertionError(" | ".join(bad))
    return "all gui/**.py compile"


@check("C. Kivy imports")
def _c():
    import kivy
    return "kivy " + kivy.__version__


@check("D. theme logic (palette, colors, day/night, pills)")
def _d():
    from gui import theme
    assert theme.hx("#ffffff") == (1.0, 1.0, 1.0, 1.0)
    assert theme.current_mode() == "aero_day"
    assert theme.pal()["content"] == "#ffffff"
    theme.set_mode("aero_night")
    assert theme.pal()["content"] != "#ffffff"
    fg, bg = theme.pill("failed")
    assert len(fg) == 4 and len(bg) == 4
    theme.set_mode("aero_day")
    return "day default + night switch + pill colors OK"


@check("E. backend constructs and loads (config/creds/providers/opencode/workers/journal/tasks)")
def _e():
    from gui.services.config import ConfigStore
    from gui.services.credentials import CredentialStore
    from gui.services.journal import Journal
    from gui.services.opencode import OpenCode
    from gui.services.orchestrator import TaskRunner
    from gui.services.providers import ProviderRegistry
    from gui.services.workers import WorkerMgr
    store = ConfigStore()
    cfg = store.load()
    for key in ("general", "workers", "opencode"):
        assert key in cfg, "config missing " + key
    creds = CredentialStore()
    registry = ProviderRegistry(creds, cfg)
    providers = registry.all()
    assert providers, "provider registry empty"
    oc = OpenCode(config_path=cfg["opencode"]["config_path"] or None,
                  exe_path=cfg["opencode"]["exe_path"] or None, creds=creds)
    mgr = WorkerMgr(oc, port_base=cfg["workers"]["port_base"])
    mgr.load()
    journal = Journal()
    journal.list_runs(limit=1)
    runner = TaskRunner(oc)
    assert runner.snapshot() is None or isinstance(runner.snapshot(), dict)
    return ("config OK, " + str(len(providers)) + " providers, " +
            str(len(mgr.workers)) + " workers known")


@check("F. no Qt residue in the Kivy layer")
def _f():
    import glob
    offenders = []
    for path in glob.glob("gui\\**\\*.py", recursive=True):
        if path.endswith("services\\runner.py"):
            continue  # the retired Qt helper; never imported by the Kivy app
        src = open(path, encoding="utf-8").read()
        if "PySide6" in src or "PyQt" in src:
            offenders.append(path)
        if "services.runner" in src or "services import runner" in src:
            offenders.append(path + " (imports Qt runner)")
    if offenders:
        raise AssertionError(" | ".join(offenders))
    return "zero PySide6/Qt imports outside retired runner.py"


@check("G. component construction (AeroButton/AeroGroup/AeroTable/ExplorerNav)")
def _g():
    try:
        from gui import theme as _t
        _t.register_fonts()
        from gui.components.aero_button import AeroButton
        from gui.components.aero_panel import AeroGroup, AeroHeader
        from gui.components.aero_table import AeroTable
        from gui.components.explorer_nav import ExplorerNav
        AeroButton("test")
        AeroGroup("test")
        AeroHeader("test", "sub")
        AeroTable(["a", "b"])
        ExplorerNav((("G", (("dashboard", "Dashboard"),)),), lambda k: None)
    except Exception:
        import traceback
        raise AssertionError(traceback.format_exc())
    return "all core components construct"


@check("G2. every gui module imports cleanly (names the exact failing file)")
def _g2():
    import glob
    import importlib
    import traceback
    mods = []
    for path in sorted(glob.glob("gui\\**\\*.py", recursive=True)):
        mod = path[:-3].replace("\\", ".")
        if mod.endswith(".__init__"):
            mod = mod[:-9]
        if mod.endswith("services.runner"):
            continue  # retired Qt helper, never imported by the Kivy app
        mods.append(mod)
    for mod in mods:
        print("       importing " + mod, flush=True)  # visible even on a native crash
        try:
            importlib.import_module(mod)
        except Exception:
            raise AssertionError(mod + " failed:\n" +
                                 traceback.format_exc()[-900:])
    return str(len(mods)) + " modules imported"


@check("H. LAUNCH TEST - the real app opens and stays up")
def _h():
    proc = subprocess.Popen([sys.executable, "gui\\app.py"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, cwd=ROOT)
    try:
        out, _ = proc.communicate(timeout=8)
        raise AssertionError("app exited during startup - FULL OUTPUT:\n" + (out or ""))
    except subprocess.TimeoutExpired:
        pass  # still running = the window opened and the loop is alive
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    return "window opened and stayed up (terminated cleanly after 8s)"


def main():
    print("CICADA Kivy migration verifier")
    print("=" * 60)
    for fn in (_a, _b, _c, _d, _e, _f, _g, _g2, _h):
        fn()
    for status, name, detail in RESULTS:
        line = "[" + status + "] " + name
        print(line)
        if detail:
            print("       " + detail.replace("\n", "\n       "))
    failed = sum(1 for r in RESULTS if r[0] == "FAIL")
    skipped = sum(1 for r in RESULTS if r[0] == "SKIP")
    passed = sum(1 for r in RESULTS if r[0] == "PASS")
    print("=" * 60)
    print(str(passed) + " passed, " + str(failed) + " failed, " +
          str(skipped) + " skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())