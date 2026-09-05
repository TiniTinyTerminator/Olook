"""Secret storage.

Prefers the session keyring through `secret-tool` (gnome-keyring / KWallet via
the Secret Service API, which Omarchy already runs for polkit and friends).
Falls back to a 0600 JSON file under the state dir when no Secret Service is
available — a headless box or a session where the keyring never unlocked.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

from . import config

SERVICE = "olook"
_FALLBACK = config.STATE_DIR / "secrets.json"


def _secret_tool():
    return shutil.which("secret-tool")


def _attrs(account_id, kind):
    return ["service", SERVICE, "account", str(account_id), "kind", str(kind)]


def set_secret(account_id, kind, value):
    tool = _secret_tool()
    if tool:
        label = f"Olook ({account_id}/{kind})"
        try:
            subprocess.run(
                [tool, "store", "--label", label, *_attrs(account_id, kind)],
                input=value, text=True, check=True, capture_output=True, timeout=30,
            )
            return "keyring"
        except (OSError, subprocess.SubprocessError):
            pass
    _file_write(account_id, kind, value)
    return "file"


def get_secret(account_id, kind):
    tool = _secret_tool()
    if tool:
        try:
            done = subprocess.run(
                [tool, "lookup", *_attrs(account_id, kind)],
                text=True, capture_output=True, timeout=30,
            )
            if done.returncode == 0 and done.stdout:
                # secret-tool does not add a trailing newline, but strip the
                # one a hand-run `secret-tool store` would have captured.
                return done.stdout.rstrip("\n")
        except (OSError, subprocess.SubprocessError):
            pass
    return _file_read(account_id, kind)


def clear_secret(account_id, kind):
    tool = _secret_tool()
    if tool:
        try:
            subprocess.run([tool, "clear", *_attrs(account_id, kind)],
                           capture_output=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            pass
    _file_delete(account_id, kind)


def clear_account(account_id):
    for kind in ("password", "refresh_token", "access_token"):
        clear_secret(account_id, kind)


# ------------------------------------------------------------------ fallback

def _file_load():
    if not _FALLBACK.exists():
        return {}
    try:
        with _FALLBACK.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _file_save(data):
    config.ensure_dirs()
    tmp = Path(str(_FALLBACK) + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(data, handle)
    os.chmod(tmp, 0o600)
    os.replace(tmp, _FALLBACK)


def _file_write(account_id, kind, value):
    data = _file_load()
    data[f"{account_id}/{kind}"] = value
    _file_save(data)


def _file_read(account_id, kind):
    return _file_load().get(f"{account_id}/{kind}")


def _file_delete(account_id, kind):
    data = _file_load()
    if data.pop(f"{account_id}/{kind}", None) is not None:
        _file_save(data)
