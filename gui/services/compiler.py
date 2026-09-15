"""Config compiler - turns the provider registry + seat assignments into the
opencode JSON config, so the GUI is the only thing that ever writes it.

- Keys are referenced as {env:VAR}; the generated file contains no secrets.
- The existing agent definitions and permissions in minimax-opencode.json
  are preserved untouched; only the provider/model sections are regenerated.
- The previous config is backed up to *.bak before the first write.
"""
import json
import os
import shutil


def _root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def build_config(registry, app_config: dict, existing: dict | None = None) -> dict:
    existing = existing or {}
    providers = {}
    for p in registry.enabled():
        models = {}
        for mid in p.models:
            models[mid] = {"name": mid}
        providers[p.id] = {
            "npm": "@ai-sdk/openai-compatible",
            "name": p.display_name,
            "options": {"baseURL": p.base_url, "apiKey": "{env:" + p.env_var + "}"},
            "models": models,
        }
    cfg = dict(existing)
    cfg["$schema"] = "https://opencode.ai/config.json"
    cfg["provider"] = providers
    if app_config.get("default_model"):
        cfg["model"] = app_config["default_model"]
    return cfg


def write_config(registry, app_config: dict, path: str | None = None) -> str:
    path = path or os.path.join(_root(), "minimax-opencode.json")
    existing = None
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8-sig") as fh:
                existing = json.load(fh)
        except (json.JSONDecodeError, OSError):
            existing = None
        backup = path + ".bak"
        if not os.path.exists(backup):
            shutil.copyfile(path, backup)   # one-time backup of the hand-written file
    cfg = build_config(registry, app_config, existing)
    text = json.dumps(cfg, indent=4)
    json.loads(text)  # validate before touching disk
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
    return path