"""Wire protocol for the TMS trigger system (two-device, Mac sender + Windows receiver).

UTF-8, line-oriented, terminated by '\\n'. Port 5050 by default.

Handshake (Mac -> Windows):
    AUTH:<token>\\n

Handshake (Windows -> Mac):
    AUTH:OK\\n        (token accepted)
    AUTH:DENIED\\n    (token mismatch; Windows then closes the socket)

Time-sync handshake (round-trip / NTP-style, runs once right after AUTH:OK,
before any STATE traffic):
    Mac -> Windows:  TIME:<t1>\\n          t1 = Mac epoch when sent
    Windows -> Mac:  TIMEACK:<t2> <t3>\\n   t2 = Win recv epoch, t3 = Win send epoch
    Mac -> Windows:  TIMESYNC:<t1> <t4>\\n  t4 = Mac epoch when TIMEACK arrived
    Windows -> Mac:  TIMEOK:<offset> <delay>\\n   result echoed back to the Mac

Windows computes the clock offset itself from its own t2/t3 plus the Mac's
t1/t4 (offset = ((t2-t1)+(t3-t4))/2 = Windows_clock - Mac_clock), appends it
to its time-sync log, and the TIMEOK reply doubles as the "timestamp received
and logged" notification to the Mac. See common/timesync.py for the maths.

Steady state (Mac -> Windows):
    STATE:GREEN\\n    sent on out-of-range -> in-range transition
    STATE:RED\\n      sent on in-range -> out-of-range transition

The receiver fires `ss`+Enter into the focused window whenever the
received STATE differs from the previous one (the very first STATE per
connection is treated as a transition from "unknown" and DOES fire).

The receiver accepts exactly one Mac connection at a time. A newer
authenticated connection replaces the older one.
"""

PREFIX_AUTH  = "AUTH:"
PREFIX_STATE = "STATE:"

PREFIX_TIME     = "TIME:"
PREFIX_TIMEACK  = "TIMEACK:"
PREFIX_TIMESYNC = "TIMESYNC:"
PREFIX_TIMEOK   = "TIMEOK:"

AUTH_OK     = "AUTH:OK"
AUTH_DENIED = "AUTH:DENIED"

STATE_GREEN = "GREEN"
STATE_RED   = "RED"
STATES      = (STATE_GREEN, STATE_RED)

LINE_LIMIT = 256   # max bytes per handshake line


def read_line(sock, limit=LINE_LIMIT):
    """Blocking single-line read. Returns stripped str.

    Raises OSError if the socket closes before '\\n', or ValueError if the
    line exceeds `limit` bytes (defense against runaway senders).
    """
    buf = bytearray()
    while True:
        chunk = sock.recv(1)
        if not chunk:
            raise OSError("connection closed before newline")
        if chunk == b"\n":
            break
        buf += chunk
        if len(buf) > limit:
            raise ValueError("line too long")
    return buf.decode("utf-8", errors="replace").strip()


def make_auth(token):
    return f"{PREFIX_AUTH}{token}\n".encode("utf-8")

def make_state(state):
    return f"{PREFIX_STATE}{state}\n".encode("utf-8")


# ── Time-sync messages ─────────────────────────────────────────────────────────
# Epochs are Unix time (seconds, UTC) as plain floats so the two machines compare
# on the same scale regardless of local timezone.

def make_time(t1):
    return f"{PREFIX_TIME}{t1:.6f}\n".encode("utf-8")

def make_timeack(t2, t3):
    return f"{PREFIX_TIMEACK}{t2:.6f} {t3:.6f}\n".encode("utf-8")

def make_timesync(t1, t4):
    return f"{PREFIX_TIMESYNC}{t1:.6f} {t4:.6f}\n".encode("utf-8")

def make_timeok(offset, delay):
    return f"{PREFIX_TIMEOK}{offset:.6f} {delay:.6f}\n".encode("utf-8")

def parse_floats_after(line, prefix, count):
    """Parse `count` space-separated floats from the body of `line` after
    `prefix`. Raises ValueError if the count or numeric format is wrong."""
    parts = line[len(prefix):].strip().split()
    if len(parts) < count:
        raise ValueError(f"expected {count} value(s) after {prefix!r}, got {line!r}")
    return tuple(float(p) for p in parts[:count])
