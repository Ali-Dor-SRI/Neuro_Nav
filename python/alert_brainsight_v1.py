#!/usr/bin/env python3
"""
alert_brainsight.py
-------------------
Monitors a Brainsight streamed-info .txt file in real-time.
Compares the "Pointer" crosshairs (MNI) against "test_target" and
alerts when the pointer drifts beyond configurable thresholds.

Usage
-----
    python3 alert_brainsight.py "path/to/Session Streamed Info.txt"
    python3 alert_brainsight.py "path/to/file.txt" --loc 50 --ang 0.3

Terminal commands while running:
    set loc <mm>       change linear threshold,   e.g.  set loc 50
    set ang <rad>      change angular threshold,  e.g.  set ang 0.15
    set remind <n>     reminder every N checks,   e.g.  set remind 10
    status             print current thresholds and last measurement
    quit / q           stop the script
"""

import sys
import os
import math
import time
import threading
import argparse
from datetime import datetime


# ── Constants ──────────────────────────────────────────────────────────────────

POLL_HZ          = 2        # checks per second  (20 fps / 10 = manageable)
POLL_INTERVAL    = 1 / POLL_HZ

TARGET_NAME      = "test_target"
CROSSHAIRS_NAME  = "Pointer"
COORD_SYS        = "MNI"

DEFAULT_LOC_THR  = 40.0     # mm
DEFAULT_ANG_THR  = 0.20     # radians  (~11.5 degrees)
DEFAULT_REMIND   = 5        # print reminder every N checks while out of range


# ── Shared state (protected by lock) ──────────────────────────────────────────

lock            = threading.Lock()
thr_loc         = DEFAULT_LOC_THR
thr_ang         = DEFAULT_ANG_THR
remind_every    = DEFAULT_REMIND


# ── Geometry helpers ──────────────────────────────────────────────────────────

def euclidean(a, b):
    """Euclidean distance between two (x, y, z) tuples."""
    return math.sqrt(sum((ai - bi) ** 2 for ai, bi in zip(a, b)))


def mat_mul_T(A, B):
    """Compute A^T @ B for two 3x3 matrices (as flat 9-element lists, row-major)."""
    # A^T[i][j] = A[j][i]   →   (A^T @ B)[i][j] = sum_k A[k][i] * B[k][j]
    result = [0.0] * 9
    for i in range(3):
        for j in range(3):
            result[i * 3 + j] = sum(A[k * 3 + i] * B[k * 3 + j] for k in range(3))
    return result


def rotation_angle(mat_ref, mat_cur):
    """
    Geodesic angle (radians) between two 3x3 rotation matrices stored
    as flat 9-element row-major lists.

    Formula: theta = arccos( (trace(R_ref^T @ R_cur) - 1) / 2 )
    """
    R_rel  = mat_mul_T(mat_ref, mat_cur)
    trace  = R_rel[0] + R_rel[4] + R_rel[8]
    cos_th = (trace - 1.0) / 2.0
    cos_th = max(-1.0, min(1.0, cos_th))   # clamp for numerical safety
    return math.acos(cos_th)


# ── File parsing (incremental) ────────────────────────────────────────────────

def parse_floats(parts, indices):
    """Extract float values from a split tab line; return None on any failure."""
    try:
        return tuple(float(parts[i]) for i in indices)
    except (IndexError, ValueError, TypeError):
        return None


def parse_target_line(parts):
    """
    Parse a 'Target Selection' row.
    Columns: row_type, date, time, target_name, coord_system,
             loc_x, loc_y, loc_z, m0n0..m2n2
    Indices:    0       1     2        3            4
                5       6     7        8..16
    """
    if len(parts) < 17:
        return None
    name   = parts[3].strip()
    csys   = parts[4].strip()
    loc    = parse_floats(parts, [5, 6, 7])
    mat    = parse_floats(parts, list(range(8, 17)))
    if loc is None or mat is None:
        return None
    return {"name": name, "coord_system": csys, "loc": loc, "mat": mat}


def parse_crosshairs_line(parts):
    """
    Parse a 'Crosshairs Position' row.
    Columns: row_type, date, time, crosshairs_driver, coord_system,
             loc_x, loc_y, loc_z, m0n0..m2n2
    Indices:    0       1     2          3                  4
                5       6     7          8..16
    """
    if len(parts) < 17:
        return None
    driver = parts[3].strip()
    csys   = parts[4].strip()
    loc    = parse_floats(parts, [5, 6, 7])
    mat    = parse_floats(parts, list(range(8, 17)))
    if loc is None or mat is None:
        return None
    return {"driver": driver, "coord_system": csys, "loc": loc, "mat": mat}


# ── Input thread (live threshold commands) ────────────────────────────────────

def input_thread():
    """Runs in a daemon thread; reads commands from stdin."""
    global thr_loc, thr_ang, remind_every
    help_text = (
        "  Commands:  set loc <mm>  |  set ang <rad>  |  set remind <n>  "
        "|  status  |  quit\n"
    )
    while True:
        try:
            line = input()
        except EOFError:
            break
        line = line.strip().lower()

        if not line:
            continue

        if line in ("quit", "q", "exit"):
            print("Stopping.")
            os._exit(0)

        elif line == "status":
            with lock:
                loc = thr_loc
                ang = thr_ang
                rem = remind_every
            print(f"  [status]  loc threshold={loc:.1f} mm  |  "
                  f"ang threshold={ang:.3f} rad  |  remind every {rem} checks")

        elif line.startswith("set "):
            parts = line.split()
            if len(parts) != 3:
                print(f"  [?] usage: {help_text}", end="")
                continue
            _, key, val_str = parts
            try:
                val = float(val_str)
            except ValueError:
                print(f"  [!] '{val_str}' is not a number")
                continue

            with lock:
                if key == "loc":
                    thr_loc = val
                    print(f"  [set]  linear threshold → {val:.1f} mm")
                elif key == "ang":
                    thr_ang = val
                    print(f"  [set]  angular threshold → {val:.3f} rad")
                elif key == "remind":
                    remind_every = max(1, int(val))
                    print(f"  [set]  reminder every {remind_every} checks")
                else:
                    print(f"  [?] unknown key '{key}'.  {help_text}", end="")
        else:
            print(f"  [?] unknown command.  {help_text}", end="")


# ── Main monitoring loop ───────────────────────────────────────────────────────

def ts():
    return datetime.now().strftime("%H:%M:%S")


def main():
    parser = argparse.ArgumentParser(description="Brainsight real-time drift alert")
    parser.add_argument("file", help="Path to the Brainsight .txt file")
    parser.add_argument("--loc", type=float, default=DEFAULT_LOC_THR,
                        help=f"Linear threshold in mm (default {DEFAULT_LOC_THR})")
    parser.add_argument("--ang", type=float, default=DEFAULT_ANG_THR,
                        help=f"Angular threshold in radians (default {DEFAULT_ANG_THR})")
    args = parser.parse_args()

    global thr_loc, thr_ang
    with lock:
        thr_loc = args.loc
        thr_ang = args.ang

    filepath = args.file

    # Start the input listener as a daemon (dies when main thread exits)
    t = threading.Thread(target=input_thread, daemon=True)
    t.start()

    print(f"\nBrainsight drift monitor")
    print(f"  File       : {filepath}")
    print(f"  Target     : '{TARGET_NAME}'  (Target Selection rows)")
    print(f"  Pointer    : '{CROSSHAIRS_NAME}'  (Crosshairs Position, {COORD_SYS})")
    print(f"  Rate       : {POLL_HZ} Hz  (every {POLL_INTERVAL:.2f} s)")
    print(f"  Thresholds : loc={thr_loc:.1f} mm   ang={thr_ang:.3f} rad")
    print(f"  Type 'set loc 50' / 'set ang 0.3' / 'status' / 'quit' to interact\n")

    target          = None       # dict with loc, mat once found
    last_pointer    = None       # most recent valid Pointer row
    file_pos        = 0          # byte offset for incremental reading

    in_exceedance   = False
    checks_over     = 0          # how many consecutive checks over threshold

    while True:
        loop_start = time.monotonic()

        # ── Read only new lines since last check ──────────────────────────────
        if not os.path.exists(filepath):
            print(f"[{ts()}]  Waiting for file: {filepath}")
        else:
            try:
                with open(filepath, "r", encoding="utf-8", errors="replace") as fh:
                    fh.seek(file_pos)
                    new_lines = fh.readlines()
                    file_pos  = fh.tell()

                for raw in new_lines:
                    line = raw.rstrip("\n\r")
                    if not line or line.startswith("#"):
                        continue
                    parts = line.split("\t")
                    row_type = parts[0].strip() if parts else ""

                    if row_type == "Target Selection":
                        parsed = parse_target_line(parts)
                        if (parsed and
                                parsed["name"] == TARGET_NAME and
                                parsed["coord_system"] == COORD_SYS):
                            target = parsed
                            print(f"[{ts()}]  Target found: '{TARGET_NAME}'  "
                                  f"loc=({parsed['loc'][0]:.1f}, "
                                  f"{parsed['loc'][1]:.1f}, "
                                  f"{parsed['loc'][2]:.1f})")

                    elif row_type == "Crosshairs Position":
                        parsed = parse_crosshairs_line(parts)
                        if (parsed and
                                parsed["driver"] == CROSSHAIRS_NAME and
                                parsed["coord_system"] == COORD_SYS):
                            last_pointer = parsed

            except OSError as e:
                print(f"[{ts()}]  Read error: {e}")

        # ── Evaluate distance ─────────────────────────────────────────────────
        if target is None:
            print(f"[{ts()}]  Waiting for '{TARGET_NAME}' in Target Selection rows...")
        elif last_pointer is None:
            print(f"[{ts()}]  Target found — waiting for '{CROSSHAIRS_NAME}' data...")
        else:
            with lock:
                cur_loc = thr_loc
                cur_ang = thr_ang
                cur_rem = remind_every

            dist  = euclidean(target["loc"], last_pointer["loc"])
            angle = rotation_angle(list(target["mat"]), list(last_pointer["mat"]))

            loc_ok = dist  <= cur_loc
            ang_ok = angle <= cur_ang
            over   = not (loc_ok and ang_ok)

            if over:
                reasons = []
                if not loc_ok:
                    reasons.append(f"loc {dist:.1f} mm > {cur_loc:.1f} mm")
                if not ang_ok:
                    reasons.append(f"ang {angle:.3f} rad > {cur_ang:.3f} rad")
                reason_str = "  |  ".join(reasons)

                if not in_exceedance:
                    # First crossing: always alert
                    print(f"[{ts()}]  ⚠  ALERT     Pointer out of range!  {reason_str}")
                    in_exceedance = True
                    checks_over   = 1
                else:
                    checks_over += 1
                    if checks_over % cur_rem == 0:
                        print(f"[{ts()}]  ⚠  REMINDER  Still out of range  "
                              f"{reason_str}  (check #{checks_over})")
            else:
                if in_exceedance:
                    # Returned to safe range
                    print(f"[{ts()}]  ✓  Back in range   "
                          f"dist={dist:.1f} mm  angle={angle:.3f} rad")
                in_exceedance = False
                checks_over   = 0

        # ── Sleep for remainder of interval ───────────────────────────────────
        elapsed = time.monotonic() - loop_start
        sleep_t = max(0.0, POLL_INTERVAL - elapsed)
        time.sleep(sleep_t)


if __name__ == "__main__":
    main()
