# Data analysis: MEP amplitude vs coil placement

This folder answers one question per session: **how far was the TMS coil from
its target when each pulse fired, and did that affect the MEP?**

It takes the MEPs recorded in QtracP (Windows) and the coil positions recorded
in Brainsight (Mac). It puts both on the same clock, then gives every MEP two
numbers:

- `trans_dist_mm` is how far the coil was from the target, in mm.
- `ang_dist_deg` is how far the coil was tilted away from the target, in
  degrees.

```
QtracP .xlsx ──► MEP table (elapsed minutes) ─┐
QtracS .QLG  ──► session start time ──────────┼─► pulse time on the Mac clock ─┐
time-sync log ─► clock offset (Windows − Mac) ┘                                ├─► MEP + distance + angle
Brainsight .txt ► coil pose over time ─► distance/angle to target ─────────────┘
```

---

## 1. Before you start

1. **Open `Neuro_Nav.Rproj` in RStudio.** This sets the working directory to
   the repo root, and the relative paths depend on it.
2. **Install the packages** (once):
   ```r
   install.packages(c("tidyverse", "readxl", "lubridate", "stringr"))
   ```
3. **Collect the four files for the session:**

| File | What it gives | Where it comes from | Example |
|---|---|---|---|
| QtracP export `.xlsx` | MEP amplitudes and stimulator output, stamped in elapsed minutes | QtracP export (Windows) | `Y:/Merged Data/xlsx Data/SNBR-188-FU1-TP3C60728A.xlsx` |
| QtracS run log `.QLG` | The wall-clock time QtracS was launched, which anchors elapsed time | QtracS data folder | `Y:/Merged Data/Data/TP3C60728A.QLG` |
| Brainsight stream `.txt` | Coil and head tracker poses at 20 Hz, plus samples and targets | Brainsight "Streamed Info" export | `Y:/Neuro_Nav_App/data/BS_Recordings/SNBR-188.txt` |
| Time-sync log | The **clock offset** in seconds (Windows − Mac) | The trigger receiver's `time_sync_logs/` folder, one file per connection | `time_sync_2026-09-10_09-14-22_SNBR-188.txt` |

**Getting the clock offset.** Open that session's time-sync file and copy the
`delta_s` value (2nd column) **with its sign**. The pipeline calls this number
`diff`, `T_delta` or `CLOCK_OFFSET_SEC`, depending on the script. A positive
value means the Windows clock was ahead. If a file has several rows, use the
one closest to when QtracS was launched (see
[`R/sync_mep_times.R`](#63-rsync_mep_timesr-pick-the-offset-automatically)).

> **Restart R between participants** (Session ▸ Restart R, or Ctrl+Shift+F10).
> The scripts share variables through the global environment, so a value left
> over from the previous participant can carry into the next run without any
> warning.

---

## 2. Which route should I use?

| You want to… | Use |
|---|---|
| Filter the MEPs yourself (channel, amplitude window, test pulses, MSO) and then add coil placement. **Recommended.** | **Route A:** [`qtrac_mep_pipeline.R`](qtrac_mep_pipeline.R) + [`join_MEPs()`](#3b-join_meps-reference) |
| Add coil placement to a MEP table you already have (any source) | [`join_MEPs()`](#3b-join_meps-reference) on its own |
| Get a ready-made CSV and three plots for one elapsed-time window, with no filtering beyond that | **Route B:** [`run_analysis.R`](run_analysis.R) |
| Check what is in a Brainsight recording (length, coils, sample names) | [`brainsight_info()`](#61-brainsight_info-whats-in-this-recording) |

The two routes use **the same coil geometry**, because `join_MEPs()` runs
`coil_to_sample_delta.R` internally. They differ in one respect:
**Route B subtracts MEP latency** (it starts from the recorded response time),
while **`join_MEPs()` does not** (it treats `Time` as the pulse itself).

---

## 3. Route A: `qtrac_mep_pipeline.R` + `join_MEPs()`

### 3a. `qtrac_mep_pipeline.R`: step-through script

Edit the **CONFIG** block, then run the script top to bottom, one chunk at a
time, looking at each result as you go.

**Files**

| Setting | Meaning |
|---|---|
| `neuronav_path` | Brainsight `.txt` for this session. The next line prints `brainsight_info()` for it: check the sample names here. |
| `QTRAC_path` | QtracP `.xlsx` export |
| `QLG_file` | QtracS `.QLG` run log |
| `join_meps_R` | Path to `join_meps.R` (leave as is) |

**Sheets and columns.** Change these only if the QtracP export layout changes.

| Setting | Default | Meaning |
|---|---|---|
| `QTRAC_cols` | `Time = "Elapsed Time (min)"`, `Channel`, `Values` | Long-format columns read from sheets T, P and D |
| `sheet_T` / `sheet_P` / `sheet_D` | `"T"` / `"P"` / `"D"` | Stimulator output / MEP peak-to-peak / conditioning delay |
| `P_time_col`, `P_chan_col` | `"...1"`, `"Chan  1"` | Wide-format columns on sheet P, used only for the histogram check |

**Filters**

| Setting | Default | Meaning |
|---|---|---|
| `QC_channel` | `5` | Channel copied into `df_t_1` for inspection. Nothing downstream uses it. |
| `delay_test` | `0` | Sheet-D delay value that marks an unconditioned **test pulse** |
| `PTP_min`, `PTP_max` | `0.16`, `0.24` | MEP amplitude window in mV (inclusive) |
| `MSO_min` | `5` | Keep pulses with stimulator output **above** this value |
| `hist_breaks` | `50` | Number of bins in the amplitude histogram |

**Neuronav join**

| Setting | Meaning |
|---|---|
| `T_delta` | Clock offset in seconds, Windows − Mac (`delta_s` from the time-sync log) |
| `sample_name` | The reference the coil distances are measured from, e.g. `"Sample 1"` (see [§5](#5-choosing-the-coordinate-frame-and-target)) |
| `coord_system` | `"MNI"` or `"Polaris"` (see [§5](#5-choosing-the-coordinate-frame-and-target)) |

**What the script builds**

| Object | Contents |
|---|---|
| `df_p_1` + histogram | Channel-1 amplitudes inside the PTP window and inside the test-pulse time span. This is a visual check only. |
| `df2` | `Time`, `MSO`, `PTP`, `Channel`: pulses above `MSO_min` whose MEP falls inside the PTP window. **This is the table passed to `join_MEPs()`.** |
| `df3` | `df2` restricted to test pulses (`D == delay_test`), used for the MSO-vs-PTP plot. To join only test pulses, pass `new_df = df3` instead. |
| `merged_df` | `df2` plus the coil-placement columns (see [§3b output](#output)), plotted as PTP against distance |

### 3b. `join_MEPs()`: reference

Adds coil placement to **any** data frame that has an elapsed-time column.

```r
source("data_analysis/join_meps.R")      # defines join_MEPs(); nothing runs yet
out <- join_MEPs(diff     = 0.081863,
                 QLG      = "Y:/Merged Data/Data/TP3C60728A.QLG",
                 new_df   = df2,
                 neuronav = "Y:/Neuro_Nav_App/data/BS_Recordings/SNBR-188.txt",
                 sample   = "Sample 1")
```

#### Required arguments

| Argument | What it is |
|---|---|
| `diff` | Clock offset in **seconds**, Windows − Mac. Copy `delta_s` from the time-sync log, sign included. |
| `QLG` | Path to the QtracS `.QLG` file, or a `POSIXct` launch time if you already have one |
| `new_df` | Your MEP table. It needs an elapsed-time column (decimal **minutes** since the QtracS launch). All other columns pass through unchanged. |
| `neuronav` | Path to this session's Brainsight `.txt` |
| `sample` | The reference pose the distances are measured from: a sample or target name (`"Sample 1"`), a timestamp (`"12:21:13.545"`), or a Polaris frame number. See [§5](#5-choosing-the-coordinate-frame-and-target). |

#### Optional arguments

| Argument | Default | What it does |
|---|---|---|
| `time_col` | `"Time"` | Name of the elapsed-time column in `new_df` |
| `max_gap_s` | `0.10` | Drops a MEP when the nearest coil frame is more than this many seconds away (tracker dropout or a wrong offset) |
| `coord_system` | `"Polaris"` | `"Polaris"` (coil relative to the head tracker) or `"MNI"` (navigated crosshairs) |
| `target_mode` | `"sample_average"` | `"sample_average"` or `"target_selection"` (legacy, MNI only) |
| `n_samples_avg` | `5` | Number of coil frames averaged into the target, starting at `sample` |
| `head_tracker` | `"ST893"` | Head tracker name (Polaris only) |
| `head_relative` | `TRUE` | `FALSE` uses the raw camera frame instead of the head frame (Polaris only) |
| `coil_name` | `"auto"` | Pins one coil (`"LCT650"`, `"CT4661"`; in MNI `"Coil B LCT"`, `"Coil A CT"`) instead of auto-detecting |
| `session_date` | `NA` | Session date as `"YYYY-MM-DD"`. The `.QLG` file holds only a time of day, so the date is otherwise taken from the file's **modification date**. |
| `tz` | `"America/Toronto"` | Time zone for all timestamps |
| `coil_dist` | `NULL` | A precomputed coil stream (columns `time`, `coil`, `trans_dist_mm`, `ang_dist_deg`). When given, `neuronav` and `sample` are not needed and the file is not parsed again. |
| `analysis_dir` | `"Y:/Neuro_Nav_App/data_analysis"` | Where `coil_to_sample_delta.R` lives. **Change this if your copy of the repo is not on `Y:`.** |
| `quiet` | `FALSE` | `TRUE` hides the progress report |

#### Output

The input columns plus five new ones. Rows whose nearest coil frame was more
than `max_gap_s` away are removed.

| Column | Meaning |
|---|---|
| `trigger_time` | Pulse time on the Mac/Brainsight clock (`QLG launch + Time − diff`) |
| `coil` | Coil active at that moment |
| `trans_dist_mm` | Straight-line distance from coil to target (mm) |
| `ang_dist_deg` | Rotation angle between the coil and target orientations (degrees) |
| `match_gap_s` | Time between the pulse and the coil frame it was matched to |

The printed report ends with `Kept … | dropped …`. **Always read it:** a large
number of drops means the times do not line up (see [§7](#7-troubleshooting)).

#### Examples

```r
# Elapsed-time column has a different name
join_MEPs(..., new_df = mep_tbl, time_col = "Elapsed Time (min)")

# Measure against the brain-space (MNI) crosshairs instead of the head frame
join_MEPs(..., coord_system = "MNI")

# Anchor the target at a moment instead of a named sample
join_MEPs(..., sample = "12:21:13.545")

# Legacy: use Brainsight's stored Target Selection pose as the target
join_MEPs(..., coord_system = "MNI", target_mode = "target_selection", sample = "Sample 5")

# The .QLG file was copied later, so its modification date is wrong
join_MEPs(..., session_date = "2026-07-28")

# Repo is not on Y:
join_MEPs(..., analysis_dir = "C:/Users/me/Neuro_Nav_App/data_analysis")

# Several MEP tables from one session: reuse the coil stream that
# run_analysis.R (or coil_to_sample_delta.R) left in the session
join_MEPs(diff = 0.081863, QLG = QLG_file, new_df = df_block2, coil_dist = coil_dist)
```

---

## 4. Route B: `run_analysis.R` (all-in-one)

Edit the top of the file, then **Source** it. It reads MEPs from sheet **P**
(amplitude) and sheet **L** (latency) of the `.xlsx`, keeps one elapsed-time
window, matches each MEP to the coil, and writes a CSV and three plots.

**INPUTS** (change for each session)

| Setting | Meaning |
|---|---|
| `XLSX_PATH` | QtracP `.xlsx` export |
| `QLG_PATH` | QtracS `.QLG` run log |
| `NEURONAV_PATH` | Brainsight `.txt` |
| `WINDOW_LOW`, `WINDOW_HIGH` | Elapsed-time window to keep, in minutes (inclusive), e.g. the block you care about |
| `CLOCK_OFFSET_SEC` | Clock offset in seconds, Windows − Mac (`delta_s`) |

**Target and frame** (see [§5](#5-choosing-the-coordinate-frame-and-target))

| Setting | Meaning |
|---|---|
| `COORD_SYSTEM` | `"Polaris"` or `"MNI"` |
| `TARGET_MODE` | `"sample_average"` or `"target_selection"` (legacy) |
| `SAMPLE_START` | Anchor for `sample_average`: a sample name, timestamp or frame number |
| `SAMPLE_NAME` | Used **only** with `target_selection`: the Target Selection name (not in the file by default; add it) |
| `N_SAMPLES_AVG` | Frames averaged into the target (default 5) |
| `HEAD_TRACKER` | Head tracker (Polaris only; default `"ST893"`) |

**OUTPUTS**

| Setting | Meaning |
|---|---|
| `PROJECT_ROOT` | Repo location (default `"Y:/Neuro_Nav_App"`). **Change this if your copy is elsewhere.** |
| `PARTICIPANT` | Label used in the output file names |
| `OUT_DIR` | Output folder (default `data_analysis/output/`) |

**Optional overrides.** Add any of these to the INPUTS block:
`MAX_MATCH_GAP_S` (default `0.10` s), `SESSION_DATE` (`"YYYY-MM-DD"`),
`COIL_NAME` (pins one coil), `HEAD_RELATIVE` (`FALSE` for the raw camera frame).

**Output files** go to `output/`, which is git-ignored because the files carry
participant data. Do not commit them.

| File | Contents |
|---|---|
| `<PARTICIPANT>_mep_coil.csv` | One row per MEP: `trigger_time`, `coil`, `delta_distance_mm`, `delta_angle_deg`, `mep_ptp` |
| `<PARTICIPANT>_mep_vs_time.png` | Raw MEP size across the window |
| `<PARTICIPANT>_logmep_vs_distance.png` | log(MEP) vs distance, with a LOESS curve per coil |
| `<PARTICIPANT>_logmep_vs_angle.png` | log(MEP) vs angle, with a LOESS curve per coil |

Behind the scenes, `run_analysis.R` sources three stage scripts, and you
normally leave these alone: `clean_mep_times.R` (MEP times),
`coil_to_sample_delta.R` (coil geometry) and `mep_vs_coil_distance.R` (the
match).

---

## 5. Choosing the coordinate frame and target

**Set `coord_system` / `COORD_SYSTEM` explicitly every time.** The defaults are
not the same everywhere: `join_MEPs()` defaults to `"Polaris"`, while
`qtrac_mep_pipeline.R` and `run_analysis.R` are currently set to `"MNI"`.

| Frame | What "coil position" means | Use it when | Needs |
|---|---|---|---|
| `"Polaris"` | The coil's tracker array relative to the head tracker. Head movement is cancelled out, and there is no brain warp. | You care about **physical coil placement and repeatability** on the head | The coil tracker **and** the head tracker (`ST893`) both visible in the same frames |
| `"MNI"` | Brainsight's navigated crosshairs in brain (MNI) space: the aim point | You care about **where on the brain** the coil was aimed | A registered Brainsight session (`Crosshairs Position` rows) |

**Target (`target_mode` / `TARGET_MODE`)**

- `"sample_average"`: the target is the **average coil pose over
  `n_samples_avg` (5) consecutive frames**, starting at the anchor. Use this for
  "where the coil actually was at the moment I marked as on-target".
- `"target_selection"` (legacy, **MNI only**): the target is the pose stored in
  Brainsight's `Target Selection` row with that name. Use this for "the planned
  target".

**Anchor (`sample` / `SAMPLE_START`).** These forms are tried in this order:

| Form | Example | Anchors on |
|---|---|---|
| Sample or target name | `"Sample 1"` | The time that `New Sample` / `Target Selection` event was logged |
| Timestamp | `"12:21:13.545"` or `"2026-07-28 12:21:13.545"` | The first coil frame at or after that time |
| Frame number | `"145929606"` | That exact Polaris frame |

Run `brainsight_info(path)` to see which sample names exist.

**Coil swaps** (e.g. `CT4661` then `LCT650`) are detected automatically, and
each row is tagged with its `coil`.

- In **Polaris**, each coil gets **its own target**: the coil in use at the
  anchor is averaged from the anchor, and the other coil from its first frames.
  Their distances are therefore **not comparable across coils**.
- In **MNI**, both coils share **one target**, so they are comparable.

If both coils were tracked at the same time, the script stops and asks you to
set `coil_name` / `COIL_NAME`.

---

## 6. Helper functions

### 6.1 `brainsight_info()`: what's in this recording?

```r
source("data_analysis/R/parse_brainsight.R")
brainsight_info("Y:/Neuro_Nav_App/data/BS_Recordings/SNBR-188.txt")
```

Prints the recording length, the trackers actually seen (with the coils among
them), the crosshairs drivers, and the samples registered (name, time,
position). **Run it first** to choose `sample` and to confirm which coils were
used.

| Argument | Default | What it does |
|---|---|---|
| `x` | (none) | Path to a `.txt` file, or a list already returned by `parse_brainsight()` |
| `coils` | `c("LCT650", "CT4661")` | Tracker names to report as coils |
| `print` | `TRUE` | `FALSE` returns the values silently (`info$coils`, `info$samples`, `info$duration_s`, …) |
| `max_samples` | `12` | How many samples to print. All are returned regardless. |

### 6.2 `parse_brainsight()`: raw tables

```r
tables  <- parse_brainsight(path, drop_null_rows = TRUE)
coil    <- tables[["Polaris Tool"]]        # also "Crosshairs Position", "New Sample", "Target Selection", …
```

| Argument | Default | What it does |
|---|---|---|
| `path` | (none) | Brainsight `.txt` file |
| `parse_datetime` | `TRUE` | Adds a `datetime` column (millisecond precision) |
| `drop_null_rows` | `FALSE` | `TRUE` drops frames where the tracker was not visible |

`(null)` becomes `NA`. A row type that is not in the file comes back as an
empty table with the correct columns.

### 6.3 `R/sync_mep_times.R`: pick the offset automatically

A standalone script. It is not used by either route. Set its CONFIG block and
source it:

| Setting | Meaning |
|---|---|
| `QLG_PATH`, `XLSX_PATH` | As above |
| `TIMESYNC_LOG_PATH` | A `time_sync_logs/` **folder** (all files are pooled) or one `.txt` file |
| `DELTA_SELECT` | Which sync row to use: `"nearest"` to the QtracS launch (default), `"first"` or `"last"` |
| `ANCHOR_OFFSET_SEC` | Shifts the launch anchor by ± seconds (default 0) |
| `XLSX_SHEET`, `ELAPSED_COL`, `MEP_COL` | Sheet `"P"`, columns 1 and 2 |

It prints the chosen `delta_s` and the file it came from, then builds `synced`
(`elapsed_min`, `windows_time`, `mac_time`, `mep`). Copy that `delta_s` into
`diff` / `T_delta` / `CLOCK_OFFSET_SEC`.

---

## 7. Troubleshooting

| Message or symptom | Likely cause and fix |
|---|---|
| `Every row was dropped` or most rows dropped | The times do not overlap. Check the **sign** of `diff`, the `.QLG` date (set `session_date`), and that the `.txt` file is from the same session. Compare the printed *Pulse window* with the *Coil window*. |
| `SAMPLE_START '…' is not a known event name…` | That sample name is not in the file. The error lists the names that are, and so does `brainsight_info()`. |
| `Coils tracked at overlapping times…` | Two coils were visible at the same time. Set `coil_name` / `COIL_NAME` to the one you used. |
| `Head tracker 'ST893' has no valid Polaris frames` | The head tracker was not seen or has a different name. Check `brainsight_info()`, or use `"MNI"`. |
| `TARGET_MODE='target_selection' requires COORD_SYSTEM='MNI'` | Target Selection poses exist only in MNI. Switch to MNI or use `sample_average`. |
| `new_df has no column 'Time'` | Pass `time_col = "<your column>"`. |
| `Required script not found` / file-not-found for `Y:/…` | Your repo is not on `Y:`. Set `analysis_dir` (join_MEPs) or `PROJECT_ROOT` (run_analysis.R). |
| Results look like the previous participant's | Restart R and run again. |

---

## 8. File map

| File | Role |
|---|---|
| `qtrac_mep_pipeline.R` | **Route A.** QtracP → filtered MEP table → `join_MEPs()` |
| `join_meps.R` | Defines `join_MEPs()` |
| `run_analysis.R` | **Route B.** All-in-one: CSV + 3 plots |
| `clean_mep_times.R` | Route B stage 1: MEP times from `.xlsx` + `.QLG` |
| `coil_to_sample_delta.R` | Coil distance and angle to target over time (used by both routes) |
| `mep_vs_coil_distance.R` | Route B stage 3: nearest-coil-frame match |
| `R/parse_brainsight.R` | `parse_brainsight()`, `brainsight_info()` |
| `R/sync_mep_times.R` | Picks the clock offset from time-sync logs |
| `R/explore.R`, `R/multi_target_explore.R`, `sandbox.R` | Exploratory scratch work, not part of the pipeline |
| `output/` | Generated CSVs and PNGs (git-ignored) |

For the maths behind the geometry (head-relative transform, SVD rotation mean,
geodesic angle), see the data-analysis section of
[`ARCHITECTURE.md`](../ARCHITECTURE.md).
