"""Headless Windows trigger receiver.

Listens for an authenticated Mac connection, types `ss`+Enter into the
focused window on every STATE change. Logs to stdout. Ctrl+C to quit.

Usage:
    python -m trigger_app_AJ.windows.main
    python -m trigger_app_AJ.windows.main --port 5050
    python -m trigger_app_AJ.windows.main --new-token         # force fresh token
    python -m trigger_app_AJ.windows.main --token mySharedTok # set a specific token (persisted)
    python -m trigger_app_AJ.windows.main --show-token        # print on-disk token and exit
    python -m trigger_app_AJ.windows.main --no-keystroke      # dry-run / debug
"""

if __name__ == "__main__" and __package__ in (None, ""):
    import os, sys
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))))

import argparse
import signal
import threading
from datetime import datetime

from trigger_app_AJ.common.config import (
    DEFAULT_PORT,
    current_token,
    get_local_ips,
    is_expired,
    regenerate_token,
    save_token,
    seconds_until_rotation,
    token_path,
)
from trigger_app_AJ.windows import qtrack
from trigger_app_AJ.windows.server import TriggerReceiver


def _log(message):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {message}", flush=True)


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
    print(f"  Token is saved at: {token_path()}")
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

    receiver = TriggerReceiver(
        token         = token,
        port          = args.port,
        on_state      = on_state,
        on_peer_change= on_peer_change,
        on_log        = _log,
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
