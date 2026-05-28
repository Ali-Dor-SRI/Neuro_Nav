#!/usr/bin/env python3
"""
alert_brainsight_v2.1.0.py
--------------------------
Real-time Brainsight drift monitor — version 2.1.0.

Changes from v2.0.1:
  - Per-DOF thresholds. Linear thresholds are stored per axis (X, Y, Z) in
    mm; angular thresholds are stored per axis (X, Y, Z) in radians, where
    "angular X" means the angle between the target's local X basis vector
    and the pointer's local X basis vector (per-axis tilt — coordinate-frame
    free, no Euler convention to argue about, no gimbal lock).
  - `set loc 40`            → all 3 linear axes set to 40 mm   (scalar, broadcasts)
    `set loc 30 40 50`      → X=30, Y=40, Z=50
    `set ang 0.2`           → all 3 angular axes set to 0.2 rad (scalar, broadcasts)
    `set ang 0.1 0.2 0.3`   → X=0.1, Y=0.2, Z=0.3
    loc and ang modes are independent — one can be scalar while the other
    is per-axis.
  - Alert and reminder messages list every violating axis individually:
        ⚠  ALERT  loc-Y 52.1 > 40.0 mm  |  ang-Z 0.31 > 0.20 rad

Carry-over fixes from v2.0.1:
  - Targets and drivers are discovered continuously from the live stream.
    First one auto-selected. The input thread reads live shared pools.
  - Truncation guard on the file pointer.

Usage
-----
    python3 alert_brainsight_v2.1.0.py "path/to/Session Streamed Info.txt"
    python3 alert_brainsight_v2.1.0.py "path/to/file.txt" --loc 50 --ang 0.3

Terminal commands while running:
    list                          show available targets and drivers
    set target <n|name>           switch active target,  e.g. set target 1
    set driver <n|name>           switch active driver,  e.g. set driver Pointer
    set loc <mm>                  set all 3 linear axes to one value
    set loc <x> <y> <z>           per-axis linear thresholds (mm)
    set ang <rad>                 set all 3 angular axes to one value
    set ang <x> <y> <z>           per-axis angular thresholds (rad)
    set remind <n>                reminder every N checks
    status                        print current settings
    quit / q                      stop
"""

import os
import math
import time
import threading
import argparse
from datetime import datetime


# ── Version & constants ────────────────────────────────────────────────────────

SCRIPT_VERSION   = "v2.1.0"

POLL_HZ          = 2           # checks per second
POLL_INTERVAL    = 1 / POLL_HZ
STATUS_INTERVAL  = 5.0         # seconds between repeated waiting/status messages

COORD_SYS        = "MNI"

DEFAULT_LOC_THR  = 40.0        # mm   (broadcasts to all 3 axes)
DEFAULT_ANG_THR  = 0.20        # rad  (~11.5°, broadcasts to all 3 axes)
DEFAULT_REMIND   = 100         # remind every N checks while out of range

AXIS_NAMES       = ("X", "Y", "Z")


# ── Shared state ───────────────────────────────────────────────────────────────

lock = threading.Lock()

# Thresholds — per-axis lists [X, Y, Z]. Scalar input broadcasts to all three.
thr_loc      = [DEFAULT_LOC_THR] * 3   # mm per axis
thr_ang      = [DEFAULT_ANG_THR] * 3   # rad per axis (per-axis tilt)
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

def axis_offsets(loc_ref, loc_cur):
    """Return (|Δx|, |Δy|, |Δz|) in mm."""
    return (abs(loc_ref[0] - loc_cur[0]),
            abs(loc_ref[1] - loc_cur[1]),
            abs(loc_ref[2] - loc_cur[2]))


def per_axis_tilts(mat_ref, mat_cur):
    """
    Return (tilt_X, tilt_Y, tilt_Z) in radians, where tilt_i is the angle
    between the i-th basis axis of mat_ref and the i-th basis axis of
    mat_cur. Matrices are row-major flat 9-element lists, so the i-th
    basis axis is the i-th column: (mat[0*3+i], mat[1*3+i], mat[2*3+i]).
    Rotation matrices are orthonormal, so columns are unit vectors and the
    dot product is the cosine directly.
    """
    tilts = []
    for i in range(3):
        cx_r = mat_ref[0 * 3 + i]; cy_r = mat_ref[1 * 3 + i]; cz_r = mat_ref[2 * 3 + i]
        cx_c = mat_cur[0 * 3 + i]; cy_c = mat_cur[1 * 3 + i]; cz_c = mat_cur[2 * 3 + i]
        cos_th = max(-1.0, min(1.0, cx_r * cx_c + cy_r * cy_c + cz_r * cz_c))
        tilts.append(math.acos(cos_th))
    return tuple(tilts)


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
    """Read once, populate global option pools. Returns the pools."""
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


def fmt_thr(vec, unit, fmt="{:.2f}"):
    """Format a 3-vector threshold, collapsing to a scalar when all equal."""
    if vec[0] == vec[1] == vec[2]:
        return f"{fmt.format(vec[0])} {unit} (all axes)"
    return ("X=" + fmt.format(vec[0]) + ", "
            "Y=" + fmt.format(vec[1]) + ", "
            "Z=" + fmt.format(vec[2]) + " " + unit)


# ── Input thread ───────────────────────────────────────────────────────────────

def input_thread():
    """Daemon thread: reads commands from stdin. Reads live option pools."""
    global thr_loc, thr_ang, remind_every
    global active_target_name, active_target, active_driver_name
    global reset_requested

    help_text = (
        "  Commands:\n"
        "    list                          show available targets and drivers\n"
        "    set target <n|name>           switch target (resets alert state)\n"
        "    set driver <n|name>           switch driver (resets alert state)\n"
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
            os._exit(0)

        elif cmd == "list":
            print_list()

        elif cmd == "status":
            with lock:
                print(
                    f"  [status]\n"
                    f"    target  : {active_target_name}\n"
                    f"    driver  : {active_driver_name}\n"
                    f"    loc thr : {fmt_thr(thr_loc, 'mm', '{:.1f}')}\n"
                    f"    ang thr : {fmt_thr(thr_ang, 'rad')}\n"
                    f"    remind  : every {remind_every} checks\n"
                )

        elif cmd in ("help", "?"):
            print(help_text)

        elif cmd == "set" and len(parts) >= 3:
            key       = parts[1].lower()
            value_toks = parts[2:]
            val_str    = " ".join(value_toks)   # for target/driver names with spaces

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
                vec = _parse_threshold_vec(value_toks, "loc")
                if vec is not None:
                    with lock:
                        thr_loc = vec
                    print(f"  [set]  linear threshold → {fmt_thr(vec, 'mm', '{:.1f}')}")

            elif key == "ang":
                vec = _parse_threshold_vec(value_toks, "ang")
                if vec is not None:
                    with lock:
                        thr_ang = vec
                    print(f"  [set]  angular threshold → {fmt_thr(vec, 'rad')}")

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
    """
    Parse 1 or 3 numeric tokens into a 3-element list.
    1 token → broadcast to all axes; 3 tokens → per-axis [X, Y, Z].
    Returns None on parse error (and prints why).
    """
    if len(tokens) == 1:
        try:
            v = float(tokens[0])
        except ValueError:
            print(f"  [!] '{tokens[0]}' is not a number")
            return None
        return [v, v, v]
    if len(tokens) == 3:
        try:
            vs = [float(t) for t in tokens]
        except ValueError:
            print(f"  [!] expected 3 numbers for per-axis {label}, got: {' '.join(tokens)}")
            return None
        return vs
    print(f"  [!] set {label} takes 1 value (scalar) or 3 values (per-axis X Y Z); "
          f"got {len(tokens)}")
    return None


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
    last_status_time = 0.0

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
                    # Guard against truncation/rotation.
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
                        with lock:
                            if parsed["driver"] and parsed["driver"] not in all_drivers:
                                all_drivers.append(parsed["driver"])
                                newly_seen_drivers.append(parsed["driver"])
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
                            if active_target_name == parsed["name"]:
                                active_target = parsed
                        if is_new:
                            newly_seen_targets.append(parsed["name"])

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
            cur_loc    = list(thr_loc)
            cur_ang    = list(thr_ang)
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
                          f"loc=({d_xyz[0]:.1f}, {d_xyz[1]:.1f}, {d_xyz[2]:.1f}) mm  "
                          f"ang=({t_xyz[0]:.3f}, {t_xyz[1]:.3f}, {t_xyz[2]:.3f}) rad")
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
                        help=f"Linear threshold mm — applied to all 3 axes "
                             f"(default {DEFAULT_LOC_THR}). Per-axis values "
                             f"can be set mid-session via 'set loc x y z'.")
    parser.add_argument("--ang", type=float, default=DEFAULT_ANG_THR,
                        help=f"Angular threshold rad — applied to all 3 axes "
                             f"(default {DEFAULT_ANG_THR}). Per-axis values "
                             f"can be set mid-session via 'set ang x y z'.")
    args = parser.parse_args()

    with lock:
        thr_loc = [args.loc] * 3
        thr_ang = [args.ang] * 3

    filepath = args.file

    print(f"\nBrainsight drift monitor  [{SCRIPT_VERSION}]")
    print(f"  File       : {filepath}")
    print(f"  Rate       : {POLL_HZ} Hz")
    print(f"  loc thr    : {fmt_thr(thr_loc, 'mm', '{:.1f}')}")
    print(f"  ang thr    : {fmt_thr(thr_ang, 'rad')}")

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
    print(f"    loc thr : {fmt_thr(thr_loc, 'mm', '{:.1f}')}")
    print(f"    ang thr : {fmt_thr(thr_ang, 'rad')}")
    print(f"    Remind  : every {remind_every} checks (~{remind_every/POLL_HZ:.0f} s)")
    print(f"    Type 'list', 'status', 'set ...', or 'quit'\n")

    # ── Start input thread ────────────────────────────────────────────────────
    t = threading.Thread(target=input_thread, daemon=True)
    t.start()

    # ── Run monitoring loop (blocks until quit) ───────────────────────────────
    monitor_loop(filepath)


if __name__ == "__main__":
    main()
