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

def participant_sent(participant):
    return OK, (f"Participant '{participant}' sent — Windows will stamp it on "
                f"this session's time-sync log rows")

def participant_missing():
    return WARN, ("No participant ID sent — this session's time-sync rows will "
                  "be unlabelled")

def participant_send_failed(reason):
    return WARN, (f"Participant ID not delivered ({reason}) — time-sync rows may "
                  f"be unlabelled; the link continues")

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

def triggers_enabled():
    return OK, ("TMS triggering ON — sending SS start/stop to QTrack on drift "
                "transitions")

def triggers_disabled():
    return WARN, ("TMS triggering OFF — time-sync and distance monitoring only; "
                  "no SS sent to QTrack")

def driver_adopted(name):
    return OK, f"Crosshairs driver adopted: {name}"

def driver_pinned(name):
    return INFO, f"Crosshairs driver pinned to: {name} (coil-follow off)"

def coil_follow_enabled():
    return INFO, ("Coil-follow ON — tracking the coil currently selected in "
                  "Brainsight")

def coil_follow_disabled():
    return INFO, "Coil-follow OFF — crosshairs driver pinned manually"

def coil_swapped(old, new):
    return WARN, f"Coil switched in Brainsight: {old} → {new} — now tracking {new}"

def coil_swap_stopped(new):
    return ALERT, f"Coil swap — stopped stimulation until {new} is on target"

def coil_swap_already_out(new):
    return WARN, (f"Coil swap — already outside threshold; stimulation stays "
                  f"stopped until {new} is on target")

def target_prompt(coil, target):
    return ALERT, (f"Coil switched to {coil} but the target was not changed — "
                   f"still measuring against '{target}'. Select the target for "
                   f"{coil} (here or in Brainsight), or click Keep current "
                   f"target")

def target_kept(coil, target):
    return INFO, f"Keeping target '{target}' for {coil} (confirmed by operator)"

def waiting_for_coil(name):
    return INFO, f"Waiting for {name} crosshairs data"

def coil_lost(name, seconds):
    return WARN, (f"{name} not visible — no crosshairs data for {seconds:.0f} s; "
                  f"drift checks paused (no trigger sent)")

def coil_still_lost(name):
    return WARN, f"{name} still not visible — drift checks paused"

def coil_found(name):
    return OK, f"{name} visible again — drift checks resumed"

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
