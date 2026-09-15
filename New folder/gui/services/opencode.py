"""OpenCode service - exe resolution, process spawning, HTTP API client.

Mirrors manager/engine.ps1 contracts: real binary preferred over the .cmd
shim, OPENCODE_CONFIG pinned for every call, 127.0.0.1-only servers.
Phase 4: child-process environments are hydrated with every provider key
stored in the DPAPI CredentialStore, so keys never appear on command lines
or in config files - opencode resolves them via {env:VAR} references.
"""
import json
import os
import shutil
import subprocess
import urllib.error
import urllib.request


def _root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class OpenCode:
    def __init__(self, config_path: str | None = None, exe_path: str | None = None,
                 creds=None):
        self.config_path = config_path or os.path.join(_root(), "minimax-opencode.json")
        self._exe = exe_path
        self._creds = creds  # CredentialStore or None

    def resolve_exe(self) -> str:
        if self._exe and os.path.isfile(self._exe):
            return self._exe
        appdata = os.environ.get("APPDATA", "")
        candidate = os.path.join(appdata, "npm", "node_modules", "opencode-ai", "bin", "opencode.exe")
        if os.path.isfile(candidate):
            return candidate
        on_path = shutil.which("opencode")
        if on_path:
            return on_path
        raise OpenCodeError("opencode executable not found. Install it or set the path in Settings.")

    def version(self) -> str:
        out = subprocess.run([self.resolve_exe(), "--version"], capture_output=True,
                             text=True, timeout=15)
        return (out.stdout or out.stderr).strip()

    def _env(self) -> dict:
        env = dict(os.environ)
        env["OPENCODE_CONFIG"] = self.config_path
        if self._creds is not None:
            for name in self._creds.names():
                value = self._creds.get(name)
                if value:
                    env[name] = value   # hydrate provider keys for {env:VAR}
        return env

    def serve(self, project: str, port: int) -> subprocess.Popen:
        args = [self.resolve_exe(), "serve", "--port", str(port), "--hostname", "127.0.0.1"]
        creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        return subprocess.Popen(args, cwd=project, env=self._env(),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                creationflags=creation)

    def run_args(self, prompt: str, project: str, model: str | None = None,
                 agent: str | None = None) -> list:
        flat = " ".join(prompt.replace("\r", " ").replace("\n", " ").split())
        args = [self.resolve_exe(), "run", flat, "--pure", "--format", "json",
                "--dir", project]
        if model:
            args += ["-m", model]
        if agent:
            args += ["--agent", agent]
        return args


class WorkerHttp:
    """Client for one worker's opencode server."""

    def __init__(self, port: int, timeout: int = 5):
        self.base = "http://127.0.0.1:" + str(port)
        self.timeout = timeout

    def _get(self, path: str):
        try:
            with urllib.request.urlopen(self.base + path, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise OpenCodeError("worker " + self.base + path + ": " + str(exc)) from exc

    def healthy(self) -> bool:
        try:
            self._get("/session")
            return True
        except OpenCodeError:
            return False

    def sessions(self):
        return self._get("/session")

    def messages(self, session_id: str):
        return self._get("/session/" + session_id + "/message")

    def prompt_async(self, session_id: str, text: str) -> None:
        body = json.dumps({"parts": [{"type": "text", "text": text}]}).encode("utf-8")
        req = urllib.request.Request(
            self.base + "/session/" + session_id + "/prompt_async", data=body,
            headers={"Content-Type": "application/json; charset=utf-8"})
        with urllib.request.urlopen(req, timeout=10):
            pass

    def abort(self, session_id: str) -> None:
        req = urllib.request.Request(self.base + "/session/" + session_id + "/abort",
                                     data=b"", method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout):
                pass
        except (urllib.error.URLError, TimeoutError):
            pass


class OpenCodeError(Exception):
    pass