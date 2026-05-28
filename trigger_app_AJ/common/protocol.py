"""Wire protocol for the TMS trigger system (two-device, Mac sender + Windows receiver).

UTF-8, line-oriented, terminated by '\\n'. Port 5050 by default.

Handshake (Mac -> Windows):
    AUTH:<token>\\n

Handshake (Windows -> Mac):
    AUTH:OK\\n        (token accepted)
    AUTH:DENIED\\n    (token mismatch; Windows then closes the socket)

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
