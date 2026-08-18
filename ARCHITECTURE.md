# Architecture

A ~5-minute tour of what this repository does and how the pieces fit together.
Sections 1–4 and 6–8 are the tour; **§5 goes deeper** on the R analysis
pipeline, for anyone who has to run or change it — skim its diagram and file
table and skip the rest until you need it.

---

## 1. What this project is

The lab runs **TMS sessions**: a magnetic coil is held against a subject's head
and pulsed, and the resulting muscle twitch (**MEP** — motor evoked potential)
is recorded. Two separate machines are involved:

- a **Mac** running **Brainsight**, the neuronavigation system that optically
  tracks where the coil is relative to the head, and
- a **Windows** PC running **QTrack / QtracP**, which fires the stimulator and
  records the MEPs.

Neither machine talks to the other out of the box. This repo is the glue, and it
solves two problems:

| | Problem | Answer in this repo |
|---|---|---|
| **Live** | The coil drifts off target mid-session and nobody notices until the data is ruined | A monitor that watches Brainsight's live output and **auto-pauses stimulation** when the coil leaves a tolerance envelope |
| **Offline** | Does MEP size actually depend on how far off-target the coil was? | An R pipeline that joins each MEP to the coil pose at the instant its pulse fired |

Everything is built on one shared substrate: **Brainsight's streamed-info text
file**, plus a **clock-sync handshake** that makes the Mac's and Windows'
timestamps comparable.

```
   MAC (Brainsight)                                WINDOWS (QTrack / QtracP)
   ┌───────────────────────────┐                   ┌──────────────────────────┐
   │ Brainsight writes         │                   │ TMS Trigger Receiver     │
   │   "Streamed Info.txt"     │                   │   • checks 4-digit token │
   │   at 20 Hz                │                   │   • clock-sync w/ Mac    │
   │        │ tail-reads 2 Hz  │   TCP :5050       │   • types "ss"+Enter     │
   │        ▼                  │  AUTH / TIME /    │     into focused QTrack  │
   │ Drift monitor (CLI or GUI)│  STATE:RED|GREEN  │        │                 │
   │   coil vs target, 6 DoF   │ ────────────────► │        ▼                 │
   │   fires on transitions    │                   │ QTrack starts/stops      │
   └───────────────────────────┘                   │ stimulation, logs MEPs   │
                │                                  └──────────────────────────┘
                │   after the session, offline                    │
                └──────────────► R pipeline ◄─────────────────────┘
                                (data_analysis/)
```

---

## 2. The data format everything reads

Brainsight exports a tab-delimited `.txt` where **the first column is a row-type
label** that determines the meaning of the rest of the line. It is appended to
live at ~20 Hz during a session.

| Row type | Carries |
|---|---|
| `Polaris Tool` | Raw optical tracker pose — one row per tracker per camera frame (`LCT650`/`CT4661` = coil arrays, `ST893` = head) |
| `Crosshairs Position` | The *navigated* coil aim-point (`Coil B LCT` / `Coil A CT`) |
| `Target Selection` | The target the operator picked in Brainsight |
| `New Sample` / `New EMG` | Marks the operator saved, and Brainsight's own EMG readings |
| `TTL Trigger` | An external pulse Brainsight received |

Every pose is a **position (x, y, z in mm) + a 3×3 rotation matrix** flattened
into nine direction-cosine columns (`m0n0`…`m2n2`, row-major). Missing values
are the literal string `(null)`. Two coordinate systems appear: `Polaris`
(the camera's own frame, only on `Polaris Tool` rows) and `MNI` (warped into
standard brain space, on everything else).

Two twin parsers turn this into tables — [`python/parse_brainsight.py`](python/parse_brainsight.py)
and [`data_analysis/R/parse_brainsight.R`](data_analysis/R/parse_brainsight.R).
Both return one table per row type, keyed by label, with `(null)` → `NA` and a
parsed `datetime` column. Missing row types come back as **empty tables with the
right columns**, so callers never need existence checks.

> Note: the live monitor does *not* use these parsers. It does its own
> split-on-tab line scanning so it can tail the file cheaply and stay
> stdlib-only (see §3).

---

## 3. The live drift monitor (Mac)

**Core idea.** Pick a *target* pose and a *current* coil pose, compare them
across **6 degrees of freedom**, and alert when any one exceeds its threshold.

- 3 **linear** DoF: the absolute offset along each axis, in mm (default 40 mm)
- 3 **angular** DoF: the *per-axis tilt* — the angle between the target's i-th
  basis vector and the coil's i-th, in radians (default 0.20 rad ≈ 11.5°).
  Comparing basis vectors directly avoids picking an Euler convention and
  sidesteps gimbal lock entirely.

**Stop/go semantics:** stimulation stops if **any** of the 6 DoF is out, and
resumes only when **all 6** are back in. Triggers fire on **transitions only** —
the repeated "still out of range" reminders deliberately send nothing.

**How it reads the file.** Polled at **2 Hz** (10× slower than Brainsight
writes it), seeking from the last read offset and consuming only new lines, with
a guard that resets to byte 0 if the file shrinks. Targets and drivers are
discovered *continuously* from the stream, not just at startup, so starting the
monitor before the session file even exists works fine.

**Auto-follow.** By default the active target tracks whichever target was most
recently selected *in Brainsight* — the operator changes it once, in the app
they're already using, and the monitor follows. Picking a target manually pins
it and turns auto-follow off.

### Two front ends, one behaviour

| | CLI | GUI |
|---|---|---|
| Entry | [`python/alert_brainsight_v2.4.0.py`](python/alert_brainsight_v2.4.0.py) | [`python/brainsight_gui/`](python/brainsight_gui/) (`python3 -m brainsight_gui`) |
| Control | Interactive REPL (`set target`, `set loc 30 40 50`, `status`, `quit`) | Two-panel wizard: **Setup** (file + IP/port/token) → **Perform** (dropdowns, sliders, colour-coded log) |
| Windows link | Optional — omit `--trigger-to` for a terminal-only monitor | **Required** — the GUI won't start without IP/port/token |

The GUI is a clean **backend / view / controller** split:
[`monitor_worker.py`](python/brainsight_gui/monitor_worker.py) holds all the
polling and socket logic with a callback API and zero Tk imports;
[`app.py`](python/brainsight_gui/app.py) wires those callbacks to the panels and
marshals every one onto the Tk thread via `root.after(0, …)`; the panels never
touch a socket. Message wording lives in one place,
[`messages.py`](python/brainsight_gui/messages.py), so the log and the worker
can't drift apart. Connection details are remembered between launches by
[`config_store.py`](python/brainsight_gui/config_store.py) (the file path is
not — it changes every session).

---

## 4. The Mac ↔ Windows trigger link

A small line-oriented TCP protocol over port 5050, defined in
[`trigger_app_AJ/common/protocol.py`](trigger_app_AJ/common/protocol.py):

```
Mac → Win:  AUTH:<4-digit token>        Win → Mac:  AUTH:OK | AUTH:DENIED
Mac → Win:  TIME:<t1>                   Win → Mac:  TIMEACK:<t2> <t3>
Mac → Win:  TIMESYNC:<t1> <t4>          Win → Mac:  TIMEOK:<offset> <delay>
Mac → Win:  STATE:RED | STATE:GREEN     (on drift transitions only)
```

**Auth.** The shared secret is a **4-digit code that rotates weekly**. The
receiver mints it, prints it in its startup banner, persists it with its issue
time in `tms_token.json`, and rotates live when the week elapses. Operators read
four digits off the Windows console and type them into the Mac once a week.

**Time-sync** ([`common/timesync.py`](trigger_app_AJ/common/timesync.py)) runs
once per connection, right after auth. It's the NTP round-trip:
`offset = ((t2−t1) + (t3−t4)) / 2`, which cancels network transit time.
`offset = Windows_clock − Mac_clock`, so **`windows_time = mac_time + offset`**.
Every result is appended to `time_sync_log.txt`. This is what later makes the
offline analysis possible at all — it's best-effort, and a failure never aborts
the trigger link.

**The Windows side** ([`windows/server.py`](trigger_app_AJ/windows/server.py) +
[`qtrack.py`](trigger_app_AJ/windows/qtrack.py)) accepts one Mac at a time (a
newer connection replaces an older one) and, on each *changed* `STATE:`, types
`ss` + Enter into whatever window is focused — QTrack's start/stop command.
It must be **lowercase**: `pyautogui.write("SS")` holds Shift, and QTrack reads
the shifted keypress as an invalid command. Keep Caps Lock off.

**Failure behaviour.** If the link is down when an alert fires, the send is
logged and dropped; the sender reconnects with exponential backoff but
**does not replay** missed transitions, so a reconnect never produces a
surprise keystroke.

**Triggering can be gated off** (`--no-triggers`, or the GUI switch) — the link
stays up for time-sync and drift reporting but no `ss` reaches QTrack. It's a
*pure gate*: flipping it never itself sends a trigger, so QTrack's current state
is untouched at the moment you toggle.

---

## 5. The offline analysis pipeline (R)

Goal: **one row per MEP**, carrying how far and how tilted the coil was from its
target at the moment that pulse fired. Three input files, produced by two
machines that never shared a clock, have to be reconciled:

```
  WINDOWS                                    MAC
  ├── <run>.QLG    QtracS run log            └── <subject>.txt   Brainsight stream
  │     → session launch wall-clock                   │
  └── <subject>.xlsx  QtracP export                   │
        → elapsed time, MEP ptp, latency              │
              │                                       │
              ▼                                       ▼
      clean_mep_times.R                     coil_to_sample_delta.R
        → mep_clean                           → coil_dist, coil_delta
              └───────────────┬───────────────────────┘
                              ▼
                   mep_vs_coil_distance.R  → analysis
                              ▼
                      run_analysis.R  →  1 CSV + 3 PNGs
```

### The files

| File | Role |
|---|---|
| [`run_analysis.R`](data_analysis/run_analysis.R) | **Orchestrator and the only file you edit.** An `INPUTS` block (3 paths, time window, clock offset, target/frame settings) + an `OUTPUTS` block, then it sources the stages and owns every plot and CSV |
| [`clean_mep_times.R`](data_analysis/clean_mep_times.R) | Stage 1 — builds `mep_clean`: MEP amplitude + **`trigger_time`** |
| [`coil_to_sample_delta.R`](data_analysis/coil_to_sample_delta.R) | Stage 2 — builds `coil_dist` / `coil_delta`: coil pose vs target over time. The largest and most configurable script (~530 lines) |
| [`mep_vs_coil_distance.R`](data_analysis/mep_vs_coil_distance.R) | Stage 3 — builds `analysis`: joins the two on time |
| [`R/parse_brainsight.R`](data_analysis/R/parse_brainsight.R) | The R twin of the Python parser — same schemas, same `(null)` → `NA`, same empty-table-with-right-columns guarantee |
| [`join_meps.R`](data_analysis/join_meps.R) | Standalone one-call join for MEPs you already have in a data frame — see "Ad-hoc joins" below |
| [`R/sync_mep_times.R`](data_analysis/R/sync_mep_times.R) | Standalone helper, not sourced by the pipeline — see "Where the clock offset comes from" below |

(`R/explore.R` and `R/multi_target_explore.R` are exploratory scratch work, not
part of the pipeline.)

**How the stages communicate.** Not by function calls or intermediate files —
each script is `source()`d and **leaves named data frames in the global
environment** for the next one. Every tunable is declared
`if (!exists("X")) X <- <default>`, so a stage runs standalone with its own
defaults *or* takes injected values from the orchestrator, which also sets
`ORCHESTRATED <- TRUE` to suppress the stages' own plots. The cost of that
pattern: **restart the R session between participants**, or a leftover variable
from the previous run silently survives into the next.

### Stage 1 — reconstructing when each pulse fired

QtracP records *elapsed minutes since QtracS launched*, not wall-clock, and the
MEP is recorded some milliseconds *after* the pulse that caused it. Four
transformations fix both:

```
actual_time    = QLG launch time-of-day + elapsed_min     # still the Windows clock
   (filter)      keep elapsed_min within [WINDOW_LOW, WINDOW_HIGH]
corrected_time = actual_time − CLOCK_OFFSET_SEC           # → the Mac clock
trigger_time   = corrected_time − latency                 # the pulse, not the response
```

Details that matter when it goes wrong: the launch anchor is scraped from the
**first `HH:MM:SS AM/PM` line in the `.QLG`**, which carries no date — the date
comes from the `.QLG` file's modified time unless `SESSION_DATE` is set
explicitly. Amplitude comes from xlsx sheet **`P`** (col 1 elapsed, col 2
peak-to-peak) and latency from sheet **`L`** (col 2, milliseconds), joined on
elapsed time. The timezone is hard-coded `America/Toronto`.

**Where the clock offset comes from.** `CLOCK_OFFSET_SEC` is the
`Windows − Mac` delta measured by the live trigger link and appended to
`time_sync_log.txt` (§4) — currently copied into the `INPUTS` block by hand.
`R/sync_mep_times.R` is the earlier standalone version that reads that log
itself and picks the sync row nearest the QtracS launch; it's the reference for
what the number means and where to find it.

### Stage 2 — where the coil was, relative to target

1. **Parse** the Brainsight stream through the shared parser.
2. **Build the coil's pose stream** — controlled by `COORD_SYSTEM`:
   - `"Polaris"` takes the raw coil tracker and expresses it *relative to the
     head tracker* — `p_rel = R_head⁻¹(p_coil − p_head)`, `R_rel = R_head⁻¹R_coil`
     — which cancels head motion without the anatomical warp. Coil and head rows
     are paired on `frame_number`, so a frame counts only if both were visible.
   - `"MNI"` uses the navigated `Crosshairs Position`, as the earlier pipeline
     did. Note that in Polaris mode "coil position" is the marker array on the
     coil *body*, **not** the aim-point on the cortex — it measures placement
     repeatability, not where the field landed.
3. **Detect the coil(s).** `LCT650` and `CT4661` are auto-detected. If both
   appear, a coincidence test decides what happened: <2% of frames overlapping
   in time means the coils were *swapped* sequentially and both are kept, each
   frame tagged with its coil; heavy overlap is ambiguous, so the script stops
   and asks you to name one.
4. **Build the reference target** — controlled by `TARGET_MODE`:
   - `"sample_average"` averages 5 consecutive 20 Hz coil frames starting at
     `SAMPLE_START` (which accepts a `New Sample`/`Target Selection` *name*, a
     timestamp, or a frame number). Positions average arithmetically;
     orientations use an **SVD rotation mean**, because the element-wise mean of
     rotation matrices isn't itself a rotation.
   - `"target_selection"` looks the target up from a `Target Selection` row
     (MNI only).
   - On a coil swap **each coil gets its own target** — two different marker
     arrays are never compared to each other.
5. **Compute the deltas** — `coil_delta` carries the per-DoF breakdown
   (`dx/dy/dz`, `dyaw/dpitch/droll`), `coil_dist` the two collapsed numbers the
   next stage actually uses.

The geometry helpers are small and self-contained, and worth reading if the
numbers ever look wrong:

| Helper | Does |
|---|---|
| `rot_to_ypr` | 3×3 matrix → yaw/pitch/roll (ZYX), `atan2` throughout |
| `rot_angle_deg` | The single geodesic angle between two orientations: `acos((tr(RaᵀRb) − 1) / 2)` — frame-independent |
| `rot_average` | Chordal mean on SO(3) via SVD, with a reflection guard |
| `coincidence_frac` | Fraction of one coil's frames within 0.1 s of the other's — the swap-vs-simultaneous test |
| `head_relative_pose` | The per-frame change of basis into the head tracker's frame |

Note the deliberate contrast with the live monitor: offline, distance is the
**Euclidean norm** and angle is the single **geodesic rotation angle**; live,
it's per-axis offsets and per-axis tilts, because an operator needs to know
*which* axis went out.

### Stage 3 — the join, and what gets thrown away

For each `trigger_time`, find the coil frame nearest in time and record
`match_gap_s`. Any MEP whose nearest frame is more than **0.10 s** away
(`MAX_MATCH_GAP_S`) is **dropped** — that means a tracker dropout, a coil stream
that ended early, or a bad clock offset, and the count of drops is printed. MEP
amplitude is log-transformed (it's roughly lognormal). Linear fits are gated
behind `FIT_MODELS`, off by default under the orchestrator: the LOESS shape is
meant to be eyeballed before anyone assumes linearity.

### Outputs

Written to `data_analysis/output/`, all git-ignored (they carry subject IDs and
session timestamps): one **CSV** — `trigger_time`, `coil`,
`delta_distance_mm`, `delta_angle_deg`, `mep_ptp`, one row per surviving MEP —
plus **three PNGs**: MEP vs time, log(MEP) vs distance, log(MEP) vs angle. The
two scatter plots are coloured and smoothed *per coil*, so a coil swap shows up
as two series rather than one misleading cloud.

### Ad-hoc joins

When the MEPs are already in the session as a data frame rather than a QtracP
export, [`join_meps.R`](data_analysis/join_meps.R) does the same job in one
call:

```r
source("Y:/Neuro_Nav_App/data_analysis/join_meps.R")
out <- join_MEPs(diff = 0.472957, QLG = QLG_PATH, new_df = df)
```

`new_df` needs an elapsed-time column in decimal minutes (default `Time`),
taken to be **the pulse itself** — no latency is subtracted, since there's no
recorded response to work back from. Every other column rides through
untouched, and the returned tibble gains `trigger_time`, `coil`,
`trans_dist_mm`, `ang_dist_deg`, and `match_gap_s`. There's no window filter:
all rows are used, minus those further than `max_gap_s` (default 0.10 s) from a
coil frame. Stage 2 is not reimplemented — it's sourced into a private
environment with every config slot injected, so the geometry can't drift from
the pipeline's and nothing leaks into your globals. Pass `coil_dist =` a
previous result to skip re-parsing the neuronav file on repeat calls.

---

## 6. Commands

**Windows — start the receiver** (prints IP, port, and token for the Mac):

```bash
python -m trigger_app_AJ.windows.main
```

Useful flags: `--show-token`, `--new-token`, `--token 1234` (pins it, disables
rotation), `--no-keystroke` (dry run), `--port N`.

**Mac — GUI:**

```bash
cd python && python3 -m brainsight_gui
```

**Mac — CLI, terminal-only (no Windows machine needed):**

```bash
python3 python/alert_brainsight_v2.4.0.py "path/to/Streamed Info.txt"
```

**Mac — CLI, with triggering:**

```bash
python3 python/alert_brainsight_v2.4.0.py "<file>" --trigger-to 192.168.1.20:5050 --token 1234
```

**Check a session file is actually being written:**

```bash
python3 python/monitor_brainsight.py "path/to/Streamed Info.txt"
```

**Send test TTL pulses to Brainsight** via an NI USB-6361 (needs `nidaqmx`;
`--dry-run` works without hardware):

```bash
python3 python/daq_trigger_out.py --interval 0.5 --count 50
```

**Analysis** — open `Neuro_Nav.Rproj` in RStudio, edit the `INPUTS` /`OUTPUTS`
blocks at the top of
[`data_analysis/run_analysis.R`](data_analysis/run_analysis.R), and run the
whole file. Nothing else needs editing, and each stage can also be run on its
own (it falls back to its own defaults). Restart the R session between
participants. R packages needed: `dplyr`, `ggplot2`, `readxl`, `lubridate`,
`stringr`.

**Builds** — PyInstaller can't cross-compile, so each runs on its own platform:
`bash python/brainsight_gui/build/build_mac.sh` → `Brainsight Monitor.app`/`.dmg`;
`trigger_app_AJ\build\build_windows.bat` → `TMS Trigger Receiver.exe`.
Both bundles are self-contained — lab machines need no Python.

---

## 7. Conventions and gotchas

- **Versioned filenames, not branches.** `alert_brainsight_v1.py` →
  `v2.4.0.py`; old versions are kept on purpose. **The highest number is the
  current one.** The GUI tracks the latest CLI's logic instead of carrying its
  own version.
- **The Mac side is stdlib-only** (`parse_brainsight.py` aside, which needs
  pandas). That's why the protocol constants and geometry are *duplicated* in
  the CLI script and in `monitor_worker.py` rather than imported from
  `trigger_app_AJ/common/` — the CLI script must be copyable to a Mac as a
  single file. `common/protocol.py` is the canonical definition; **change it and
  the two copies together.** Only the Windows receiver has a dependency
  (`pyautogui`).
- **Nothing with subject data is tracked.** `.gitignore` excludes `data/`, all
  `*.csv`, `data_analysis/output/`, the token files, `config.json`, and
  `time_sync_log.txt`. Session exports live in the lab data store.
- **Open `Neuro_Nav.Rproj` before running R** — but note the `data_analysis/`
  scripts hard-code **absolute** paths (`Y:/Neuro_Nav_App/...` for the repo,
  `Y:/Merged Data/...` for the Qtrac exports). They run as-is only on the lab
  Windows machine; elsewhere, change `PROJECT_ROOT` and the input paths in
  `run_analysis.R`.
- **Docs to cross-check:** [`CLAUDE.md`](CLAUDE.md) is the deepest reference but
  still describes an `R/` directory at the repo root — those helpers now live in
  [`data_analysis/R/`](data_analysis/R/). [`README.md`](README.md) still names
  v2.2.0 as the CLI entry point; v2.4.0 is current.
  [`trigger_app_AJ/README.md`](trigger_app_AJ/README.md) is the authority on the
  wire protocol and troubleshooting; [`CHANGELOG.md`](CHANGELOG.md) records what
  each version added.

## 8. Where to start reading

| To understand… | Read |
|---|---|
| The file format everything depends on | [`python/parse_brainsight.py`](python/parse_brainsight.py) — the `SCHEMAS` dict is the whole spec |
| The live drift logic, end to end | [`python/alert_brainsight_v2.4.0.py`](python/alert_brainsight_v2.4.0.py) — `monitor_loop()` is the heart |
| How the two machines agree on time | [`trigger_app_AJ/common/timesync.py`](trigger_app_AJ/common/timesync.py) |
| How the GUI stays thread-safe | [`python/brainsight_gui/monitor_worker.py`](python/brainsight_gui/monitor_worker.py) — the docstring states the contract |
| The offline analysis | [`data_analysis/run_analysis.R`](data_analysis/run_analysis.R) — its `INPUTS` block is the whole interface — then the three stage scripts in order |
| Why an MEP's timestamp is what it is | [`data_analysis/clean_mep_times.R`](data_analysis/clean_mep_times.R) — the four-line transformation chain in its header comment |
| The coil-vs-target geometry and its options | [`data_analysis/coil_to_sample_delta.R`](data_analysis/coil_to_sample_delta.R) — the header comment documents both switches before any code runs |
