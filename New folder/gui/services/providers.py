"""Provider registry - seamless provider/key/model management. Phase 4.

One Provider record = id, name, base URL, env var for its key, enabled flag,
discovered model list. Presets (MiniMax, Cerebras) always exist; custom
OpenAI-compatible providers are data, not code. Keys live ONLY in the DPAPI
CredentialStore; this module never persists secrets. Non-secret records are
saved to gui-config.json so the GUI, the compiler, and the CLI agree.
"""
import json
import time
import urllib.error
import urllib.request

from .credentials import CredentialStore

PRESETS = {
    "minimax": {
        "display_name": "MiniMax",
        "base_url": "https://api.minimax.io/v1",
        "env_var": "MINIMAX_API_KEY",
    },
    "cerebras": {
        "display_name": "Cerebras",
        "base_url": "https://api.cerebras.ai/v1",
        "env_var": "CEREBRAS_API_KEY",
    },
}


class Provider:
    protocol = "openai_compatible"

    def __init__(self, provider_id, display_name, base_url, env_var, creds,
                 enabled=True, models=None, custom=False):
        self.id = provider_id
        self.display_name = display_name
        self.base_url = base_url.rstrip("/")
        self.env_var = env_var
        self.enabled = enabled
        self.models = list(models or [])   # discovered or manual model IDs
        self.custom = custom
        self._creds = creds

    # -- secrets ---------------------------------------------------------
    def set_key(self, key: str) -> None:
        self._creds.set(self.env_var, key)

    def clear_key(self) -> None:
        self._creds.delete(self.env_var)

    def has_key(self) -> bool:
        return self._creds.get(self.env_var) is not None

    def masked_key(self) -> str:
        return CredentialStore.mask(self._creds.get(self.env_var))

    # -- live API ----------------------------------------------------------
    def _request(self, path, timeout=15):
        key = self._creds.get(self.env_var)
        if not key:
            raise ProviderError(
                self.display_name + ": no API key stored (" + self.env_var + ").")
        req = urllib.request.Request(
            self.base_url + path,
            headers={"Authorization": "Bearer " + key, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                raise ProviderError(self.display_name + ": API key rejected (401).") from exc
            if exc.code == 429:
                raise ProviderError(self.display_name + ": rate limited (429).") from exc
            raise ProviderError(self.display_name + ": HTTP " + str(exc.code) + ".") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ProviderError(self.display_name + ": unreachable (" + str(exc) + ").") from exc

    def test_connection(self) -> dict:
        start = time.monotonic()
        self.list_models_live()
        return {"ok": True, "latency_ms": int((time.monotonic() - start) * 1000)}

    def list_models_live(self) -> list:
        """Hit GET {base}/models. Raises ProviderError on failure."""
        data = self._request("/models")
        return sorted(m.get("id", "") for m in data.get("data", []) if m.get("id"))

    def discover_models(self) -> list:
        """Live discovery merged into the stored model list."""
        found = self.list_models_live()
        merged = sorted(set(self.models) | set(found))
        self.models = merged
        return merged

    # -- persistence shape -------------------------------------------------
    def to_record(self) -> dict:
        return {"display_name": self.display_name, "base_url": self.base_url,
                "env_var": self.env_var, "enabled": self.enabled,
                "models": self.models, "custom": self.custom}


class ProviderRegistry:
    def __init__(self, creds=None, config: dict | None = None):
        self._creds = creds or CredentialStore()
        self._providers = {}
        saved = (config or {}).get("providers", {})
        for pid, preset in PRESETS.items():
            rec = saved.get(pid, {})
            self._providers[pid] = Provider(
                pid, preset["display_name"], preset["base_url"], preset["env_var"],
                self._creds,
                enabled=rec.get("enabled", True),
                models=rec.get("models", []),
                custom=False)
        for pid, rec in saved.items():
            if pid in self._providers or not rec.get("custom"):
                continue
            self._providers[pid] = Provider(
                pid, rec["display_name"], rec["base_url"], rec["env_var"],
                self._creds, enabled=rec.get("enabled", True),
                models=rec.get("models", []), custom=True)

    # -- management ---------------------------------------------------------
    def add_custom(self, display_name: str, base_url: str) -> Provider:
        slug = "".join(c for c in display_name.lower() if c.isalnum()) or "custom"
        pid = slug
        n = 2
        while pid in self._providers:
            pid = slug + str(n)
            n += 1
        env_var = "PROVIDER_" + slug.upper() + "_API_KEY"
        prov = Provider(pid, display_name, base_url, env_var, self._creds,
                        enabled=True, models=[], custom=True)
        self._providers[pid] = prov
        return prov

    def remove(self, provider_id: str) -> None:
        prov = self._providers[provider_id]
        if not prov.custom:
            raise ProviderError("Built-in providers can be disabled but not removed.")
        prov.clear_key()
        del self._providers[provider_id]

    def get(self, provider_id: str) -> Provider:
        if provider_id not in self._providers:
            raise ProviderError("Unknown provider: " + provider_id)
        return self._providers[provider_id]

    def all(self) -> list:
        return list(self._providers.values())

    def enabled(self) -> list:
        return [p for p in self._providers.values() if p.enabled]

    def all_models(self) -> list:
        """Every selectable model as provider/model strings."""
        out = []
        for p in self.enabled():
            for m in p.models:
                out.append(p.id + "/" + m)
        return sorted(out)

    def records(self) -> dict:
        return {pid: p.to_record() for pid, p in self._providers.items()}


class ProviderError(Exception):
    pass