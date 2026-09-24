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
│  alert_brainsight_v2.6.0.py  ──auth─►│ :5050   │ TMS Trigger Receiver         │
│    (polls file at 2 Hz;              │ ──────► │   (auths Mac; listens for    │
│     interactive REPL;                │ STATE:  │    STATE: lines; types       │
│     sends STATE: on transitions)     │         │    "ss<Enter>" into the      │
│                                      │         │    focused QTrack window)    │
└──────────────────────────────────────┘         └──────────────────────────────┘
```

* Mac runs `python/alert_brainsight_v2.6.0.py` — the same drift monitor
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
* **The participant ID is typed on the Mac** (v2.5.0) and travels over the
  same link; Windows stamps it on every time-sync row, so each clock offset
  says whose session it belongs to. See [Participant ID](#participant-id).
* **Every connection writes its own time-sync file**, named for the moment it
  connected and the participant — one session's clock offset is one file,
  instead of one row buried in a log that grows across the whole study. **The
  receiver asks at startup where to save them** (remembered between launches;
  `--log-dir` to preset it), so they can land straight on the lab share. See
  [Time-sync logs](#time-sync-logs).
* **Triggering can be switched off** (v2.4.0): `--no-triggers` at launch,
  or `set trigger on|off` at the REPL (GUI: the "Send TMS triggers" switch),
  suppresses the `STATE:` sends while keeping the link, time-sync, and drift
  monitoring live — run the monitor for time-sync + distance only, no `ss`
  to QTrack. See [Trigger semantics](#trigger-semantics).

---

## Directory layout

```
trigger_app_AJ/
├── common/
│   ├── protocol.py            AUTH + SESSION + STATE + TIME line format
│   ├── timesync.py            clock-offset maths + per-connection log writer
│   └── config.py              port, paths, token load/save
├── windows/
│   ├── server.py              TCP listener + auth + SESSION/STATE/TIME dispatch
│   ├── qtrack.py              ss+Enter keystroke (pyautogui)
│   └── main.py                CLI entry point
├── build/
│   └── build_windows.bat      PyInstaller .exe builder
├── README.md
├── requirements.txt
├── time_sync_logs/            auto-generated; default/fallback time-sync log folder
├── receiver_settings.json     auto-generated; the log folder the operator chose
└── tms_token.json             auto-generated; 4-digit code + weekly-rotation issue time

python/
├── alert_brainsight_v2.1.0.py terminal-only monitor (unchanged)
├── alert_brainsight_v2.2.0.py monitor + integrated trigger sender
├── alert_brainsight_v2.3.0.py + auto-follow of file's target selection
├── alert_brainsight_v2.4.0.py + TMS triggering on/off toggle
├── alert_brainsight_v2.5.0.py + participant ID on the time-sync log
└── alert_brainsight_v2.6.0.py + auto coil-swap following ← current
```

The Mac side does NOT depend on the `trigger_app_AJ/` package — the
protocol constants are inlined in `alert_brainsight_v2.6.0.py` so you
can copy that single file to the Mac and run it.

---

## Quick start

### On the Windows machine (the receiver)

```bat
pip install -r trigger_app_AJ\requirements.txt
python -m trigger_app_AJ.windows.main
```

It first asks where to save the time-sync logs, offering the folder you used
last time — press Enter to accept it, or paste a different one (see
[Time-sync logs](#time-sync-logs)):

```
  Where should the time-sync logs be saved?
    [Enter] = C:\TMS\trigger_app_AJ\time_sync_logs
    > Y:\Merged Data\time_sync_logs
```

Then:

```
================================================================
  Windows Trigger Receiver
  Port  : 5050
  Token : 0042   (4-digit code)
          rotates in ~7.0 days (on Mon 10 Jun, 09:15)
  File  : C:\...\trigger_app_AJ\tms_token.json

  On the Mac, run:
    python python/alert_brainsight_v2.6.0.py <file> \
        --trigger-to <this-windows-ip>:5050 --token <4-digit code> \
        --participant <study code>
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
| `--log-dir PATH`  | Save the time-sync logs in `PATH` (skips the startup prompt; remembered) |
| `--no-prompt`     | Don't ask where to save them — use the remembered folder      |

### On the Mac (the sender)

Copy `python/alert_brainsight_v2.6.0.py` to the Mac if not already
there, then:

```bash
python3 alert_brainsight_v2.6.0.py "/path/to/Streamed Info.txt" \
    --trigger-to 192.168.1.20:5050 \
    --token <token-from-windows> \
    --participant SNBR-000
```

The script keeps the v2.1.0 REPL (per-axis thresholds, target/driver
discovery) and the v2.2.0 trigger sender, adds auto-follow of the
file's target selection (below), lets you gate the SS triggers with
`--no-triggers` / `set trigger on|off` (v2.4.0, see
[Trigger semantics](#trigger-semantics)), and labels the session with
`--participant` (v2.5.0, see [Participant ID](#participant-id)).

`status` at the REPL shows the trigger link state:

```
[status]
    subject : SNBR-000
    target  : test_target
    follow  : on
    driver  : Coil B LCT
    loc thr : 40.0 mm (all axes)
    ang thr : 0.20 rad (all axes)
    remind  : every 100 checks
    trigger : connected
    SS keys : on
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

## Participant ID

Every clock-offset row the Windows receiver writes is stamped with the study
code for the session — and the id also names the connection's log file — so a
sync can be matched to a participant long after the session.

**Where you type it: the Mac.** In the GUI it is the first field of the Setup
panel (required, and shown in the Perform panel's top bar during the session);
on the CLI it is `--participant SNBR-000`. It reaches Windows over the trigger
link as a `SESSION:` line, sent before the time-sync so the connection's first
row is already labelled.

It is deliberately *not* entered on the Windows receiver. That process types
`ss` into whatever window has focus — clicking into its console to type would
take focus off QTrack, and a trigger arriving at that moment would land in the
console instead. The receiver echoes the id it received so the QTrack operator
can still check it:

```
[10:25:41] Session: SNBR-000
```

**Use the study code, never a name.** The logs are plain text files on the
Windows machine, and the id appears in their *filenames* as well as their rows
(git-ignored, but not otherwise protected).

**Correcting a typo.** `set participant <id>` at the CLI re-sends it live; rows
already written keep the old id, so reconnect (GUI: Back → Next) if you need a
freshly labelled row. In the GUI the field is read-only during a session for
the same reason — going Back reconnects and writes a new row.

**If none is supplied** (CLI without `--participant`), the column is written
empty and the receiver logs that the rows will be unlabelled.

---

## Time-sync logs

**One file per connection.** Each time a Mac authenticates, its clock offset
goes into a new file in the log folder, named for the moment the connection was
made and the participant it declared:

```
time_sync_logs/
├── time_sync_2026-09-10_09-14-22_SNBR-000.txt
├── time_sync_2026-09-10_11-02-58_SNBR-001.txt
└── time_sync_2026-09-10_13-47-05.txt          ← no participant supplied
```

A session's offset is therefore a file you can copy, rename, or file alongside
the QTrack export, instead of one row to find inside a log that grows across
the whole study. Reconnecting mid-session (the link drops, or the operator goes
Back in the GUI to fix the participant) makes a *new* file — reconnects are
exactly what re-runs the sync, so the newest file is the live one.

Each file carries the same `#` header and the same ten tab-separated columns
the shared log used to carry, so anything that parsed that log parses one of
these unchanged. Details of the row format are under
[Wire protocol](#wire-protocol).

- **The file is created on the connection's first successful sync**, not at
  connect time, so a connection that never syncs leaves no empty file behind.
- Two connections in the same second get `-2`, `-3` suffixes; an existing
  file is never appended to by a later connection.
- The receiver names the file it wrote in its console log:
  `... - logged for SNBR-000 (new log file: ...\time_sync_2026-09-10_09-14-22_SNBR-000.txt)`.
- **Analysis:** point `TIMESYNC_LOG_PATH` in
  `data_analysis/R/sync_mep_times.R` at the log folder — it reads every file in
  it, pools the rows in time order, and adds a `log_file` column. A single
  `.txt` path still works (one connection's file, or an older shared log).

### Choosing where they are saved

The receiver **asks at startup**, offering the folder used last time:

```
  Where should the time-sync logs be saved?
    [Enter] = C:\TMS\trigger_app_AJ\time_sync_logs
    > Y:\Merged Data\time_sync_logs
```

Point it straight at the lab share and the logs land next to the QTrack
exports, with no copying step after a session.

- **Enter** keeps the offered folder. A pasted path may be quoted (Explorer's
  "Copy as path" adds the quotes) and may use `%VARS%` or `~` — all handled.
- **It is remembered** in `receiver_settings.json` next to the `.exe`
  (git-ignored), so a share path is typed once, not every session.
- **`--log-dir "<folder>"`** answers the question in advance — put it in the
  desktop shortcut and the receiver never asks. It is remembered too.
  **`--no-prompt`** keeps the remembered folder without asking. The prompt is
  also skipped automatically when there is no console to ask on (started by a
  scheduled task or with piped input), so an unattended start never hangs.
- The folder is created at startup if it doesn't exist. If that fails you get a
  warning, not a refusal to start — the receiver's job is to trigger the TMS.

**If the folder is unreachable when a sync arrives** (share down, drive letter
not mapped), that connection's file is written to the built-in
`time_sync_logs/` folder next to the `.exe` instead, and the receiver says so:

```
[10:25:41] Time-sync: cannot write to the chosen log folder (Y:\Merged Data\time_sync_logs): ...
[10:25:41] Time-sync: wrote to the built-in folder instead - copy it to the share afterwards, ...
```

The clock offset is the one thing the offline analysis cannot be reconstructed
without, so it is never dropped just because a share is down. Copy those files
across afterwards. Triggering is unaffected either way.

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

**Participant (Mac → Windows, once right after AUTH:OK, before the time-sync):**
```
SESSION:<participant_id>
```
The study code for the session, typed on the **Mac** (Setup panel, or
`--participant` / `set participant <id>` on the CLI). One-way — Windows does
not reply; it holds the value for the life of the connection and stamps it on
every time-sync row it writes (and on the name of that connection's log file),
so each clock offset says which participant it belongs to. Sent *before* `TIME:` so the connection's first sync
row is already labelled. A later re-send (typo fix) applies to subsequent rows;
rows already written keep the old id — reconnect to get a fresh, correctly
labelled row. The id is sanitized on both ends (`sanitize_participant`): no
tabs (the log is tab-separated), no newlines (the wire is line-oriented),
capped at 64 characters.

It is entered on the Mac rather than the Windows receiver on purpose: the
receiver types `ss` into whatever window has focus, so typing on that machine
mid-session could swallow a keystroke meant for QTrack. The receiver echoes the
id to its console (`Session: …`) so the QTrack operator can still
verify it.

**Time-sync (round-trip, once right after the SESSION line, before any STATE traffic):**
```
Mac → Win:  TIME:<t1>            t1 = Mac epoch when sent
Win → Mac:  TIMEACK:<t2> <t3>    t2 = Win recv epoch, t3 = Win send epoch
Mac → Win:  TIMESYNC:<t1> <t4>   t4 = Mac epoch when TIMEACK arrived
Win → Mac:  TIMEOK:<offset> <delay>   ← result + "received & logged" notice
```
Windows computes the clock offset itself —
`offset = ((t2-t1)+(t3-t4))/2 = Windows_clock − Mac_clock` (positive ⇒ Windows
ahead) — and `delay` is the round-trip network time, which the formula cancels
out of `offset`. The result is written to **this connection's own log file**
(see [Time-sync logs](#time-sync-logs)) as one tab-separated row:

```
win_local_time  delta_s  rtt_ms  mac_local_time  peer  t1  t2  t3  t4  participant
```

`participant` is the id from the `SESSION:` line (empty if none was sent). To
align the neuronav (Mac) and TMS/EMG (Windows) recordings:
`windows_time = mac_time + offset`. The `TIMEOK` reply is the Mac's
confirmation that its timestamp was received and logged; the sync is
best-effort and a failure does not abort the trigger link.

**Steady state (Mac → Windows):**
```
STATE:RED          ← sent on in-range → out-of-range transition
STATE:GREEN        ← sent on out-of-range → in-range transition
```

A newer authenticated Mac connection replaces the older one
(`Replacing previous Mac connection` shows in the receiver log). Each new
connection re-runs the time-sync, so reconnects refresh the offset.

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

### Toggling triggers off (monitoring-only)

`--no-triggers` at launch, or `set trigger on|off` at the REPL (GUI: the
**"Send TMS triggers (SS start/stop to QTrack)"** switch in the Perform
panel), gates the sends. With triggering **off** the Mac still connects,
time-syncs, and reports drift — it just never emits `STATE:`, so no `ss`
reaches QTrack. It's a **pure gate**: flipping it never itself sends a
trigger, so QTrack's current stimulation state is left untouched at the
instant you toggle; on re-enable, the next out→in / in→out transition
fires normally. Default **on** (current behavior); the connection stays up
either way, so time-sync still runs. `status` shows the gate as `SS keys`.

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

The token file `tms_token.json` and the settings file
`receiver_settings.json` are created/read **next to the .exe**, so the 4-digit
code, its weekly rotation schedule, and the chosen time-sync log folder all
survive upgrades. The built-in `time_sync_logs/` fallback folder sits there
too.

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
| `common/protocol.py`                       | `AUTH:` / `SESSION:` / `STATE:` / `TIME:` constants + builders + line reader |
| `common/timesync.py`                       | Clock-offset maths + per-connection log writer   |
| `common/config.py`                         | Port, timeouts, 4-digit token + weekly rotation, log-folder setting |
| `windows/server.py`                        | TCP listener, auth, STATE + time-sync dispatch   |
| `windows/qtrack.py`                        | `ss`+Enter via pyautogui                         |
| `windows/main.py`                          | CLI entry: `python -m trigger_app_AJ.windows.main` |
| `build/build_windows.bat`                  | PyInstaller .exe builder                         |
| `tms_token.json`                           | Auto-generated 4-digit token + issue time (Windows side) |
| `receiver_settings.json`                   | Auto-generated; time-sync log folder the operator chose  |
| `requirements.txt`                         | `pyautogui` + `pyinstaller`                      |
| `../python/alert_brainsight_v2.6.0.py`     | Mac sender (monitor + trigger output)            |
