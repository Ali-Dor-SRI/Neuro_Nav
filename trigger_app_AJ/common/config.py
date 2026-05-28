"""Shared configuration: paths, ports, defaults."""

import os
import secrets
import socket
import sys

LISTEN_HOST = "0.0.0.0"
DEFAULT_PORT = 5050      # 5000 is reserved by macOS AirPlay Receiver since macOS Monterey.

AUTH_TIMEOUT_SEC      = 5.0    # receiver drops a connection if AUTH doesn't arrive in time
RECONNECT_INITIAL_SEC = 1
RECONNECT_MAX_SEC     = 30

TOKEN_FILENAME = "tms_token.txt"


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


def load_or_create_token():
    """Read the token from disk, or generate one and persist it.

    Returns (token, is_new). The token survives across runs so the Mac
    doesn't have to be reconfigured every time the receiver restarts.
    """
    path = token_path()
    try:
        with open(path, "r") as f:
            token = f.read().strip()
            if token:
                return token, False
    except FileNotFoundError:
        pass
    return _generate_and_save(path), True


def regenerate_token():
    """Discard any persisted token and write a fresh one. Returns the new token."""
    return _generate_and_save(token_path())


def save_token(token):
    """Write a specific token string to disk (for --token override + persist)."""
    with open(token_path(), "w") as f:
        f.write(token + "\n")


def _generate_and_save(path):
    token = secrets.token_urlsafe(12)
    with open(path, "w") as f:
        f.write(token + "\n")
    return token


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
