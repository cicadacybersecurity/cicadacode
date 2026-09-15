"""WorkerMgr - first-class worker registry, lifecycle, and task dispatch.

Worker identity is its opencode session (the rule the overseer converged on
in v4.8). Registry persists to state/workers.json so the overseer, the CLI,
and the GUI agree on who is who - no port/window-title archaeology.

Task dispatch mirrors manager/console.ps1: spawn
  opencode run <task> --attach http://127.0.0.1:<port> --dir <project>
      --agent <agent> -m <model> --pure --format json --title <name>
as a hidden subprocess; the JSONL stdout carries the sessionID, which is
captured back into the registry.
"""
import json
import os
import socket
import subprocess
import threading
import time
from dataclasses import asdict, dataclass, field

from .opencode import OpenCode, OpenCodeError, WorkerHttp

STATES = ("stopped", "starting", "idle", "running", "stopping", "failed", "unreachable")


def _root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@dataclass
class Worker:
    name: str
    project: str
    port: int = 0
    pid: int = 0
    session: str = ""
    model: str = ""
    agent: str = "build"
    state: str = "stopped"
    task: str = ""
    started_utc: str = ""
    last_activity_utc: str = ""
    error: str = ""
    log: list = field(default_factory=list)   # bounded ring buffer

    def remember(self, message: str, severity: str = "info") -> None:
        self.log.append({"t": time.strftime("%H:%M:%S"), "sev": severity, "msg": message})
        del self.log[:-500]  # bounded in-memory log


class WorkerMgr:
    def __init__(self, opencode: OpenCode | None = None, port_base: int = 4310,
                 state_path: str | None = None):
        self.oc = opencode or OpenCode()
        self.port_base = port_base
        self.state_path = state_path or os.path.join(_root(), "state", "workers.json")
        self.workers: dict[str, Worker] = {}
        self._task_procs: dict[str, object] = {}
        self._lock = threading.Lock()

    # -- ports ----------------------------------------------------------
    def free_port(self, index: int) -> int:
        port = self.port_base + index
        while port < self.port_base + 100:
            with socket.socket() as sock:
                if sock.connect_ex(("127.0.0.1", port)) != 0:
                    return port
            port += 1
        raise OpenCodeError("No free loopback port in the worker range.")

    # -- lifecycle ------------------------------------------------------
    def start(self, name: str, project: str, model: str = "",
              agent: str = "build") -> Worker:
        if not os.path.isdir(project):
            raise OpenCodeError(f"Project directory does not exist: {project}")
        worker = self.workers.get(name) or Worker(name=name, project=project)
        worker.project = project
        worker.state = "starting"
        worker.port = self.free_port(len(self.workers) + 1)
        proc = self.oc.serve(project, worker.port)
        worker.pid = proc.pid
        worker.model = model
        worker.agent = agent
        worker.started_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        deadline = time.monotonic() + 10
        http = WorkerHttp(worker.port)
        while time.monotonic() < deadline:
            if http.healthy():
                worker.state = "idle"
                worker.error = ""
                break
            if proc.poll() is not None:
                worker.state = "failed"
                worker.error = "opencode serve exited during startup"
                break
            time.sleep(0.25)
        else:
            worker.state = "failed"
            worker.error = "health check timed out after 10s"
            try:
                proc.kill()
            except OSError:
                pass
        worker.remember(f"start -> {worker.state}",
                        "info" if worker.state == "idle" else "error")
        self.workers[name] = worker
        self.save()
        return worker

    def stop(self, name: str) -> Worker:
        worker = self.workers[name]
        worker.state = "stopping"
        self._kill_task_proc(name)
        try:
            os.kill(worker.pid, 9)
        except OSError:
            pass
        worker.state = "stopped"
        worker.remember("stopped")
        self.save()
        return worker

    def restart(self, name: str) -> Worker:
        worker = self.workers[name]
        self.stop(name)
        return self.start(name, worker.project, worker.model, worker.agent)

    def kill(self, name: str) -> Worker:
        """Force stop: kill task process and server, keep registry entry."""
        worker = self.workers[name]
        self._kill_task_proc(name)
        try:
            os.kill(worker.pid, 9)
        except OSError:
            pass
        worker.state = "stopped"
        worker.remember("killed (force)", "warn")
        self.save()
        return worker

    def remove(self, name: str) -> None:
        if name in self.workers:
            self.kill(name)
            del self.workers[name]
            self.save()

    def health(self, name: str) -> str:
        worker = self.workers[name]
        if worker.state in ("stopped", "failed"):
            return worker.state
        ok = WorkerHttp(worker.port, timeout=2).healthy()
        if not ok and worker.state != "unreachable":
            worker.state = "unreachable"
            worker.remember("health poll failed", "error")
            self.save()
        elif ok and worker.state == "unreachable":
            worker.state = "idle"
            worker.remember("recovered")
            self.save()
        return worker.state

    def health_all(self) -> dict:
        return {n: self.health(n) for n in list(self.workers)}

    def sweep_orphans(self) -> int:
        """On startup: workers whose process died while the GUI was closed."""
        swept = 0
        for name, worker in list(self.workers.items()):
            if worker.state in ("stopped", "failed"):
                continue
            alive = False
            if worker.pid:
                try:
                    os.kill(worker.pid, 0)
                    alive = True
                except OSError:
                    alive = False
            if not alive or not WorkerHttp(worker.port, timeout=2).healthy():
                worker.state = "failed"
                worker.error = "process not found at GUI startup (orphan swept)"
                worker.remember("orphan swept at startup", "warn")
                swept += 1
        if swept:
            self.save()
        return swept

    # -- tasks ----------------------------------------------------------
    def is_busy(self, name: str) -> bool:
        proc = self._task_procs.get(name)
        return proc is not None and proc.poll() is None

    def send_task(self, name: str, text: str) -> None:
        worker = self.workers[name]
        if worker.state not in ("idle", "running"):
            raise OpenCodeError(f"{name} is {worker.state} - start it first.")
        if self.is_busy(name):
            raise OpenCodeError(f"{name} is busy - wait or Abort the current task.")
        flat = " ".join(text.replace("\r", " ").replace("\n", " ").split())
        if not flat:
            raise OpenCodeError("Task text is empty.")
        url = f"http://127.0.0.1:{worker.port}"
        args = self.oc.run_args(flat, worker.project, model=worker.model or None,
                                agent=worker.agent or None)
        args += ["--attach", url, "--title", worker.name]
        if worker.session:
            args += ["--session", worker.session]
        log_dir = os.path.join(_root(), "state", "logs")
        os.makedirs(log_dir, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        log_path = os.path.join(log_dir, f"{name}-{stamp}.jsonl")
        log_fh = open(log_path, "a", encoding="utf-8")
        creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        proc = subprocess.Popen(args, cwd=worker.project, env=self.oc._env(),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, creationflags=creation)
        self._task_procs[name] = proc
        worker.task = flat
        worker.state = "running"
        worker.last_activity_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        worker.remember(f"task sent: {flat[:80]}")
        self.save()
        threading.Thread(target=self._watch_task,
                         args=(name, proc, log_fh), daemon=True).start()

    def _watch_task(self, name: str, proc, log_fh) -> None:
        worker = self.workers.get(name)
        try:
            for line in proc.stdout:
                log_fh.write(line)
                log_fh.flush()
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                sid = ev.get("sessionID")
                if worker and sid and not worker.session:
                    worker.session = sid
                    worker.remember(f"session captured: {sid}")
                    self.save()
            proc.wait()
        finally:
            log_fh.close()
            if worker:
                worker.state = "idle" if WorkerHttp(worker.port).healthy() else "unreachable"
                worker.last_activity_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                worker.remember(f"task finished (exit {proc.returncode})")
                self.save()
            with self._lock:
                self._task_procs.pop(name, None)

    def abort_task(self, name: str) -> None:
        worker = self.workers[name]
        if worker.session:
            WorkerHttp(worker.port, timeout=10).abort(worker.session)
            worker.remember("abort sent", "warn")
        self._kill_task_proc(name)
        worker.state = "idle"
        self.save()

    def _kill_task_proc(self, name: str) -> None:
        with self._lock:
            proc = self._task_procs.pop(name, None)
        if proc is not None and proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass

    def messages(self, name: str) -> list:
        worker = self.workers[name]
        if not worker.session:
            return []
        try:
            return WorkerHttp(worker.port, timeout=5).messages(worker.session)
        except OpenCodeError:
            return []

    # -- persistence ----------------------------------------------------
    def save(self) -> None:
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        data = {n: asdict(w) for n, w in self.workers.items()}
        tmp = self.state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
        os.replace(tmp, self.state_path)

    def load(self) -> None:
        try:
            with open(self.state_path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            self.workers = {n: Worker(**w) for n, w in data.items()}
        except (FileNotFoundError, json.JSONDecodeError, TypeError):
            self.workers = {}