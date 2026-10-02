#!/usr/bin/env python3
"""
monitor_brainsight.py
---------------------
Polls a Brainsight streamed-info .txt file every 5 seconds and reports
whether it is accessible, its current size, and whether it is growing.

Usage
-----
    python monitor_brainsight.py "C:/path/to/Session Streamed Info.txt"

Press Ctrl+C to stop.
"""

import sys
import os
import time
from datetime import datetime


POLL_INTERVAL = 5   # seconds between checks


def fmt_size(n_bytes: int) -> str:
    """Human-readable file size."""
    if n_bytes < 1024:
        return f"{n_bytes} B"
    elif n_bytes < 1024 ** 2:
        return f"{n_bytes / 1024:.1f} KB"
    else:
        return f"{n_bytes / 1024 ** 2:.2f} MB"


def check_file(path: str, prev_size: int | None) -> int | None:
    """
    Check the file and print a one-line status report.
    Returns the current file size (int) if accessible, else None.
    """
    ts = datetime.now().strftime("%H:%M:%S")

    # ── Does the file exist? ──────────────────────────────────────────────────
    if not os.path.exists(path):
        print(f"[{ts}]  NOT FOUND     {path}")
        return None

    # ── Can it be opened for reading? ────────────────────────────────────────
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            fh.read(1)           # minimal read to confirm access
    except PermissionError:
        print(f"[{ts}]  LOCKED        File exists but cannot be opened (permission denied)")
        return None
    except OSError as exc:
        print(f"[{ts}]  ERROR         {exc}")
        return None

    # ── Size & growth ─────────────────────────────────────────────────────────
    size = os.path.getsize(path)

    if prev_size is None:
        growth = "  (first check)"
    elif size > prev_size:
        growth = f"  ▲ +{fmt_size(size - prev_size)} since last check"
    elif size == prev_size:
        growth = "  — no change"
    else:
        growth = f"  ▼ shrank by {fmt_size(prev_size - size)}"

    print(f"[{ts}]  ACCESSIBLE    {fmt_size(size)}{growth}")
    return size


def main():
    if len(sys.argv) < 2:
        print("Usage: python monitor_brainsight.py <path_to_file>")
        print('Example: python monitor_brainsight.py "C:/Data/Session Streamed Info.txt"')
        sys.exit(1)

    path = sys.argv[1]

    print(f"Monitoring: {path}")
    print(f"Polling every {POLL_INTERVAL} s  |  Press Ctrl+C to stop\n")

    prev_size = None
    try:
        while True:
            prev_size = check_file(path, prev_size)
            time.sleep(POLL_INTERVAL)
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
