"""CredentialStore - DPAPI-backed secret storage (Windows CurrentUser scope).

Secrets are encrypted with CryptProtectData and stored as blob files under
state/secrets/. Plaintext never touches disk. On non-Windows hosts the store
refuses to operate rather than falling back to insecure storage.
"""
import base64
import ctypes
import ctypes.wintypes as wt
import os


def _root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class _DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wt.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def _blob(data: bytes) -> _DATA_BLOB:
    buf = ctypes.create_string_buffer(data, len(data))
    return _DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))


def _crypt(data: bytes, protect: bool) -> bytes:
    if os.name != "nt":
        raise CredentialError("DPAPI storage requires Windows; refusing insecure fallback.")
    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    fn = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    in_blob = _blob(data)
    out_blob = _DATA_BLOB()
    if not fn(ctypes.byref(in_blob), None, None, None, None, 0, ctypes.byref(out_blob)):
        raise CredentialError("DPAPI call failed (CryptProtectData/CryptUnprotectData).")
    try:
        return ctypes.string_at(out_blob.pbData, out_blob.cbData)
    finally:
        kernel32.LocalFree(out_blob.pbData)


class CredentialStore:
    def __init__(self, directory: str | None = None):
        self.dir = directory or os.path.join(_root(), "state", "secrets")
        os.makedirs(self.dir, exist_ok=True)

    def _path(self, name: str) -> str:
        safe = "".join(c for c in name if c.isalnum() or c in "._-")
        if not safe:
            raise CredentialError("Credential name is empty or invalid.")
        return os.path.join(self.dir, safe + ".bin")

    def set(self, name: str, value: str) -> None:
        if not value:
            raise CredentialError("Refusing to store an empty secret.")
        blob = _crypt(value.encode("utf-8"), protect=True)
        with open(self._path(name), "wb") as fh:
            fh.write(base64.b64encode(blob))

    def get(self, name: str) -> str | None:
        path = self._path(name)
        if not os.path.exists(path):
            return None
        with open(path, "rb") as fh:
            blob = base64.b64decode(fh.read())
        return _crypt(blob, protect=False).decode("utf-8")

    def delete(self, name: str) -> None:
        path = self._path(name)
        if os.path.exists(path):
            os.unlink(path)

    def names(self) -> list:
        return [f[:-4] for f in os.listdir(self.dir) if f.endswith(".bin")]

    @staticmethod
    def mask(value: str | None) -> str:
        if not value:
            return "(not set)"
        return "****" + value[-4:] if len(value) > 4 else "****"


class CredentialError(Exception):
    pass