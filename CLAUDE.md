# Neuro_Nav

Real-time processing and visualization of neuronavigation data from
**Brainsight TMS** sessions. The project is split across Python (real-time
monitoring tools) and R (offline analysis and visualization).

---

## Directory structure

```
Neuro_Nav/
├── CLAUDE.md
├── Neuro_Nav.Rproj              R project root (working directory for all R scripts)
├── data/                        Raw session exports from Brainsight
│   ├── Session 3  Streamed Info.txt
│   └── Session 6_ Streamed Info.txt
├── launch_gui.command           Double-click launcher for the Mac GUI
├── python/                      Python tools — run from the project root
│   ├── parse_brainsight.py      Shared parser library (import in other scripts)
│   ├── monitor_brainsight.py    Polls a file and reports accessibility every 5 s
│   ├── alert_brainsight_v1.py   Drift alert tool — v1
│   ├── alert_brainsight_v2.py   Drift alert tool — v2
│   ├── alert_brainsight_v2.0.1.py
│   ├── alert_brainsight_v2.1.0.py   per-axis thresholds
│   ├── alert_brainsight_v2.2.0.py   + TCP trigger output to Windows receiver
│   ├── alert_brainsight_v2.3.0.py   + auto-follow of file's target
│   ├── alert_brainsight_v2.4.0.py   + TMS trigger on/off toggle
│   ├── alert_brainsight_v2.5.0.py   + participant ID on the time-sync log  (current)
│   └── brainsight_gui/          Tk GUI wrapping the monitor + trigger sender
├── R/                           R scripts — run via RStudio with Neuro_Nav.Rproj open
│   ├── parse_brainsight.R       Shared parser library (source in other scripts)
│   ├── explore.R                2D/3D coil trajectory visualization (Session 3)
│   └── multi_target_explore.R  Multi-target exploration (Session 6)
├── data_analysis/              Offline MEP-vs-coil-placement pipeline (see "Data analysis pipeline")
│   ├── run_analysis.R          Orchestrator — set INPUTS, run
│   ├── clean_mep_times.R       Stage 1 — MEP ptp + wall-clock trigger_time (QtracP .xlsx/.QLG)
│   ├── coil_to_sample_delta.R  Stage 2 — coil distance/angle to target (Polaris head-rel / MNI)
│   ├── mep_vs_coil_distance.R  Stage 3 — per-MEP nearest coil pose at trigger_time
│   ├── R/                      parse_brainsight.R (+ explore.R, multi_target_explore.R, sync_mep_times.R)
│   └── output/                 generated CSV + PNGs
└── trigger_app_AJ/              Separate Mac↔Windows TMS trigger app (standalone)
    ├── README.md               Wire protocol + run instructions (current Mac sender: v2.5.0)
    ├── TMS_CrossPlatform_Trigger_System.md
    ├── common/                 Protocol constants + config (port, 4-digit weekly token) + time-sync maths
    └── windows/                TCP receiver that types `ss`+Enter into QTrack (+ writes time_sync_log.txt)
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

## Python

### Shared parser — `python/parse_brainsight.py`

```python
from python.parse_brainsight import parse_brainsight

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

### File monitor — `python/monitor_brainsight.py`

```bash
python3 python/monitor_brainsight.py "data/Session 3  Streamed Info.txt"
```

Reports file size and growth every 5 s. Useful to confirm a live session
file is being written before starting more complex tools.

### Drift alert — `python/alert_brainsight_v2.5.0.py`  ← current version

```bash
python3 python/alert_brainsight_v2.5.0.py "data/Session 3  Streamed Info.txt"
python3 python/alert_brainsight_v2.5.0.py "data/Session 3  Streamed Info.txt" --loc 50 --ang 0.3

# Send STATE:RED / STATE:GREEN triggers to the Windows receiver on transitions:
python3 python/alert_brainsight_v2.5.0.py "<file>" --trigger-to 192.168.1.20:5050 --token <tok>

# Connected for time-sync + distance monitoring, but NO SS triggers to QTrack:
python3 python/alert_brainsight_v2.5.0.py "<file>" --trigger-to 192.168.1.20:5050 --token <tok> --no-triggers

# Pin a target manually instead of auto-following the file:
python3 python/alert_brainsight_v2.5.0.py "<file>" --no-follow

# Label the session so Windows stamps the study code on every time-sync row:
python3 python/alert_brainsight_v2.5.0.py "<file>" --trigger-to 192.168.1.20:5050 --token <tok> --participant SNBR-000
```

**Startup flow:**
1. (If `--trigger-to`) establishes the TCP trigger link to Windows first.
2. Scans the file for all `Target Selection` names and `Crosshairs Position`
   driver names. With auto-follow on (default) it adopts the most-recent
   selection; with `--no-follow` it presents a numbered menu to pick one.
   The driver is always picked from a menu.
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
**before** the time-sync handshake, and Windows stamps it on every row of
`time_sync_log.txt` — so each clock offset records whose session it belongs to.
It is entered on the **Mac** by design: the Windows receiver types `ss` into
whatever window has focus, so typing there mid-session could swallow a trigger
meant for QTrack (the receiver echoes the id to its console instead). Change it
live with `set participant <id>`; the new value applies to rows logged from
then on, so reconnect if you need a fresh row under a corrected id. Use the
study code, never a name.

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
set driver <n|name>   switch active driver (resets alert state)
set follow on|off     toggle auto-follow of the file's target selection
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

### Mac GUI — `python/brainsight_gui/` (`python -m brainsight_gui`)

Tk wrapper around the v2.5.0 monitor + trigger sender. Two-step wizard:
**Setup** (participant ID, file path, Windows IP/port/token, Connect & Start) →
**Perform** (driver + target dropdowns, per-axis threshold sliders, scrolling log).
The backend is `monitor_worker.MonitorWorker` (mirrors the CLI logic with
callbacks instead of `print`/REPL). Auto-follow is exposed as the
"Auto-follow target selected in the Brainsight file" checkbox; picking from
the Target dropdown pins a target and unchecks it. The **"Send TMS triggers
(SS start/stop to QTrack)"** switch in the Perform panel gates triggering (same
pure-gate semantics as the CLI's `set trigger`): unchecked keeps the link up
for time-sync + distance monitoring but sends no `ss` to QTrack. Defaults ON
each launch (not persisted). `launch_gui.command` double-click-launches it on
the Mac.

The **Participant ID** is the first Setup field and is **required** — an
unlabelled time-sync row can't be matched to a participant afterwards. It is
sent to Windows on connect and shown read-only in the Perform panel's top bar;
to change it, go Back (which reconnects and writes a freshly labelled row).

`brainsight_gui/config_store.py` persists the Windows IP, port, and token to
`~/Library/Application Support/Neuro_Nav/config.json` after a successful
connection and prefills them on the next launch (the Brainsight file path and
the participant ID are not saved — they change per session, and the id is
participant data).

### Trigger token — `trigger_app_AJ/common/config.py`

The Mac↔Windows shared secret is a **4-digit numeric code** (`0000`–`9999`)
that **rotates once a week**. The Windows receiver stores the code and its
issue time in `tms_token.json` (next to the .exe / package), mints a fresh
one at startup if it's >7 days old, and also rotates **live** when the week
elapses while running (logging the new code). `--token <code>` pins a fixed
code and disables rotation; `--new-token` forces a fresh one; `--show-token`
prints the current code. The Mac GUI remembers the code between launches, so
operators only re-enter it after the weekly rotation. (Both token files and
`config.json` are git-ignored.)

### Time sync — `trigger_app_AJ/common/timesync.py`

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
**`windows_time = mac_time + offset`**. Each result is appended to
**`time_sync_log.txt`** (next to the .exe / package, git-ignored): one
tab-separated row per sync with both machines' local wall-clock times, the
delta, the round-trip delay, the four raw epochs, and the **participant**
(v2.5.0 — last column, so logs written before it keep their field positions;
empty when no id was sent, and a `#` note marks the width change once in an
existing log). `data_analysis/R/sync_mep_times.R` reads the log and tolerates
both widths. The `TIMEOK` reply is the
Mac's notification that its timestamp was received and logged (surfaced in the
CLI log and the GUI log). The whole exchange is **best-effort** — a sync failure
is logged but never aborts the trigger link. A reconnect re-runs the sync.

---

## R

**Always open `Neuro_Nav.Rproj` in RStudio before running any R script.**
This sets the working directory to the project root, which all relative
paths assume.

### Shared parser — `R/parse_brainsight.R`

```r
source("R/parse_brainsight.R")

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

### explore.R

Loads Session 3. Filters `Polaris Tool` to tracker `LCT650` in MNI space,
computes distance to Sample 2, identifies the **closest sustained approach**
using a 200-frame rolling mean (≈ 10 s window), and plots:

- `df_polaris_graph` — 2D ggplot with sample target (red ✗) and held-nearest
  marker (orange ▲)
- A **3D rotatable plotly** coloured by distance to Sample 2

### multi_target_explore.R

Loads Session 6 via `parse_brainsight.R`. Multi-target exploration —
work in progress.

---

## Data analysis pipeline (`data_analysis/`)

Offline **MEP-vs-coil-placement** analysis: correlate TMS MEP amplitude
(QtracP) with how far/tilted the coil was from its target (Brainsight
neuronav). Entry point is **`data_analysis/run_analysis.R`** — set its INPUTS
block and run. It drives three stages, reusing their math:

| Stage script              | Builds       | Role                                                        |
|---------------------------|--------------|-------------------------------------------------------------|
| `clean_mep_times.R`       | `mep_clean`  | MEP peak-to-peak + wall-clock `trigger_time` from the QtracP `.xlsx` (`.QLG` launch anchor, clock-offset, latency) |
| `coil_to_sample_delta.R`  | `coil_dist`  | coil translational/angular distance to the target over time |
| `mep_vs_coil_distance.R`  | `analysis`   | per-MEP: nearest coil pose at each `trigger_time`           |

Outputs to `data_analysis/output/`: a stats-ready CSV (one row per MEP:
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
`data_analysis/R/` carries its own copy of `parse_brainsight.R`.

---

## Versioning convention

Python monitoring/alert scripts are versioned in the filename:
`alert_brainsight_v1.py`, `alert_brainsight_v2.py`,
`alert_brainsight_v2.1.0.py`, … `alert_brainsight_v2.5.0.py`.

Keep old versions in `python/` — do not delete them. The highest version
number is always the current one (currently **v2.5.0**). The `brainsight_gui/`
package tracks the latest CLI version's logic rather than carrying a version
in its name.

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
- `pyautogui` (Windows trigger receiver only — `trigger_app_AJ/windows/`)

The alert scripts and the Tk GUI (`brainsight_gui/`) are stdlib-only.

**R:**
- `tidyverse`
- `plotly`
- `zoo` (rolling mean in explore.R)
