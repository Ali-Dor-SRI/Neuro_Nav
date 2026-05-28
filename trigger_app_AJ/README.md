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
│  alert_brainsight_v2.2.0.py  ──auth─►│ :5050   │ TMS Trigger Receiver         │
│    (polls file at 2 Hz;              │ ──────► │   (auths Mac; listens for    │
│     interactive REPL;                │ STATE:  │    STATE: lines; types       │
│     sends STATE: on transitions)     │         │    "ss<Enter>" into the      │
│                                      │         │    focused QTrack window)    │
└──────────────────────────────────────┘         └──────────────────────────────┘
```

* Mac runs `python/alert_brainsight_v2.2.0.py` — the same drift monitor
  you've been using, plus optional `--trigger-to HOST:PORT --token TOK`
  flags that maintain a TCP connection to Windows and send `STATE:RED`
  / `STATE:GREEN` on the in/out-of-range transitions.
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
└── tms_token.txt              auto-generated on first run; the shared-secret

python/
├── alert_brainsight_v2.1.0.py terminal-only monitor (unchanged)
└── alert_brainsight_v2.2.0.py monitor + integrated trigger sender   ← current
```

The Mac side does NOT depend on the `trigger_app_AJ/` package — the
protocol constants are inlined in `alert_brainsight_v2.2.0.py` so you
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
  Token : <16-char auto-generated string>
  File  : C:\...\trigger_app_AJ\tms_token.txt

  On the Mac, run:
    python python/alert_brainsight_v2.2.0.py <file> \
        --trigger-to <this-windows-ip>:5050 --token <token>
================================================================
```

Note the IP address (`ipconfig` will show it) and the token. Open
QTrack and leave it focused.

CLI flags:

| Flag              | Meaning                                                       |
|-------------------|---------------------------------------------------------------|
| `--port N`        | Listen on a different port (default 5050)                    |
| `--token TOK`     | Override the on-disk token for this run (not persisted)       |
| `--no-keystroke`  | Dry-run — log received STATE changes but don't type. Testing only. |
| `--show-token`    | Print the current on-disk token and exit                      |

### On the Mac (the sender)

Copy `python/alert_brainsight_v2.2.0.py` to the Mac if not already
there, then:

```bash
python3 alert_brainsight_v2.2.0.py "/path/to/Streamed Info.txt" \
    --trigger-to 192.168.1.20:5050 \
    --token <token-from-windows>
```

The script behaves exactly like v2.1.0 (interactive REPL, per-axis
thresholds, target/driver discovery) — the trigger sender just adds an
extra background thread that pushes STATE: lines on transitions.

`status` at the REPL shows the trigger link state:

```
[status]
    target  : test_target
    driver  : Coil B LCT
    loc thr : 40.0 mm (all axes)
    ang thr : 0.20 rad (all axes)
    remind  : every 100 checks
    trigger : connected
```

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

The token file `tms_token.txt` is created/read **next to the .exe** so
it survives upgrades.

---

## Troubleshooting

- **Mac logs `[trigger] not connected; dropped STATE:RED`** — the
  receiver isn't running, wrong IP, or a firewall is blocking inbound
  on the chosen port. Confirm `python -m trigger_app_AJ.windows.main`
  is running on Windows and `ipconfig` shows the IP you're using on
  the Mac. Windows Firewall may prompt on first run — allow private
  network.
- **`AUTH:DENIED`** — token mismatch. On Windows, run
  `python -m trigger_app_AJ.windows.main --show-token` to see the
  current token, paste it into the Mac `--token` flag.
- **Receiver logs "Replacing previous Mac connection" every few
  seconds** — two Mac scripts are running and competing. Stop one.
- **Keystrokes don't reach QTrack** — QTrack must be the focused
  window; Caps Lock must be OFF. Raise `KEY_INTERVAL` or
  `PRE_ENTER_DELAY` at the top of `windows/qtrack.py` if QTrack drops
  keystrokes.
- **QTrack says "Invalid command"** — the command must be sent
  lowercase. See the docstring at the top of `windows/qtrack.py`.
- **Mac sender says "Waiting for target selection..."** — the
  Brainsight file has no `Target Selection` (MNI) row yet. The
  monitor auto-adopts the first one to appear in the stream. You can
  also pick one interactively once it appears: `set target 1`.

---

## Files

| Path                                       | Purpose                                          |
|--------------------------------------------|--------------------------------------------------|
| `common/protocol.py`                       | `AUTH:` / `STATE:` constants + line reader       |
| `common/config.py`                         | Port, timeouts, token file load/save             |
| `windows/server.py`                        | TCP listener, auth, STATE dispatch               |
| `windows/qtrack.py`                        | `ss`+Enter via pyautogui                         |
| `windows/main.py`                          | CLI entry: `python -m trigger_app_AJ.windows.main` |
| `build/build_windows.bat`                  | PyInstaller .exe builder                         |
| `tms_token.txt`                            | Auto-generated shared-secret token (Windows side)|
| `requirements.txt`                         | `pyautogui` + `pyinstaller`                      |
| `../python/alert_brainsight_v2.2.0.py`     | Mac sender (monitor + trigger output)            |
