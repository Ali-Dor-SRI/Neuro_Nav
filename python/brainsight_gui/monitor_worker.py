"""Threaded backend for the Brainsight GUI.

Mirrors the polling + trigger logic of `alert_brainsight_v2.2.0.py` but
exposes it as a class with callbacks instead of `print()` and the input
REPL. UI code never touches sockets or files directly — it talks to
MonitorWorker, MonitorWorker talks back via callbacks dispatched onto
the UI thread.

Design contract:
  - All methods on MonitorWorker are safe to call from the UI thread.
  - Callbacks may be invoked from background threads; MonitorWorker
    routes them through `ui_dispatch(fn, *args)` so the UI never has to
    care about threading. `ui_dispatch` is typically `root.after(0, ...)`.
"""

import math
import os
import socket
import threading
import time

from brainsight_gui import messages as M


# ── Constants ────────────────────────────────────────────────────────────────

POLL_HZ          = 2
POLL_INTERVAL    = 1.0 / POLL_HZ
STATUS_INTERVAL  = 5.0           # rate-limit repeated "waiting…" messages

COORD_SYS        = "MNI"

DEFAULT_LOC_THR  = 40.0          # mm
DEFAULT_ANG_THR  = 0.20          # rad
DEFAULT_REMIND   = 100           # reminder every N polls while out

AXIS_NAMES       = ("X", "Y", "Z")

TRIGGER_RECONNECT_INITIAL_SEC = 1
TRIGGER_RECONNECT_MAX_SEC     = 30

# Protocol constants (inlined; see trigger_app_AJ/common/protocol.py for the
# canonical definition).
PREFIX_AUTH  = "AUTH:"
PREFIX_STATE = "STATE:"
PREFIX_SESSION  = "SESSION:"
PREFIX_TIME     = "TIME:"
PREFIX_TIMEACK  = "TIMEACK:"
PREFIX_TIMESYNC = "TIMESYNC:"
PREFIX_TIMEOK   = "TIMEOK:"
AUTH_OK      = "AUTH:OK"
AUTH_DENIED  = "AUTH:DENIED"
STATE_GREEN  = "GREEN"
STATE_RED    = "RED"

PARTICIPANT_MAX_LEN = 64   # keeps SESSION: under the 256-byte line limit


def sanitize_participant(value, limit=PARTICIPANT_MAX_LEN):
    """Make a typed participant id safe for the wire AND for the log file.

    The wire is newline-delimited and the Windows time-sync log is
    tab-separated, so a pasted value carrying either would corrupt both.
    Mirrors trigger_app_AJ/common/protocol.sanitize_participant().
    """
    if not value:
        return ""
    text = "".join(ch for ch in str(value) if ch.isprintable())
    return " ".join(text.split())[:limit]


# ── Geometry / parsing (copied from alert_brainsight_v2.2.0) ────────────────

def _parse_floats(parts, indices):
    try:
        return tuple(float(parts[i]) for i in indices)
    except (IndexError, ValueError, TypeError):
        return None

def _parse_target_row(parts):
    if len(parts) < 17:
        return None
    loc = _parse_floats(parts, [5, 6, 7])
    mat = _parse_floats(parts, list(range(8, 17)))
    if not loc or not mat:
        return None
    return {"name": parts[3].strip(), "coord_system": parts[4].strip(),
            "loc": loc, "mat": mat}

def _parse_crosshairs_row(parts):
    if len(parts) < 17:
        return None
    loc = _parse_floats(parts, [5, 6, 7])
    mat = _parse_floats(parts, list(range(8, 17)))
    if not loc or not mat:
        return None
    return {"driver": parts[3].strip(), "coord_system": parts[4].strip(),
            "loc": loc, "mat": mat}

def _axis_offsets(loc_ref, loc_cur):
    return (abs(loc_ref[0] - loc_cur[0]),
            abs(loc_ref[1] - loc_cur[1]),
            abs(loc_ref[2] - loc_cur[2]))

def _per_axis_tilts(mat_ref, mat_cur):
    tilts = []
    for i in range(3):
        cx_r = mat_ref[0*3+i]; cy_r = mat_ref[1*3+i]; cz_r = mat_ref[2*3+i]
        cx_c = mat_cur[0*3+i]; cy_c = mat_cur[1*3+i]; cz_c = mat_cur[2*3+i]
        cos_th = max(-1.0, min(1.0, cx_r*cx_c + cy_r*cy_c + cz_r*cz_c))
        tilts.append(math.acos(cos_th))
    return tuple(tilts)

def _read_line(sock, limit=256):
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


# ── TriggerSender (TCP client to the Windows receiver) ──────────────────────

class _TriggerSender:
    """Long-lived TCP client. Reconnects automatically. Best-effort sends."""

    def __init__(self, host, port, token, on_log, on_link_state, participant=""):
        self.host = host; self.port = port; self.token = token
        self._on_log        = on_log         # callable(level, message)
        self._on_link_state = on_link_state  # callable(connected, info)
        self._participant   = sanitize_participant(participant)

        self._sock = None
        self._sock_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._connected_event = threading.Event()
        self._thread = None

    def start(self):
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop_event.set()
        with self._sock_lock:
            sock = self._sock; self._sock = None
        if sock is not None:
            try: sock.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            try: sock.close()
            except OSError: pass

    def is_connected(self):
        return self._connected_event.is_set()

    def wait_until_connected(self, timeout=None):
        deadline = None if timeout is None else (time.monotonic() + timeout)
        while not self._stop_event.is_set():
            slice_left = None
            if deadline is not None:
                slice_left = deadline - time.monotonic()
                if slice_left <= 0:
                    return False
            chunk = 0.25 if slice_left is None else min(0.25, slice_left)
            if self._connected_event.wait(timeout=chunk):
                return True
        return False

    def send_state(self, state):
        if state not in (STATE_GREEN, STATE_RED):
            return False
        with self._sock_lock:
            sock = self._sock
        if sock is None:
            return False
        try:
            sock.sendall(f"{PREFIX_STATE}{state}\n".encode("utf-8"))
            return True
        except OSError as exc:
            self._on_log(*M.connection_lost(f"send failed: {exc}"))
            return False

    def _loop(self):
        attempt = 0
        while not self._stop_event.is_set():
            sock = None; auth_denied = False
            try:
                self._on_log(*M.connecting(self.host, self.port))
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(5.0)
                sock.connect((self.host, self.port))
                sock.sendall(f"{PREFIX_AUTH}{self.token}\n".encode("utf-8"))
                first = _read_line(sock)
                if first != AUTH_OK:
                    if first == AUTH_DENIED:
                        auth_denied = True
                        self._on_log(*M.auth_denied())
                    raise OSError("authentication failed")
                # Declare the participant BEFORE the sync, so the first row
                # Windows logs already carries it. Best-effort.
                self._send_session(sock)
                # Round-trip clock sync before any STATE traffic. Best-effort.
                self._time_sync(sock)
                sock.settimeout(None)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                with self._sock_lock:
                    self._sock = sock
                self._connected_event.set()
                self._on_log(*M.connection_successful(self.host, self.port))
                self._on_link_state(True, f"{self.host}:{self.port}")
                attempt = 0
                self._read_until_closed(sock)
            except (OSError, ValueError) as exc:
                if not auth_denied:
                    self._on_log(*M.connection_lost(str(exc)))
            finally:
                self._connected_event.clear()
                self._on_link_state(False, "")
                with self._sock_lock:
                    if self._sock is sock:
                        self._sock = None
                if sock is not None:
                    try: sock.close()
                    except OSError: pass
            if self._stop_event.is_set():
                break
            if auth_denied:
                wait = TRIGGER_RECONNECT_MAX_SEC
            else:
                attempt += 1
                wait = min(TRIGGER_RECONNECT_INITIAL_SEC * (2 ** (attempt - 1)),
                           TRIGGER_RECONNECT_MAX_SEC)
            if self._stop_event.wait(timeout=wait):
                break

    def _send_session(self, sock):
        """Tell Windows which participant this connection is for, so it can
        stamp the study code on the time-sync rows it writes. One-way and
        best-effort — a failure here must not cost us the trigger link."""
        participant = self._participant
        try:
            sock.sendall(f"{PREFIX_SESSION}{participant}\n".encode("utf-8"))
        except OSError as exc:
            self._on_log(*M.participant_send_failed(str(exc)))
            return
        self._on_log(*(M.participant_sent(participant) if participant
                       else M.participant_missing()))

    def _time_sync(self, sock):
        """Round-trip clock sync with the Windows receiver. Windows computes
        and logs the offset; the TIMEOK reply carries the result back here for
        display. Best-effort — failures are logged but don't drop the link."""
        try:
            sock.settimeout(5.0)
            t1 = time.time()
            sock.sendall(f"{PREFIX_TIME}{t1:.6f}\n".encode("utf-8"))
            ack = _read_line(sock)
            t4 = time.time()
            if not ack.startswith(PREFIX_TIMEACK):
                self._on_log(*M.time_sync_failed(f"unexpected reply {ack!r}"))
                return
            sock.sendall(f"{PREFIX_TIMESYNC}{t1:.6f} {t4:.6f}\n".encode("utf-8"))
            ok = _read_line(sock)
            if not ok.startswith(PREFIX_TIMEOK):
                self._on_log(*M.time_sync_failed(f"unexpected confirmation {ok!r}"))
                return
            parts = ok[len(PREFIX_TIMEOK):].strip().split()
            if len(parts) >= 2:
                self._on_log(*M.time_synced(float(parts[0]), float(parts[1])))
        except (OSError, ValueError) as exc:
            self._on_log(*M.time_sync_failed(str(exc)))

    def _read_until_closed(self, sock):
        while not self._stop_event.is_set():
            try:
                data = sock.recv(1024)
            except OSError:
                return
            if not data:
                return


# ── MonitorWorker ────────────────────────────────────────────────────────────

class MonitorWorker:
    """Backend that the GUI talks to.

    Construction takes a ui_dispatch callable that runs a function on the
    UI thread (in Tk, this is `lambda fn, *args: root.after(0, fn, *args)`).
    All callbacks set on the worker are invoked via ui_dispatch.

    Callbacks (set by the App layer; default to no-op):
        on_status_message(level: str, message: str)
        on_targets_changed(list_of_names: list[str], active_name: str | None)
        on_drivers_changed(list_of_names: list[str], active_name: str | None)
        on_link_state(connected: bool, info: str)
        on_thresholds_changed(loc_vec3: list[float], ang_vec3: list[float])
    """

    def __init__(self, ui_dispatch):
        self._dispatch = ui_dispatch

        # User-settable state (call under lock)
        self._lock = threading.Lock()
        self._filepath = None
        self._trigger_host = None
        self._trigger_port = None
        self._trigger_token = None
        # Study code for this session; sent to Windows on connect so it can
        # stamp the time-sync log rows with it.
        self._participant = ""

        self._thr_loc = [DEFAULT_LOC_THR] * 3
        self._thr_ang = [DEFAULT_ANG_THR] * 3
        self._remind_every = DEFAULT_REMIND

        self._active_target_name = None
        self._active_target      = None     # dict {loc, mat}
        self._active_driver_name = None
        self._all_targets = {}              # name -> dict
        self._all_drivers = []              # list[str]

        # Auto-follow: when True, the active target tracks the most-recently
        # selected Target Selection (MNI) row in the file. A manual pick
        # (set_target) turns this off so the operator can pin one target.
        self._auto_follow        = True
        self._last_selected_name = None     # most-recent file selection seen

        # TMS triggering gate: when False, STATE:RED/GREEN are NOT sent to the
        # Windows receiver, so no SS keystrokes reach QTrack. Time-sync and
        # distance monitoring continue regardless. Pure gate — toggling never
        # itself sends a trigger; on re-enable, the next in↔out drift
        # transition fires normally. Defaults ON (current behavior).
        self._triggers_enabled   = True

        # Loop state
        self._reset_requested = False
        self._stop_event = threading.Event()
        self._poll_thread = None
        self._trigger_sender = None

        # Callbacks
        self.on_status_message      = lambda level, msg: None
        self.on_targets_changed     = lambda names, active: None
        self.on_drivers_changed     = lambda names, active: None
        self.on_link_state          = lambda connected, info: None
        self.on_thresholds_changed  = lambda loc, ang: None
        self.on_follow_changed      = lambda enabled: None
        self.on_triggers_changed    = lambda enabled: None

    # ── Setters (call from UI thread) ────────────────────────────────────────

    def configure(self, filepath, trigger_host, trigger_port, trigger_token,
                  participant=""):
        """Set the inputs collected in Setup. Call before start()."""
        with self._lock:
            self._filepath      = filepath
            self._trigger_host  = trigger_host
            self._trigger_port  = trigger_port
            self._trigger_token = trigger_token
            self._participant   = sanitize_participant(participant)

    def set_target(self, name):
        """Manually pin the active target by exact name. Turns auto-follow
        OFF so the file's selections no longer override the operator's pick.
        No-op if not in the pool."""
        with self._lock:
            if name in self._all_targets:
                self._active_target_name = name
                self._active_target      = self._all_targets[name]
                self._auto_follow        = False
                self._reset_requested    = True
                changed = True
            else:
                changed = False
        if changed:
            self._dispatch(self.on_status_message, M.INFO,
                           f"Target pinned to: {name} (auto-follow off)")
            self._dispatch(self.on_follow_changed, False)
            self._emit_targets()

    def set_auto_follow(self, enabled):
        """Enable/disable auto-follow. When enabling, immediately jump to the
        file's most-recently selected target (if one has been seen)."""
        enabled = bool(enabled)
        with self._lock:
            self._auto_follow = enabled
            followed = None
            if (enabled and self._last_selected_name is not None
                    and self._last_selected_name in self._all_targets
                    and self._active_target_name != self._last_selected_name):
                self._active_target_name = self._last_selected_name
                self._active_target      = self._all_targets[self._last_selected_name]
                self._reset_requested    = True
                followed = self._last_selected_name
        self._dispatch(self.on_status_message,
                       *(M.follow_enabled() if enabled else M.follow_disabled()))
        if followed is not None:
            self._dispatch(self.on_status_message, *M.target_followed(followed))
        self._dispatch(self.on_follow_changed, enabled)
        self._emit_targets()

    def set_triggers_enabled(self, enabled):
        """Enable/disable sending TMS triggers (STATE:RED/GREEN → SS keystrokes
        on the Windows side). Pure gate: toggling never itself sends a trigger,
        and internal in/out-of-range tracking, logging, and time-sync are all
        unaffected. On re-enable, the next in↔out transition fires normally."""
        enabled = bool(enabled)
        with self._lock:
            self._triggers_enabled = enabled
        self._dispatch(self.on_status_message,
                       *(M.triggers_enabled() if enabled else M.triggers_disabled()))
        self._dispatch(self.on_triggers_changed, enabled)

    def set_driver(self, name):
        with self._lock:
            if name in self._all_drivers:
                self._active_driver_name = name
                self._reset_requested    = True
                changed = True
            else:
                changed = False
        if changed:
            self._dispatch(self.on_status_message, M.INFO,
                           f"Crosshairs driver set to: {name}")
            self._emit_drivers()

    def set_linear_threshold(self, vec3):
        with self._lock:
            self._thr_loc = list(vec3)
            cur_loc = list(self._thr_loc); cur_ang = list(self._thr_ang)
        self._dispatch(self.on_thresholds_changed, cur_loc, cur_ang)

    def set_angular_threshold(self, vec3):
        with self._lock:
            self._thr_ang = list(vec3)
            cur_loc = list(self._thr_loc); cur_ang = list(self._thr_ang)
        self._dispatch(self.on_thresholds_changed, cur_loc, cur_ang)

    # ── Lifecycle ────────────────────────────────────────────────────────────

    def start(self):
        """Spawn the TriggerSender (if configured) and the poll thread.

        Returns True if it started, False if not configured. Trigger
        connection is established asynchronously; check is_connected()
        or wait via the on_link_state callback.
        """
        with self._lock:
            filepath = self._filepath
            host     = self._trigger_host
            port     = self._trigger_port
            token    = self._trigger_token
            who      = self._participant
        if not filepath:
            self._dispatch(self.on_status_message, M.ALERT,
                           "Cannot start: file path not set")
            return False
        if not (host and port and token):
            self._dispatch(self.on_status_message, M.ALERT,
                           "Cannot start: trigger destination not set "
                           "(IP/port/token)")
            return False

        self._stop_event.clear()
        self._trigger_sender = _TriggerSender(
            host=host, port=port, token=token, participant=who,
            on_log=lambda lvl, msg: self._dispatch(
                self.on_status_message, lvl, msg),
            on_link_state=lambda conn, info: self._dispatch(
                self.on_link_state, conn, info),
        )
        self._trigger_sender.start()
        self._poll_thread = threading.Thread(target=self._poll_loop, daemon=True)
        self._poll_thread.start()
        return True

    def stop(self):
        self._stop_event.set()
        if self._trigger_sender is not None:
            self._trigger_sender.stop()
            self._trigger_sender = None

    def is_link_connected(self):
        return self._trigger_sender is not None and self._trigger_sender.is_connected()

    # ── Poll loop (background thread) ────────────────────────────────────────

    def _poll_loop(self):
        file_pos      = 0
        last_pointer  = None
        in_exceedance = False
        checks_over   = 0
        last_status_time = 0.0
        file_announced = False

        while not self._stop_event.is_set():
            loop_start = time.monotonic()

            with self._lock:
                do_reset = self._reset_requested
                if do_reset:
                    self._reset_requested = False
                filepath = self._filepath

            if do_reset:
                last_pointer = None
                in_exceedance = False
                checks_over   = 0

            # ── 1. Read file ─────────────────────────────────────────────────
            if not os.path.exists(filepath):
                now = time.monotonic()
                if now - last_status_time >= STATUS_INTERVAL:
                    last_status_time = now
                    self._dispatch(self.on_status_message,
                                   *M.waiting_for_file(filepath))
                file_announced = False
            else:
                if not file_announced:
                    file_announced = True
                    self._dispatch(self.on_status_message, *M.file_found())
                try:
                    with open(filepath, encoding="utf-8", errors="replace") as fh:
                        # truncation guard
                        fh.seek(0, os.SEEK_END)
                        end = fh.tell()
                        if file_pos > end:
                            file_pos = 0
                        fh.seek(file_pos)
                        new_lines = fh.readlines()
                        file_pos = fh.tell()
                    pointer_from_batch = self._consume_lines(new_lines)
                    if pointer_from_batch is not None:
                        last_pointer = pointer_from_batch
                except OSError as exc:
                    self._dispatch(self.on_status_message, M.WARN,
                                   f"Read error: {exc}")

            # ── 2. Evaluate ──────────────────────────────────────────────────
            with self._lock:
                cur_target = self._active_target
                cur_loc    = list(self._thr_loc)
                cur_ang    = list(self._thr_ang)
                cur_rem    = self._remind_every
                cur_driver = self._active_driver_name
                cur_triggers = self._triggers_enabled

            if cur_target is None or cur_driver is None or last_pointer is None:
                now = time.monotonic()
                if now - last_status_time >= STATUS_INTERVAL:
                    last_status_time = now
                    if cur_target is None:
                        self._dispatch(self.on_status_message,
                                       *M.waiting_for_target())
                    elif cur_driver is None:
                        self._dispatch(self.on_status_message,
                                       *M.waiting_for_driver())
            else:
                d_xyz = _axis_offsets(cur_target["loc"], last_pointer["loc"])
                t_xyz = _per_axis_tilts(list(cur_target["mat"]),
                                         list(last_pointer["mat"]))
                # Build a list of every DoF that's outside its threshold.
                # 6 DoF total: 3 linear (|Δx|, |Δy|, |Δz|) and 3 angular
                # (per-axis tilt for X, Y, Z basis vectors).
                reasons = []
                for i, name in enumerate(AXIS_NAMES):
                    if d_xyz[i] > cur_loc[i]:
                        reasons.append(
                            f"loc-{name} {d_xyz[i]:.1f} > {cur_loc[i]:.1f} mm")
                for i, name in enumerate(AXIS_NAMES):
                    if t_xyz[i] > cur_ang[i]:
                        reasons.append(
                            f"ang-{name} {t_xyz[i]:.3f} > {cur_ang[i]:.3f} rad")

                # Trigger semantics (per spec):
                #   STOP stimulation  if ANY of the 6 DoF exceeds its threshold
                #   START stimulation only when ALL 6 DoF are within
                # `reasons` is non-empty iff any DoF is out; empty iff all 6
                # are within. So `over` directly encodes the stop condition.
                over = bool(reasons)
                if over:
                    if not in_exceedance:
                        in_exceedance = True
                        checks_over = 1
                        self._dispatch(self.on_status_message,
                                       *M.out_of_range(reasons))
                        if self._trigger_sender is not None and cur_triggers:
                            self._trigger_sender.send_state(STATE_RED)
                    else:
                        checks_over += 1
                        if checks_over % cur_rem == 0:
                            self._dispatch(self.on_status_message,
                                           *M.reminder_out_of_range(reasons,
                                                                    checks_over))
                else:
                    if in_exceedance:
                        in_exceedance = False
                        self._dispatch(self.on_status_message,
                                       *M.back_in_range(d_xyz, t_xyz))
                        if self._trigger_sender is not None and cur_triggers:
                            self._trigger_sender.send_state(STATE_GREEN)
                    else:
                        # Periodic "within threshold" heartbeat so the user
                        # sees something even when nothing changes.
                        now = time.monotonic()
                        if now - last_status_time >= STATUS_INTERVAL:
                            last_status_time = now
                            self._dispatch(self.on_status_message,
                                           *M.in_range(d_xyz, t_xyz))
                    checks_over = 0

            # ── 3. Sleep ────────────────────────────────────────────────────
            elapsed = time.monotonic() - loop_start
            self._stop_event.wait(timeout=max(0.0, POLL_INTERVAL - elapsed))

    def _consume_lines(self, new_lines):
        """Parse a batch of file lines and update internal state.

        Returns the latest Crosshairs Position dict for the active driver
        in MNI seen in this batch (or None if no matching row). The poll
        loop uses that as `last_pointer` for the evaluation step.
        """
        latest_pointer = None
        new_targets = []
        new_drivers = []
        batch_last_target = None    # most-recent Target Selection (MNI) in batch

        with self._lock:
            cur_driver = self._active_driver_name

        for raw in new_lines:
            parts = raw.rstrip().split("\t")
            row_type = parts[0].strip() if parts else ""
            if row_type == "Crosshairs Position":
                parsed = _parse_crosshairs_row(parts)
                if not parsed:
                    continue
                with self._lock:
                    if parsed["driver"] and parsed["driver"] not in self._all_drivers:
                        self._all_drivers.append(parsed["driver"])
                        new_drivers.append(parsed["driver"])
                if (parsed["driver"] == cur_driver
                        and parsed["coord_system"] == COORD_SYS):
                    latest_pointer = parsed
            elif row_type == "Target Selection":
                parsed = _parse_target_row(parts)
                # Null / non-MNI rows (e.g. "<No Selection>") are ignored;
                # the last real target keeps being tracked.
                if not parsed or parsed["coord_system"] != COORD_SYS:
                    continue
                with self._lock:
                    is_new = parsed["name"] not in self._all_targets
                    self._all_targets[parsed["name"]] = parsed
                    self._last_selected_name = parsed["name"]
                    if self._active_target_name == parsed["name"]:
                        # refresh geometry of the active target
                        self._active_target = parsed
                if is_new:
                    new_targets.append(parsed["name"])
                batch_last_target = parsed["name"]

        # ── Follow the file's most-recent selection ─────────────────────────
        # Switch when auto-follow is on, or unconditionally for the very first
        # selection (so monitoring can start even if follow is off and nothing
        # is pinned yet). A pinned target (follow off) is never overridden.
        if batch_last_target is not None:
            with self._lock:
                had_target = self._active_target_name is not None
                switch = ((self._auto_follow or self._active_target_name is None)
                          and self._active_target_name != batch_last_target)
                if switch:
                    self._active_target_name = batch_last_target
                    self._active_target      = self._all_targets[batch_last_target]
                    self._reset_requested    = True
            if switch:
                msg = M.target_followed if had_target else M.target_adopted
                self._dispatch(self.on_status_message, *msg(batch_last_target))
            self._emit_targets()
        elif new_targets:
            self._emit_targets()

        for name in new_drivers:
            with self._lock:
                if self._active_driver_name is None:
                    self._active_driver_name = name
                    self._reset_requested    = True
                    adopted = True
                else:
                    adopted = False
            if adopted:
                self._dispatch(self.on_status_message, *M.driver_adopted(name))
            self._emit_drivers()

        return latest_pointer

    # ── Emitters ─────────────────────────────────────────────────────────────

    def _emit_targets(self):
        with self._lock:
            names = list(self._all_targets.keys())
            active = self._active_target_name
        self._dispatch(self.on_targets_changed, names, active)

    def _emit_drivers(self):
        with self._lock:
            names = list(self._all_drivers)
            active = self._active_driver_name
        self._dispatch(self.on_drivers_changed, names, active)
