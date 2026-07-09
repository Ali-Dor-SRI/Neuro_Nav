#!/usr/bin/env python3
"""
alert_brainsight_v2.4.0.py
--------------------------
Real-time Brainsight drift monitor - version 2.4.0.

Adds (v2.3.0 -> v2.4.0):
  - TMS triggering toggle. Sending of STATE:RED / STATE:GREEN triggers (which
    drive the `ss` start/stop keystrokes on the Windows receiver) can now be
    switched off without dropping the link. With triggering OFF the monitor
    still connects, time-syncs, and reports drift in the terminal - it just
    never sends a trigger. Lets the operator run the app for time-sync +
    distance monitoring only. Enabled by default (current behavior).
      * `--no-triggers` starts with triggering OFF.
      * `set trigger on|off` toggles it live.
      * Pure gate: toggling never itself sends a trigger; on re-enable, the
        next in/out-of-range transition fires normally.

Adds (v2.2.0 -> v2.3.0):
  - Auto-follow target selection. The active (tracked) target now follows
    the target most recently selected in the Brainsight stream: every time
    a new `Target Selection` (MNI) row is written, the monitor switches to
    it and resets alert state. Enabled by default.
      * `--no-follow` starts with auto-follow off (classic behavior: pick a
        target from the menu and keep it pinned).
      * `set follow on|off` toggles it live.
      * `set target <n|name>` pins a target manually and turns follow OFF.
      * `<No Selection>` / null Target Selection rows are ignored - the last
        real target keeps being tracked.

Carried over from v2.2.0:
  - Optional TCP trigger output. With `--trigger-to HOST:PORT --token TOK`,
    the monitor maintains a connection to a Windows trigger receiver and
    sends STATE:RED on the in-range -> out-of-range transition,
    STATE:GREEN on the out -> in transition. The Windows receiver fires
    `ss`+Enter into the focused QTrack window on each STATE change.
    Reminders DO NOT fire triggers - only actual transitions.
  - Per-axis thresholds for both linear (mm) and angular (rad, per-axis tilt).
    `set loc 40` or `set loc 30 40 50`; same for `set ang`.

Usage
-----
    # Terminal-only (no trigger), auto-follow on:
    python3 alert_brainsight_v2.4.0.py "path/to/Streamed Info.txt"

    # Pin a target manually instead of following the file:
    python3 alert_brainsight_v2.4.0.py "path/to/Streamed Info.txt" --no-follow

    # With trigger to Windows receiver:
    python3 alert_brainsight_v2.4.0.py "path/to/Streamed Info.txt" \\
        --trigger-to 192.168.1.20:5050 --token 1234

    # Connected for time-sync + distance monitoring, but no SS triggers:
    python3 alert_brainsight_v2.4.0.py "path/to/Streamed Info.txt" \\
        --trigger-to 192.168.1.20:5050 --token 1234 --no-triggers

Terminal commands while running:
    list                          show available targets and drivers
    set target <n|name>           pin active target (turns auto-follow OFF)
    set driver <n|name>           switch active driver (resets alert state)
    set follow on|off             toggle auto-follow of the file's selection
    set trigger on|off            toggle sending SS triggers to Windows/QTrack
    set loc <mm>                  scalar linear threshold (all 3 axes)
    set loc <x> <y> <z>           per-axis linear thresholds (mm)
    set ang <rad>                 scalar angular threshold (all 3 axes)
    set ang <x> <y> <z>           per-axis angular thresholds (rad)
    set remind <n>                reminder every N checks
    status                        current settings (incl. trigger link state)
    quit / q                      stop
"""

import os
import math
import socket
import time
import threading
import argparse
from datetime import datetime


# ── Version & constants ────────────────────────────────────────────────────────

SCRIPT_VERSION   = "v2.4.0"

POLL_HZ          = 2
POLL_INTERVAL    = 1 / POLL_HZ
STATUS_INTERVAL  = 5.0

COORD_SYS        = "MNI"

DEFAULT_LOC_THR  = 40.0
DEFAULT_ANG_THR  = 0.20
DEFAULT_REMIND   = 100

AXIS_NAMES       = ("X", "Y", "Z")

# Trigger link defaults
TRIGGER_RECONNECT_INITIAL_SEC = 1
TRIGGER_RECONNECT_MAX_SEC     = 30
TRIGGER_AUTH_TIMEOUT_SEC      = 5.0
TRIGGER_LINE_LIMIT            = 256

# Protocol constants (inlined; trigger_app_AJ/common/protocol.py is the
# canonical definition).
PREFIX_AUTH  = "AUTH:"
PREFIX_STATE = "STATE:"
PREFIX_TIME     = "TIME:"
PREFIX_TIMEACK  = "TIMEACK:"
PREFIX_TIMESYNC = "TIMESYNC:"
PREFIX_TIMEOK   = "TIMEOK:"
AUTH_OK      = "AUTH:OK"
AUTH_DENIED  = "AUTH:DENIED"
STATE_GREEN  = "GREEN"
STATE_RED    = "RED"


# ── Shared state ───────────────────────────────────────────────────────────────

lock = threading.Lock()

thr_loc      = [DEFAULT_LOC_THR] * 3
thr_ang      = [DEFAULT_ANG_THR] * 3
remind_every = DEFAULT_REMIND

active_target_name = None
active_target      = None
active_driver_name = None

all_targets = {}
all_drivers = []

# Auto-follow: when True the active target tracks the most-recently selected
# Target Selection (MNI) row in the file. A manual `set target` turns it off.
auto_follow        = True
last_selected_name = None      # most-recent file selection seen

# TMS triggering gate: when False, STATE:RED/GREEN are not sent (no `ss`
# keystrokes reach QTrack). The link, time-sync, and drift reporting all
# continue. Pure gate - toggling never itself sends a trigger. Default ON.
triggers_enabled   = True

reset_requested = False

# Optional trigger sender (set in main() if --trigger-to provided)
trigger_sender = None


# ── Geometry ──────────────────────────────────────────────────────────────────

def axis_offsets(loc_ref, loc_cur):
    return (abs(loc_ref[0] - loc_cur[0]),
            abs(loc_ref[1] - loc_cur[1]),
            abs(loc_ref[2] - loc_cur[2]))


def per_axis_tilts(mat_ref, mat_cur):
    """Angle between the i-th basis axis of mat_ref and mat_cur (row-major 3x3)."""
    tilts = []
    for i in range(3):
        cx_r = mat_ref[0*3+i]; cy_r = mat_ref[1*3+i]; cz_r = mat_ref[2*3+i]
        cx_c = mat_cur[0*3+i]; cy_c = mat_cur[1*3+i]; cz_c = mat_cur[2*3+i]
        cos_th = max(-1.0, min(1.0, cx_r*cx_c + cy_r*cy_c + cz_r*cz_c))
        tilts.append(math.acos(cos_th))
    return tuple(tilts)


# ── File parsing ───────────────────────────────────────────────────────────────

def parse_floats(parts, indices):
    try:
        return tuple(float(parts[i]) for i in indices)
    except (IndexError, ValueError, TypeError):
        return None

def parse_target_row(parts):
    if len(parts) < 17:
        return None
    loc = parse_floats(parts, [5, 6, 7])
    mat = parse_floats(parts, list(range(8, 17)))
    if not loc or not mat:
        return None
    return {"name": parts[3].strip(), "coord_system": parts[4].strip(),
            "loc": loc, "mat": mat}

def parse_crosshairs_row(parts):
    if len(parts) < 17:
        return None
    loc = parse_floats(parts, [5, 6, 7])
    mat = parse_floats(parts, list(range(8, 17)))
    if not loc or not mat:
        return None
    return {"driver": parts[3].strip(), "coord_system": parts[4].strip(),
            "loc": loc, "mat": mat}


# ── Startup scan ───────────────────────────────────────────────────────────────

def scan_file(filepath):
    """Read the whole file once. Returns (targets, drivers, last_target_name)
    where last_target_name is the most-recent Target Selection (MNI) seen."""
    global all_targets, all_drivers
    targets = {}
    drivers = []
    last_target = None
    if os.path.exists(filepath):
        with open(filepath, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                parts    = raw.rstrip().split("\t")
                row_type = parts[0].strip() if parts else ""
                if row_type == "Target Selection":
                    parsed = parse_target_row(parts)
                    if parsed and parsed["coord_system"] == COORD_SYS:
                        targets[parsed["name"]] = parsed
                        last_target = parsed["name"]
                elif row_type == "Crosshairs Position":
                    if len(parts) > 3:
                        d = parts[3].strip()
                        if d and d not in drivers:
                            drivers.append(d)
    with lock:
        all_targets = dict(targets)
        all_drivers = list(drivers)
    return targets, drivers, last_target


# ── Interactive menu ──────────────────────────────────────────────────────────

def show_and_pick(label, options, current=None):
    print(f"\n  {label}:")
    for i, name in enumerate(options, 1):
        marker = "  <- current" if name == current else ""
        print(f"    {i}. {name}{marker}")
    print()
    while True:
        raw = input(f"  Select {label} [1-{len(options)}]: ").strip()
        if raw.isdigit():
            idx = int(raw) - 1
            if 0 <= idx < len(options):
                return options[idx]
        if raw in options:
            return raw
        print(f"  Enter a number between 1 and {len(options)}, or the exact name.")


def print_list():
    with lock:
        targets = list(all_targets.keys())
        drivers = list(all_drivers)
        cur_t   = active_target_name
        cur_d   = active_driver_name
        follow  = auto_follow
    print("\n  -- Available targets (Target Selection, MNI) --------------------")
    if not targets:
        print("    (none seen yet - waiting for stream)")
    for i, name in enumerate(targets, 1):
        marker = "  <- active" if name == cur_t else ""
        print(f"    {i}. {name}{marker}")
    follow_str = "ON (tracking the file's selection)" if follow else "OFF (pinned)"
    print(f"\n  Auto-follow: {follow_str}")
    print("\n  -- Available crosshairs drivers ---------------------------------")
    if not drivers:
        print("    (none seen yet - waiting for stream)")
    for i, name in enumerate(drivers, 1):
        marker = "  <- active" if name == cur_d else ""
        print(f"    {i}. {name}{marker}")
    print("\n  To change:  set target <number or name>  |  set driver <number or name>")
    print("              set follow on|off\n")


def fmt_thr(vec, unit, fmt="{:.2f}"):
    if vec[0] == vec[1] == vec[2]:
        return f"{fmt.format(vec[0])} {unit} (all axes)"
    return ("X=" + fmt.format(vec[0]) + ", "
            "Y=" + fmt.format(vec[1]) + ", "
            "Z=" + fmt.format(vec[2]) + " " + unit)


# ── Trigger sender ────────────────────────────────────────────────────────────

class TriggerSender:
    """Long-lived TCP client to a Windows trigger receiver.

    Runs a background thread that connects, authenticates, and stays
    connected; reconnects with exponential backoff if the link drops.
    send_state(state) is non-blocking and best-effort - if not currently
    connected, the call logs a dropped event and returns False.
    """

    def __init__(self, host, port, token, on_log=None):
        self.host  = host
        self.port  = port
        self.token = token
        self._on_log = on_log or print

        self._sock = None
        self._sock_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._connected_event = threading.Event()
        self._thread = None

    def start(self):
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._connection_loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop_event.set()
        with self._sock_lock:
            sock = self._sock
            self._sock = None
        if sock is not None:
            try: sock.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            try: sock.close()
            except OSError: pass

    def is_connected(self):
        return self._connected_event.is_set()

    def wait_until_connected(self, timeout=None):
        """Block until the link is up. Returns True if connected, False on timeout.
        Drops out immediately if .stop() has been called."""
        # Spin on short waits so .stop() cancels promptly even with timeout=None.
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
            self._on_log(f"  [trigger] refusing invalid state {state!r}")
            return False
        with self._sock_lock:
            sock = self._sock
        if sock is None:
            self._on_log(f"  [trigger] not connected; dropped STATE:{state}")
            return False
        try:
            sock.sendall(f"{PREFIX_STATE}{state}\n".encode("utf-8"))
            self._on_log(f"  [trigger] -> STATE:{state}")
            return True
        except OSError as exc:
            self._on_log(f"  [trigger] send failed: {exc}")
            return False

    def _time_sync(self, sock):
        """Round-trip clock sync with the Windows receiver (NTP-style).

        Sends our clock, reads Windows' TIMEACK, replies with our two
        timestamps so Windows can compute the offset and log it, then reads
        the TIMEOK confirmation (which carries the result back for display).
        Best-effort: any failure is logged and swallowed so the trigger link
        proceeds regardless.
        """
        try:
            sock.settimeout(TRIGGER_AUTH_TIMEOUT_SEC)
            t1 = time.time()
            sock.sendall(f"{PREFIX_TIME}{t1:.6f}\n".encode("utf-8"))
            ack = _read_line(sock, limit=TRIGGER_LINE_LIMIT)
            t4 = time.time()
            if not ack.startswith(PREFIX_TIMEACK):
                self._on_log(f"  [time-sync] unexpected reply: {ack!r}")
                return
            # We don't need t2/t3 on the Mac — Windows computes the delta.
            sock.sendall(f"{PREFIX_TIMESYNC}{t1:.6f} {t4:.6f}\n".encode("utf-8"))
            ok = _read_line(sock, limit=TRIGGER_LINE_LIMIT)
            if not ok.startswith(PREFIX_TIMEOK):
                self._on_log(f"  [time-sync] unexpected confirmation: {ok!r}")
                return
            parts = ok[len(PREFIX_TIMEOK):].strip().split()
            if len(parts) >= 2:
                offset, delay = float(parts[0]), float(parts[1])
                sign = "ahead of" if offset >= 0 else "behind"
                self._on_log(
                    f"  [time-sync] OK — Windows logged our timestamp; "
                    f"Windows clock is {abs(offset) * 1000.0:.1f} ms {sign} the Mac "
                    f"(delta {offset:+.6f}s, rtt {delay * 1000.0:.1f} ms)")
            else:
                self._on_log("  [time-sync] OK — Windows logged our timestamp")
        except (OSError, ValueError) as exc:
            self._on_log(f"  [time-sync] failed (continuing without sync): {exc}")

    def _connection_loop(self):
        attempt = 0
        while not self._stop_event.is_set():
            sock = None
            auth_denied = False
            try:
                self._on_log(f"  [trigger] connecting to {self.host}:{self.port}...")
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(5.0)
                sock.connect((self.host, self.port))
                sock.sendall(f"{PREFIX_AUTH}{self.token}\n".encode("utf-8"))

                # Read AUTH:OK / AUTH:DENIED
                first = _read_line(sock, limit=TRIGGER_LINE_LIMIT)
                if first != AUTH_OK:
                    if first == AUTH_DENIED:
                        auth_denied = True
                        self._on_log("  [trigger] AUTH DENIED - check the token")
                    else:
                        self._on_log(f"  [trigger] unexpected response: {first!r}")
                    raise OSError("authentication failed")

                # Time-sync handshake on the freshly-authed socket, before any
                # STATE traffic can interleave. Best-effort: a sync failure is
                # logged but must not abort the trigger link.
                self._time_sync(sock)

                sock.settimeout(None)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                with self._sock_lock:
                    self._sock = sock
                self._connected_event.set()
                self._on_log("  [trigger] connected to receiver")
                attempt = 0

                self._read_until_closed(sock)
            except (OSError, ValueError) as exc:
                if not auth_denied:
                    self._on_log(f"  [trigger] connect error: {exc}")
            finally:
                self._connected_event.clear()
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
            self._on_log(f"  [trigger] reconnecting in {wait}s...")
            if self._stop_event.wait(timeout=wait):
                break

    def _read_until_closed(self, sock):
        while not self._stop_event.is_set():
            try:
                data = sock.recv(1024)
            except OSError:
                return
            if not data:
                self._on_log("  [trigger] receiver closed connection")
                return
            # Receiver shouldn't say anything; log if it does.
            msg = data.decode("utf-8", errors="replace").strip()
            if msg:
                self._on_log(f"  [trigger] <- {msg!r}")


def _read_line(sock, limit):
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


# ── Input thread ───────────────────────────────────────────────────────────────

def input_thread():
    global thr_loc, thr_ang, remind_every
    global active_target_name, active_target, active_driver_name
    global auto_follow, last_selected_name
    global triggers_enabled
    global reset_requested

    help_text = (
        "  Commands:\n"
        "    list                          show available targets and drivers\n"
        "    set target <n|name>           pin active target (turns follow OFF)\n"
        "    set driver <n|name>           switch driver (resets alert state)\n"
        "    set follow on|off             toggle auto-follow of file selection\n"
        "    set trigger on|off            toggle SS triggers to Windows/QTrack\n"
        "    set loc <mm>                  scalar linear threshold (all 3 axes)\n"
        "    set loc <x> <y> <z>           per-axis linear thresholds (mm)\n"
        "    set ang <rad>                 scalar angular threshold (all 3 axes)\n"
        "    set ang <x> <y> <z>           per-axis angular thresholds (rad)\n"
        "    set remind <n>                reminder every N checks\n"
        "    status                        current settings\n"
        "    quit / q                      stop\n"
    )

    while True:
        try:
            line = input()
        except EOFError:
            break
        parts = line.strip().split()
        if not parts:
            continue
        cmd = parts[0].lower()

        if cmd in ("quit", "q", "exit"):
            print("Stopping.")
            if trigger_sender is not None:
                trigger_sender.stop()
            os._exit(0)

        elif cmd == "list":
            print_list()

        elif cmd == "status":
            with lock:
                link = "n/a (no --trigger-to)"
                if trigger_sender is not None:
                    link = ("connected" if trigger_sender.is_connected()
                            else "disconnected")
                follow_str = "on" if auto_follow else "off"
                trig_str = "on" if triggers_enabled else "OFF (monitoring only)"
                print(
                    f"  [status]\n"
                    f"    target  : {active_target_name}\n"
                    f"    follow  : {follow_str}\n"
                    f"    driver  : {active_driver_name}\n"
                    f"    loc thr : {fmt_thr(thr_loc, 'mm', '{:.1f}')}\n"
                    f"    ang thr : {fmt_thr(thr_ang, 'rad')}\n"
                    f"    remind  : every {remind_every} checks\n"
                    f"    trigger : {link}\n"
                    f"    SS keys : {trig_str}\n"
                )

        elif cmd in ("help", "?"):
            print(help_text)

        elif cmd == "set" and len(parts) >= 3:
            key       = parts[1].lower()
            value_toks = parts[2:]
            val_str    = " ".join(value_toks)

            if key == "target":
                with lock:
                    names = list(all_targets.keys())
                chosen = _resolve_option(val_str, names, "target")
                if chosen:
                    with lock:
                        active_target_name = chosen
                        active_target      = all_targets[chosen]
                        auto_follow        = False
                        reset_requested    = True
                    print(f"  [set]  target pinned -> '{chosen}'  "
                          f"(auto-follow off, alert state reset)")

            elif key == "driver":
                with lock:
                    names = list(all_drivers)
                chosen = _resolve_option(val_str, names, "driver")
                if chosen:
                    with lock:
                        active_driver_name = chosen
                        reset_requested    = True
                    print(f"  [set]  driver -> '{chosen}'  (alert state reset)")

            elif key == "follow":
                v = val_str.strip().lower()
                if v in ("on", "true", "1", "yes"):
                    with lock:
                        auto_follow = True
                        switched = None
                        if (last_selected_name is not None
                                and last_selected_name in all_targets
                                and active_target_name != last_selected_name):
                            active_target_name = last_selected_name
                            active_target      = all_targets[last_selected_name]
                            reset_requested    = True
                            switched = last_selected_name
                    print("  [set]  auto-follow ON - tracking the file's "
                          "most-recent target selection")
                    if switched:
                        print(f"  [set]  now tracking '{switched}' "
                              f"(alert state reset)")
                elif v in ("off", "false", "0", "no"):
                    with lock:
                        auto_follow = False
                    print("  [set]  auto-follow OFF - target pinned manually")
                else:
                    print("  [!] usage: set follow on|off")

            elif key in ("trigger", "triggers"):
                v = val_str.strip().lower()
                if v in ("on", "true", "1", "yes"):
                    with lock:
                        triggers_enabled = True
                    print("  [set]  TMS triggering ON - sending SS start/stop "
                          "to QTrack on drift transitions")
                elif v in ("off", "false", "0", "no"):
                    with lock:
                        triggers_enabled = False
                    print("  [set]  TMS triggering OFF - monitoring + time-sync "
                          "only; no SS sent to QTrack")
                else:
                    print("  [!] usage: set trigger on|off")

            elif key == "loc":
                vec = _parse_threshold_vec(value_toks, "loc")
                if vec is not None:
                    with lock:
                        thr_loc = vec
                    print(f"  [set]  linear threshold -> {fmt_thr(vec, 'mm', '{:.1f}')}")

            elif key == "ang":
                vec = _parse_threshold_vec(value_toks, "ang")
                if vec is not None:
                    with lock:
                        thr_ang = vec
                    print(f"  [set]  angular threshold -> {fmt_thr(vec, 'rad')}")

            elif key == "remind":
                try:
                    val = max(1, int(float(val_str)))
                    with lock:
                        remind_every = val
                    print(f"  [set]  reminder every {val} checks (~{val/POLL_HZ:.0f} s)")
                except ValueError:
                    print(f"  [!] '{val_str}' is not a number")

            else:
                print(f"  [?] unknown key '{key}'\n{help_text}")

        else:
            print(f"  [?] unknown command\n{help_text}")


def _parse_threshold_vec(tokens, label):
    if len(tokens) == 1:
        try: v = float(tokens[0])
        except ValueError:
            print(f"  [!] '{tokens[0]}' is not a number")
            return None
        return [v, v, v]
    if len(tokens) == 3:
        try: return [float(t) for t in tokens]
        except ValueError:
            print(f"  [!] expected 3 numbers for per-axis {label}, "
                  f"got: {' '.join(tokens)}")
            return None
    print(f"  [!] set {label} takes 1 value (scalar) or 3 values "
          f"(per-axis X Y Z); got {len(tokens)}")
    return None


def _resolve_option(val_str, options, label):
    val_str = val_str.strip()
    if not options:
        print(f"  [!] no {label}s seen yet - type 'list' once the stream provides one.")
        return None
    if val_str.isdigit():
        idx = int(val_str) - 1
        if 0 <= idx < len(options):
            return options[idx]
        print(f"  [!] '{val_str}' is out of range (1-{len(options)})")
        return None
    if val_str in options:
        return val_str
    print(f"  [!] '{val_str}' not found. Type 'list' to see options.")
    return None


# ── Monitoring loop ────────────────────────────────────────────────────────────

def ts():
    return datetime.now().strftime("%H:%M:%S")


def monitor_loop(filepath):
    global reset_requested
    global active_target_name, active_target, active_driver_name
    global last_selected_name

    file_pos      = 0
    last_pointer  = None
    in_exceedance    = False
    checks_over      = 0
    last_status_time = 0.0

    while True:
        loop_start = time.monotonic()

        with lock:
            do_reset = reset_requested
            if do_reset:
                reset_requested = False
        if do_reset:
            last_pointer  = None
            in_exceedance = False
            checks_over   = 0

        if not os.path.exists(filepath):
            now = time.monotonic()
            if now - last_status_time >= STATUS_INTERVAL:
                last_status_time = now
                print(f"[{ts()}]  File not found: {filepath}")
        else:
            try:
                with open(filepath, encoding="utf-8", errors="replace") as fh:
                    fh.seek(0, os.SEEK_END)
                    end = fh.tell()
                    if file_pos > end:
                        file_pos = 0
                    fh.seek(file_pos)
                    new_lines = fh.readlines()
                    file_pos  = fh.tell()

                with lock:
                    cur_driver = active_driver_name

                newly_seen_targets = []
                newly_seen_drivers = []
                batch_last_target  = None   # most-recent Target Selection in batch

                for raw in new_lines:
                    parts    = raw.rstrip().split("\t")
                    row_type = parts[0].strip() if parts else ""

                    if row_type == "Crosshairs Position":
                        parsed = parse_crosshairs_row(parts)
                        if not parsed:
                            continue
                        with lock:
                            if parsed["driver"] and parsed["driver"] not in all_drivers:
                                all_drivers.append(parsed["driver"])
                                newly_seen_drivers.append(parsed["driver"])
                        if (parsed["driver"] == cur_driver
                                and parsed["coord_system"] == COORD_SYS):
                            last_pointer = parsed

                    elif row_type == "Target Selection":
                        parsed = parse_target_row(parts)
                        # Null / non-MNI rows (e.g. "<No Selection>") are
                        # ignored; the last real target keeps being tracked.
                        if not parsed or parsed["coord_system"] != COORD_SYS:
                            continue
                        with lock:
                            is_new = parsed["name"] not in all_targets
                            all_targets[parsed["name"]] = parsed
                            last_selected_name = parsed["name"]
                            if active_target_name == parsed["name"]:
                                active_target = parsed
                        if is_new:
                            newly_seen_targets.append(parsed["name"])
                        batch_last_target = parsed["name"]

                # ── Follow the file's most-recent selection ──────────────────
                # Switch when auto-follow is on, or unconditionally for the
                # very first selection (so monitoring can start even with
                # follow off and nothing pinned). A pinned target is never
                # overridden while follow is off.
                if batch_last_target is not None:
                    with lock:
                        had_target = active_target_name is not None
                        do_switch = ((auto_follow or active_target_name is None)
                                     and active_target_name != batch_last_target)
                        if do_switch:
                            active_target_name = batch_last_target
                            active_target      = all_targets[batch_last_target]
                            reset_requested    = True
                    if do_switch:
                        if had_target:
                            print(f"[{ts()}]  -> following file selection: "
                                  f"target '{batch_last_target}' (alert state reset)")
                        else:
                            print(f"[{ts()}]  + target '{batch_last_target}' "
                                  f"auto-selected (alert state reset)")

                # Announce newly-discovered targets (pool/dropdown only;
                # following above already handled any active switch).
                for name in newly_seen_targets:
                    if name != batch_last_target:
                        print(f"[{ts()}]  + discovered target '{name}' "
                              f"(use 'set target' to pin it)")

                for name in newly_seen_drivers:
                    with lock:
                        if active_driver_name is None:
                            active_driver_name = name
                            reset_requested    = True
                            auto = True
                        else:
                            auto = False
                    if auto:
                        print(f"[{ts()}]  + discovered driver '{name}' - auto-selected")
                    else:
                        print(f"[{ts()}]  + discovered driver '{name}' "
                              f"(use 'set driver' to switch)")

            except OSError as e:
                print(f"[{ts()}]  Read error: {e}")

        with lock:
            cur_target = active_target
            cur_loc    = list(thr_loc)
            cur_ang    = list(thr_ang)
            cur_rem    = remind_every
            cur_driver = active_driver_name
            cur_triggers = triggers_enabled

        if cur_target is None or cur_driver is None or last_pointer is None:
            now = time.monotonic()
            if now - last_status_time >= STATUS_INTERVAL:
                last_status_time = now
                if cur_target is None:
                    print(f"[{ts()}]  Waiting for target selection... "
                          f"(no Target Selection row in stream yet)")
                elif cur_driver is None:
                    print(f"[{ts()}]  Waiting for driver selection... "
                          f"(no Crosshairs Position row in stream yet)")
                else:
                    print(f"[{ts()}]  Waiting for '{cur_driver}' crosshairs data...")
        else:
            d_xyz = axis_offsets(cur_target["loc"], last_pointer["loc"])
            t_xyz = per_axis_tilts(list(cur_target["mat"]),
                                   list(last_pointer["mat"]))

            reasons = []
            for i, name in enumerate(AXIS_NAMES):
                if d_xyz[i] > cur_loc[i]:
                    reasons.append(
                        f"loc-{name} {d_xyz[i]:.1f} > {cur_loc[i]:.1f} mm")
            for i, name in enumerate(AXIS_NAMES):
                if t_xyz[i] > cur_ang[i]:
                    reasons.append(
                        f"ang-{name} {t_xyz[i]:.3f} > {cur_ang[i]:.3f} rad")

            over = bool(reasons)

            if over:
                reason_str = "  |  ".join(reasons)
                if not in_exceedance:
                    print(f"[{ts()}]  [ALERT]    {reason_str}")
                    in_exceedance = True
                    checks_over   = 1
                    # Trigger transition: in-range -> out-of-range
                    if trigger_sender is not None and cur_triggers:
                        trigger_sender.send_state(STATE_RED)
                else:
                    checks_over += 1
                    if checks_over % cur_rem == 0:
                        print(f"[{ts()}]  [REMINDER] {reason_str}  "
                              f"(check #{checks_over})")
                        # NB: reminders do NOT fire triggers.
            else:
                if in_exceedance:
                    print(f"[{ts()}]  [OK] Back in range   "
                          f"loc=({d_xyz[0]:.1f}, {d_xyz[1]:.1f}, {d_xyz[2]:.1f}) mm  "
                          f"ang=({t_xyz[0]:.3f}, {t_xyz[1]:.3f}, {t_xyz[2]:.3f}) rad")
                    # Trigger transition: out -> in-range
                    if trigger_sender is not None and cur_triggers:
                        trigger_sender.send_state(STATE_GREEN)
                in_exceedance = False
                checks_over   = 0

        elapsed = time.monotonic() - loop_start
        time.sleep(max(0.0, POLL_INTERVAL - elapsed))


# ── Entry point ───────────────────────────────────────────────────────────────

def _parse_trigger_to(value):
    """Parse 'host:port' into (host, port). Raises SystemExit on bad input."""
    if ":" not in value:
        raise SystemExit(f"--trigger-to expects HOST:PORT, got {value!r}")
    host, _, port_str = value.rpartition(":")
    try:
        port = int(port_str)
    except ValueError:
        raise SystemExit(f"--trigger-to port must be an integer, got {port_str!r}")
    if not host:
        raise SystemExit(f"--trigger-to host is empty in {value!r}")
    return host, port


def main():
    global thr_loc, thr_ang
    global active_target_name, active_target, active_driver_name
    global auto_follow, last_selected_name
    global triggers_enabled
    global trigger_sender

    parser = argparse.ArgumentParser(
        description=f"Brainsight drift monitor + trigger sender {SCRIPT_VERSION}",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("file", help="Path to the Brainsight .txt file")
    parser.add_argument("--loc", type=float, default=DEFAULT_LOC_THR,
                        help=f"Linear threshold mm - all 3 axes (default {DEFAULT_LOC_THR}). "
                             f"Use 'set loc x y z' at the REPL for per-axis values.")
    parser.add_argument("--ang", type=float, default=DEFAULT_ANG_THR,
                        help=f"Angular threshold rad - all 3 axes (default {DEFAULT_ANG_THR}). "
                             f"Use 'set ang x y z' at the REPL for per-axis values.")
    parser.add_argument("--no-follow", dest="follow", action="store_false",
                        help="Disable auto-follow: pick a target from the menu "
                             "and keep it pinned (classic v2.2.0 behavior). "
                             "Auto-follow is ON by default.")
    parser.set_defaults(follow=True)
    parser.add_argument("--no-triggers", dest="triggers", action="store_false",
                        help="Start with TMS triggering OFF: still connect, "
                             "time-sync, and monitor drift, but do NOT send "
                             "STATE:RED/GREEN (no SS keystrokes reach QTrack). "
                             "Toggle live with 'set trigger on|off'. Triggering "
                             "is ON by default.")
    parser.set_defaults(triggers=True)
    parser.add_argument("--trigger-to", default=None, metavar="HOST:PORT",
                        help="Send STATE: triggers to a Windows receiver at HOST:PORT. "
                             "If omitted, alerts are terminal-only.")
    parser.add_argument("--token", default=None,
                        help="Auth token required by the Windows receiver. "
                             "Required when --trigger-to is set.")
    args = parser.parse_args()

    with lock:
        thr_loc = [args.loc] * 3
        thr_ang = [args.ang] * 3
        auto_follow = args.follow
        triggers_enabled = args.triggers

    filepath = args.file

    print(f"\nBrainsight drift monitor  [{SCRIPT_VERSION}]")
    print(f"  File       : {filepath}")
    print(f"  Rate       : {POLL_HZ} Hz")
    print(f"  loc thr    : {fmt_thr(thr_loc, 'mm', '{:.1f}')}")
    print(f"  ang thr    : {fmt_thr(thr_ang, 'rad')}")
    print(f"  Auto-follow: {'on' if args.follow else 'off'}")
    print(f"  Triggering : {'on' if args.triggers else 'OFF (monitoring only)'}")

    # ── Trigger sender (optional) ────────────────────────────────────────────
    # Establish the trigger link FIRST, before looking for the Brainsight
    # file. The sender's background thread surfaces refused / bad-token /
    # unreachable-host errors via its own log lines, so any
    # misconfiguration shows up immediately instead of being hidden
    # behind a "Waiting for file..." loop.
    if args.trigger_to is not None:
        if not args.token:
            raise SystemExit("--trigger-to requires --token")
        host, port = _parse_trigger_to(args.trigger_to)
        print(f"  Trigger to : {host}:{port} (with token)")
        trigger_sender = TriggerSender(host=host, port=port, token=args.token)
        trigger_sender.start()

        print(f"\n  Establishing trigger connection to {host}:{port} ...")
        print(f"  (Ctrl+C to abort)")
        try:
            while not trigger_sender.wait_until_connected(timeout=STATUS_INTERVAL):
                print(f"  ... still waiting for receiver at {host}:{port}")
        except KeyboardInterrupt:
            print("\n  Aborted by user.")
            trigger_sender.stop()
            raise SystemExit(1)
        print(f"  Trigger link established.\n")
    elif args.token:
        print("  [i] --token provided but no --trigger-to; ignored.")

    # ── Wait for file ─────────────────────────────────────────────────────────
    _last_file_msg = 0.0
    while not os.path.exists(filepath):
        now = time.monotonic()
        if now - _last_file_msg >= STATUS_INTERVAL:
            _last_file_msg = now
            print(f"  Waiting for file to appear...  (Ctrl+C to cancel)")
        time.sleep(0.5)

    # ── Scan file (initial) ───────────────────────────────────────────────────
    print("\n  Scanning file for available targets and drivers...")
    initial_targets, initial_drivers, initial_last_target = scan_file(filepath)
    with lock:
        last_selected_name = initial_last_target

    target_names = list(initial_targets.keys())
    if args.follow:
        # Auto-follow: adopt the file's most-recent selection; the monitor
        # loop will keep switching as new selections are written.
        if initial_last_target is not None:
            with lock:
                active_target_name = initial_last_target
                active_target      = initial_targets[initial_last_target]
            print(f"  Auto-follow ON - tracking the file's most-recent "
                  f"target: '{initial_last_target}'")
            print(f"  (use 'set target <n|name>' to pin one, or 'set follow off')")
        else:
            print("  Auto-follow ON - no Target Selection (MNI) yet; "
                  "will track the next one to appear.")
    else:
        if target_names:
            chosen_target = show_and_pick("target", target_names)
            with lock:
                active_target_name = chosen_target
                active_target      = initial_targets[chosen_target]
        else:
            print("  [i] No Target Selection rows (MNI) in the file yet.")
            print("      The first one to appear in the stream will be auto-selected.")

    if initial_drivers:
        chosen_driver = show_and_pick("crosshairs driver", initial_drivers)
        with lock:
            active_driver_name = chosen_driver
    else:
        print("  [i] No Crosshairs Position rows in the file yet.")
        print("      The first driver to appear in the stream will be auto-selected.")

    print(f"\n  -- Starting monitor ---------------------------------------------")
    print(f"    Target  : {active_target_name}")
    print(f"    Follow  : {'on' if args.follow else 'off'}")
    print(f"    Driver  : {active_driver_name}")
    print(f"    loc thr : {fmt_thr(thr_loc, 'mm', '{:.1f}')}")
    print(f"    ang thr : {fmt_thr(thr_ang, 'rad')}")
    print(f"    Remind  : every {remind_every} checks (~{remind_every/POLL_HZ:.0f} s)")
    if trigger_sender is not None:
        if triggers_enabled:
            print(f"    Trigger : sending SS to receiver on transitions")
        else:
            print(f"    Trigger : link up; SS triggers OFF (monitoring only)")
    print(f"    Type 'list', 'status', 'set ...', or 'quit'\n")

    t = threading.Thread(target=input_thread, daemon=True)
    t.start()

    try:
        monitor_loop(filepath)
    finally:
        if trigger_sender is not None:
            trigger_sender.stop()


if __name__ == "__main__":
    main()
