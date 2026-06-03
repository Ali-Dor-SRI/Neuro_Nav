# TMS Cross-Platform Trigger System

Two-process pipeline that turns Brainsight drift events on the **Mac**
into QTrack keystrokes on the **Windows** machine. Terminal-only on
both sides — no GUIs.

```
┌──────────────────────────────────────┐         ┌──────────────────────────────┐
│  Mac                                 │         │  Windows                     │
│  ────                                │         │  ───────                     │
│  Brainsight  ──── writes ───►        │         │                              │
│       Streamed Info .txt             │         │                              │
│              │                       │         │                              │
│              ▼                       │  TCP    │                              │
│  alert_brainsight_v2.3.0.py  ──auth─►│ :5050   │ TMS Trigger Receiver         │
│    (polls file at 2 Hz;              │ ──────► │   (auths Mac; listens for    │
│     interactive REPL;                │ STATE:  │    STATE: lines; types       │
│     sends STATE: on transitions)     │         │    "ss<Enter>" into the      │
│                                      │         │    focused QTrack window)    │
└──────────────────────────────────────┘         └──────────────────────────────┘
```

* Mac runs `python/alert_brainsight_v2.3.0.py` — the same drift monitor
  you've been using, plus optional `--trigger-to HOST:PORT --token TOK`
  flags that maintain a TCP connection to Windows and send `STATE:RED`
  / `STATE:GREEN` on the in/out-of-range transitions. The tracked target
  **auto-follows the most-recently selected target in the Brainsight
  file** (see [Auto-follow target](#auto-follow-target) below).
* Windows runs `trigger_app_AJ/windows/main.py` — a headless receiver
  that listens on a port, authenticates the Mac with a shared-secret
  token, and types `ss`+Enter into whatever window is focused (QTrack)
  on every state change.
* Triggers fire on **transitions only** — once when the tracker leaves
  the threshold envelope, once when it returns. Reminders do **not**
  trigger.

---

## Directory layout

```
trigger_app_AJ/
├── common/
│   ├── protocol.py            AUTH + STATE line format
│   └── config.py              port, paths, token load/save
├── windows/
│   ├── server.py              TCP listener + auth + STATE dispatch
│   ├── qtrack.py              ss+Enter keystroke (pyautogui)
│   └── main.py                CLI entry point
├── build/
│   └── build_windows.bat      PyInstaller .exe builder
├── README.md
├── requirements.txt
└── tms_token.json             auto-generated; 4-digit code + weekly-rotation issue time

python/
├── alert_brainsight_v2.1.0.py terminal-only monitor (unchanged)
├── alert_brainsight_v2.2.0.py monitor + integrated trigger sender
└── alert_brainsight_v2.3.0.py + auto-follow of file's target selection ← current
```

The Mac side does NOT depend on the `trigger_app_AJ/` package — the
protocol constants are inlined in `alert_brainsight_v2.3.0.py` so you
can copy that single file to the Mac and run it.

---

## Quick start

### On the Windows machine (the receiver)

```bat
pip install -r trigger_app_AJ\requirements.txt
python -m trigger_app_AJ.windows.main
```

You'll see:

```
================================================================
  Windows Trigger Receiver
  Port  : 5050
  Token : 0042   (4-digit code)
          rotates in ~7.0 days (on Mon 10 Jun, 09:15)
  File  : C:\...\trigger_app_AJ\tms_token.json

  On the Mac, run:
    python python/alert_brainsight_v2.3.0.py <file> \
        --trigger-to <this-windows-ip>:5050 --token <4-digit code>
================================================================
```

Note the IP address (`ipconfig` will show it) and the 4-digit token. Open
QTrack and leave it focused.

The token is a **4-digit code that rotates once a week** (see
[Token](#token) below). Enter it once in the Mac GUI; the GUI remembers it
(and the IP/port) for the next launch, and you only re-enter it after the
weekly rotation.

CLI flags:

| Flag              | Meaning                                                       |
|-------------------|---------------------------------------------------------------|
| `--port N`        | Listen on a different port (default 5050)                    |
| `--token TOK`     | Pin a fixed token (persisted; disables weekly rotation)       |
| `--new-token`     | Mint a fresh 4-digit token now and start a new week           |
| `--no-keystroke`  | Dry-run — log received STATE changes but don't type. Testing only. |
| `--show-token`    | Print the current on-disk token and exit                      |

### On the Mac (the sender)

Copy `python/alert_brainsight_v2.3.0.py` to the Mac if not already
there, then:

```bash
python3 alert_brainsight_v2.3.0.py "/path/to/Streamed Info.txt" \
    --trigger-to 192.168.1.20:5050 \
    --token <token-from-windows>
```

The script keeps the v2.1.0 REPL (per-axis thresholds, target/driver
discovery) and the v2.2.0 trigger sender, and adds auto-follow of the
file's target selection (below).

`status` at the REPL shows the trigger link state:

```
[status]
    target  : test_target
    follow  : on
    driver  : Coil B LCT
    loc thr : 40.0 mm (all axes)
    ang thr : 0.20 rad (all axes)
    remind  : every 100 checks
    trigger : connected
```

---

## Token

The Mac authenticates to the Windows receiver with a shared secret. As of
the current version that secret is:

- **A 4-digit numeric code** (`0000`–`9999`, leading zeros allowed, e.g.
  `0042`) — easy to read off the Windows console and type on the Mac.
- **Rotated once a week.** The receiver persists the code together with its
  issue time in `tms_token.json`. On startup it mints a fresh code if the
  stored one is missing or older than 7 days, and — because the receiver
  often runs for days — it also rotates **live** the moment the week
  elapses, logging the new code:

  ```
  [09:15:02] Weekly token rotation — RE-ENTER this code in the Mac app:
  [09:15:02]     Token : 7321   (rotates in ~7.0 days (on Mon 17 Jun, 09:15))
  ```

  A Mac that is already connected keeps its connection through a rotation;
  the new code is only needed for the next connect.

**Mac remembers the connection.** The Mac GUI saves the Windows IP, port,
and token to `~/Library/Application Support/Neuro_Nav/config.json` after a
successful connection, and prefills them on the next launch — so you only
re-enter the code once a week (when it rotates), not every session.

**Pinning a fixed code.** `--token <code>` on the receiver pins a specific
secret and **disables** weekly rotation (use this if you want a stable code
across the study). `--new-token` mints a fresh code immediately and starts a
new week. `--show-token` prints the current code.

---

## Auto-follow target

By default the monitor **tracks whichever target was most recently
selected in the Brainsight file**. Each time Brainsight writes a new
`Target Selection` (MNI) row, the Mac client switches its active target
to that one and resets alert state — so the operator changes the target
once, in Brainsight, and both the Mac monitor and the Windows trigger
follow automatically.

- `<No Selection>` / `(null)` rows are ignored; the last real target
  keeps being tracked.
- **Pinning:** `set target <n|name>` (or, in the GUI, picking from the
  Target dropdown) pins a target and turns auto-follow **off**, so the
  file's later selections no longer override the operator's choice.
- **Toggle:** `set follow on|off` at the REPL, or the
  "Auto-follow target selected in the Brainsight file" checkbox in the
  GUI. Re-enabling follow immediately jumps to the file's most-recent
  selection.
- **Startup:** auto-follow adopts the most-recent selection already in
  the file. Start with `--no-follow` to instead pick a target from the
  menu and keep it pinned (classic v2.2.0 behavior).

---

## Wire protocol

UTF-8, line-oriented, terminated by `\n`. Port **5050** by default.

**Handshake (Mac → Windows):**
```
AUTH:<token>
```

**Handshake (Windows → Mac):**
```
AUTH:OK            ← token accepted
AUTH:DENIED        ← token mismatch; Windows then closes the socket
```

**Steady state (Mac → Windows):**
```
STATE:RED          ← sent on in-range → out-of-range transition
STATE:GREEN        ← sent on out-of-range → in-range transition
```

A newer authenticated Mac connection replaces the older one
(`Replacing previous Mac connection` shows in the receiver log).

---

## Trigger semantics

The Mac sender tracks `in_exceedance` (the same flag the alert monitor
already used). It fires:

| Transition                          | Mac sends     | Windows action |
|-------------------------------------|---------------|----------------|
| in-range → out-of-range             | `STATE:RED`   | `ss`+Enter     |
| out-of-range → in-range             | `STATE:GREEN` | `ss`+Enter     |
| out-of-range → still-out (reminder) | nothing       | nothing        |

Out-of-range = **any axis** exceeding **either** the linear (mm) or
angular (rad) threshold for that axis. Angular DOFs use "per-axis tilt":
the angle between the target's i-th basis vector and the pointer's
i-th. Frame-free, no Euler convention, no gimbal lock.

### What happens when the network drops

* If the Mac can't reach the receiver when an alert fires, the send is
  dropped and logged (`[trigger] not connected; dropped STATE:RED`).
  The mac sender keeps trying to reconnect in the background.
* On reconnect, the Mac does NOT replay missed transitions — to avoid
  an extra keystroke at every reconnect. Reconnection only restores
  future triggers.

If you need the receiver and sender to re-sync after a drop, restart
the Mac monitor; it'll re-evaluate from the current state.

---

## Installer (no Python required on the Windows machine)

```bat
trigger_app_AJ\build\build_windows.bat
```

Output: `trigger_app_AJ\dist\TMS Trigger Receiver.exe` — a single-file
console exe. Run it from a `cmd` window; it behaves like
`python -m trigger_app_AJ.windows.main` (same flags).

The token file `tms_token.json` is created/read **next to the .exe** so
the 4-digit code and its weekly rotation schedule survive upgrades.

---

## Troubleshooting

- **Mac logs `[trigger] not connected; dropped STATE:RED`** — the
  receiver isn't running, wrong IP, or a firewall is blocking inbound
  on the chosen port. Confirm `python -m trigger_app_AJ.windows.main`
  is running on Windows and `ipconfig` shows the IP you're using on
  the Mac. Windows Firewall may prompt on first run — allow private
  network.
- **`AUTH:DENIED`** — token mismatch, most often because the weekly
  rotation changed the code. On Windows, run
  `python -m trigger_app_AJ.windows.main --show-token` to see the current
  4-digit code, then re-enter it on the Mac (GUI token field, or the
  `--token` flag). The Mac GUI saves the corrected code for next time.
- **Receiver logs "Replacing previous Mac connection" every few
  seconds** — two Mac scripts are running and competing. Stop one.
- **Keystrokes don't reach QTrack** — QTrack must be the focused
  window; Caps Lock must be OFF. Raise `KEY_INTERVAL` or
  `PRE_ENTER_DELAY` at the top of `windows/qtrack.py` if QTrack drops
  keystrokes.
- **QTrack says "Invalid command"** — the command must be sent
  lowercase. See the docstring at the top of `windows/qtrack.py`.
- **Mac sender says "Waiting for target selection..."** — the
  Brainsight file has no `Target Selection` (MNI) row yet. With
  auto-follow on (the default) the monitor adopts the most-recent
  selection as soon as one appears, and tracks every later change. You
  can also pin one interactively: `set target 1` (this turns follow
  off; `set follow on` to resume tracking the file).

---

## Files

| Path                                       | Purpose                                          |
|--------------------------------------------|--------------------------------------------------|
| `common/protocol.py`                       | `AUTH:` / `STATE:` constants + line reader       |
| `common/config.py`                         | Port, timeouts, 4-digit token + weekly rotation  |
| `windows/server.py`                        | TCP listener, auth, STATE dispatch               |
| `windows/qtrack.py`                        | `ss`+Enter via pyautogui                         |
| `windows/main.py`                          | CLI entry: `python -m trigger_app_AJ.windows.main` |
| `build/build_windows.bat`                  | PyInstaller .exe builder                         |
| `tms_token.json`                           | Auto-generated 4-digit token + issue time (Windows side) |
| `requirements.txt`                         | `pyautogui` + `pyinstaller`                      |
| `../python/alert_brainsight_v2.3.0.py`     | Mac sender (monitor + trigger output)            |
