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
import time

from trigger_app_AJ.common import protocol as proto
from trigger_app_AJ.common import timesync
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
        on_timesync(offset, delay, peer_str, participant)  # clock offset (Win - Mac), seconds
        on_participant(participant)    # study code the Mac sent for this session
        on_log(message)
    """

    def __init__(self, token, port=DEFAULT_PORT,
                 on_state=None, on_peer_change=None, on_timesync=None,
                 on_participant=None, on_log=None, timesync_log_path=None):
        self.token = token
        self.port  = port
        self._on_state         = on_state         or (lambda *a, **kw: None)
        self._on_peer_change   = on_peer_change   or (lambda *a, **kw: None)
        self._on_timesync      = on_timesync      or (lambda *a, **kw: None)
        self._on_participant   = on_participant   or (lambda *a, **kw: None)
        self._on_log           = on_log           or (lambda *a, **kw: None)
        self._timesync_log_path = timesync_log_path or timesync.timesync_log_path()

        self._server_socket = None
        self._peer_socket   = None
        self._peer_address  = None
        self._last_state    = None
        self._ts_pending    = None   # (t1, t2, t3) between TIME and TIMESYNC
        self._participant   = ""     # study code from the current connection's SESSION line
        self._lock          = threading.Lock()
        self.running        = False

    # ── lifecycle ────────────────────────────────────────────────────────────

    def set_token(self, token):
        """Replace the accepted token (used by the weekly rotation). Existing
        authenticated connections are unaffected; new connections must use the
        new token."""
        with self._lock:
            self.token = token

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
        with self._lock:
            expected = self.token
        if not hmac.compare_digest(offered, expected):
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
            self._ts_pending = None
            # The participant belongs to the connection that sent it; a new Mac
            # connection re-declares it (or leaves it blank).
            self._participant = ""
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
                recv_time = time.time()   # for time-sync: when this data landed
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self._handle_line(sock, line.decode("utf-8", errors="replace").strip(),
                                      recv_time)
        except OSError as exc:
            self._on_log(f"Read error: {exc}")
        finally:
            with self._lock:
                still_current = (self._peer_socket is sock)
                if still_current:
                    self._peer_socket  = None
                    self._peer_address = None
                    self._last_state   = None
                    self._ts_pending   = None
                    self._participant  = ""
            if still_current:
                self._on_log("Mac disconnected")
                self._on_peer_change(False, None)
            try: sock.close()
            except OSError: pass

    def _handle_line(self, sock, line, recv_time):
        if not line:
            return
        if line.startswith(proto.PREFIX_TIME):
            self._handle_time(sock, line, recv_time)
            return
        if line.startswith(proto.PREFIX_TIMESYNC):
            self._handle_timesync(sock, line)
            return
        if line.startswith(proto.PREFIX_SESSION):
            self._handle_session(line)
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

    # ── session label ─────────────────────────────────────────────────────────

    def _handle_session(self, line):
        """Mac sent SESSION:<participant>. Hold it for this connection and
        stamp it on every time-sync row logged from here on. One-way — no
        reply. The Mac sends it before the first TIME:, so the opening sync is
        already labelled; a later re-send (typo fix) affects later rows only."""
        participant = proto.sanitize_participant(
            line[len(proto.PREFIX_SESSION):])
        with self._lock:
            previous = self._participant
            self._participant = participant
        if not participant:
            self._on_log("Participant: (none supplied by the Mac)")
        elif previous and previous != participant:
            self._on_log(f"Participant changed: {previous!r} -> {participant!r} "
                         f"(applies to time-sync rows logged from now on)")
        else:
            self._on_log(f"Participant: {participant}")
        self._on_participant(participant)

    # ── time-sync ─────────────────────────────────────────────────────────────

    def _handle_time(self, sock, line, recv_time):
        """Mac sent TIME:<t1>. Record t1/t2/t3 and reply TIMEACK:<t2> <t3>.
        TIMEACK also serves as the 'timestamp received' notification."""
        try:
            (t1,) = proto.parse_floats_after(line, proto.PREFIX_TIME, 1)
        except ValueError:
            self._on_log(f"Bad TIME line: {line!r}")
            return
        t2 = recv_time
        t3 = time.time()
        with self._lock:
            self._ts_pending = (t1, t2, t3)
        try:
            sock.sendall(proto.make_timeack(t2, t3))
        except OSError as exc:
            self._on_log(f"Time-sync: TIMEACK send failed: {exc}")
            return
        self._on_log("Time-sync: received Mac timestamp - acknowledged")

    def _handle_timesync(self, sock, line):
        """Mac sent TIMESYNC:<t1> <t4>. Compute the offset against our own
        t2/t3, append it to the log, and reply TIMEOK:<offset> <delay>."""
        try:
            _t1, t4 = proto.parse_floats_after(line, proto.PREFIX_TIMESYNC, 2)
        except ValueError:
            self._on_log(f"Bad TIMESYNC line: {line!r}")
            return
        with self._lock:
            pending = self._ts_pending
            self._ts_pending = None
            peer = self._peer_address
            participant = self._participant
        if pending is None:
            self._on_log("Time-sync: TIMESYNC with no prior TIME — ignored")
            return
        t1, t2, t3 = pending
        offset, delay = timesync.compute_offset(t1, t2, t3, t4)
        peer_str = f"{peer[0]}:{peer[1]}" if peer else "?"
        who = participant or "(no participant)"
        try:
            path = timesync.append_log(offset, delay, t1, t2, t3, t4, peer_str,
                                       participant, self._timesync_log_path)
            self._on_log(
                f"Time-sync: delta = {offset:+.6f} s (Windows - Mac), "
                f"rtt {delay * 1000.0:.2f} ms - logged for {who} to {path}")
        except OSError as exc:
            self._on_log(f"Time-sync: log write failed: {exc}")
        try:
            sock.sendall(proto.make_timeok(offset, delay))
        except OSError as exc:
            self._on_log(f"Time-sync: TIMEOK send failed: {exc}")
        self._on_timesync(offset, delay, peer_str, participant)


def _close(sock):
    try: sock.shutdown(socket.SHUT_RDWR)
    except OSError: pass
    try: sock.close()
    except OSError: pass


def _send_and_close(sock, message):
    try: sock.sendall(message.encode("utf-8"))
    except OSError: pass
    _close(sock)
