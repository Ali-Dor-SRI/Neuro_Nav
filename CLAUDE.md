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
│   ├── alert_brainsight_v2.3.0.py   + auto-follow of file's target  (current)
│   └── brainsight_gui/          Tk GUI wrapping the monitor + trigger sender
├── R/                           R scripts — run via RStudio with Neuro_Nav.Rproj open
│   ├── parse_brainsight.R       Shared parser library (source in other scripts)
│   ├── explore.R                2D/3D coil trajectory visualization (Session 3)
│   └── multi_target_explore.R  Multi-target exploration (Session 6)
└── trigger_app_AJ/              Separate Mac↔Windows TMS trigger app (standalone)
    ├── README.md               Wire protocol + run instructions (current Mac sender: v2.3.0)
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

### Drift alert — `python/alert_brainsight_v2.3.0.py`  ← current version

```bash
python3 python/alert_brainsight_v2.3.0.py "data/Session 3  Streamed Info.txt"
python3 python/alert_brainsight_v2.3.0.py "data/Session 3  Streamed Info.txt" --loc 50 --ang 0.3

# Send STATE:RED / STATE:GREEN triggers to the Windows receiver on transitions:
python3 python/alert_brainsight_v2.3.0.py "<file>" --trigger-to 192.168.1.20:5050 --token <tok>

# Pin a target manually instead of auto-following the file:
python3 python/alert_brainsight_v2.3.0.py "<file>" --no-follow
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
set loc <mm>          linear threshold — scalar (all axes)
set loc <x> <y> <z>   linear threshold — per-axis
set ang <rad>         angular threshold — scalar (all axes)
set ang <x> <y> <z>   angular threshold — per-axis
set remind <n>        reminder every N checks (default 100, ~50 s)
status                print current settings (incl. follow + trigger link)
quit                  stop
```

Waiting/status messages are **rate-limited to once every 5 s**;
alert and reminder messages fire immediately.

### Mac GUI — `python/brainsight_gui/` (`python -m brainsight_gui`)

Tk wrapper around the v2.3.0 monitor + trigger sender. Two-step wizard:
**Setup** (file path, Windows IP/port/token, Connect & Start) →  **Perform**
(driver + target dropdowns, per-axis threshold sliders, scrolling log).
The backend is `monitor_worker.MonitorWorker` (mirrors the CLI logic with
callbacks instead of `print`/REPL). Auto-follow is exposed as the
"Auto-follow target selected in the Brainsight file" checkbox; picking from
the Target dropdown pins a target and unchecks it. `launch_gui.command`
double-click-launches it on the Mac.

`brainsight_gui/config_store.py` persists the Windows IP, port, and token to
`~/Library/Application Support/Neuro_Nav/config.json` after a successful
connection and prefills them on the next launch (the Brainsight file path is
not saved — it changes per session).

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
per connection**, right after `AUTH:OK` and before any `STATE:` traffic. The
exchange is round-trip (NTP-style) so network latency is cancelled, not folded
into the result:

```
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
delta, the round-trip delay, and the four raw epochs. The `TIMEOK` reply is the
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

## Versioning convention

Python monitoring/alert scripts are versioned in the filename:
`alert_brainsight_v1.py`, `alert_brainsight_v2.py`,
`alert_brainsight_v2.1.0.py`, … `alert_brainsight_v2.3.0.py`.

Keep old versions in `python/` — do not delete them. The highest version
number is always the current one (currently **v2.3.0**). The `brainsight_gui/`
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
