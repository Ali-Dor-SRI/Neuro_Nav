"""Headless Windows trigger receiver.

Listens for an authenticated Mac connection, types `ss`+Enter into the
focused window on every STATE change. Logs to stdout. Ctrl+C to quit.

On startup it asks where the time-sync logs should be saved, offering the
folder used last time (Enter accepts it). `--log-dir` answers that in advance.

Usage:
    python -m trigger_app_AJ.windows.main
    python -m trigger_app_AJ.windows.main --port 5050
    python -m trigger_app_AJ.windows.main --new-token         # force fresh token
    python -m trigger_app_AJ.windows.main --token 1234       # set a specific token (persisted)
    python -m trigger_app_AJ.windows.main --show-token        # print on-disk token and exit
    python -m trigger_app_AJ.windows.main --no-keystroke      # dry-run / debug
    python -m trigger_app_AJ.windows.main --log-dir "Y:/Merged Data/time_sync_logs"
    python -m trigger_app_AJ.windows.main --no-prompt         # keep the remembered folder, don't ask
"""

if __name__ == "__main__" and __package__ in (None, ""):
    import os, sys
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))))

import argparse
import os
import signal
import sys
import threading
from datetime import datetime

from trigger_app_AJ.common.config import (
    DEFAULT_PORT,
    current_token,
    get_local_ips,
    is_expired,
    normalize_dir,
    regenerate_token,
    save_log_dir,
    save_token,
    saved_log_dir,
    seconds_until_rotation,
    settings_path,
    token_path,
)
from trigger_app_AJ.common.timesync import default_log_dir
from trigger_app_AJ.windows import qtrack
from trigger_app_AJ.windows.server import TriggerReceiver


def _log(message):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {message}", flush=True)


def _prompt_log_dir(default_dir):
    """Ask where the time-sync logs should be saved; Enter keeps `default_dir`.

    Returns the chosen folder. A blank answer, no console to ask on (stdin
    piped, started by a service/scheduled task) or Ctrl+C at the prompt all
    keep `default_dir` — starting the receiver must never hinge on someone
    being there to answer.
    """
    print("  Where should the time-sync logs be saved?")
    print(f"    [Enter] = {default_dir}")
    if not sys.stdin or not sys.stdin.isatty():
        print("    (no console to type into - using the folder above)")
        print()
        return default_dir
    try:
        typed = input("    > ")
    except (EOFError, KeyboardInterrupt):
        print()
        return default_dir
    print()
    return normalize_dir(typed) or default_dir


def _rotation_note(issued_at):
    """Human-readable 'rotates in N days (on <date>)' for the banner/logs."""
    secs = seconds_until_rotation(issued_at)
    days = secs / 86400.0
    when = datetime.fromtimestamp(issued_at + secs).strftime("%a %d %b, %H:%M")
    return f"rotates in ~{days:.1f} days (on {when})"


def main():
    parser = argparse.ArgumentParser(
        description="Windows trigger receiver (listens for Mac, fires ss+Enter).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"TCP port to listen on (default {DEFAULT_PORT})")
    parser.add_argument("--token", default=None,
                        help="Set a specific token (persisted to disk). "
                             "Overrides any previous on-disk token.")
    parser.add_argument("--new-token", action="store_true",
                        help="Discard the on-disk token and generate a fresh one.")
    parser.add_argument("--no-keystroke", action="store_true",
                        help="Log STATE changes but do not actually type into "
                             "the focused window. Useful for testing.")
    parser.add_argument("--show-token", action="store_true",
                        help="Print the on-disk token and exit.")
    parser.add_argument("--log-dir", default=None, metavar="PATH",
                        help="Folder to save the time-sync logs in (one .txt "
                             "per Mac connection). Skips the startup prompt "
                             "and is remembered for next launch. Defaults to "
                             "the folder used last time.")
    parser.add_argument("--no-prompt", action="store_true",
                        help="Don't ask where to save the time-sync logs — use "
                             "the remembered folder. For shortcuts and "
                             "unattended starts.")
    args = parser.parse_args()

    if args.show_token:
        tok, _issued, _rotated = current_token()
        print(tok)
        return 0

    # ── Resolve which token to use ────────────────────────────────────────────
    if args.new_token and args.token:
        raise SystemExit("Use either --token or --new-token, not both.")

    # auto_rotate: only the managed token rotates weekly. A token pinned with
    # --token is a deliberate fixed shared secret and is left alone.
    auto_rotate = args.token is None
    if args.token:
        token, issued_at = save_token(args.token)
    elif args.new_token:
        token, issued_at = regenerate_token()
    else:
        token, issued_at, _rotated = current_token()

    # ── Resolve where the time-sync logs go ───────────────────────────────────
    # Priority: --log-dir, else ask (pre-filled with the folder used last time,
    # else the built-in one), else -- with --no-prompt or no console -- that
    # same remembered folder. Whatever is chosen is remembered for next launch.
    builtin_log_dir = default_log_dir()
    print()
    if args.log_dir:
        log_dir = normalize_dir(args.log_dir) or builtin_log_dir
    else:
        remembered = saved_log_dir() or builtin_log_dir
        log_dir = remembered if args.no_prompt else _prompt_log_dir(remembered)
    remembered_ok = save_log_dir(log_dir)

    # Create it now so a typo shows up before a session rather than during one.
    # A failure is a warning, not a stop: the receiver's job is to trigger the
    # TMS, and an unreachable share falls back to the built-in folder per sync.
    log_dir_problem = None
    try:
        os.makedirs(log_dir, exist_ok=True)
    except OSError as exc:
        log_dir_problem = str(exc)

    # ── Detect LAN IPs ────────────────────────────────────────────────────────
    ips = get_local_ips()
    primary_ip = ips[0] if ips else "<this machine's LAN IP>"

    # ── Banner ────────────────────────────────────────────────────────────────
    print()
    print("============================================================")
    print("  TMS Trigger Receiver  -  ready and waiting for the Mac")
    print("============================================================")
    print()
    print("  Enter these three values in the Mac app:")
    print()
    if ips:
        print(f"    IP address : {primary_ip}")
        for extra in ips[1:]:
            print(f"                 {extra}   (alternate)")
    else:
        print(f"    IP address : (none detected - check your network connection)")
    print(f"    Port       : {args.port}")
    print(f"    Token      : {token}   (4-digit code)")
    if auto_rotate:
        print(f"                 {_rotation_note(issued_at)}")
    else:
        print(f"                 (fixed via --token; no weekly rotation)")
    print()
    print("  Time-sync logs (one .txt per Mac connection):")
    print(f"    {log_dir}{os.sep}")
    if log_dir_problem:
        print(f"    WARNING: this folder is not writable right now - {log_dir_problem}")
        print( "             If it is still unreachable when a sync arrives, that")
        print(f"             file goes to {builtin_log_dir}{os.sep} instead.")
    elif log_dir != builtin_log_dir:
        print(f"    (falls back to {builtin_log_dir}{os.sep} if this folder is unreachable)")
    if not remembered_ok:
        print("    NOTE: could not save this choice - it will need re-entering next launch.")
    print()
    if args.no_keystroke:
        print("  Mode: DRY-RUN - STATE changes are logged but no keystrokes are sent.")
        print()
    elif not qtrack.is_available():
        print("  WARNING: pyautogui is not installed - keystrokes are disabled.")
        print()
    print("  Keep this window open. Status messages will appear below.")
    print("============================================================")
    print()
    print("  Troubleshooting")
    print("  ---------------")
    print("  If the Mac says 'connection timed out':")
    print(f"    1. From the Mac, check the IP is reachable:   ping {primary_ip}")
    print(f"    2. Allow inbound TCP port {args.port} through Windows Defender Firewall")
    print("    3. Make sure both machines are on the same Wi-Fi / network")
    print("  If the Mac says 'AUTH:DENIED':")
    print("    The token does not match - re-enter the Token shown above exactly.")
    print("  If the time-sync logs are not where you expect:")
    print("    They go to the folder shown above, one file per connection,")
    print("    named for its start time and participant. Change it with the")
    print("    startup prompt or --log-dir \"<folder>\".")
    print(f"  Token is saved at:    {token_path()}")
    print(f"  Log folder saved at:  {settings_path()}")
    print("============================================================")
    print()

    # ── Wire up ───────────────────────────────────────────────────────────────
    def on_state(state, is_change):
        if not is_change:
            _log(f"STATE:{state}  (no change, ignored)")
            return
        _log(f"STATE:{state}  -> firing keystroke")
        if args.no_keystroke:
            _log("  (--no-keystroke set; suppressed)")
        else:
            qtrack.send_command(on_log=_log)

    def on_peer_change(connected, addr_str):
        if connected:
            _log(f"Mac connected from {addr_str}")
        else:
            _log("Mac disconnected; awaiting new connection")

    def on_timesync(offset, delay, peer_str, participant):
        sign = "ahead of" if offset >= 0 else "behind"
        who  = f" for {participant}" if participant else ""
        _log(f"Clock offset{who}: Windows is {abs(offset) * 1000.0:.1f} ms {sign} "
             f"the Mac (delta {offset:+.6f} s, rtt {delay * 1000.0:.2f} ms)")

    def on_participant(participant):
        # Echo it: this is the QTrack operator's chance to catch a wrong
        # participant before the session's data is logged under it.
        if participant:
            _log(f"Session: {participant}")
        else:
            _log("Session: (none supplied - time-sync rows will be unlabelled)")

    receiver = TriggerReceiver(
        token            = token,
        port             = args.port,
        on_state         = on_state,
        on_peer_change   = on_peer_change,
        on_timesync      = on_timesync,
        on_participant   = on_participant,
        on_log           = _log,
        timesync_log_dir = log_dir,
        fallback_log_dir = builtin_log_dir,
    )
    receiver.start()

    stop_event = threading.Event()
    def _stop(_signum, _frame):
        stop_event.set()
    signal.signal(signal.SIGINT,  _stop)
    signal.signal(signal.SIGTERM, _stop)

    try:
        while not stop_event.is_set():
            # Weekly rotation: once the managed token is a week old, mint a
            # fresh one and hand it to the receiver. The currently connected
            # Mac stays connected; the new code is needed on the next connect.
            if auto_rotate and is_expired(issued_at):
                token, issued_at = regenerate_token()
                receiver.set_token(token)
                _log("Weekly token rotation — RE-ENTER this code in the Mac app:")
                _log(f"    Token : {token}   ({_rotation_note(issued_at)})")
            stop_event.wait(0.5)
    finally:
        _log("Shutting down...")
        receiver.stop()
        _log("Goodbye.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main() or 0)
