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
├── python/                      Python tools — run from the project root
│   ├── parse_brainsight.py      Shared parser library (import in other scripts)
│   ├── monitor_brainsight.py    Polls a file and reports accessibility every 5 s
│   ├── alert_brainsight_v1.py   Drift alert tool — v1
│   └── alert_brainsight_v2.py   Drift alert tool — v2 (current)
├── R/                           R scripts — run via RStudio with Neuro_Nav.Rproj open
│   ├── parse_brainsight.R       Shared parser library (source in other scripts)
│   ├── explore.R                2D/3D coil trajectory visualization (Session 3)
│   └── multi_target_explore.R  Multi-target exploration (Session 6)
└── trigger_app_AJ/              Separate Mac↔Windows TMS trigger app (standalone)
    ├── README.md
    └── TMS_CrossPlatform_Trigger_System.md
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

### Drift alert — `python/alert_brainsight_v2.py`  ← current version

```bash
python3 python/alert_brainsight_v2.py "data/Session 3  Streamed Info.txt"
python3 python/alert_brainsight_v2.py "data/Session 3  Streamed Info.txt" --loc 50 --ang 0.3
```

**Startup flow:**
1. Scans the file for all `Target Selection` names and `Crosshairs Position`
   driver names, then presents numbered menus to pick the active target and driver.
2. Monitors at **2 Hz** (every 0.5 s — 10× slower than the 20 Hz write rate).
3. Alerts when the pointer drifts beyond the linear or angular threshold.

**Default thresholds:**

| Parameter | Default | Meaning                          |
|-----------|---------|----------------------------------|
| `--loc`   | 40 mm   | Euclidean distance to target     |
| `--ang`   | 0.2 rad | Geodesic rotation angle (~11.5°) |

Angular distance formula: `θ = arccos((trace(Rᵀ·R) − 1) / 2)`

**Live commands while running:**

```
list                  show available targets and drivers
set target <n|name>   switch active target (resets alert state)
set driver <n|name>   switch active driver (resets alert state)
set loc <mm>          change linear threshold
set ang <rad>         change angular threshold
set remind <n>        reminder every N checks (default 100, ~50 s)
status                print current settings
quit                  stop
```

Waiting/status messages are **rate-limited to once every 5 s**;
alert and reminder messages fire immediately.

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
`alert_brainsight_v1.py`, `alert_brainsight_v2.py`, …

Keep old versions in `python/` — do not delete them. The highest version
number is always the current one.

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

**R:**
- `tidyverse`
- `plotly`
- `zoo` (rolling mean in explore.R)
