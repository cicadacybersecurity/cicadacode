"""ConfigStore - non-secret application configuration.

Persists to state/gui-config.json (plain JSON, no secrets - secrets live in
the DPAPI CredentialStore). Atomic writes, tolerant of missing/corrupt files.
"""
import json
import os
import tempfile

DEFAULTS = {
    "general": {"refresh_interval_sec": 3, "notifications": True, "theme": "aero_day"},
    "workers": {"default_count": 2, "port_base": 4310, "max_workers": 3},
    "opencode": {"exe_path": "", "config_path": "minimax-opencode.json"},
    "providers": {},           # provider_id -> non-secret provider record
    "default_provider": "minimax",
    "default_model": "minimax/MiniMax-M2.7",
    "seats": {                 # per-role model assignment
        "planner": "minimax/MiniMax-M3",
        "reviewer": "minimax/MiniMax-M3",
        "builder": "minimax/MiniMax-M2.7",
    },
}


def _root() -> str:
    # gui/services/config.py -> project root
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class ConfigStore:
    def __init__(self, path: str | None = None):
        self.path = path or os.path.join(_root(), "state", "gui-config.json")

    def load(self) -> dict:
        cfg = json.loads(json.dumps(DEFAULTS))
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                on_disk = json.load(fh)
            cfg = _deep_merge(cfg, on_disk)
        except FileNotFoundError:
            pass
        except (json.JSONDecodeError, OSError) as exc:
            raise ConfigError(f"Malformed configuration at {self.path}: {exc}") from exc
        return cfg

    def save(self, cfg: dict) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self.path), suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(cfg, fh, indent=2)
            os.replace(tmp, self.path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


class ConfigError(Exception):
    pass


def _deep_merge(base: dict, over: dict) -> dict:
    for key, val in over.items():
        if isinstance(val, dict) and isinstance(base.get(key), dict):
            base[key] = _deep_merge(base[key], val)
        else:
            base[key] = val
    return base