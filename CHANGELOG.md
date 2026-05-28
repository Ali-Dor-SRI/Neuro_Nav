# Changelog

All notable changes to this project are documented here. The project
follows [semantic versioning](https://semver.org/) per-component
(`alert-brainsight-vX.Y.Z`, `trigger-app-vX.Y.Z`, `gui-vX.Y.Z`) plus a
project-wide release tag (`vX.Y.Z`).

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
