"""Windows-side TCP receiver.

Listens on a port, accepts at most one authenticated Mac connection at a
time, reads STATE: lines, and fires `ss`+Enter into the focused window
on every state change (including the very first STATE: per connection,
so an initial RED while QTrack is focused still gets a keystroke).

Single-threaded design except for the accept loop: one accept thread,
each accepted connection handled inline on its own thread. The Tk-less
caller (main.py) just polls callbacks.
"""

import hmac
import socket
import threading

from trigger_app_AJ.common import protocol as proto
from trigger_app_AJ.common.config import (
    AUTH_TIMEOUT_SEC,
    DEFAULT_PORT,
    LISTEN_HOST,
)


class TriggerReceiver:
    """TCP listener for trigger events.

    Callbacks (fired on background threads — main script must be
    thread-safe or marshal as appropriate):
        on_state(state, is_change)     # GREEN / RED; is_change is False on duplicates
        on_peer_change(connected, addr_str)
        on_log(message)
    """

    def __init__(self, token, port=DEFAULT_PORT,
                 on_state=None, on_peer_change=None, on_log=None):
        self.token = token
        self.port  = port
        self._on_state         = on_state         or (lambda *a, **kw: None)
        self._on_peer_change   = on_peer_change   or (lambda *a, **kw: None)
        self._on_log           = on_log           or (lambda *a, **kw: None)

        self._server_socket = None
        self._peer_socket   = None
        self._peer_address  = None
        self._last_state    = None
        self._lock          = threading.Lock()
        self.running        = False

    # ── lifecycle ────────────────────────────────────────────────────────────

    def start(self):
        self.running = True
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def stop(self):
        self.running = False
        with self._lock:
            peer = self._peer_socket
            self._peer_socket = None
        for sock in (peer, self._server_socket):
            if sock is not None:
                try: sock.close()
                except OSError: pass

    # ── accept loop ──────────────────────────────────────────────────────────

    def _accept_loop(self):
        try:
            self._server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._server_socket.bind((LISTEN_HOST, self.port))
            self._server_socket.listen(2)
            self._on_log(f"Listening on port {self.port}")
        except OSError as exc:
            self._on_log(f"Failed to bind port {self.port}: {exc}")
            return

        while self.running:
            try:
                sock, addr = self._server_socket.accept()
            except OSError:
                break
            threading.Thread(
                target=self._handle_connection,
                args=(sock, addr),
                daemon=True,
            ).start()

    def _handle_connection(self, sock, addr):
        addr_str = f"{addr[0]}:{addr[1]}"
        self._on_log(f"Incoming connection from {addr_str} - awaiting auth")
        try:
            sock.settimeout(AUTH_TIMEOUT_SEC)
            line = proto.read_line(sock)
        except (OSError, ValueError) as exc:
            self._on_log(f"Auth read failed from {addr_str}: {exc}")
            _close(sock)
            return

        if not line.startswith(proto.PREFIX_AUTH):
            self._on_log(f"Rejected {addr_str}: expected AUTH line, got {line!r}")
            _send_and_close(sock, proto.AUTH_DENIED + "\n")
            return

        offered = line[len(proto.PREFIX_AUTH):]
        if not hmac.compare_digest(offered, self.token):
            self._on_log(f"Rejected {addr_str}: invalid token")
            _send_and_close(sock, proto.AUTH_DENIED + "\n")
            return

        try:
            sock.settimeout(None)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            sock.sendall((proto.AUTH_OK + "\n").encode("utf-8"))
        except OSError as exc:
            self._on_log(f"Auth ack failed for {addr_str}: {exc}")
            _close(sock)
            return

        # Install as current peer; bump any previous one.
        with self._lock:
            old = self._peer_socket
            self._peer_socket  = sock
            self._peer_address = addr
            # New connection -> reset state-tracking so the first STATE
            # received counts as a transition (forces a keystroke).
            self._last_state = None
        if old is not None:
            self._on_log("Replacing previous Mac connection")
            _close(old)

        self._on_log(f"Mac authenticated: {addr_str}")
        self._on_peer_change(True, addr_str)
        self._read_loop(sock)

    def _read_loop(self, sock):
        buf = b""
        try:
            while self.running:
                data = sock.recv(1024)
                if not data:
                    break
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self._handle_line(line.decode("utf-8", errors="replace").strip())
        except OSError as exc:
            self._on_log(f"Read error: {exc}")
        finally:
            with self._lock:
                still_current = (self._peer_socket is sock)
                if still_current:
                    self._peer_socket  = None
                    self._peer_address = None
                    self._last_state   = None
            if still_current:
                self._on_log("Mac disconnected")
                self._on_peer_change(False, None)
            try: sock.close()
            except OSError: pass

    def _handle_line(self, line):
        if not line:
            return
        if not line.startswith(proto.PREFIX_STATE):
            self._on_log(f"Unknown message: {line!r}")
            return
        state = line[len(proto.PREFIX_STATE):].strip().upper()
        if state not in proto.STATES:
            self._on_log(f"Unknown state: {state}")
            return
        with self._lock:
            is_change = (state != self._last_state)
            self._last_state = state
        self._on_state(state, is_change)


def _close(sock):
    try: sock.shutdown(socket.SHUT_RDWR)
    except OSError: pass
    try: sock.close()
    except OSError: pass


def _send_and_close(sock, message):
    try: sock.sendall(message.encode("utf-8"))
    except OSError: pass
    _close(sock)
