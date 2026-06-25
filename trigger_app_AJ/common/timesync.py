"""Clock-offset maths and the Windows-side time-sync log.

The Mac (running Brainsight / neuronav) and the Windows machine (running
QTrack for TMS/EMG) keep independent clocks. Each writes wall-clock
timestamps into its own data files, so to line events up across the two
recordings you need to know how far apart the two clocks are.

When the trigger link is established the two devices exchange timestamps
NTP-style (see protocol.py). Windows computes the offset between the clocks
and appends it here. ``offset = Windows_clock - Mac_clock`` (positive means
the Windows clock is ahead of the Mac clock), so to convert a Mac/neuronav
timestamp to the Windows/TMS clock:

    windows_time = mac_time + offset

The round-trip exchange cancels most of the network transit time, so the
offset is not biased by how long the message took to travel.
"""

import os
from datetime import datetime

from trigger_app_AJ.common.config import app_dir

TIMESYNC_LOG_FILENAME = "time_sync_log.txt"

_HEADER = (
    "# Neuro_Nav time-sync log\n"
    "# delta_s = Windows_clock - Mac_clock  (positive => Windows clock is AHEAD of Mac).\n"
    "# To map a Mac/neuronav timestamp onto the Windows/TMS-EMG clock:  windows = mac + delta_s\n"
    "# rtt_ms is the round-trip network delay (already removed from delta_s).\n"
    "# Tab-separated columns:\n"
    "# win_local_time\tdelta_s\trtt_ms\tmac_local_time\tpeer"
    "\tt1_mac_epoch\tt2_win_epoch\tt3_win_epoch\tt4_mac_epoch\n"
)


def timesync_log_path():
    """Path to the time-sync log — next to the .exe when frozen, else the
    trigger_app_AJ/ directory (same convention as the token file)."""
    return os.path.join(app_dir(), TIMESYNC_LOG_FILENAME)


def compute_offset(t1, t2, t3, t4):
    """NTP-style clock offset and round-trip delay, in seconds.

        t1 = Mac     sent TIME
        t2 = Windows received TIME
        t3 = Windows sent TIMEACK
        t4 = Mac     received TIMEACK

    Returns (offset, delay) where offset = Windows_clock - Mac_clock and
    delay is the round-trip network time.
    """
    offset = ((t2 - t1) + (t3 - t4)) / 2.0
    delay  = (t4 - t1) - (t3 - t2)
    return offset, delay


def _fmt_local(epoch):
    """Epoch -> local wall-clock string with millisecond precision."""
    return datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def append_log(offset, delay, t1, t2, t3, t4, peer, path=None):
    """Append one time-sync result as a line to the log file.

    Writes the column header first if the file is new/empty. Returns the path
    written to. Raises OSError on write failure (caller decides how loud).
    """
    path = path or timesync_log_path()
    need_header = (not os.path.exists(path)) or os.path.getsize(path) == 0
    row = "\t".join((
        _fmt_local(t2),            # Windows local time the sync landed
        f"{offset:+.6f}",          # delta_s (Windows - Mac)
        f"{delay * 1000.0:.3f}",   # rtt_ms
        _fmt_local(t1),            # Mac local time at send
        str(peer),
        f"{t1:.6f}", f"{t2:.6f}", f"{t3:.6f}", f"{t4:.6f}",
    ))
    with open(path, "a", encoding="utf-8") as f:
        if need_header:
            f.write(_HEADER)
        f.write(row + "\n")
    return path
