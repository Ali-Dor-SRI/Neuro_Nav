"""Shared configuration: paths, ports, defaults."""

import json
import os
import secrets
import socket
import sys
import time

LISTEN_HOST = "0.0.0.0"
DEFAULT_PORT = 5050      # 5000 is reserved by macOS AirPlay Receiver since macOS Monterey.

AUTH_TIMEOUT_SEC      = 5.0    # receiver drops a connection if AUTH doesn't arrive in time
RECONNECT_INITIAL_SEC = 1
RECONNECT_MAX_SEC     = 30

# The shared secret is a 4-digit numeric code (0000-9999) that rotates once a
# week. Token + issue time are persisted as JSON so the code survives restarts
# (the Mac doesn't reconfigure on every receiver restart) but still rotates on
# schedule.
TOKEN_FILENAME = "tms_token.json"
TOKEN_TTL_SEC  = 7 * 24 * 60 * 60      # one week


def app_dir():
    """Directory where the token file lives.

    Next to the executable when frozen by PyInstaller; otherwise the
    trigger_app_AJ/ directory (two levels up from common/config.py).
    """
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def token_path():
    return os.path.join(app_dir(), TOKEN_FILENAME)


def _now():
    return time.time()


def _generate_token():
    """A fresh 4-digit numeric token, zero-padded (e.g. '0042')."""
    return f"{secrets.randbelow(10000):04d}"


def _write_record(token, issued_at):
    with open(token_path(), "w") as f:
        json.dump({"token": token, "issued_at": issued_at}, f)
    return token, issued_at


def _read_record():
    """Return {'token': str, 'issued_at': float} or None if unreadable.

    Tolerates a legacy plain-text token file (just the token, no JSON) by
    adopting it with a fresh issue time, so an old install rotates a week
    from upgrade rather than being treated as instantly expired.
    """
    try:
        with open(token_path(), "r") as f:
            raw = f.read().strip()
    except FileNotFoundError:
        return None
    if not raw:
        return None
    try:
        data = json.loads(raw)
        token = str(data["token"]).strip()
        issued_at = float(data["issued_at"])
        return {"token": token, "issued_at": issued_at} if token else None
    except (ValueError, KeyError, TypeError):
        return {"token": raw, "issued_at": _now()}   # legacy plain token


def is_expired(issued_at, now=None):
    now = _now() if now is None else now
    return (now - issued_at) >= TOKEN_TTL_SEC


def seconds_until_rotation(issued_at, now=None):
    now = _now() if now is None else now
    return max(0.0, TOKEN_TTL_SEC - (now - issued_at))


def current_token():
    """Return (token, issued_at, rotated).

    Loads the persisted token; if it's missing or older than a week, mints a
    new 4-digit token and persists it with a fresh issue time. `rotated` is
    True when a new token was written.
    """
    rec = _read_record()
    if rec is not None and not is_expired(rec["issued_at"]):
        return rec["token"], rec["issued_at"], False
    token, issued_at = _write_record(_generate_token(), _now())
    return token, issued_at, True


def regenerate_token():
    """Force a fresh token now. Returns (token, issued_at)."""
    return _write_record(_generate_token(), _now())


def save_token(token):
    """Persist a specific token with a fresh issue time (for --token override).
    Returns (token, issued_at)."""
    return _write_record(token, _now())


# ── Operator settings (not secrets) ───────────────────────────────────────────
# Currently just where the time-sync logs are written. Kept in its own file so
# tms_token.json stays a single-purpose secret store, and so a lab share path
# typed once survives restarts (the receiver often runs for days).

SETTINGS_FILENAME = "receiver_settings.json"


def settings_path():
    return os.path.join(app_dir(), SETTINGS_FILENAME)


def normalize_dir(path):
    """Clean up a folder path typed or pasted into the console.

    Windows Explorer's "Copy as path" wraps the path in double quotes and
    operators paste with stray whitespace, so both are stripped; %VARS% and ~
    are expanded so either shell's idiom works. Returns "" for blank input.
    """
    text = str(path or "").strip().strip('"').strip("'").strip()
    if not text:
        return ""
    return os.path.abspath(os.path.expanduser(os.path.expandvars(text)))


def _read_settings():
    """The settings dict, or {} if the file is missing/unreadable/corrupt."""
    try:
        with open(settings_path(), "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def saved_log_dir():
    """Time-sync log folder remembered from the last run ("" if none)."""
    return normalize_dir(_read_settings().get("log_dir", ""))


def save_log_dir(path):
    """Remember `path` as the time-sync log folder for the next launch.

    Best-effort: returns True if it was written, False if the settings file
    could not be saved (a read-only install directory, say). Not being able to
    remember the choice must never stop the receiver from running with it.
    """
    data = _read_settings()
    data["log_dir"] = normalize_dir(path)
    try:
        with open(settings_path(), "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        return True
    except OSError:
        return False


def get_local_ips():
    """Return a list of LAN IPs the receiver is reachable at.

    Returns the route-picked default-interface IP first (best guess for
    "the IP the Mac should connect to"), followed by any others found
    via getaddrinfo. Empty list if offline.
    """
    ips = []

    # 1. Route trick: open a UDP socket toward a public IP; doesn't send
    #    anything, but getsockname() returns the local IP of the interface
    #    that would carry the traffic.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        primary = s.getsockname()[0]
        if primary and primary != "0.0.0.0":
            ips.append(primary)
    except OSError:
        pass
    finally:
        s.close()

    # 2. Other addresses bound to this host (multi-homed, VPN, etc).
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, family=socket.AF_INET):
            ip = info[4][0]
            if ip and ip != "127.0.0.1" and ip not in ips:
                ips.append(ip)
    except OSError:
        pass

    return ips
