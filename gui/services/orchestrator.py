"""TaskRunner - autonomous plan -> build -> validate -> review loop.

Port of manager/orchestrator.ps1 to a GUI-drivable service. Calls opencode
directly (opencode run --pure --format json); no worker fleet required.
Journals runs to state/runs/<id>.json in the existing CLI format, so both
dashboard.ps1 and the GUI Dashboard see the same runs.
"""
import json
import os
import re
import subprocess
import threading
import time

from .opencode import OpenCode

MAX_TASKS = 8

PLAN_PROMPT = """You are the planning engine of an autonomous coding system.

Project directory: {project}
Objective: {objective}

Break the objective into a small number of concrete, independently implementable tasks, ordered so earlier tasks unblock later ones.

Respond with ONLY a JSON array. Each element is an object:
{{"title":"short imperative task","files":["likely","paths"],"validate":"single command that proves the task works","risk":"low"}}

Rules:
- Each task must be completable by one coding agent in one focused session.
- "validate": exactly ONE Windows PowerShell command, runnable from the project root, that exits 0 on success and non-zero on failure. Single line only - never chain commands with semicolons or &&. Empty string if no mechanical check exists.
- "risk": "high" for auth/security, secrets, destructive operations, concurrency, database migrations, public API changes, anything needing network or credentials. Everything else is "low".
- CAPABILITY ENVELOPE: builders have ONLY read, edit, bash, glob, grep, list, lsp tools. There is NO network, NO web access, NO credentials, NO user to answer questions. If the objective needs a capability outside this envelope, respond BLOCKED: <missing capability> instead of a JSON array.
- Granularity: if the objective names N distinct deliverables, emit exactly N tasks (or more, never fewer). One task only for a single deliverable. Cap at 8 tasks.
- No prose. No markdown fences. JSON only.

If the objective is too unclear to plan, respond with: BLOCKED: <reason>
"""

BUILD_PROMPT = """You are the builder in an autonomous coding system. You work alone in the project directory.

Project: {project}
Overall objective: {objective}
Assigned task: {title}
Likely files: {files}
A suitable validation command is probably: {validate}
{retry}
Rules:
- Inspect before editing; start from the likely files. Make the smallest correct change. Follow existing conventions. Do not modify unrelated files.
- If the task involves parsing existing files, inspect a real sample first; never invent the input format.
- Implement the task fully, then run the narrowest relevant validation and fix failures you caused.
- Do not stop at analysis or proposals: make the real changes.
- Honesty: if you cannot obtain a real result, end with STATUS: BLOCKED and name what is missing. Never fabricate content or results.

End your final message with EXACTLY this structure, one per line:
STATUS: COMPLETE
VALIDATION: <the single command you ran; empty if none>
RESULT: <one line: pass/fail + key output>
FILES: <comma-separated files you changed>

Or, if you cannot proceed:
STATUS: BLOCKED: <one-line reason>
"""

REVIEW_PROMPT = """You are the reviewer in an autonomous coding system.

Project: {project}
Objective: {objective}
Task: {title}
Attempt: {attempt}

Builder's final report:
---
{report}
---

Independent validation evidence gathered by the orchestrator:
{evidence}

You have read and bash tools - use them. Do not trust the report: open the files it claims changed and re-run the validation command yourself before deciding.

Decide the next action. Reply with exactly one verdict line:
NEXT                  - task genuinely complete and validated
RETRY: <what to fix>  - concrete problems; builder must retry
BLOCKED: <reason>     - human input required
"""

# The validation gate runs shell commands with the user's privileges, so
# destructive or network commands are refused outright (same rule the
# apply-hardening.ps1 patch added to the PS orchestrator).
DENY = re.compile(
    r"(?i)\b(remove-item|del|erase|rd|rmdir|format|stop-process|stop-computer|"
    r"restart-computer|shutdown|iex|invoke-expression|invoke-webrequest|iwr|"
    r"curl|wget|start-process|set-executionpolicy|reg\s+add|reg\s+delete)\b")


def _root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class TaskRunner:
    def __init__(self, opencode: "OpenCode | None" = None):
        self.oc = opencode or OpenCode()
        self.run = None
        self._thread = None
        self._cancel = threading.Event()
        self._lock = threading.Lock()

    # ------------------------------------------------------------------ API
    def start(self, project: str, objective: str, plan_model: str,
              review_model: str, builder_model: str, max_retries: int = 2) -> None:
        if self._thread and self._thread.is_alive():
            raise RuntimeError("A run is already in progress.")
        if not os.path.isdir(project):
            raise RuntimeError("Project directory does not exist: " + project)
        if not objective.strip():
            raise RuntimeError("Objective is required.")
        self._cancel.clear()
        run_id = "run_" + time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        self.run = {
            "id": run_id,
            "mode": "gui-unsupervised",
            "project": os.path.abspath(project),
            "objective": objective.strip(),
            "status": "running",
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "tasks": [],
            "events": [],
            "models": {"plan": plan_model, "review": review_model,
                       "builder": builder_model},
            "max_retries": max_retries,
        }
        self._event("run_started", objective.strip())
        self._save()
        self._thread = threading.Thread(target=self._execute, daemon=True)
        self._thread.start()

    def cancel(self) -> None:
        self._cancel.set()
        self._event("cancel_requested", "")

    def running(self) -> bool:
        return bool(self._thread and self._thread.is_alive())

    def snapshot(self):
        with self._lock:
            if self.run is None:
                return None
            return json.loads(json.dumps(self.run))

    # -------------------------------------------------------------- internals
    def _event(self, type_: str, data: str) -> None:
        with self._lock:
            if self.run is None:
                return
            self.run["events"].append({
                "t": time.strftime("%H:%M:%S"), "type": type_, "data": data})
            self.run["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self._save()

    def _save(self) -> None:
        with self._lock:
            if self.run is None:
                return
            run_dir = os.path.join(_root(), "state", "runs")
            os.makedirs(run_dir, exist_ok=True)
            path = os.path.join(run_dir, self.run["id"] + ".json")
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self.run, fh, indent=2)
            os.replace(tmp, path)

    def _finish(self, status: str, note: str = "") -> None:
        with self._lock:
            if self.run is not None:
                self.run["status"] = status
        self._event("run_" + status, note)

    def _call_agent(self, prompt: str, model: str, agent: str):
        """Returns (text, exit_code). Runs opencode headless, JSONL parsed."""
        project = self.run["project"]
        args = self.oc.run_args(prompt, project, model=model, agent=agent)
        log_dir = os.path.join(_root(), "state", "logs")
        os.makedirs(log_dir, exist_ok=True)
        log_path = os.path.join(
            log_dir, self.run["id"] + "-" + agent + "-" +
            time.strftime("%H%M%S", time.gmtime()) + ".jsonl")
        creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        proc = subprocess.Popen(args, cwd=project, env=self.oc._env(),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, creationflags=creation)
        texts = []
        with open(log_path, "a", encoding="utf-8") as log_fh:
            for line in proc.stdout:
                log_fh.write(line)
                if self._cancel.is_set():
                    proc.kill()
                    break
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if ev.get("type") == "text":
                    part = ev.get("part") or {}
                    if part.get("text"):
                        texts.append(part["text"])
        proc.wait()
        raw = "".join(texts)
        text = re.sub(r"(?s)<think>.*?</think>", "", raw).strip()
        return text, proc.returncode

    @staticmethod
    def _parse_plan(text: str):
        m = re.search(r"\[.*\]", text, re.S)
        if not m:
            return None
        try:
            plan = json.loads(m.group(0))
        except json.JSONDecodeError:
            return None
        if not isinstance(plan, list):
            return None
        return [t for t in plan if isinstance(t, dict) and t.get("title")]

    def _validate(self, cmd: str):
        """Returns (ok, evidence). Refuses dangerous commands."""
        if not cmd.strip():
            return True, "(no validation command supplied)"
        if DENY.search(cmd):
            return False, "validation command refused by the safety gate: " + cmd
        try:
            proc = subprocess.run(
                ["powershell", "-NoProfile", "-Command", cmd],
                cwd=self.run["project"], capture_output=True, text=True,
                timeout=120)
            out = (proc.stdout or "")[-500:].strip()
            evidence = "exit " + str(proc.returncode) + (": " + out if out else "")
            return proc.returncode == 0, evidence
        except subprocess.TimeoutExpired:
            return False, "validation timed out after 120s"
        except OSError as exc:
            return False, "validation could not run: " + str(exc)

    # ------------------------------------------------------------------ loop
    def _execute(self) -> None:
        models = self.run["models"]
        objective = self.run["objective"]
        project = self.run["project"]
        max_retries = self.run["max_retries"]

        # ---- plan
        self._event("planning", models["plan"])
        plan_text, code = self._call_agent(
            PLAN_PROMPT.format(project=project, objective=objective),
            models["plan"], "plan")
        if self._cancel.is_set():
            return self._finish("cancelled")
        if plan_text.strip().upper().startswith("BLOCKED"):
            return self._finish("blocked", plan_text.strip())
        plan = self._parse_plan(plan_text)
        if not plan:
            return self._finish("failed",
                                "planner returned no usable task list (exit " +
                                str(code) + ")")
        plan = plan[:MAX_TASKS]
        with self._lock:
            self.run["tasks"] = [
                {"n": i + 1, "title": t["title"], "status": "pending",
                 "attempts": 0, "verdict": "", "validate": t.get("validate", ""),
                 "files": t.get("files", []), "risk": t.get("risk", "low")}
                for i, t in enumerate(plan)]
        self._event("planned", str(len(plan)) + " tasks")
        self._save()

        # ---- build / validate / review per task
        for task in self.run["tasks"]:
            if self._cancel.is_set():
                return self._finish("cancelled")
            task["status"] = "building"
            self._event("task_started", "task " + str(task["n"]) + ": " + task["title"])
            feedback = ""
            done = False
            while task["attempts"] <= max_retries and not done:
                if self._cancel.is_set():
                    return self._finish("cancelled")
                task["attempts"] += 1
                retry = ""
                if task["attempts"] > 1 and feedback:
                    retry = ("This is attempt " + str(task["attempts"]) +
                             ". The previous attempt was rejected with this feedback:\n" +
                             feedback + "\nFix the cited problems first.")
                report, _ = self._call_agent(
                    BUILD_PROMPT.format(project=project, objective=objective,
                                        title=task["title"],
                                        files=", ".join(task["files"]),
                                        validate=task["validate"], retry=retry),
                    models["builder"], "build")
                if self._cancel.is_set():
                    return self._finish("cancelled")
                if report.strip().upper().startswith("STATUS: BLOCKED"):
                    task["status"] = "blocked"
                    task["verdict"] = report.strip()[:200]
                    self._event("task_blocked", task["verdict"])
                    self._save()
                    return self._finish("blocked", task["verdict"])

                # independent validation gate
                ok, evidence = self._validate(task["validate"])
                self._event("validation", "task " + str(task["n"]) + ": " + evidence)

                verdict_text, _ = self._call_agent(
                    REVIEW_PROMPT.format(project=project, objective=objective,
                                         title=task["title"],
                                         attempt=task["attempts"],
                                         report=report[-3000:], evidence=evidence),
                    models["review"], "review")
                if self._cancel.is_set():
                    return self._finish("cancelled")
                first = (verdict_text.strip().splitlines() or [""])[0].strip()
                if first.upper().startswith("NEXT"):
                    task["status"] = "done"
                    task["verdict"] = "NEXT"
                    done = True
                    self._event("task_done", "task " + str(task["n"]))
                elif first.upper().startswith("BLOCKED"):
                    task["status"] = "blocked"
                    task["verdict"] = first[:200]
                    self._event("task_blocked", first[:200])
                    self._save()
                    return self._finish("blocked", first[:200])
                else:
                    feedback = first[6:].strip() if first.upper().startswith("RETRY") else first
                    task["verdict"] = "RETRY: " + feedback[:180]
                    self._event("task_retry",
                                "task " + str(task["n"]) + ": " + feedback[:180])
                self._save()
            if not done:
                task["status"] = "failed"
                self._save()
                return self._finish("failed",
                                    "task " + str(task["n"]) + " exhausted retries: " +
                                    task["title"])

        self._finish("done", str(len(self.run["tasks"])) + " tasks completed")