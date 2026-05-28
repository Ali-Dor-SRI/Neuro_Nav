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
import time
from datetime import datetime

from trigger_app_AJ.common.config import (
    DEFAULT_PORT,
    TOKEN_FILENAME,
    get_local_ips,
    load_or_create_token,
    regenerate_token,
    save_token,
    token_path,
)
from trigger_app_AJ.windows import qtrack
from trigger_app_AJ.windows.server import TriggerReceiver


def _log(message):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {message}", flush=True)


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
        tok, _ = load_or_create_token()
        print(tok)
        return 0

    # ── Resolve which token to use ────────────────────────────────────────────
    if args.new_token and args.token:
        raise SystemExit("Use either --token or --new-token, not both.")

    if args.token:
        token = args.token
        save_token(token)
        token_origin = f"--token flag (saved to {TOKEN_FILENAME})"
    elif args.new_token:
        token = regenerate_token()
        token_origin = f"freshly regenerated (saved to {TOKEN_FILENAME})"
    else:
        token, is_new = load_or_create_token()
        token_origin = (f"newly generated (saved to {TOKEN_FILENAME})" if is_new
                        else f"loaded from {TOKEN_FILENAME}")

    # ── Detect LAN IPs ────────────────────────────────────────────────────────
    ips = get_local_ips()
    primary_ip = ips[0] if ips else "<this machine's LAN IP>"

    # ── Banner ────────────────────────────────────────────────────────────────
    print()
    print("============================================================")
    print("  Windows Trigger Receiver")
    print("============================================================")
    print(f"  Listening on  : 0.0.0.0:{args.port}  (all interfaces)")
    if ips:
        print(f"  Reachable at  : {primary_ip}:{args.port}")
        for extra in ips[1:]:
            print(f"                  {extra}:{args.port}")
    else:
        print(f"  Reachable at  : (no LAN IPs detected - check network)")
    print(f"  Token         : {token}")
    print(f"  Token source  : {token_origin}")
    print(f"  Token file    : {token_path()}")
    if args.no_keystroke:
        print(f"  Mode          : DRY-RUN (no keystrokes will be sent)")
    elif not qtrack.is_available():
        print(f"  WARNING       : pyautogui not installed - keystrokes disabled.")
    print()
    print("  On the Mac, run:")
    print(f"    python3 alert_brainsight_v2.2.0.py <file> \\")
    print(f"        --trigger-to {primary_ip}:{args.port} \\")
    print(f"        --token {token}")
    print()
    print("  If the Mac reports 'connection timed out':")
    print(f"    1. Confirm the IP above is reachable from the Mac (ping {primary_ip})")
    print(f"    2. Allow inbound TCP {args.port} through Windows Defender Firewall")
    print(f"    3. Confirm both machines are on the same LAN / subnet")
    print("  If the Mac reports 'AUTH:DENIED': the token is wrong - copy from above.")
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
            time.sleep(0.5)
    finally:
        _log("Shutting down...")
        receiver.stop()
        _log("Goodbye.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main() or 0)
