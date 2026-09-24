"""Clock-offset maths and the Windows-side time-sync logs.

The Mac (running Brainsight / neuronav) and the Windows machine (running
QTrack for TMS/EMG) keep independent clocks. Each writes wall-clock
timestamps into its own data files, so to line events up across the two
recordings you need to know how far apart the two clocks are.

When the trigger link is established the two devices exchange timestamps
NTP-style (see protocol.py). Windows computes the offset between the clocks
and writes it here. ``offset = Windows_clock - Mac_clock`` (positive means
the Windows clock is ahead of the Mac clock), so to convert a Mac/neuronav
timestamp to the Windows/TMS clock:

    windows_time = mac_time + offset

The round-trip exchange cancels most of the network transit time, so the
offset is not biased by how long the message took to travel.

**One file per connection.** Each Mac connection gets its own log file in
``time_sync_logs/``, named for the connection's start time and the
participant it declared, e.g.::

    time_sync_logs/time_sync_2026-09-10_14-33-07_SNBR-000.txt

Each file carries the same header and columns the single shared log used to
carry, so anything that parsed the old log parses one of these unchanged --
it just reads a directory of them instead of one growing file. A file is
created lazily, on the connection's first logged sync, so a connection that
never syncs leaves no empty file behind.

**Where they go is the operator's choice** -- ``--log-dir`` or the receiver's
startup prompt, remembered in ``receiver_settings.json``. ``default_log_dir()``
below is only the built-in location: the starting default, and the fallback the
receiver writes to if the chosen folder (typically a lab share) is unreachable
when a sync arrives.
"""

import os
import re
from datetime import datetime

from trigger_app_AJ.common.config import app_dir

TIMESYNC_LOG_DIRNAME = "time_sync_logs"
TIMESYNC_LOG_PREFIX  = "time_sync"

_HEADER = (
    "# Neuro_Nav time-sync log - ONE FILE PER MAC CONNECTION.\n"
    "# delta_s = Windows_clock - Mac_clock  (positive => Windows clock is AHEAD of Mac).\n"
    "# To map a Mac/neuronav timestamp onto the Windows/TMS-EMG clock:  windows = mac + delta_s\n"
    "# rtt_ms is the round-trip network delay (already removed from delta_s).\n"
    "# participant is the study code typed into the Mac app for this session\n"
    "#   (empty if the operator did not supply one).\n"
    "# Tab-separated columns:\n"
    "# win_local_time\tdelta_s\trtt_ms\tmac_local_time\tpeer"
    "\tt1_mac_epoch\tt2_win_epoch\tt3_win_epoch\tt4_mac_epoch\tparticipant\n"
)

# Anything outside this set is squashed to '-' in the filename's participant
# segment, so a pasted id can never escape into a path or break the shell.
_FILENAME_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")
_FILENAME_ID_MAX = 40


def default_log_dir():
    """Built-in location for the per-connection time-sync logs - next to the
    .exe when frozen, else the trigger_app_AJ/ directory (same convention as
    the token file).

    This is where logs go until the operator chooses somewhere else, and where
    they go anyway if that choice turns out to be unwritable at the moment a
    sync lands. It is always on the local machine, so it cannot go offline.
    """
    return os.path.join(app_dir(), TIMESYNC_LOG_DIRNAME)


def _filename_participant(participant):
    """Participant id reduced to a filename-safe segment ("" if unusable)."""
    slug = _FILENAME_UNSAFE.sub("-", str(participant or "")).strip("-._")
    return slug[:_FILENAME_ID_MAX].strip("-._")


def new_log_path(started_at=None, participant="", directory=None):
    """Path for a fresh per-connection log, and create its directory.

    `started_at` is the connection's start epoch (defaults to now) and names
    the file; `participant` is appended when the Mac supplied one, so the
    folder can be scanned by eye. The file itself is NOT created -- the first
    `append_log()` writes it, header included.

    If a file of that name already exists (two connections within the same
    second), `-2`, `-3`, ... is appended so an earlier connection's log is
    never appended to or overwritten.
    """
    directory = directory or timesync_log_dir()
    os.makedirs(directory, exist_ok=True)
    stamp = datetime.fromtimestamp(
        started_at if started_at is not None else datetime.now().timestamp()
    ).strftime("%Y-%m-%d_%H-%M-%S")
    who  = _filename_participant(participant)
    base = f"{TIMESYNC_LOG_PREFIX}_{stamp}" + (f"_{who}" if who else "")
    path = os.path.join(directory, base + ".txt")
    n = 2
    while os.path.exists(path):
        path = os.path.join(directory, f"{base}-{n}.txt")
        n += 1
    return path


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


def append_log(path, offset, delay, t1, t2, t3, t4, peer, participant=""):
    """Write one time-sync result as a line to this connection's log file.

    `path` comes from `new_log_path()` and belongs to exactly one connection.
    The column header is written first if the file is new/empty, so the very
    first sync of a connection creates a complete, self-describing file. A
    connection that syncs more than once (a re-sync on the same link) appends
    to the same file.

    `participant` is the study code the Mac sent for this session ("" if the
    operator supplied none), written as the last column.

    Returns the path written to. Raises OSError on write failure (caller
    decides how loud).
    """
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    need_header = (not os.path.exists(path)) or os.path.getsize(path) == 0
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
        f.write(row + "\n")
    return path
