"""Human-readable status messages, mapping internal events to log lines.

Centralized here so the worker (which produces events) and the panels
(which display them) stay in lock-step with a single phrasing.
"""

# Severity levels — used by perform_panel to colorize the log row.
INFO     = "info"
OK       = "ok"
WARN     = "warn"
ALERT    = "alert"
REMINDER = "reminder"

LEVEL_COLORS = {
    INFO:     "#555555",
    OK:       "#1a7f1a",
    WARN:     "#b87515",
    ALERT:    "#c0392b",
    REMINDER: "#d4a017",
}


# ── Event -> message text ────────────────────────────────────────────────────

def waiting_for_file(path):
    return INFO, f"Waiting for file to be created: {path}"

def file_found():
    return INFO, "File found — beginning to read stream"

def connecting(host, port):
    return INFO, f"Connecting to Windows receiver at {host}:{port}..."

def connection_successful(host, port):
    return OK, f"Connection successful — link to {host}:{port}"

def connection_lost(reason=""):
    msg = "Connection lost"
    if reason:
        msg += f" ({reason})"
    return WARN, msg

def auth_denied():
    return ALERT, "Auth rejected by Windows — check the token"

def time_synced(offset, delay):
    sign = "ahead of" if offset >= 0 else "behind"
    return OK, (f"Time-sync OK — Windows logged our timestamp; Windows clock is "
                f"{abs(offset) * 1000.0:.1f} ms {sign} the Mac "
                f"(delta {offset:+.6f}s, rtt {delay * 1000.0:.1f} ms)")

def time_sync_failed(reason):
    return WARN, f"Time-sync skipped ({reason}) — trigger link continues"

def waiting_for_target():
    return INFO, "Waiting for target selection — no Target Selection row yet"

def waiting_for_driver():
    return INFO, "Waiting for crosshairs driver — no Crosshairs Position row yet"

def target_adopted(name):
    return OK, f"Target adopted: {name}"

def target_followed(name):
    return OK, f"Now tracking '{name}' — followed the Brainsight file's selection"

def follow_enabled():
    return INFO, ("Auto-follow ON — tracking the target most recently "
                  "selected in the Brainsight file")

def follow_disabled():
    return INFO, "Auto-follow OFF — target pinned manually"

def driver_adopted(name):
    return OK, f"Crosshairs driver adopted: {name}"

def in_range(d_xyz, t_xyz):
    return OK, (f"Within threshold (all 6 DoF OK) — "
                f"loc=({d_xyz[0]:.1f}, {d_xyz[1]:.1f}, {d_xyz[2]:.1f}) mm  "
                f"ang=({t_xyz[0]:.3f}, {t_xyz[1]:.3f}, {t_xyz[2]:.3f}) rad")

def out_of_range(reasons):
    n = len(reasons)
    return ALERT, (f"Outside threshold — stopped stimulation "
                   f"({n} of 6 DoF out)  |  " + "  |  ".join(reasons))

def reminder_out_of_range(reasons, count):
    return REMINDER, (f"Reminder #{count}: still outside threshold "
                      f"({len(reasons)} of 6 DoF out)  |  "
                      + "  |  ".join(reasons))

def back_in_range(d_xyz, t_xyz):
    return OK, (f"All 6 DoF back within threshold — resumed stimulation  "
                f"loc=({d_xyz[0]:.1f}, {d_xyz[1]:.1f}, {d_xyz[2]:.1f}) mm  "
                f"ang=({t_xyz[0]:.3f}, {t_xyz[1]:.3f}, {t_xyz[2]:.3f}) rad")
