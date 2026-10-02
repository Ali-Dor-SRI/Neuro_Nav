# Neuro_Nav

Real-time processing and visualization of neuronavigation data from
**Brainsight TMS** sessions. The project is split across Python (`dev/`: real-time
monitoring GUI + trigger receiver) and R (`analysis/`: offline analysis and visualization).

---

## Directory structure

The repo has three top-level areas: **`dev/`** (the live Mac + Windows system),
**`analysis/`** (offline R pipeline + dashboard) and **`archive/`** (retired
code, kept for reference). Raw session data lives on the lab's **UNAS shared
drive**, not in the repo (a local `data/` folder is git-ignored).

```
Neuro_Nav/
├── CLAUDE.md
├── Neuro_Nav.Rproj              R project root (working directory for all R scripts)
├── dev/                         Python import root — run `python -m ...` from here
│   ├── README.md               Wire protocol + run instructions
│   ├── requirements.txt
│   ├── common/                 Protocol constants + config (port, 4-digit weekly token) + time-sync maths
│   ├── windows_receiver/       TCP receiver that types `ss`+Enter into QTrack (+ writes time_sync_logs/)
│   │   ├── main.py / server.py / qtrack.py
│   │   ├── launch_receiver.bat Dev-mode launcher
│   │   └── build/              build_windows.bat (PyInstaller) + icon
│   ├── mac_gui/                Tk GUI wrapping the drift monitor + trigger sender (`python -m mac_gui`)
│   │   ├── launch_gui.command  Double-click launcher for the Mac GUI
│   │   ├── parse_brainsight.py Python parser library (pandas; not imported by the GUI)
│   │   └── build/              build_mac.sh (PyInstaller .app/.dmg) + icon
│   └── tools/                  Lab utilities (rsync_script.sh: upload recordings to the shared drive)
├── analysis/                    Offline MEP-vs-coil-placement pipeline (see "Data analysis pipeline")
│   ├── README.md               User guide for lab members — keep in sync with the code
│   ├── run_analysis.R          Orchestrator — set INPUTS, run
│   ├── clean_mep_times.R       Stage 1 — MEP ptp + wall-clock trigger_time (QtracP .xlsx/.QLG)
│   ├── coil_to_sample_delta.R  Stage 2 — coil distance/angle to target (Polaris head-rel / MNI)
│   ├── mep_vs_coil_distance.R  Stage 3 — per-MEP nearest coil pose at trigger_time
│   ├── join_meps.R / qtrac_mep_pipeline.R   Routes A/B helpers
│   ├── R/                      parse_brainsight.R, sync_mep_times.R
│   ├── offset_study/           Route C — multi-participant 6-DoF coil-offset vs MEP study
│   │   ├── run_offset_study.R  orchestrator: reads manifest.csv, per-participant + group outputs
│   │   ├── manifest.csv        one row per participant (xlsx, QLG, Brainsight, time_sync folder)
│   │   ├── app/app.R           Shiny dashboard; DATA_DIRS_DEFAULT (top of file) = the data folders
│   │   └── R/                  qtrac_io, coil_geometry, brainsight_targets, pulses, analysis, plots, data_locator
│   └── output/                 generated CSV + PNGs (offset_study/<id>/ and offset_study/group/)
└── archive/                     Retired code — not maintained, kept for reference
    ├── cli/                    Mac CLI: alert_brainsight_v1 … v2.6.0.py, monitor_brainsight.py, daq_trigger_out.py
    ├── analysis/               Exploratory R scratch (explore.R, multi_target_explore.R, sandbox.R) + stray outputs
    └── build_artifacts/        Stale PyInstaller .spec files and build_intermediate folders
```

---

## Data format

Brainsight exports tab-delimited `.txt` files. Each line starts with a
**row-type label** that determines the remaining columns:

| Row type             | Key columns                                              |
|----------------------|----------------------------------------------------------|
| `Polaris Tool`       | tracker_name, coord_system, x, y, z, 3×3 rotation mat  |
| `Target Selection`   | target_name, coord_system, loc_x/y/z, 3×3 rotation mat |
| `Crosshairs Position`| crosshairs_driver, coord_system, loc_x/y/z, 3×3 mat    |
| `New Sample`         | sample_name, index, coord_system, loc_x/y/z, 3×3 mat   |
| `New EMG`            | sample_name, EMG peak-to-peak, latency, window, data    |
| `TTL Trigger`        | trigger_name                                            |

- Missing values are written as `(null)`.
- The file is written at **20 Hz** during a live session.
- All spatial coordinates are in **millimetres**; rotation matrices are
  dimensionless (direction cosines).
- Coordinate systems present: `Polaris` (tracker native) and `MNI` (brain space).
  **Use MNI** for all distance/angle calculations.

---

## Python (`dev/` and `archive/cli/`)

All Python under `dev/` is imported from `dev/` as the root (`cd dev`, then
`python -m mac_gui` / `python -m windows_receiver.main`). The CLI tools below
live in `archive/cli/` — **archived**, superseded by the GUI, but still runnable.

### Shared parser — `dev/mac_gui/parse_brainsight.py`

```python
from mac_gui.parse_brainsight import parse_brainsight   # run from dev/

tables = parse_brainsight("data/Session 3  Streamed Info.txt",
                          drop_null_rows=True)   # drops frames where tracker invisible

df_coil    = tables["Polaris Tool"]       # columns: datetime, tracker_name, coord_system, x, y, z, m0n0…m2n2
df_targets = tables["Target Selection"]
df_cross   = tables["Crosshairs Position"]
df_samples = tables["New Sample"]
meta       = tables["_metadata"]          # {'Version': '7', 'Created by': 'Brainsight 2.5.12', …}
```

All `(null)` values become `pd.NA`. Numeric columns are cast to `float`.
`datetime` is a `pandas.Timestamp` (ms precision).

### File monitor — `archive/cli/monitor_brainsight.py`

```bash
python3 archive/cli/monitor_brainsight.py "data/Session 3  Streamed Info.txt"
```

Reports file size and growth every 5 s. Useful to confirm a live session
file is being written before starting more complex tools.

### Drift alert — `archive/cli/alert_brainsight_v2.6.0.py`  ← last CLI version (archived)

```bash
python3 archive/cli/alert_brainsight_v2.6.0.py "data/Session 3  Streamed Info.txt"
python3 archive/cli/alert_brainsight_v2.6.0.py "data/Session 3  Streamed Info.txt" --loc 50 --ang 0.3

# Send STATE:RED / STATE:GREEN triggers to the Windows receiver on transitions:
python3 archive/cli/alert_brainsight_v2.6.0.py "<file>" --trigger-to 192.168.1.20:5050 --token <tok>

# Connected for time-sync + distance monitoring, but NO SS triggers to QTrack:
python3 archive/cli/alert_brainsight_v2.6.0.py "<file>" --trigger-to 192.168.1.20:5050 --token <tok> --no-triggers

# Pin a target manually instead of auto-following the file:
python3 archive/cli/alert_brainsight_v2.6.0.py "<file>" --no-follow

# Pin the crosshairs driver instead of following coil swaps in Brainsight:
python3 archive/cli/alert_brainsight_v2.6.0.py "<file>" --no-coil-follow

# Label the session so Windows stamps the study code on every time-sync row:
python3 archive/cli/alert_brainsight_v2.6.0.py "<file>" --trigger-to 192.168.1.20:5050 --token <tok> --participant SNBR-000
```

**Startup flow:**
1. (If `--trigger-to`) establishes the TCP trigger link to Windows first.
2. Scans the file for all `Target Selection` names and `Crosshairs Position`
   driver names. With auto-follow on (default) it adopts the most-recent
   selection; with `--no-follow` it presents a numbered menu to pick one.
   The driver likewise follows the file's current coil (default) or, with
   `--no-coil-follow`, is picked from a menu.
3. Monitors at **2 Hz** (every 0.5 s — 10× slower than the 20 Hz write rate).
4. Alerts (per-axis: 3 linear + 3 angular DoF) when any DoF drifts beyond
   its threshold; with `--trigger-to`, fires triggers on transitions only.

**Auto-follow target** (v2.3.0): the active target tracks the target most
recently selected in the Brainsight file — operators change the target once,
in Brainsight, and the monitor (and any Windows trigger) follow. `<No
Selection>` / `(null)` rows are ignored (last real target keeps tracking).
A manual `set target` **pins** a target and turns follow off; `set follow on`
resumes. Default ON; start with `--no-follow` for the classic pinned mode.

**TMS triggering toggle** (v2.4.0): sending of the `STATE:RED/GREEN` triggers —
which drive the `ss` start/stop keystrokes on the Windows receiver — can be
switched off independently of the link. With triggering **off**, the monitor
still connects, time-syncs, and reports drift, but sends no trigger: i.e.
time-sync + distance monitoring only. It's a **pure gate** — toggling never
itself sends a trigger, so QTrack's stimulation state is left untouched at the
instant you flip it; on re-enable, the next in/out-of-range transition fires
normally. Default ON (current behavior); start with `--no-triggers` for
monitoring-only, or toggle live with `set trigger on|off`.

**Participant ID** (v2.5.0): `--participant SNBR-000` labels the session. The
id is sent to the Windows receiver as a `SESSION:` line right after auth and
**before** the time-sync handshake, and Windows stamps it on every time-sync
row it logs — and in the name of that connection's log file — so each clock
offset records whose session it belongs to.
It is entered on the **Mac** by design: the Windows receiver types `ss` into
whatever window has focus, so typing there mid-session could swallow a trigger
meant for QTrack (the receiver echoes the id to its console instead). Change it
live with `set participant <id>`; the new value applies to rows logged from
then on, so reconnect if you need a fresh row under a corrected id. Use the
study code, never a name.

**Auto coil-swap following** (v2.6.0): Brainsight only writes `Crosshairs
Position` rows for the coil currently selected in it, so a coil switch shows
up in the file as the driver name changing (`Coil A CT` → `Coil B LCT`, as in
SNBR-157/179/188). With coil-follow on (default) the tracked driver follows
it: at startup the file's current coil is adopted (no driver menu), and each
later switch is logged as `[SWAP]`. On a swap the old coil's last pose is
discarded and, if the state was in range and triggering is on, `STATE:RED` is
sent — stimulation stops at the swap; the new coil's first on-target pose then
sends `STATE:GREEN` through the normal transition (already out of range ⇒
nothing extra is sent). The target is kept — it is an MNI pose, valid for
either coil. A manual `set driver` **pins** a driver and turns coil-follow
off; `set coil-follow on` resumes (and switches to the file's coil the same
way). Start with `--no-coil-follow` for the classic menu-picked, pinned driver.

**Stale-pose timeout** (v2.6.0): if no crosshairs row arrives for the tracked
driver for **30 s** (`POINTER_STALE_SEC`; coil out of the camera's view), its
last pose is dropped and drift checks pause (`[LOST]`, then `[FOUND]` when data
returns). **No trigger is sent** for this — the in/out-of-range state is kept,
so the first real transition after the coil reappears fires normally. Before
v2.6.0 the last pose was judged indefinitely.

**Default thresholds:**

| Parameter | Default | Meaning                          |
|-----------|---------|----------------------------------|
| `--loc`   | 40 mm   | Per-axis linear offset to target |
| `--ang`   | 0.2 rad | Per-axis tilt angle (~11.5°)     |

Per-axis tilt: angle between the target's i-th basis vector and the
pointer's i-th basis vector (frame-free; no Euler convention / gimbal lock).

**Live commands while running:**

```
list                  show available targets and drivers (+ follow state)
set target <n|name>   pin active target (turns auto-follow OFF; resets alert state)
set driver <n|name>   pin active driver (turns coil-follow OFF; resets alert state)
set follow on|off     toggle auto-follow of the file's target selection
set coil-follow on|off  toggle following coil swaps made in Brainsight
set trigger on|off    enable/disable sending SS triggers (monitoring-only when off)
set participant <id>  study code stamped on the Windows time-sync log rows
set loc <mm>          linear threshold — scalar (all axes)
set loc <x> <y> <z>   linear threshold — per-axis
set ang <rad>         angular threshold — scalar (all axes)
set ang <x> <y> <z>   angular threshold — per-axis
set remind <n>        reminder every N checks (default 100, ~50 s)
status                print current settings (incl. follow, trigger link + SS on/off)
quit                  stop
```

Waiting/status messages are **rate-limited to once every 5 s**;
alert and reminder messages fire immediately.

### Mac GUI — `dev/mac_gui/` (`python -m mac_gui`)

Tk wrapper around the v2.6.0 monitor + trigger sender. Two-step wizard:
**Setup** (participant ID, file path, Windows IP/port/token, Connect & Start) →
**Perform** (driver + target dropdowns, per-axis threshold sliders, scrolling log).
The backend is `monitor_worker.MonitorWorker` (mirrors the CLI logic with
callbacks instead of `print`/REPL). Auto-follow is exposed as the
"Auto-follow target selected in the Brainsight file" checkbox; picking from
the Target dropdown pins a target and unchecks it. Coil-follow is the
"Auto-follow coil selected in Brainsight" checkbox under the driver dropdown
(same pin/uncheck behaviour; same swap and 30 s stale-pose handling as the
CLI). **GUI-only target prompt:** when a swap is followed and the active target
hasn't changed in the 30 s before it (`TARGET_CHANGE_LOOKBACK_SEC`), a red
banner asks the operator to pick the target for the new coil; it clears on any
target change (dropdown pick — even the same target — or auto-follow) or on
"Keep current target". Prompt only — trigger behaviour is unchanged. The window
resizes to any size: panels live in `scroll_frame.ScrollFrame`, which stretches
them when there's room and scrolls when there isn't. The **"Send TMS triggers
(SS start/stop to QTrack)"** switch in the Perform panel gates triggering (same
pure-gate semantics as the CLI's `set trigger`): unchecked keeps the link up
for time-sync + distance monitoring but sends no `ss` to QTrack. Defaults ON
each launch (not persisted). `dev/mac_gui/launch_gui.command` double-click-launches it on
the Mac.

The **Participant ID** is the first Setup field and is **required** — an
unlabelled time-sync row can't be matched to a participant afterwards. It is
sent to Windows on connect and shown read-only in the Perform panel's top bar;
to change it, go Back (which reconnects and writes a freshly labelled row).

`mac_gui/config_store.py` persists the Windows IP, port, and token to
`~/Library/Application Support/Neuro_Nav/config.json` after a successful
connection and prefills them on the next launch (the Brainsight file path and
the participant ID are not saved — they change per session, and the id is
participant data).

### Trigger token — `dev/common/config.py`

The Mac↔Windows shared secret is a **4-digit numeric code** (`0000`–`9999`)
that **rotates once a week**. The Windows receiver stores the code and its
issue time in `tms_token.json` (next to the .exe / package), mints a fresh
one at startup if it's >7 days old, and also rotates **live** when the week
elapses while running (logging the new code). `--token <code>` pins a fixed
code and disables rotation; `--new-token` forces a fresh one; `--show-token`
prints the current code. The Mac GUI remembers the code between launches, so
operators only re-enter it after the weekly rotation. (Both token files and
`config.json` are git-ignored.)

### Time sync — `dev/common/timesync.py`

So events recorded on the Mac (neuronav/Brainsight) can be lined up with the
TMS/EMG files recorded on Windows (QTrack), the two clocks are compared **once
per connection**, right after `AUTH:OK` (and the `SESSION:` participant line)
and before any `STATE:` traffic. The exchange is round-trip (NTP-style) so
network latency is cancelled, not folded into the result:

```
Mac → Win:  SESSION:<participant> (sent first; labels the rows below)
Mac → Win:  TIME:<t1>            t1 = Mac epoch when sent
Win → Mac:  TIMEACK:<t2> <t3>    t2 = Win recv epoch, t3 = Win send epoch
Mac → Win:  TIMESYNC:<t1> <t4>   t4 = Mac epoch when TIMEACK arrived
Win → Mac:  TIMEOK:<offset> <delay>
```

Windows computes the offset itself: `offset = ((t2-t1)+(t3-t4))/2 =
Windows_clock − Mac_clock` (positive ⇒ Windows ahead), with `delay` the
round-trip network time. To map a Mac/neuronav timestamp onto the Windows clock:
**`windows_time = mac_time + offset`**. Each result is written as one
tab-separated row — both machines' local wall-clock times, the delta, the
round-trip delay, the four raw epochs, and the **participant** (v2.5.0, last
column; empty when no id was sent).

**One log file per connection.** Every Mac connection gets its own file in the
log folder, named for the moment it connected and the participant it declared,
e.g. `time_sync_2026-09-10_09-14-22_SNBR-000.txt`. The file is created on that
connection's **first successful sync** (a connection that never syncs leaves
no empty file); same-second collisions get a `-2`, `-3` suffix so an earlier
file is never appended to.

**The operator chooses the folder** (v2.7.0). The receiver asks at startup,
offering the folder used last time — Enter accepts it, or paste another (quotes
from Explorer's "Copy as path", `%VARS%` and `~` are all handled). The choice
is remembered in `receiver_settings.json` next to the .exe (git-ignored), so a
lab-share path is typed once. `--log-dir "<folder>"` presets it and skips the
prompt (for a shortcut); `--no-prompt` keeps the remembered folder without
asking, as does having no console to ask on (scheduled task / piped stdin), so
an unattended start never hangs. Default and **fallback** is the built-in
`time_sync_logs/` next to the .exe: if the chosen folder is unwritable when a
sync lands (share down, drive not mapped), that connection's file is written
locally instead and the receiver logs both the reason and where it went — the
clock offset is never dropped because a share is offline, and triggering is
unaffected either way. Every file carries the same `#` header and the same
ten columns the older single `time_sync_log.txt` carried, so a parser written
for that log reads one of these unchanged.
`analysis/R/sync_mep_times.R` takes either the folder (reads every file,
pools the rows in time order, adds a `log_file` column) or a single `.txt`
path, and tolerates the 9-field rows of pre-participant logs. The `TIMEOK` reply is the
Mac's notification that its timestamp was received and logged (surfaced in the
CLI log and the GUI log). The whole exchange is **best-effort** — a sync failure
is logged but never aborts the trigger link. A reconnect re-runs the sync.

---

## R

**Always open `Neuro_Nav.Rproj` in RStudio before running any R script.**
This sets the working directory to the project root, which all relative
paths assume.

### Shared parser — `analysis/R/parse_brainsight.R`

```r
source("analysis/R/parse_brainsight.R")

tables <- parse_brainsight("data/Session 3  Streamed Info.txt",
                           drop_null_rows = TRUE)

df_coil    <- tables[["Polaris Tool"]]        # datetime (POSIXct), tracker_name, coord_system, x, y, z, m0n0…m2n2
df_targets <- tables[["Target Selection"]]
df_cross   <- tables[["Crosshairs Position"]]
df_samples <- tables[["New Sample"]]
meta       <- tables[["_metadata"]]           # list(Version="7", …)
```

Missing row types return a **zero-row data.frame with correct columns**
(not NULL), so downstream code needs no existence checks.

**Recording summary — `brainsight_info()`**

```r
brainsight_info("data/BS_Recordings/SNBR-179.txt")   # parses, then summarizes
brainsight_info(tables)                              # or an already-parsed list
info <- brainsight_info(path, print = FALSE)         # values only, no printing
```

Prints the recording length (first to last timestamped row, any row type),
the trackers used with per-tracker frame counts and visible spans, the coils
among them, the `Crosshairs Position` drivers, and the samples registered —
then returns all of it invisibly (`info$duration_s`, `info$coils`,
`info$trackers`, `info$samples`, …).

**Samples registered** are the `New Sample` rows — name, index, time, MNI
position and associated target — in the order Brainsight wrote them. This is
*not* the set of targets selected during the session: a `Target Selection`
can name a sample registered in an earlier session, and one sample can be
selected many times over (Session 6: 1 sample registered, 9 selections).
`max_samples` (default 12) caps how many print; all are returned.

A tracker counts as **used** only if at least one of its frames carries a
position: Brainsight writes a row for every *configured* tracker on every
frame whether the camera sees it or not, so row counts alone would report
pointers and calibration blocks that were never in view (SNBR-179 lists five,
three were used). The rest are named on a `never visible:` line.

Which trackers are **coils** is convention, not data — the file has no such
field. The default is `BRAINSIGHT_COILS` (`LCT650`, `CT4661`, matching
`COIL_CANDIDATES` in `coil_to_sample_delta.R`); pass
`brainsight_info(path, coils = c(...))` for a session that used something else.

### explore.R (archived: `archive/analysis/`)

Loads Session 3. Filters `Polaris Tool` to tracker `LCT650` in MNI space,
computes distance to Sample 2, identifies the **closest sustained approach**
using a 200-frame rolling mean (≈ 10 s window), and plots:

- `df_polaris_graph` — 2D ggplot with sample target (red ✗) and held-nearest
  marker (orange ▲)
- A **3D rotatable plotly** coloured by distance to Sample 2

### multi_target_explore.R (archived: `archive/analysis/`)

Loads Session 6 via `parse_brainsight.R`. Multi-target exploration —
work in progress.

---

## Data analysis pipeline (`analysis/`)

> **Keep `analysis/README.md` in sync.** It is the user guide for lab
> members (routes, every argument/setting with its default, examples,
> troubleshooting). Any change to the pipeline code — `run_analysis.R`, the
> stage scripts, `join_meps.R`, `qtrac_mep_pipeline.R`, `R/parse_brainsight.R`,
> `R/sync_mep_times.R` — that adds, removes, renames or re-defaults an
> argument, changes an output, or changes behaviour must update that README
> in the same change.

Offline **MEP-vs-coil-placement** analysis: correlate TMS MEP amplitude
(QtracP) with how far/tilted the coil was from its target (Brainsight
neuronav). Entry point is **`analysis/run_analysis.R`** — set its INPUTS
block and run. It drives three stages, reusing their math:

| Stage script              | Builds       | Role                                                        |
|---------------------------|--------------|-------------------------------------------------------------|
| `clean_mep_times.R`       | `mep_clean`  | MEP peak-to-peak + wall-clock `trigger_time` from the QtracP `.xlsx` (`.QLG` launch anchor, clock-offset, latency) |
| `coil_to_sample_delta.R`  | `coil_dist`  | coil translational/angular distance to the target over time |
| `mep_vs_coil_distance.R`  | `analysis`   | per-MEP: nearest coil pose at each `trigger_time`           |

Outputs to `analysis/output/`: a stats-ready CSV (one row per MEP:
`delta_distance_mm`, `delta_angle_deg`, `mep_ptp`) + three PNGs (MEP vs time,
log(MEP) vs distance, log(MEP) vs angle).

### Coordinate frame & target (set in `run_analysis.R`, resolved in `coil_to_sample_delta.R`)

Two switches control what the coil is measured against. **Defaults are the
current workflow**; the legacy MNI/Target-Selection path is kept selectable.

**`COORD_SYSTEM`** — the frame every pose lives in:
- `"Polaris"` *(default)* — the coil is a raw optical tracker (**LCT650** *or*
  **CT4661**, auto-detected — no need to specify) expressed **relative to the
  head tracker (ST893)**:
  `p_rel = Rₕₑₐd⁻¹·(p_coil − p_head)`, `R_rel = Rₕₑₐd⁻¹·R_coil`.
  Head-motion-corrected like MNI but without the anatomical warp. Only raw
  `Polaris Tool` rows carry Polaris data (samples/targets/crosshairs are
  MNI-only), and a frame needs **both** the coil and head trackers visible
  (paired by `frame_number`). If the session **swaps coils** (LCT650 and CT4661
  tracked in disjoint time blocks), both are kept and each frame is tagged with
  its coil. `COIL_NAME` (default `"auto"`) pins one coil if ever needed;
  `HEAD_RELATIVE = FALSE` keeps the raw camera frame.
- `"MNI"` *(legacy)* — the navigated `Crosshairs Position` (`Coil B LCT` /
  `Coil A CT`) in MNI, as the earlier pipeline did.

**`TARGET_MODE`** — how the reference target is defined:
- `"sample_average"` *(default)* — the target is the **average coil pose over
  `N_SAMPLES_AVG` (=5) consecutive `Polaris Tool` tracker frames** (the raw
  20 Hz coil samples), starting at and **including** the frame `SAMPLE_START`.
  `SAMPLE_START` accepts (in priority order) a **New Sample / Target Selection
  name** (e.g. `"Sample 1"` → that event's timestamp), a timestamp
  (`"12:21:13.545"` → first frame at/after it), or a Polaris Tool `frame_number`
  (`"145929606"`). Position = arithmetic mean;
  orientation = chordal **SVD rotation mean**. Averaging ~5 consecutive ~50 ms
  samples yields a jitter-reduced target pose at the chosen instant; the frames
  come straight from the (head-relative) coil stream. Fewer than 5 available ⇒
  uses those and warns. **On a coil swap, each coil block gets its OWN target**
  (the two coils' raw trackers aren't directly comparable): the block containing
  `SAMPLE_START` is averaged from there; every other coil block auto-uses the
  first `N_SAMPLES_AVG` frames of its own segment. Each coil's over-time frames
  are then measured against that coil's target, and outputs carry a `coil` column.
- `"target_selection"` *(legacy)* — looks the target up directly from the
  `Target Selection` row named `SAMPLE_NAME` (MNI only; single target, all coils).

Legacy combo: `COORD_SYSTEM="MNI"` + `TARGET_MODE="target_selection"` +
`SAMPLE_NAME="Sample 5"`. (`Polaris` + `target_selection` is rejected — Target
Selection rows have no Polaris pose.)

**Physical note:** in Polaris/head-relative mode "coil position" is the coil
tracker's marker array (LCT650 or CT4661) on the **coil body** relative to the
head — a coil-placement repeatability measure — *not* the crosshairs aim-point
on the cortex (that point is MNI-only, unavailable in Polaris). Because LCT650
and CT4661 are different arrays on different coils, they are compared only
**within** a coil (each vs its own target), never across the swap.

Extra R deps beyond the list below: `readxl`, `lubridate`, `stringr`.
`analysis/R/` carries its own copy of `parse_brainsight.R`.

### Coil-offset study (`analysis/offset_study/`, Route C)

Multi-participant pipeline (`run_offset_study.R` + `manifest.csv`) asking
whether the coil's 6-DoF offset from its target changes the MEP at fixed
stimulation. Facts it relies on, all verified on the SNBR recordings:

- **Pulse times come from the QtracS `.QLG`**, one `Trigger stim` line per
  pulse with real elapsed seconds. The xlsx `Elapsed Time (min)` is a nominal
  sweep counter that drifts ahead of real time (~45 s / 27 min); Routes A/B,
  which anchor it to the launch, misplace pulses by 70–115 s. The launch
  instant is pinned to ms by intersecting the 1 s wall-clock stamps with the
  elapsed seconds of every QLG line. `mac_time = launch + elapsed − delta_s`
  with `delta_s` read **with its sign** from the time-sync log.
- **Brainsight cosines: rows are the tool axes**, row 3 = outward coil normal.
  Offsets are expressed in the target's frame: `dx/dy` in-plane, `dz` along
  the normal (+ = lifted), `rx/ry` tilt, `rz` twist about the normal
  (rotation vector of `M_t %*% t(M_c)`). Magnitudes equal Routes A/B's
  `trans_dist_mm` / `ang_dist_deg`.
- **Target per coil** = the target selected for the most visible time while
  that coil drove the crosshairs (one target ⇒ shared; one per coil ⇒ own;
  >2 ⇒ longest-selected wins). This assignment is always computed from MNI
  (`Crosshairs Position`/`Target Selection`, the only rows that record which
  target was selected when) regardless of `coord_system`.
- **`coord_system`** (manifest column, default `"MNI"`) picks the frame the
  OFFSET is then measured in: `"MNI"` (navigated crosshairs, always valid)
  or `"Polaris"` (raw coil tracker relative to the head tracker `ST893`,
  like `coil_to_sample_delta.R`'s Polaris mode). Since a Target Selection has
  no Polaris pose, a coil's Polaris target is the average of its own first
  `n_samples_avg` frames at/after its target's first selection. Because
  LCT650/CT4661 are different tracker bodies, Polaris is only valid when
  **every coil present has its own target** (`os_targets_per_coil()`); a
  participant requesting Polaris without that fails with a clear error
  without stopping the rest of the batch.
- **Strata** (participant × pulse class × ISI × MSO) hold the stimulus
  fixed; every effect is estimated within strata. **Both coils, and their
  targets, count as one** for the offset-vs-EMG comparison (log MEP, MEP
  present): coil is not part of `stratum` (`os_prepare_pulses()`) and is not
  adjusted for, so each pulse's offset is measured from its own coil's target
  but the effect is estimated across both coils together. **Exception: the
  tracked-intensity model** (outcome = % MSO, a stimulator setting that
  depends on the coil) keeps a coil × ISI baseline (`ci_stratum`); pooled
  without it, a between-coil intensity difference reads as an offset effect.
  Pulse classes from sheet D: `single` (ISI 0), `paired` (any other ISI, sign
  kept).
- Pulses with the coil > 25 mm or > 30° from target are excluded as "off the
  head", not "off target" (`CFG$max_offset_mm/max_angle_deg`).
- **Phases**: `nav_phase` pre-target / on-target (was the coil's target already
  selected?), `run_phase` hotspot_rmt / tsici / fixed_int / post, `tracked` =
  T-SICI block. Effect models use the on-target phase (`CFG$analysis_phase`).
  For tracked pulses the primary outcome is the **tracked intensity**
  (`MSO ~ |offset| + time + coil:ISI`), since the tracker clamps MEP size.

Group level: random-effects mean of participant slopes + `lmerTest` mixed
models (log MEP and tracked MSO). Outputs under `output/offset_study/`
(git-ignored). `offset_study/app/app.R` is the Shiny dashboard over those
outputs (`shiny::runApp("analysis/offset_study/app")`; its Run page takes
the four data folders — defaults in a `DATA_DIRS_DEFAULT` block at the top of
`app.R`, overridden by what is saved in `offset_study/data_paths.json` — finds
each participant's files from a study ID (`R/data_locator.R`), adds them to the
manifest and runs the whole manifest. Run also sweeps the folders and adds every
participant not yet in the manifest whose four files are all found and whose
Brainsight recording and a time-sync row are dated the QtracS-code session day
(`os_scan_folders()`; never flips an `include = FALSE` row; tick-box to turn off); launch config in
`.claude/launch.json`). Full guide in `analysis/README.md` §9; keep it
in sync (same rule as above).

The group tables (`group/all_*.csv`) hold **only the participants that
completed the last run**; Overview/Group/Decisions read those, while the
Participant page reads the participant's own `<id>/<id>_*.csv`. The manifest
stores full paths, so data moved on the share make participants fail with
`Brainsight file not found` and drop out of the group (2026-10-02: recordings
and time-sync logs moved to `Y:/Merged Data/Neuro_Nav/recording` and
`.../Neuro_nav_time_sync`). `os_relocate_missing()` (Run page: **Repair moved
paths**, also applied by Run) repoints manifest paths that no longer exist to
the same file name in the current data folders.

Routes A/B (`clean_mep_times.R`, `join_meps.R`) now take pulse times from the
QLG trigger lines through `offset_study/R/qtrac_io.R` too (`QTRAC_IO_PATH`);
their example `CLOCK_OFFSET_SEC` / `diff` values carry the log's negative sign.

---

## Versioning convention

Python monitoring/alert scripts are versioned in the filename:
`alert_brainsight_v1.py`, `alert_brainsight_v2.py`,
`alert_brainsight_v2.1.0.py`, … `alert_brainsight_v2.6.0.py`.

Keep old versions in `archive/cli/` — do not delete them. The CLI is no longer
developed; **v2.6.0** is its last version. The `dev/mac_gui/` package carries the
live logic (it mirrors v2.6.0) and is not versioned in its name.

---

## Key tracker names (Session 3)

| Name       | Role                                    |
|------------|-----------------------------------------|
| `LCT650`   | Coil tracker — the moving TMS coil      |
| `ST893`    | Head tracker — fixed to subject's head  |
| `CT4661`   | No valid MNI data in Session 3          |

Crosshairs driver in Session 3: `Coil B LCT`
Target used for drift testing: `test_target` (future sessions); `Sample 2` (Session 3)

---

## Dependencies

**Python** — standard library only, except:
- `pandas` (parse_brainsight.py)
- `pyautogui` (Windows trigger receiver only — `dev/windows_receiver/`)

The archived alert scripts and the Tk GUI (`dev/mac_gui/`) are stdlib-only.

**R:**
- `tidyverse`
- `plotly`
- `zoo` (rolling mean in explore.R)
