"""QTrack keystroke automation.

QTrack's command is the bare 's' key pressed twice. It MUST be sent
lowercase: pyautogui.write("ss") presses 's' with no Shift modifier —
identical to typing it by hand with Caps Lock off, which QTrack accepts.
Sending "SS" makes pyautogui hold Shift, and QTrack reads that shifted
keypress as a different (invalid) command, even though QTrack always
*displays* the command in capitals.

Keep Caps Lock OFF on this Windows machine, or a bare 's' will be
capitalized by the OS and Shift-folded again.
"""

import time

try:
    import pyautogui
    # pyautogui injects a default 0.1s pause after every call; disable so
    # the keystroke fires fast.
    pyautogui.PAUSE = 0
except ImportError:
    pyautogui = None

COMMAND         = "ss"
KEY_INTERVAL    = 0.05   # seconds between each keystroke; raised from 0.02 for QTrack reliability
PRE_ENTER_DELAY = 0.05   # seconds between the command and Enter — lets QTrack register the command


def is_available():
    return pyautogui is not None


def send_command(on_log=None):
    """Type COMMAND + Enter into whatever window is focused. Returns True on success."""
    if pyautogui is None:
        if on_log:
            on_log("Skipping keystroke: pyautogui not installed.")
        return False
    try:
        pyautogui.write(COMMAND, interval=KEY_INTERVAL)
        if PRE_ENTER_DELAY > 0:
            time.sleep(PRE_ENTER_DELAY)
        pyautogui.press("enter")
        if on_log:
            on_log(f"Sent: {COMMAND} Enter")
        return True
    except Exception as exc:  # pyautogui surfaces platform-specific errors
        if on_log:
            on_log(f"Keystroke failed: {exc}")
        return False
