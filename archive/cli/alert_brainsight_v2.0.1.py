#!/usr/bin/env python3
"""
alert_brainsight_v2.0.1.py
--------------------------
Real-time Brainsight drift monitor — version 2.0.1.

Bugfixes from v2:
  - Targets and drivers are now discovered CONTINUOUSLY from the live stream,
    not only at startup. v2 scanned once and froze the option lists, so if
    the file had no Target Selection rows yet (typical at session start) the
    monitor was permanently stuck in "Waiting for target selection…" and
    threshold changes never had any visible effect (because the evaluation
    branch needs an active target+driver+pointer to run at all).
  - If no target/driver is active yet, the FIRST one to appear in the stream
    is auto-selected and announced. Subsequent ones are added to the option
    list so `list` / `set target <n|name>` / `set driver <n|name>` work for
    options that were not present at startup.
  - The input thread now reads live shared option pools instead of a frozen
    snapshot captured at thread start.
  - File-truncation guard: if the file shrinks (rotated/restarted), the read
    pointer resets to 0 instead of seeking past EOF and silently losing data.

Usage
-----
    python3 alert_brainsight_v2.0.1.py "path/to/Session Streamed Info.txt"
    python3 alert_brainsight_v2.0.1.py "path/to/file.txt" --loc 50 --ang 0.3

Terminal commands while running:
    list                   show available targets and drivers
    set target <n|name>    switch active target,  e.g. set target 1
    set driver <n|name>    switch active driver,  e.g. set driver Pointer
    set loc    <mm>        change linear threshold
    set ang    <rad>       change angular threshold
    set remind <n>         reminder every N checks
    status                 print current settings and last measurement
    quit / q               stop
"""

import os
import math
import time
import threading
import argparse
from datetime import datetime


# ── Version & constants ────────────────────────────────────────────────────────

SCRIPT_VERSION   = "v2.0.1"

POLL_HZ          = 2           # checks per second
POLL_INTERVAL    = 1 / POLL_HZ
STATUS_INTERVAL  = 5.0         # seconds between repeated waiting/status messages

COORD_SYS        = "MNI"

DEFAULT_LOC_THR  = 40.0        # mm
DEFAULT_ANG_THR  = 0.20        # radians (~11.5°)
DEFAULT_REMIND   = 100         # remind every N checks while out of range


# ── Shared state ───────────────────────────────────────────────────────────────

lock = threading.Lock()

# Thresholds (editable at runtime)
thr_loc      = DEFAULT_LOC_THR
thr_ang      = DEFAULT_ANG_THR
remind_every = DEFAULT_REMIND

# Active selection (editable at runtime)
active_target_name = None   # str
active_target      = None   # dict {loc, mat}
active_driver_name = None   # str

# Live option pools — mutated by monitor_loop as new rows arrive, read by
# input_thread. Always access under `lock`.
all_targets = {}            # name → {name, coord_system, loc, mat}
all_drivers = []            # ordered unique list of driver names

# Signal from input thread → monitoring loop
reset_requested = False     # True when target/driver just changed


# ── Geometry ──────────────────────────────────────────────────────────────────

def euclidean(a, b):
    return math.sqrt(sum((ai - bi) ** 2 for ai, bi in zip(a, b)))

def mat_mul_T(A, B):
    """Compute A^T @ B for two 3x3 row-major flat lists."""
    result = [0.0] * 9
    for i in range(3):
        for j in range(3):
            result[i * 3 + j] = sum(A[k * 3 + i] * B[k * 3 + j] for k in range(3))
    return result

def rotation_angle(mat_ref, mat_cur):
    """Geodesic angle (rad) between two rotation matrices."""
    R_rel  = mat_mul_T(mat_ref, mat_cur)
    trace  = R_rel[0] + R_rel[4] + R_rel[8]
    cos_th = max(-1.0, min(1.0, (trace - 1.0) / 2.0))
    return math.acos(cos_th)


# ── File parsing ───────────────────────────────────────────────────────────────

def parse_floats(parts, indices):
    try:
        return tuple(float(parts[i]) for i in indices)
    except (IndexError, ValueError, TypeError):
        return None

def parse_target_row(parts):
    """Return dict or None from a 'Target Selection' split line."""
    if len(parts) < 17:
        return None
    loc = parse_floats(parts, [5, 6, 7])
    mat = parse_floats(parts, list(range(8, 17)))
    if not loc or not mat:
        return None
    return {
        "name":         parts[3].strip(),
        "coord_system": parts[4].strip(),
        "loc":          loc,
        "mat":          mat,
    }

def parse_crosshairs_row(parts):
    """Return dict or None from a 'Crosshairs Position' split line."""
    if len(parts) < 17:
        return None
    loc = parse_floats(parts, [5, 6, 7])
    mat = parse_floats(parts, list(range(8, 17)))
    if not loc or not mat:
        return None
    return {
        "driver":       parts[3].strip(),
        "coord_system": parts[4].strip(),
        "loc":          loc,
        "mat":          mat,
    }


# ── Startup scan ───────────────────────────────────────────────────────────────

def scan_file(filepath):
    """
    Read the file once and populate the global option pools.
    Returns (targets_dict, drivers_list) for the startup menus; the globals
    are the source of truth for the live loop and input thread.
    """
    global all_targets, all_drivers
    targets = {}
    drivers = []

    if os.path.exists(filepath):
        with open(filepath, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                parts    = raw.rstrip().split("\t")
                row_type = parts[0].strip() if parts else ""

                if row_type == "Target Selection":
                    parsed = parse_target_row(parts)
                    if parsed and parsed["coord_system"] == COORD_SYS:
                        targets[parsed["name"]] = parsed

                elif row_type == "Crosshairs Position":
                    if len(parts) > 3:
                        d = parts[3].strip()
                        if d and d not in drivers:
                            drivers.append(d)

    with lock:
        all_targets = dict(targets)
        all_drivers = list(drivers)

    return targets, drivers


# ── Interactive numbered menu (used at startup and via 'list') ─────────────────

def show_and_pick(label, options, current=None):
    """Blocking numbered-menu prompt. Returns the chosen string."""
    print(f"\n  {label}:")
    for i, name in enumerate(options, 1):
        marker = "  ← current" if name == current else ""
        print(f"    {i}. {name}{marker}")
    print()
    while True:
        raw = input(f"  Select {label} [1–{len(options)}]: ").strip()
        if raw.isdigit():
            idx = int(raw) - 1
            if 0 <= idx < len(options):
                return options[idx]
        if raw in options:
            return raw
        print(f"  Enter a number between 1 and {len(options)}, or the exact name.")


def print_list():
    """Print live available options (used mid-session)."""
    with lock:
        targets = list(all_targets.keys())
        drivers = list(all_drivers)
        cur_t   = active_target_name
        cur_d   = active_driver_name

    print("\n  ── Available targets (Target Selection, MNI) ─────────────────")
    if not targets:
        print("    (none seen yet — waiting for stream)")
    for i, name in enumerate(targets, 1):
        marker = "  ← active" if name == cur_t else ""
        print(f"    {i}. {name}{marker}")

    print("\n  ── Available crosshairs drivers ──────────────────────────────")
    if not drivers:
        print("    (none seen yet — waiting for stream)")
    for i, name in enumerate(drivers, 1):
        marker = "  ← active" if name == cur_d else ""
        print(f"    {i}. {name}{marker}")

    print("\n  To change:  set target <number or name>  |  set driver <number or name>\n")


# ── Input thread ───────────────────────────────────────────────────────────────

def input_thread():
    """Daemon thread: reads commands from stdin. Reads live option pools."""
    global thr_loc, thr_ang, remind_every
    global active_target_name, active_target, active_driver_name
    global reset_requested

    help_text = (
        "  Commands:\n"
        "    list                  show available targets and drivers\n"
        "    set target <n|name>   switch target (resets alert state)\n"
        "    set driver <n|name>   switch driver (resets alert state)\n"
        "    set loc    <mm>       linear threshold\n"
        "    set ang    <rad>      angular threshold\n"
        "    set remind <n>        reminder every N checks\n"
        "    status                current settings\n"
        "    quit / q              stop\n"
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
            os._exit(0)

        elif cmd == "list":
            print_list()

        elif cmd == "status":
            with lock:
                print(
                    f"  [status]\n"
                    f"    target  : {active_target_name}\n"
                    f"    driver  : {active_driver_name}\n"
                    f"    loc thr : {thr_loc:.1f} mm\n"
                    f"    ang thr : {thr_ang:.3f} rad\n"
                    f"    remind  : every {remind_every} checks\n"
                )

        elif cmd in ("help", "?"):
            print(help_text)

        elif cmd == "set" and len(parts) >= 3:
            key      = parts[1].lower()
            val_str  = " ".join(parts[2:])

            if key == "target":
                with lock:
                    target_names = list(all_targets.keys())
                chosen = _resolve_option(val_str, target_names, "target")
                if chosen:
                    with lock:
                        active_target_name = chosen
                        active_target      = all_targets[chosen]
                        reset_requested    = True
                    print(f"  [set]  target → '{chosen}'  (alert state reset)")

            elif key == "driver":
                with lock:
                    driver_names = list(all_drivers)
                chosen = _resolve_option(val_str, driver_names, "driver")
                if chosen:
                    with lock:
                        active_driver_name = chosen
                        reset_requested    = True
                    print(f"  [set]  driver → '{chosen}'  (alert state reset)")

            elif key == "loc":
                try:
                    val = float(val_str)
                    with lock:
                        thr_loc = val
                    print(f"  [set]  linear threshold → {val:.1f} mm")
                except ValueError:
                    print(f"  [!] '{val_str}' is not a number")

            elif key == "ang":
                try:
                    val = float(val_str)
                    with lock:
                        thr_ang = val
                    print(f"  [set]  angular threshold → {val:.3f} rad")
                except ValueError:
                    print(f"  [!] '{val_str}' is not a number")

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


def _resolve_option(val_str, options, label):
    """Resolve a user-typed string (index or exact name) to a valid option."""
    val_str = val_str.strip()
    if not options:
        print(f"  [!] no {label}s seen yet — type 'list' once the stream provides one.")
        return None
    if val_str.isdigit():
        idx = int(val_str) - 1
        if 0 <= idx < len(options):
            return options[idx]
        print(f"  [!] '{val_str}' is out of range (1–{len(options)})")
        return None
    if val_str in options:
        return val_str
    print(f"  [!] '{val_str}' not found. Type 'list' to see options.")
    return None


# ── Monitoring loop ────────────────────────────────────────────────────────────

def ts():
    return datetime.now().strftime("%H:%M:%S")


def monitor_loop(filepath):
    """Main polling loop — runs in the main thread."""
    global reset_requested
    global active_target_name, active_target, active_driver_name

    file_pos      = 0
    last_pointer  = None

    in_exceedance    = False
    checks_over      = 0
    last_status_time = 0.0     # throttle repeated waiting messages

    while True:
        loop_start = time.monotonic()

        # ── Handle target/driver change ───────────────────────────────────────
        with lock:
            do_reset = reset_requested
            if do_reset:
                reset_requested = False
        if do_reset:
            last_pointer  = None
            in_exceedance = False
            checks_over   = 0

        # ── Read new lines ────────────────────────────────────────────────────
        if not os.path.exists(filepath):
            now = time.monotonic()
            if now - last_status_time >= STATUS_INTERVAL:
                last_status_time = now
                print(f"[{ts()}]  File not found: {filepath}")
        else:
            try:
                with open(filepath, encoding="utf-8", errors="replace") as fh:
                    # Guard against truncation/rotation: if file shrank below
                    # our pointer, restart from the top so we don't sit past
                    # EOF silently.
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

                for raw in new_lines:
                    parts    = raw.rstrip().split("\t")
                    row_type = parts[0].strip() if parts else ""

                    if row_type == "Crosshairs Position":
                        parsed = parse_crosshairs_row(parts)
                        if not parsed:
                            continue
                        # Track every driver we see, regardless of coord
                        # system, so the option pool stays complete.
                        with lock:
                            if parsed["driver"] and parsed["driver"] not in all_drivers:
                                all_drivers.append(parsed["driver"])
                                newly_seen_drivers.append(parsed["driver"])
                        # Update last_pointer only for active driver in MNI.
                        if (parsed["driver"] == cur_driver
                                and parsed["coord_system"] == COORD_SYS):
                            last_pointer = parsed

                    elif row_type == "Target Selection":
                        parsed = parse_target_row(parts)
                        if not parsed or parsed["coord_system"] != COORD_SYS:
                            continue
                        with lock:
                            is_new = parsed["name"] not in all_targets
                            all_targets[parsed["name"]] = parsed
                            # If user is already on this target, refresh its
                            # geometry from the newer row.
                            if active_target_name == parsed["name"]:
                                active_target = parsed
                        if is_new:
                            newly_seen_targets.append(parsed["name"])

                # Announce + auto-select (first one only) when nothing is active.
                for name in newly_seen_targets:
                    with lock:
                        if active_target is None:
                            active_target_name = name
                            active_target      = all_targets[name]
                            reset_requested    = True
                            auto = True
                        else:
                            auto = False
                    if auto:
                        print(f"[{ts()}]  + discovered target '{name}' — auto-selected")
                    else:
                        print(f"[{ts()}]  + discovered target '{name}' "
                              f"(use 'set target' to switch)")

                for name in newly_seen_drivers:
                    with lock:
                        if active_driver_name is None:
                            active_driver_name = name
                            reset_requested    = True
                            auto = True
                        else:
                            auto = False
                    if auto:
                        print(f"[{ts()}]  + discovered driver '{name}' — auto-selected")
                    else:
                        print(f"[{ts()}]  + discovered driver '{name}' "
                              f"(use 'set driver' to switch)")

            except OSError as e:
                print(f"[{ts()}]  Read error: {e}")

        # ── Evaluate ──────────────────────────────────────────────────────────
        with lock:
            cur_target = active_target
            cur_loc    = thr_loc
            cur_ang    = thr_ang
            cur_rem    = remind_every
            cur_driver = active_driver_name

        if cur_target is None or cur_driver is None or last_pointer is None:
            now = time.monotonic()
            if now - last_status_time >= STATUS_INTERVAL:
                last_status_time = now
                if cur_target is None:
                    print(f"[{ts()}]  Waiting for target selection… "
                          f"(no Target Selection row in stream yet)")
                elif cur_driver is None:
                    print(f"[{ts()}]  Waiting for driver selection… "
                          f"(no Crosshairs Position row in stream yet)")
                else:
                    print(f"[{ts()}]  Waiting for '{cur_driver}' crosshairs data…")
        else:
            dist  = euclidean(cur_target["loc"], last_pointer["loc"])
            angle = rotation_angle(list(cur_target["mat"]),
                                   list(last_pointer["mat"]))
            over  = (dist > cur_loc) or (angle > cur_ang)

            if over:
                reasons = []
                if dist  > cur_loc:
                    reasons.append(f"loc {dist:.1f} mm > {cur_loc:.1f} mm")
                if angle > cur_ang:
                    reasons.append(f"ang {angle:.3f} rad > {cur_ang:.3f} rad")
                reason_str = "  |  ".join(reasons)

                if not in_exceedance:
                    print(f"[{ts()}]  ⚠  ALERT     {reason_str}")
                    in_exceedance = True
                    checks_over   = 1
                else:
                    checks_over += 1
                    if checks_over % cur_rem == 0:
                        print(f"[{ts()}]  ⚠  REMINDER  {reason_str}  "
                              f"(check #{checks_over})")
            else:
                if in_exceedance:
                    print(f"[{ts()}]  ✓  Back in range   "
                          f"dist={dist:.1f} mm  angle={angle:.3f} rad")
                in_exceedance = False
                checks_over   = 0

        # ── Sleep ─────────────────────────────────────────────────────────────
        elapsed = time.monotonic() - loop_start
        time.sleep(max(0.0, POLL_INTERVAL - elapsed))


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    global thr_loc, thr_ang
    global active_target_name, active_target, active_driver_name

    parser = argparse.ArgumentParser(
        description=f"Brainsight drift monitor {SCRIPT_VERSION}"
    )
    parser.add_argument("file", help="Path to the Brainsight .txt file")
    parser.add_argument("--loc", type=float, default=DEFAULT_LOC_THR,
                        help=f"Linear threshold mm (default {DEFAULT_LOC_THR})")
    parser.add_argument("--ang", type=float, default=DEFAULT_ANG_THR,
                        help=f"Angular threshold rad (default {DEFAULT_ANG_THR})")
    args = parser.parse_args()

    with lock:
        thr_loc = args.loc
        thr_ang = args.ang

    filepath = args.file

    print(f"\nBrainsight drift monitor  [{SCRIPT_VERSION}]")
    print(f"  File       : {filepath}")
    print(f"  Rate       : {POLL_HZ} Hz  |  "
          f"loc thr: {thr_loc:.1f} mm  |  ang thr: {thr_ang:.3f} rad")

    # ── Wait for file ─────────────────────────────────────────────────────────
    _last_file_msg = 0.0
    while not os.path.exists(filepath):
        now = time.monotonic()
        if now - _last_file_msg >= STATUS_INTERVAL:
            _last_file_msg = now
            print(f"  Waiting for file to appear…  (Ctrl+C to cancel)")
        time.sleep(0.5)

    # ── Scan file (initial) ───────────────────────────────────────────────────
    print("\n  Scanning file for available targets and drivers…")
    initial_targets, initial_drivers = scan_file(filepath)

    # ── Startup menu: pick target ─────────────────────────────────────────────
    target_names = list(initial_targets.keys())
    if target_names:
        chosen_target = show_and_pick("target", target_names)
        with lock:
            active_target_name = chosen_target
            active_target      = initial_targets[chosen_target]
    else:
        print("  [i] No Target Selection rows (MNI) in the file yet.")
        print("      The first one to appear in the stream will be auto-selected.")

    # ── Startup menu: pick driver ─────────────────────────────────────────────
    if initial_drivers:
        chosen_driver = show_and_pick("crosshairs driver", initial_drivers)
        with lock:
            active_driver_name = chosen_driver
    else:
        print("  [i] No Crosshairs Position rows in the file yet.")
        print("      The first driver to appear in the stream will be auto-selected.")

    # ── Summary ───────────────────────────────────────────────────────────────
    print(f"\n  ── Starting monitor ─────────────────────────────────────────")
    print(f"    Target  : {active_target_name}")
    print(f"    Driver  : {active_driver_name}")
    print(f"    loc thr : {thr_loc:.1f} mm   |   ang thr : {thr_ang:.3f} rad")
    print(f"    Remind  : every {remind_every} checks (~{remind_every/POLL_HZ:.0f} s)")
    print(f"    Type 'list', 'status', 'set ...', or 'quit'\n")

    # ── Start input thread ────────────────────────────────────────────────────
    t = threading.Thread(target=input_thread, daemon=True)
    t.start()

    # ── Run monitoring loop (blocks until quit) ───────────────────────────────
    monitor_loop(filepath)


if __name__ == "__main__":
    main()
