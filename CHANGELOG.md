# Changelog

All notable changes to this project are documented here. The project
follows [semantic versioning](https://semver.org/) per-component
(`alert-brainsight-vX.Y.Z`, `trigger-app-vX.Y.Z`, `gui-vX.Y.Z`) plus a
project-wide release tag (`vX.Y.Z`).

---

## `gui-v0.2.0` — 2026-09-23

### Added — the GUI asks for a target after a coil swap

A coil swap keeps the current target, so if nobody selects a new one the
new coil is judged against the old coil's target. Now, when a swap is
followed and the active target has **not changed in the 30 s before it**
(`TARGET_CHANGE_LOOKBACK_SEC`), the Perform panel shows a red banner
("Coil changed to Coil B LCT, but the target was not changed…"), rings the
bell, and logs an alert.

- The banner clears when the operator picks a target from the Target
  dropdown (re-picking the same one counts), when Brainsight's selection
  changes the active target via auto-follow, or on **Keep current target**
  (logged as confirmed).
- Adopting the first target at startup doesn't count as a change, so a
  swap soon after launch still prompts.
- It's a prompt only: trigger behaviour on a swap is unchanged (stimulation
  stops at the swap and resumes when the new coil is on target).
- `MonitorWorker`: `get_target_prompt()`, `keep_target()`,
  `on_target_prompt_changed`. GUI-only; the CLI (v2.6.0) is unchanged.

### Changed — the window resizes to any size

The 640×600 minimum is gone. The panels sit in a new scroll container
(`scroll_frame.py`): with room to spare they stretch to fill the window (the
log grows with it); when the window is smaller than the controls, scrollbars
appear (mouse wheel / Shift+wheel) instead of cutting controls off. The log's
requested size is smaller so it can shrink before anything else scrolls.

---

## `alert-brainsight-v2.6.0` — 2026-09-16

### Added — the monitor follows a coil swap made in Brainsight

Brainsight only writes `Crosshairs Position` rows for the coil selected in
it, so switching coils shows up in the file as the driver name changing
(`Coil A CT` → `Coil B LCT` in SNBR-157, -179 and -188). Previously the Mac
kept tracking the old driver and never saw the new coil's rows.

- **Mac CLI** (`python/alert_brainsight_v2.6.0.py`; v2.5.0 kept): coil-follow,
  ON by default. The driver adopted at startup is the file's current coil (no
  menu); every later switch is followed and logged as `[SWAP]`.
  `--no-coil-follow` restores the menu-picked, pinned driver; `set driver`
  pins one (and turns coil-follow off); `set coil-follow on|off` toggles it
  live. Shown in `list` and `status`.
- **Swap handling:** the old coil's last pose is discarded. If the state was
  in range and triggering is on, `STATE:RED` is sent, so stimulation stops at
  the swap; the new coil's first on-target pose sends `STATE:GREEN` through
  the normal transition. If already out of range, nothing extra is sent. The
  target is unchanged (an MNI pose, valid for either coil).
- **Stale-pose timeout:** no crosshairs row for the tracked driver for 30 s
  (`POINTER_STALE_SEC`) drops its last pose and pauses drift checks
  (`[LOST]` / `[FOUND]`). No trigger is sent and the in/out-of-range state is
  kept. Before this, a coil out of view (or swapped away) was judged on its
  last pose indefinitely.
- **Mac GUI** (`brainsight_gui/`): same logic in `MonitorWorker`
  (`set_coil_follow()`, `on_coil_follow_changed`), plus an "Auto-follow coil
  selected in Brainsight" checkbox under the driver dropdown; picking a driver
  unchecks it. A file that already contains a swap now opens on the current
  coil rather than the first one seen.

---

## `trigger-app-v2.7.0` — 2026-09-14

### Added — the operator chooses where the time-sync logs are saved

The Windows receiver no longer writes only to its own install folder. It
**asks at startup** where the per-connection time-sync logs should go,
offering the folder used last time:

```
  Where should the time-sync logs be saved?
    [Enter] = C:\TMS\trigger_app_AJ\time_sync_logs
    > Y:\Merged Data\time_sync_logs
```

Point it at the lab share and the logs land next to the QTrack exports, with
no copying step after a session. Still terminal-only.

- **`windows/main.py`**: the startup prompt (Enter = the offered folder), plus
  `--log-dir "<folder>"` to answer it in advance (for a desktop shortcut) and
  `--no-prompt` to keep the remembered folder silently. The prompt is skipped
  automatically when there is no console to ask on — a scheduled task or piped
  stdin — so an unattended start never hangs. The banner shows the folder in
  use, where the choice is stored, and the fallback.
- **`common/config.py`**: `receiver_settings.json` next to the .exe (new,
  git-ignored) remembers the folder — `saved_log_dir()` / `save_log_dir()` —
  so a share path is typed once, not every session. `normalize_dir()` cleans
  up what gets pasted: Explorer's "Copy as path" quotes, stray whitespace,
  `%VARS%` and `~`. Failing to save the choice is a note, never a stop.
- **`windows/server.py`**: new `fallback_log_dir=`. If the chosen folder is
  unwritable when a sync lands (share down, drive letter not mapped), the row
  is written to the built-in `time_sync_logs/` as a new file instead — the
  connection's later syncs follow it there — and the receiver logs the reason
  and the location. The clock offset is the one thing the offline analysis
  cannot be reconstructed without, so it is never dropped just because a share
  is offline. Triggering is unaffected either way.
- **`common/timesync.py`**: `timesync_log_dir()` → `default_log_dir()`, now
  documented as the default *and* the always-local fallback.

The folder is created at startup if missing; a failure there is a warning, not
a refusal to start. File naming, row format, and the file-per-connection layout
are unchanged, so `data_analysis/R/sync_mep_times.R` just points at wherever
the logs now live.

---

## `trigger-app-v2.6.0` — 2026-09-10

### Changed — one time-sync log file per connection

The Windows receiver no longer appends every clock offset to a single
`time_sync_log.txt` that grows across the whole study. **Each Mac connection
now writes its own file** into `time_sync_logs/`, named for the moment it
connected and the participant it declared:

```
time_sync_logs/
├── time_sync_2026-09-10_09-14-22_SNBR-000.txt
├── time_sync_2026-09-10_11-02-58_SNBR-001.txt
└── time_sync_2026-09-10_13-47-05.txt          ← no participant supplied
```

A session's clock offset is now a file you can copy or file alongside the
QTrack export, rather than a row to locate inside a shared log.

- **`common/timesync.py`**: `timesync_log_path()` → `timesync_log_dir()`, new
  `new_log_path(started_at, participant, directory)` (creates the folder,
  builds the name, suffixes `-2`/`-3` on a same-second collision so an earlier
  connection's file is never reused). `append_log()` now takes the target
  `path` as its first argument. The participant is squashed to a
  filename-safe slug for the name only — the row still carries it verbatim.
  The pre-participant-log migration note was dropped: every file is new, so it
  always gets the full header and can never have a mixed row width.
- **`windows/server.py`**: `timesync_log_path=` → `timesync_log_dir=`; the
  connection's start time and log path join the per-connection state that is
  reset on connect/disconnect. The file is created **lazily, on the first
  successful sync**, so a connection that never syncs leaves nothing behind,
  and the participant (sent before `TIME:`) is already known when it is named.
  The console line now says which file was written.
- **`windows/main.py`**: the startup banner points at the folder.
- **Analysis** (`data_analysis/R/sync_mep_times.R`): `read_timesync()` accepts
  a **folder** — it reads every `time_sync*.txt` in it, pools the rows in
  chronological order (so `DELTA_SELECT` "first"/"last"/"nearest" mean what
  they always did) and adds a `log_file` column. A single `.txt` path still
  works, including an older shared log.
- **`.gitignore`**: `time_sync_logs/` and `time_sync_*.txt` alongside the
  existing `time_sync_log.txt`.

Row format is unchanged — the same `#` header and the same ten tab-separated
columns — so anything that parsed the old log parses one of these files as-is.
Existing `time_sync_log.txt` files are left where they are; nothing writes to
them any more.

---

## `alert-brainsight-v2.5.0` — 2026-09-01

### Added — participant ID recorded on the time-sync log

The study code for a session is now entered on the **Mac** and stamped by the
Windows receiver on every row of `time_sync_log.txt`, so each clock offset
records whose session it belongs to.

- **Wire protocol** (`trigger_app_AJ/common/protocol.py`): new one-way
  `SESSION:<participant_id>` line, sent by the Mac immediately after `AUTH:OK`
  and **before** the time-sync handshake, so a connection's first sync row is
  already labelled. New `sanitize_participant()` (shared contract, mirrored in
  the two stdlib-only Mac copies) strips tabs/newlines/non-printables and caps
  the id at 64 characters — the wire is line-oriented and the log is
  tab-separated, so an unsanitized paste would corrupt both.
- **Windows receiver** (`windows/server.py`, `windows/main.py`): holds the id
  for the life of the connection (cleared on connect/disconnect), stamps it on
  each logged row, echoes `Session: …` to the console so the QTrack
  operator can verify it, and exposes it via `on_participant` /
  `on_timesync(..., participant)`.
- **Log format** (`common/timesync.py`): `participant` added as the **last**
  column, so the nine existing columns keep their positions for anything
  already parsing the log. Appending to a pre-participant log writes a one-time
  `#` note recording the width change.
- **Mac CLI** (`python/alert_brainsight_v2.5.0.py`): `--participant SNBR-000`
  at launch, `set participant <id>` live (applies to rows logged from then on —
  reconnect for a fresh row under a corrected id), shown in `status`.
- **Mac GUI** (`brainsight_gui/`): required "Participant ID" field at the top of
  Setup, normalized in place on submit, displayed read-only in the Perform top
  bar. Deliberately **not** persisted to `config.json` (it changes per session
  and it is participant data).
- **Analysis** (`data_analysis/R/sync_mep_times.R`): `read_timesync()` now
  splits rows by hand instead of `read.table`, so mixed 9-/10-field logs parse,
  and returns a `participant` column (`NA` where a row is unlabelled).

Why the Mac end: the Windows receiver types `ss` into whatever window has
focus, so clicking into its console to type a participant ID would take focus
off QTrack and a trigger arriving at that moment would land in the console.

---

## `dist-v0.1.0` — 2026-05-29

### Added — distributable bundles for both platforms

**Mac (`Brainsight Monitor.app` + `.dmg`):**
- `python/brainsight_gui/build/build_mac.sh` — runs on macOS, produces
  `dist/Brainsight Monitor.app` (windowed, no terminal) and
  `dist/Brainsight Monitor.dmg` (drag-to-Applications installer). Uses
  PyInstaller with `--windowed`, `--osx-bundle-identifier
  com.lab.brainsight.monitor`.
- `python/brainsight_gui/build/generate_icon.py` — Pillow-based icon
  generator. Deep-blue rounded-square gradient + "Bs" monogram at
  1024×1024. Converted to `.icns` by the build script via macOS-native
  `sips` + `iconutil`. Gracefully falls back to the default icon if
  those tools aren't available.

**Windows (`TMS Trigger Receiver.exe`):**
- Existing `trigger_app_AJ/build/build_windows.bat` verified end-to-end
  with the current receiver (LAN-IP detection, `--new-token`, etc.).
  Output: a 30 MB self-contained `.exe` with `--console` mode so
  double-clicking opens a terminal showing the live banner + log.
- `launch_receiver.bat` at the repo root — dev-mode launcher that
  opens a console, runs the receiver from source (`python -m
  trigger_app_AJ.windows.main`), and keeps the window open with
  `pause` for any traceback inspection.

### Distribution flow

| Audience | Mac | Windows |
|---|---|---|
| Dev | `launch_gui.command` (uses local Python) | `launch_receiver.bat` (uses local Python) |
| Lab members | `Brainsight Monitor.dmg` (drag to Applications) | `TMS Trigger Receiver.exe` (double-click) |

Neither lab deliverable requires Python or any pip install on the
target machine.

---

## `gui-v0.1.0` — 2026-05-28

### Added — `python/brainsight_gui/` (Mac-side Tk GUI)

Lightweight Tkinter + ttk GUI that exposes every CLI feature of the
alert monitor without dropping into a terminal. Backend, view, and
controller are cleanly separated:

- **`monitor_worker.py`** — threaded backend. File polling + TCP
  trigger sender wrapped as a class with callback API. No Tk imports.
- **`threshold_widget.py`** — reusable widget: one slider in "general"
  mode, three sliders (X/Y/Z) in "3 DoF" mode, each with an editable
  numeric field below.
- **`setup_panel.py`** — Module 1: file path (with Browse...), Windows
  IP + port, auth token, `Next →` / `Cancel` button.
- **`perform_panel.py`** — Module 2: Crosshairs driver dropdown,
  Target dropdown, linear + angular threshold widgets, scrolling
  color-coded message log, `← Back` button.
- **`app.py`** — main window. Wizard-style navigation between Setup
  and Perform: Setup is shown alone; clicking Next attempts to connect
  to the Windows receiver; once `AUTH:OK` arrives, Setup is hidden and
  Perform takes over. Back returns to Setup, preserving every field /
  slider / dropdown / log entry.
- **`launch_gui.command`** at the repo root — double-click in Finder
  to launch on macOS.

### Trigger semantics — made explicit

The 6-DoF stop/go logic (which has been the actual behavior since
`alert-brainsight-v2.1.0`) is now documented inline and reflected in
every log message:

- **STOP stimulation** if ANY of the 6 DoF exceeds its threshold —
  `STATE:RED` fires the moment the first axis crosses out.
- **START stimulation** only when ALL 6 DoF are within — `STATE:GREEN`
  fires only when the last axis returns in.

Log lines now show `(N of 6 DoF out)` and `(all 6 DoF OK)` so the
operator can see the count at a glance.

---

## [v0.1.0] — 2026-05-28

Initial public release. Tagged commit covers:

### `alert-brainsight-v2.2.0`
- New: integrated TCP trigger sender. With `--trigger-to HOST:PORT
  --token TOK`, the monitor maintains a background TCP connection to a
  Windows trigger receiver and sends `STATE:RED` / `STATE:GREEN` on
  the in/out-of-range transitions. Reminders never fire triggers.
- New: connection is established **before** the file-wait loop, so
  network misconfiguration surfaces immediately instead of being
  hidden by "Waiting for file...".
- `TriggerSender.wait_until_connected(timeout)` — blocks until the
  link is up, with prompt cancellation.

### `alert-brainsight-v2.1.0`
- New: per-axis thresholds for both linear (mm) and angular (rad). The
  CLI flag `--loc`/`--ang` still take a scalar; the REPL accepts
  `set loc 30 40 50` and `set ang 0.1 0.2 0.3` for per-axis control.
- Angular DOFs decomposed as **per-axis tilt** — the angle between the
  target's i-th basis vector and the pointer's i-th. Frame-free, no
  Euler convention, no gimbal lock.
- Alert messages now list every violating axis individually.

### `alert-brainsight-v2.0.1`
- Fix: targets and drivers are now discovered continuously from the
  live stream. Earlier versions scanned the file once at startup, so a
  file that started empty (typical at session start) left the monitor
  permanently stuck on "Waiting for target selection..." and threshold
  changes appeared inert.
- The first target/driver seen is auto-selected; subsequent ones are
  added to the live option pool and can be switched to with
  `set target <n|name>` / `set driver <n|name>`.
- Truncation guard on the read pointer.

### `trigger-app-v0.1.0`
- New: headless Windows trigger receiver
  (`trigger_app_AJ/windows/main.py`). Listens for an authenticated Mac
  connection, types `ss`+Enter into the focused QTrack window on every
  STATE change.
- Wire protocol: `AUTH:<token>` → `AUTH:OK` / `AUTH:DENIED`, then
  `STATE:GREEN` / `STATE:RED` lines from Mac to Windows.
- Startup banner shows the LAN IP, the shared-secret token, the exact
  command to paste on the Mac, and Windows-Defender firewall hints for
  the common "connection timed out" failure mode.
- Token-control flags: `--new-token` (force regenerate), `--token TOK`
  (set + persist), `--show-token` (print + exit).

### Repository
- Mirrored to two GitHub accounts via dual-push on `origin`:
  - `github.com/Ali-Dor-SRI/Neuro_Nav` (canonical)
  - `github.com/Aria-Doroodchi/Neuro_Nav` (mirror)
