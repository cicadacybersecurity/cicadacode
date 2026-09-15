"""Journal - reads/writes the existing state/runs JSON format so the CLI
dashboard and the GUI see the same runs."""
import json
import os
import time


def _root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class Journal:
    def __init__(self, runs_dir: str | None = None):
        self.dir = runs_dir or os.path.join(_root(), "state", "runs")

    def list_runs(self, limit: int = 20) -> list:
        if not os.path.isdir(self.dir):
            return []
        files = sorted(
            (f for f in os.listdir(self.dir) if f.endswith(".json")),
            key=lambda f: os.path.getmtime(os.path.join(self.dir, f)),
            reverse=True,
        )[:limit]
        runs = []
        for name in files:
            try:
                with open(os.path.join(self.dir, name), "r", encoding="utf-8") as fh:
                    runs.append(json.load(fh))
            except (json.JSONDecodeError, OSError):
                continue
        return runs

    def mark_interrupted(self, stale_minutes: int = 45) -> int:
        now = time.time()
        fixed = 0
        for run in self.list_runs(limit=200):
            if run.get("status") != "running":
                continue
            try:
                updated = time.mktime(time.strptime(run["updated"][:19], "%Y-%m-%dT%H:%M:%S"))
            except (KeyError, ValueError):
                continue
            if (now - updated) / 60 > stale_minutes:
                run["status"] = "interrupted"
                path = os.path.join(self.dir, run["id"] + ".json")
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump(run, fh, indent=2)
                fixed += 1
        return fixed