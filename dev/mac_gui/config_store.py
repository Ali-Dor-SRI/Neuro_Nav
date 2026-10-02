"""Persisted GUI settings so the app doesn't ask for the same connection
details every launch.

Stores the Windows IP, port, and auth token as JSON. Location follows the
platform convention; on macOS that's
``~/Library/Application Support/Neuro_Nav/config.json`` — writable even when
the .app lives in /Applications, and it survives app updates.

All functions are best-effort: a missing or corrupt file reads back as an
empty config, and a failed write returns False rather than raising, so a
read-only or sandboxed filesystem never crashes the GUI.
"""

import json
import os
import sys

APP_NAME        = "Neuro_Nav"
CONFIG_FILENAME = "config.json"


def config_dir():
    if sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    elif sys.platform.startswith("win"):
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, APP_NAME)


def config_path():
    return os.path.join(config_dir(), CONFIG_FILENAME)


def load_config():
    """Return the full config dict (empty dict if missing/unreadable)."""
    try:
        with open(config_path(), "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, ValueError, OSError):
        return {}


def save_config(data):
    """Write the config dict atomically. Returns True on success."""
    path = config_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
        return True
    except OSError:
        return False


# ── Connection details (Windows IP / port / token) ─────────────────────────

def load_connection():
    """Return {'windows_ip', 'port', 'token'} as saved, or {} if none."""
    conn = load_config().get("connection")
    return conn if isinstance(conn, dict) else {}


def save_connection(windows_ip, port, token):
    """Persist the connection details that just authenticated successfully."""
    cfg = load_config()
    cfg["connection"] = {
        "windows_ip": windows_ip,
        "port":       port,
        "token":      token,
    }
    return save_config(cfg)
