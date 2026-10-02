# =====================================================================
# clean_mep_times.R   (stage 1 of the neuronav + TMS MEP analysis)
#
# Goal of this stage: pull the MEPs recorded after a given time point out of
# a QtracP .xlsx export, stamp each one with a real (not elapsed) wall-clock
# time anchored on the QtracS .QLG launch, and keep the cleaned data frame in
# R. No export of the data frame yet -- later stages will bind this to the
# neuronav stream.
#
# Pipeline (per MEP sample):
#   actual_time    = QLG launch + the REAL elapsed seconds of the pulse's
#                    "Trigger stim" line in the .QLG, matched to the xlsx row
#                    by the nominal sweep clock both files carry (see
#                    offset_study/R/qtrac_io.R). The xlsx "Elapsed Time (min)"
#                    is a sweep counter that drifts ahead of real time by up to
#                    minutes, so it is used only as the matching key.
#   <filter>         keep only elapsed in [WINDOW_LOW, WINDOW_HIGH] minutes
#   corrected_time = actual_time - CLOCK_OFFSET_SEC seconds   (clock sync)
#                    == the "MEP time"
#   latency_min    = sheet "L" Chan-1 latency (ms) / 60000     (ms -> minutes)
#   trigger_time   = corrected_time - latency_min              (TMS pulse time)
#
# NOTE: the four numbers in the CONFIG block (window bounds + clock offset)
# and the file paths are SPECIFIC TO THIS PARTICIPANT/SESSION. They are
# hard-coded here on purpose; a later stage will import them automatically.
# =====================================================================

# ---- CONFIG (edit per session) --------------------------------------
# Each injectable input uses `if (!exists())` so a parent orchestrator
# (run_analysis.R) can set it first; edit the default after the `<-` for
# standalone runs.
if (!exists("XLSX_PATH"))   XLSX_PATH <- "Y:/Merged Data/xlsx Data/SNBR-169-MT-FU1-TP3C60625B.xlsx"
if (!exists("QLG_PATH"))    QLG_PATH  <- "Y:/Merged Data/Data/TP3C60625B.QLG"

# Filter window on the .xlsx "elapsed time" column (UNITS: minutes, inclusive).
if (!exists("WINDOW_LOW"))  WINDOW_LOW  <- 36.69168472   # keep MEPs elapsed >= this
if (!exists("WINDOW_HIGH")) WINDOW_HIGH <- 43.96465302   # keep MEPs elapsed <= this

# Clock-sync correction subtracted from the actual time (UNITS: seconds).
# Copy `delta_s` from the time-sync log WITH ITS SIGN (Windows - Mac; it has
# been negative, i.e. the Mac ahead, in every session so far). Positive =
# the Windows clock runs ahead, so we shift timestamps earlier.
if (!exists("CLOCK_OFFSET_SEC")) CLOCK_OFFSET_SEC <- -0.837211

# Reader for the QtracS run log's per-pulse trigger lines (shared with Route C).
if (!exists("QTRAC_IO_PATH")) QTRAC_IO_PATH <- "Y:/Neuro_Nav_App/analysis/offset_study/R/qtrac_io.R"

# Session calendar date for the wall-clock anchor. The .QLG row-1 line only
# carries a time-of-day (no date); leave as NA to use the .QLG file's own
# modified-date, or hard-code "YYYY-MM-DD" to override.
if (!exists("SESSION_DATE")) SESSION_DATE <- NA

# Sheet + column layout of the QtracP export.
XLSX_SHEET       <- "P"   # sheet holding elapsed time + peak-to-peak
TIME_COL         <- 1     # col 1 = elapsed time (minutes, decimal)
PTP_COL          <- 2     # col 2 = peak-to-peak amplitude (the only populated
                          #         channel here; labelled "Chan 1" in the sheet)

LAT_SHEET        <- "L"   # sheet holding MEP latency
LAT_TIME_COL     <- 1     # col 1 = elapsed time (minutes) — same join key as sheet P
LAT_COL          <- 2     # col 2 = MEP latency, Chan 1 (UNITS: milliseconds)

TZ               <- "America/Toronto"   # wall-clock zone for all timestamps

# Where to drop the QC scatter plot for this stage (standalone runs only).
if (!exists("PLOT_PATH")) PLOT_PATH <- "Y:/Neuro_Nav_App/analysis/mep_scatter.png"
# ---------------------------------------------------------------------

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(lubridate)
  library(stringr)
  library(ggplot2)
})
options(digits.secs = 3)   # print milliseconds on POSIXct

# ---- 1. QLG launch time + per-pulse trigger lines -------------------
# Session date: explicit override, else the QLG file's modified date.
session_date <- if (is.na(SESSION_DATE)) {
  as_date(file.info(QLG_PATH)$mtime)
} else {
  as_date(SESSION_DATE)
}
source(QTRAC_IO_PATH)                       # os_read_qlg(), os_match_pulses()
qlg       <- os_read_qlg(QLG_PATH, session_date, TZ)
launch_dt <- qlg$launch_dt

# ---- 2. elapsed time + peak-to-peak from sheet "P" ------------------
# Row 1 is the "Chan n" header; data starts row 2.
xlsx_raw <- suppressMessages(
  read_excel(XLSX_PATH, sheet = XLSX_SHEET, col_names = FALSE, skip = 1L)
)

mep <- tibble(
  elapsed_min = as.numeric(xlsx_raw[[TIME_COL]]),
  ptp         = as.numeric(xlsx_raw[[PTP_COL]])
) |>
  filter(!is.na(elapsed_min), !is.na(ptp))

# ---- 2b. MEP latency from sheet "L" ---------------------------------
# Col 1 is the same elapsed-time join key as sheet "P"; col 2 (Chan 1) is the
# MEP latency in MILLISECONDS. Convert to minute fractions so it matches the
# units of every other time in this file (elapsed_min, etc.).
lat_raw <- suppressMessages(
  read_excel(XLSX_PATH, sheet = LAT_SHEET, col_names = FALSE, skip = 1L)
)

lat <- tibble(
  elapsed_min = as.numeric(lat_raw[[LAT_TIME_COL]]),
  latency_ms  = as.numeric(lat_raw[[LAT_COL]])
) |>
  filter(!is.na(elapsed_min), !is.na(latency_ms)) |>
  mutate(latency_min = latency_ms / 60000)   # ms -> minutes (1 min = 60000 ms)

# ---- 3. actual time, window filter, clock-sync, latency + trigger ---
# corrected_time is the "MEP time"; subtracting the latency yields the
# trigger_time (when the TMS pulse fired, latency before the MEP was recorded).
# Real pulse time: the matched QLG trigger line's elapsed seconds after launch.
mep <- os_match_pulses(mep, qlg$triggers)
n_unmatched <- sum(is.na(mep$win_time))
if (n_unmatched > 0L)
  warning(n_unmatched, " MEP row(s) had no matching 'Trigger stim' line in the QLG and were dropped.")

mep_clean <- mep |>
  filter(!is.na(win_time)) %>%
  mutate(actual_time = win_time) %>%
  filter(elapsed_min >= WINDOW_LOW, elapsed_min <= WINDOW_HIGH) %>%
  mutate(corrected_time = actual_time - dseconds(CLOCK_OFFSET_SEC)) %>%  # = MEP time
  left_join(lat, by = "elapsed_min") %>%
  mutate(trigger_time = corrected_time - dminutes(latency_min)) %>%
  select(elapsed_min, actual_time, corrected_time, latency_ms, latency_min,
         trigger_time, ptp)

# ---- 4. report ------------------------------------------------------
message(sprintf("QLG launch anchor : %s  (date from %s; %d trigger lines, %d MEP rows matched)",
                format(launch_dt, "%Y-%m-%d %H:%M:%OS3"),
                if (is.na(SESSION_DATE)) "QLG mtime" else "config",
                qlg$n_triggers, nrow(mep) - n_unmatched))
message(sprintf("Elapsed window    : [%.8f, %.8f] min", WINDOW_LOW, WINDOW_HIGH))
message(sprintf("Clock offset       : %.6f s subtracted", CLOCK_OFFSET_SEC))
message(sprintf("MEPs kept          : %d of %d", nrow(mep_clean), nrow(mep)))
message(sprintf("Latency (ms)       : %.1f-%.1f  (mean %.1f)",
                min(mep_clean$latency_ms), max(mep_clean$latency_ms),
                mean(mep_clean$latency_ms)))

# ---- 5. QC deliverable: scatter (time x, peak-to-peak y) ------------
# Standalone only -- under run_analysis.R the orchestrator owns the plots.
if (!exists("ORCHESTRATED")) {
  print(head(mep_clean, 10L))
  qc_plot <- ggplot(mep_clean, aes(x = corrected_time, y = ptp)) +
    geom_point(size = 2, alpha = 0.8, colour = "#2c7fb8") +
    scale_x_datetime(date_labels = "%H:%M:%OS1") +
    labs(
      title    = "MEP peak-to-peak vs. clock-corrected time",
      subtitle = sprintf("%d MEPs  |  elapsed %.3f-%.3f min  |  offset -%.3f s",
                          nrow(mep_clean), WINDOW_LOW, WINDOW_HIGH, CLOCK_OFFSET_SEC),
      x = "Corrected wall-clock time", y = "Peak-to-peak amplitude (mV)"
    ) +
    theme_minimal(base_size = 12)
  ggsave(PLOT_PATH, qc_plot, width = 9, height = 5, dpi = 150)
  message(sprintf("QC scatter written : %s", PLOT_PATH))
}

# `mep_clean` is left in the R session for the next stage (no data export).
