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
| Brainsight stream `.txt` | Coil and head tracker poses at 20 Hz, plus samples and targets | Brainsight "Streamed Info" export | `Y:/Merged Data/Neuro_Nav/recording/SNBR-188.txt` |
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
| Ask **whether coil offset (6 DoF) changes the MEP**, for every participant and for the group, with per-pulse times taken from the QtracS log and one target per coil | **Route C:** [`offset_study/run_offset_study.R`](offset_study/run_offset_study.R), see [§9](#9-route-c-the-coil-offset-study-offset_study) |
| Check what is in a Brainsight recording (length, coils, sample names) | [`brainsight_info()`](#61-brainsight_info-whats-in-this-recording) |

The two routes use **the same coil geometry**, because `join_MEPs()` runs
`coil_to_sample_delta.R` internally. They differ in one respect:
**Route B subtracts MEP latency** (it starts from the recorded response time),
while **`join_MEPs()` does not** (it treats `Time` as the pulse itself).

**Pulse timing in every route comes from the QtracS `.QLG`.** The xlsx
`Elapsed Time (min)` is a nominal sweep counter that runs ahead of real time
by up to minutes, so both routes pair each xlsx row with its `Trigger stim`
line in the QLG (by the nominal clock both files carry) and use that line's
real elapsed seconds; rows with no trigger line are dropped and counted. The
reader lives in `offset_study/R/qtrac_io.R`. **Copy `delta_s` with its
sign**: it has been negative (Mac ahead) in every session so far, and the
scripts subtract it as given.

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
source("analysis/join_meps.R")      # defines join_MEPs(); nothing runs yet
out <- join_MEPs(diff     = 0.081863,
                 QLG      = "Y:/Merged Data/Data/TP3C60728A.QLG",
                 new_df   = df2,
                 neuronav = "Y:/Merged Data/Neuro_Nav/recording/SNBR-188.txt",
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
| `analysis_dir` | `"Y:/Neuro_Nav_App/analysis"` | Where `coil_to_sample_delta.R` lives. **Change this if your copy of the repo is not on `Y:`.** |
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
join_MEPs(..., analysis_dir = "C:/Users/me/Neuro_Nav_App/analysis")

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
| `OUT_DIR` | Output folder (default `analysis/output/`) |

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
source("analysis/R/parse_brainsight.R")
brainsight_info("Y:/Merged Data/Neuro_Nav/recording/SNBR-188.txt")
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
| `offset_study/` | **Route C.** Multi-participant coil-offset study: `run_offset_study.R`, `manifest.csv`, `R/*.R` (see §9) |
| `output/` | Generated CSVs and PNGs (git-ignored) |

For the maths behind the geometry (head-relative transform, SVD rotation mean,
geodesic angle), see the data-analysis section of
[`ARCHITECTURE.md`](../ARCHITECTURE.md).

---

## 9. Route C: the coil-offset study (`offset_study/`)

**Question.** When the stimulus is the same (same % MSO, same ISI), does the
coil's offset from its target change the MEP, and which of the six degrees of
freedom matters? Answered per participant and for the group. For the EMG
outcomes (MEP size, MEP present) both coils, and their targets, **count as
one**: each pulse's offset is measured from its own coil's target, but the
offset-vs-EMG effect is estimated across both coils together (see step 7).

```r
# open Neuro_Nav.Rproj, then:
source("analysis/offset_study/run_offset_study.R")
# or from a shell, optionally with another manifest:
Rscript analysis/offset_study/run_offset_study.R [manifest.csv]
```

Extra packages: `lmerTest` (and `lme4`) for the group mixed models, `tidyr`,
`purrr`, `readr`. Everything else is shared with Routes A and B.

### 9.1 The manifest

One row per participant in [`offset_study/manifest.csv`](offset_study/manifest.csv):

| Column | Meaning |
|---|---|
| `participant` | Study code. Also matched against the `participant` label of the time-sync rows. |
| `xlsx`, `qlg`, `brainsight` | QtracP export, QtracS run log, Brainsight `.txt` |
| `timesync` | The `time_sync` **folder** (every `time_sync*.txt` in it is pooled) or one file |
| `clock_offset_s` | Optional. A `delta_s` typed by hand (Windows − Mac, seconds, sign included) skips the time-sync lookup. |
| `session_date` | Optional `YYYY-MM-DD`. Default: the date stamped on the Brainsight rows. |
| `coord_system` | Optional `"MNI"` (default) or `"Polaris"`. See [§9.2a](#92a-coordinate-frame-polaris-vs-mni). |
| `include` | `TRUE`/`FALSE`. Rows set to `FALSE` are listed but skipped. |
| `notes` | Free text, ignored |

You need not type the paths: the dashboard's Run page finds a participant's
four files from the data folders and adds the row for you ([§9.4a](#94a-the-dashboard-offset_studyapp)).

The time-sync row is chosen as follows: rows labelled with this participant
are preferred; among the candidates the one nearest the QtracS launch wins.
The QC file says which row was used and warns when it is unlabelled, on
another day, or more than 4 h from the launch.

### 9.2 What it does, step by step

1. **Pulse times come from the QtracS `.QLG`, not from the xlsx.** The xlsx
   `Elapsed Time (min)` column is Qtrac's *nominal sweep clock*: it advances a
   fixed amount per sweep and runs ahead of real time by 1.5 s every few
   pulses (45 s over a 27-minute session). The QLG writes one
   `Trigger stim n, TH= …` line per pulse with real seconds since launch, and
   in its third column the same nominal clock the xlsx uses. Each xlsx row is
   matched to the trigger line whose nominal clock is nearest (they agree to
   ~0.03 min); that line's real elapsed seconds become the pulse time. The
   launch instant itself is pinned to a few ms by intersecting every line's
   1 s wall-clock stamp with its elapsed seconds. Then
   `mac_time = launch + elapsed − delta_s`.
   *Routes A and B anchor the xlsx counter to the launch and are therefore
   off by 70–115 s; use Route C for anything that needs pulse-level timing.*
2. **Targets.** Every visible `Crosshairs Position` frame is attributed to
   the target selected at that instant (last `Target Selection` at or before
   it; `<No Selection>` counts as none). Per coil, the target selected for the
   **most visible time while that coil was in use** is that coil's target.
   One target in the file → both coils use it. One per coil → each its own.
   More than two → the longest-selected wins. This assignment always comes
   from MNI (the only rows that record which target was selected when),
   regardless of `coord_system` (§9.2a). `<id>_targets.csv` holds the
   assignment and the seconds behind it; `target_at_frame` in the pulse
   table flags pulses fired while a different target was selected.
3. **Six degrees of freedom, in the target's frame.** Brainsight's nine
   cosines are the coil's x, y, z axes as rows; row 3 is the outward normal
   (verified on four recordings). For each frame:
   `dx_mm, dy_mm` in-plane shift along the target's own axes; `dz_mm` along
   the normal (+ = lifted off the head); `rx_deg, ry_deg` tilt about the
   target's x and y; `rz_deg` twist about the normal (handle rotation).
   `trans_dist_mm` and `ang_dist_deg` are the same collapsed numbers Routes
   A/B report; `tangential_mm`, `tilt_deg`, `twist_deg` are added.
4. **Pulse classes** from sheet D: `single` (ISI 0: hotspotting, RMT
   tracking, test-alone pulses, 1 mV tracking), `paired` (any other ISI,
   sign kept: + threshold-tracked T-SICI, − fixed-intensity A-SICI/SICF).
5. **Join.** Nearest coil frame within `max_gap_s` (0.15 s). Pulses before or
   after the neuronav recording, with the coil out of view, or with the coil
   off the head (> 25 mm or > 30° from target) are dropped; the counts and
   reasons are in the QC file and the `drop_reason` column.
6. **Phases.** `nav_phase` is `pre-target` when the pulse fired before the
   coil's assigned target had been selected in Brainsight (hotspotting,
   searching) and `on-target` afterwards. `run_phase` splits the session by
   protocol: `hotspot_rmt`, `tsici` (paired pulses with a positive ISI and the
   single test pulses among them), `fixed_int` (negative-ISI paired pulses),
   `post`. `tracked` marks the T-SICI block, where the tracker
   holds the MEP near 0.2 mV by changing the intensity. The **analysis set**
   is the on-target phase (`analysis_phase`); pre-target pulses stay in the
   tables for placement QC but are excluded from the effect models.
7. **Statistics, always within strata.** A stratum is
   participant × class × ISI × MSO: the pulses given the same stimulus
   setting. **The coils are not part of it**: both coils, and their targets,
   count as one, so pulses fired with either coil at the same MSO and ISI
   share a stratum (each pulse's offset is still measured from its own
   coil's target, step 2). Per participant and pulse class (and per
   class × ISI), for each DoF as `|DoF|` (primary), signed (asymmetry) and
   the magnitudes:
   `lm(log(MEP) ~ predictor + stratum)` → slope per mm or per degree, 95% CI,
   p, `% MEP change per unit`, plus a pooled within-stratum Spearman ρ and a
   logistic "MEP present" model. For **tracked pulses** the primary outcome is
   the intensity: `lm(MSO ~ predictor + elapsed_min + coil:ISI)` (% MSO per
   unit; the time trend absorbs slow threshold drift). **This is the one
   place the coils do not count as one**: % MSO is a stimulator setting, not
   an EMG value, and it depends on the coil, so the model keeps a coil × ISI
   baseline. Pooled without it, a between-coil difference in intensity reads
   as an offset effect whenever the two coils sat differently. Group: the
   participant slopes combined by a random-effects (DerSimonian–Laird) mean
   and by their plain mean/t-test, and pooled mixed models
   `lmer(log(MEP) ~ predictor + (1 + predictor | participant) + (1 | stratum))` and
   `lmer(MSO ~ predictor + elapsed_min + (1 + predictor | participant) + (1 | coil:ISI))`.
   *The MEP models do not adjust for coil either, so a difference in MEP size
   between the two coils at the same % MSO (or a slow drift between the
   blocks each coil was used in) is not separated from an offset effect; the
   `coil` column stays in `<id>_pulses.csv` if you want to check.*

### 9.2a Coordinate frame: Polaris vs MNI

`coord_system` (manifest column, per participant, default `"MNI"`) picks the
frame the offset in step 3 is measured in — the target *assignment* in step 2
(which named target belongs to which coil) is unaffected either way.

| Frame | What "coil position" means | Needs |
|---|---|---|
| `"MNI"` (default) | Brainsight's navigated crosshairs (the aim point) | A registered Brainsight session |
| `"Polaris"` | The coil's raw tracker (`LCT650`/`CT4661`) relative to the head tracker (`head_tracker`, default `ST893`) — cancels head motion, no anatomical warp, like `coil_to_sample_delta.R`'s Polaris mode | Every coil present to have its **own** target |

Brainsight never logs a `Target Selection` pose in Polaris space, so a
coil's Polaris target is instead the average of that **same coil's own**
head-relative frames — `n_samples_avg` (5) of them, starting at the moment
its assigned target was first selected. Because `LCT650` and `CT4661` are
different tracker bodies, this only means something when every coil present
has been assigned its own target (as many distinct target names as coils,
none shared): two coils sharing one target can't both be measured against
it in Polaris space, only in MNI (the anatomical frame makes a shared
target directly comparable across coils). A participant with `coord_system
= Polaris` that doesn't meet this fails with a clear error and is recorded
under "Failed" in the report — it does not stop the rest of the batch.
`<id>_qc.txt` states which frame a participant actually used, and every row
of `<id>_pulses.csv`/`all_pulses.csv` carries it in a `coord_system` column.

**Don't mix frames in one group run.** MNI and Polaris offsets are different
physical measurements, so pooling participants analysed in different frames
into the same forest plot, two-stage summary or mixed model would treat them
as if they were the same outcome. `run_offset_study.R` warns (but does not
stop) when a run's included participants end up in more than one frame —
keep `coord_system` consistent across a manifest you intend to pool, and
only mix by running Polaris participants and MNI participants as two
separate passes (e.g. two manifests, or toggle `include`) when you want to
compare them side by side rather than pooled.

### 9.3 Settings (`CFG` at the top of `run_offset_study.R`)

| Setting | Default | Meaning |
|---|---|---|
| `tz` | `America/Toronto` | Time zone of both machines |
| `match_tol_min` | `0.08` | xlsx vs QLG nominal-clock tolerance when pairing pulses (min) |
| `max_gap_s` | `0.15` | Largest pulse-to-frame gap accepted (s) |
| `max_offset_mm`, `max_angle_deg` | `25`, `30` | Beyond these the coil was off the head; pulse excluded |
| `analysis_phase` | `"on-target"` | Phase the effect models use (`"all"` = every kept pulse) |
| `tol_mm`, `tol_deg` | `2,3,5`, `5,10` | Placement tolerances reported as % of pulses within |
| `log_floor_mv` | `0.02` | MEPs below this are noise; floored before `log()` |
| `present_mv` | `0.05` | "An MEP was present" threshold for the logistic model |
| `min_mso` | `5` | Pulses below this intensity (dummy pulses) are ignored |
| `min_pulses` | `8` | Minimum pulses for any model |
| `block_gap_s` | `30` | Gap that splits a coil block in the timeline plot |
| `head_tracker` | `"ST893"` | Polaris only: coil frames are expressed relative to this tracker |
| `n_samples_avg` | `5` | Polaris only: frames averaged into each coil's own target |

### 9.4 Outputs (`output/offset_study/`, git-ignored)

Per participant, in `<id>/`: `<id>_pulses.csv` (one row per pulse with
everything above), `<id>_stats.csv`, `<id>_placement.csv` (per coil **and
phase**: median/p90 distance, % within each tolerance, per-DoF medians),
`<id>_targets.csv`, `<id>_stream_2hz.csv`, `<id>_target_events.csv`,
`<id>_coil_blocks.csv` (the dashboard's inputs), `<id>_timeline.png` (6 DoF
over the session with pulses, coil blocks and target selections),
`<id>_dof_vs_mep.png`, and `<id>_qc.txt` — **read the QC file first**: launch
time, matching rate, clock offset used, target assignment, phases, drop
reasons, match gap.

Group, in `group/`: `all_pulses.csv`, `all_stats.csv`, `all_placement.csv`,
`group_two_stage.csv`, `group_mixed.csv` (log MEP and tracked MSO),
`forest_<class>_abs.png` and `forest_<class>_tracked_mso.png` (one row per
participant plus the group mean, one facet per DoF), `pooled_dof_vs_mep.png`
(stratum-centred log MEP vs \|DoF\|, one line per participant),
`placement.png`, `run_info.json` (settings and timestamp) and
`offset_study_report.md` with the QC and the main tables.

### 9.4a The dashboard (`offset_study/app/`)

```r
shiny::runApp("analysis/offset_study/app")     # from the repo root
```

A Shiny front end over the outputs above (packages: `shiny`, `bslib`, `DT`,
`plotly`, `callr`, `jsonlite`). Pages: **Overview** (key numbers, rule-based
findings, placement boxes), **Participant** (QC text, interactive 6-DoF
timeline with hover, MEP vs offset, stats and placement tables),
**Group** (forest plot, pooled figure, two-stage and mixed-model tables with
outcome/form selectors), **Decisions** (tolerance sliders → % of pulses that
would pass per participant and coil, expected MEP change from the pooled
slopes, traffic lights, recommendations), **Methods & glossary** (every
column defined, the full run report) and **Run** (folders, participants,
manifest and settings, below). Every page has a "How to read
this" panel. Nothing is recomputed in the app.

All times in the dashboard are the Toronto wall-clock times the pipeline
wrote (a pulse fired at 12:04 shows as 12:04).

**Which run a page shows.** The Overview, Group and Decisions pages read the
group tables (`group/all_*.csv`), which hold **only the participants that
completed the last run**. A participant that failed it (an input file not
found, say) is missing from those pages, and a yellow banner on the Overview
names every such participant with the reason. The Participant page reads that
participant's **own** folder (`<id>/<id>_pulses.csv`, `_stats.csv`,
`_placement.csv`, the 2 Hz stream and the QC text), so it stays complete for
anyone analysed in an earlier run; a note under its title says when the outputs
shown are from an earlier run and not part of the current group results.

**The Run page**, top to bottom:

1. **Data folders**: where the four kinds of file live (QtracP `.xlsx`, QtracS
   `.QLG`, Brainsight `.txt`, time-sync logs). The starting values are the
   `DATA_DIRS_DEFAULT` block at the **top of `app/app.R`**. Whatever you type
   on the page overrides them and is remembered in
   `offset_study/data_paths.json` (written by **Save folders**, **Add** or
   **Run**); **Reset to script defaults** deletes that file. Each box shows
   live whether the folder exists and how many files it holds. Paths may be
   pasted straight from Explorer ("Copy as path", backslashes, quotes).
2. **Participants to add**: pick or type study IDs (`227` becomes `SNBR-227`).
   For each the app finds the files and previews them (`R/data_locator.R`):
   - `xlsx`: `<ID>-….xlsx` in the xlsx folder. With several (follow-up
     sessions) the **newest session** is used, dated from the QtracS code, and
     the others are named in the note.
   - `qlg`: `<code>.QLG`, where `<code>` is the ten-character QtracS code that
     ends the xlsx name (`SNBR-196-TP3C60922B.xlsx` → `TP3C60922B.QLG`).
   - `brainsight`: `<ID>.txt` or `<ID>-….txt`; with several, the one last
     written on the session day.
   - `timesync`: the folder itself. Not finding a file named for the ID is a
     note, not an error (the pipeline then uses the nearest unlabelled row).

   A participant is **ready** only when the xlsx, QLG, Brainsight file and
   time-sync folder are all found; otherwise the row says what is missing and
   the ID stays in the box. **Add to manifest**, or simply **Run**, adds the
   ready ones. An ID already in the manifest only has its four paths refreshed;
   its `clock_offset_s`, `coord_system`, `include` and `notes` are kept.

   **Automatic adding.** You do not have to pick IDs at all. With the box
   *"When I run the pipeline, also add every participant whose files are all
   found"* ticked (the default), Run sweeps the folders: every ID that has a
   recording in the Brainsight folder is looked up, and each one that is
   **not yet in the manifest** and is complete is added with `include = TRUE`
   and a note `auto-added <date>`. Complete means the four files above are
   found **and** two same-day checks pass, because files that exist but belong
   to different days would give wrong times without any error:
   - the Brainsight recording's first data row is dated the **session day**
     (the date carried by the QtracS code, `TP3C6`**`0922`**`B` → 22 Sep 2026),
     and the file has data rows;
   - the time-sync folder holds a row dated the session day (the clock offset
     drifts by up to a second between days).

   Under the box the page lists, live (refreshed every 30 s, so a time-sync
   file copied in while the page is open shows up), who is **ready to add**,
   who has a recording but is **still waiting** and why (e.g. `no time-sync row
   is dated 2026-09-29`, `no xlsx for this ID`), and who is **complete but
   `include = FALSE`**. A row you set to `include = FALSE` is never switched
   back on; it is only reported, so set `include = TRUE` yourself to run it.
   Untick the box to run exactly what the manifest lists. Only the dashboard's
   Run does this: `Rscript run_offset_study.R` reads `manifest.csv` as it is.
3. **Manifest**: the table from §9.1. Double-click a cell to edit; select rows
   and **Delete selected rows** to remove them. Every change from Add or Delete
   is written to `manifest.csv` straight away, and Run saves it again.

   **Moved data.** The manifest stores full paths, so moving the data on the
   share leaves its rows pointing at folders that no longer exist. Set the new
   folders in step 1; a line above the table then says how many manifest paths
   are gone but have **the same file name** in those folders, and **Repair
   moved paths** (next to Save manifest, above the table; or simply Run)
   points the manifest at them
   (`os_relocate_missing()` in `R/data_locator.R`). A path that still exists is
   never changed, a time-sync *folder* is replaced by the current time-sync
   folder, and `include`, `notes` and the other columns are untouched. Files
   that are in neither place are listed in red: those participants will fail
   until the file is copied into the folder of step 1. The line re-checks the
   folders every 30 s, so a file copied in while the page is open clears it,
   and the Overview banner's last line says whether the participants the last
   run failed can be found **now**.
4. **Settings for this run** and **Add & run pipeline**: Run repairs moved
   paths, adds the ready
   participants (the automatic sweep, then any IDs left in step 2's box),
   saves the manifest and the folders, warns about any
   included row whose files are missing (that participant fails and is skipped;
   the others still run), then analyses **every participant with
   `include = TRUE`** and re-pools the group statistics: the run is always the
   whole manifest, not just the new participants. The settings (effect-model
   phase, off-head limits, placement tolerances) are passed to the run; the
   QC lines, the report and the findings text follow whatever tolerances you
   list. The log updates live and the outputs reload when it finishes.

On a fresh checkout the app starts with no outputs and creates the output
folder; the first Run fills it.

### 9.5 Reading the numbers

- A negative `estimate` for an `abs` predictor means the MEP shrinks as the
  coil drifts along that axis, at fixed stimulation. `pct_change_per_unit`
  is that slope as % MEP per mm (or per degree).
- `n_strata` is how many distinct stimulus settings contributed; an effect
  that rests on 2–3 strata is fragile.
- For threshold-tracked pulses (RMT, T-SICI) the tracker holds the MEP near
  0.2 mV by *changing the intensity*, so a coil effect shows up in
  `tracked_mso` rather than `log_mep`. That outcome is fitted on the tracked
  pulses only, with a time trend and coil × ISI held fixed; it is still
  entangled with the tracker's own dynamics, so read it alongside the
  MEP-size result rather than instead of it.
- `nav_phase` matters when comparing placement numbers: `pre-target` blocks
  describe the search, `on-target` blocks describe how well the coil was held.
- `mep_present` is a log-odds slope; its `pct_change_per_unit` is the change
  in odds per unit.

### 9.6 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `matched to a QLG trigger (0%)` | The QLG belongs to another recording (different 10-letter code) or lacks `Trigger stim` lines. |
| `** DATE DIFFERS **` on the QtracS line | The QLG was copied later; the session date comes from Brainsight, so this is a warning only. |
| `outside the neuronav recording: N` large | Brainsight was started after hotspotting, or the clock offset has the wrong sign. Compare the QtracS launch and the Brainsight span in the QC file. |
| `no target was selected while it was in use` | The coil was used before any `Target Selection`; the fallback rule is printed. Add a target in Brainsight next time. |
| `time-sync row is dated …` | No sync row from this session in the folder; copy the receiver's `time_sync_logs/` file over, or set `clock_offset_s`. |
| `lmerTest not installed` | `install.packages("lmerTest")`; the participant stage still runs. |
| Overview / Group / Decisions show one or a few participants; mixed-model tables empty; yellow banner on the Overview | The last run failed the others (`Brainsight file not found: …` after the data were moved) and the group tables hold only those that completed. Set the folders on the Run page, press **Repair moved paths**, run again. The run log ends with `** N of M included participants FAILED` when this happens. |
| `Not at the manifest path and not in the folders of step 1` (red, above the manifest table) | The file was not carried over when the data were moved. Copy it into the folder of step 1 (same file name) and run again. |
