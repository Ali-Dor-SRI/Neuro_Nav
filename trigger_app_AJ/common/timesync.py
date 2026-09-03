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
    "# participant is the study code typed into the Mac app for this session\n"
    "#   (empty if the operator did not supply one). It is the LAST column so\n"
    "#   that logs written before it existed keep their column positions.\n"
    "# Tab-separated columns:\n"
    "# win_local_time\tdelta_s\trtt_ms\tmac_local_time\tpeer"
    "\tt1_mac_epoch\tt2_win_epoch\tt3_win_epoch\tt4_mac_epoch\tparticipant\n"
)

# Written once when appending to a log created before the participant column
# existed, so a human reading the file can see why the row width changed.
_MIGRATION_NOTE = (
    "# --- 'participant' appended as a 10th column from the next row on ---\n"
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


def _is_pre_participant_log(path):
    """True for an existing, non-empty log whose header predates the
    participant column — so the note explaining the extra field is written
    exactly once. Only the '#' header lines are inspected, so a participant id
    that happens to contain the word can never be mistaken for the header."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            head = f.read(4096)
    except OSError:
        return False
    if not head.strip():
        return False
    return not any("participant" in ln
                   for ln in head.splitlines() if ln.startswith("#"))


def append_log(offset, delay, t1, t2, t3, t4, peer, participant="", path=None):
    """Append one time-sync result as a line to the log file.

    `participant` is the study code the Mac sent for this session ("" if the
    operator supplied none). It is written LAST so that the positions of the
    original nine columns are unchanged for anything already parsing the log.

    Writes the column header first if the file is new/empty. Returns the path
    written to. Raises OSError on write failure (caller decides how loud).
    """
    path = path or timesync_log_path()
    need_header = (not os.path.exists(path)) or os.path.getsize(path) == 0
    need_note   = (not need_header) and _is_pre_participant_log(path)
    row = "\t".join((
        _fmt_local(t2),            # Windows local time the sync landed
        f"{offset:+.6f}",          # delta_s (Windows - Mac)
        f"{delay * 1000.0:.3f}",   # rtt_ms
        _fmt_local(t1),            # Mac local time at send
        str(peer),
        f"{t1:.6f}", f"{t2:.6f}", f"{t3:.6f}", f"{t4:.6f}",
        str(participant or ""),    # study code typed on the Mac
    ))
    with open(path, "a", encoding="utf-8") as f:
        if need_header:
            f.write(_HEADER)
        elif need_note:
            f.write(_MIGRATION_NOTE)
        f.write(row + "\n")
    return path
