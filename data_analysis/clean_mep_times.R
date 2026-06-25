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
#   actual_time    = QLG_launch_time + elapsed_minutes        (from .xlsx "P")
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
XLSX_PATH        <- "Y:/Merged Data/xlsx Data/SNBR-169-MT-FU1-TP3C60625B.xlsx"
QLG_PATH         <- "Y:/Merged Data/Data/TP3C60625B.QLG"

# Filter window on the .xlsx "elapsed time" column (UNITS: minutes, inclusive).
WINDOW_LOW       <- 36.69168472   # keep MEPs with elapsed >= this
WINDOW_HIGH      <- 43.96465302   # keep MEPs with elapsed <= this

# Clock-sync correction subtracted from the actual time (UNITS: seconds).
# Positive = the recorded clock runs ahead, so we shift timestamps earlier.
CLOCK_OFFSET_SEC <- 0.837211

# Session calendar date for the wall-clock anchor. The .QLG row-1 line only
# carries a time-of-day (no date); leave as NA to use the .QLG file's own
# modified-date, or hard-code "YYYY-MM-DD" to override.
SESSION_DATE     <- NA

# Sheet + column layout of the QtracP export.
XLSX_SHEET       <- "P"   # sheet holding elapsed time + peak-to-peak
TIME_COL         <- 1     # col 1 = elapsed time (minutes, decimal)
PTP_COL          <- 2     # col 2 = peak-to-peak amplitude (the only populated
                          #         channel here; labelled "Chan 1" in the sheet)

LAT_SHEET        <- "L"   # sheet holding MEP latency
LAT_TIME_COL     <- 1     # col 1 = elapsed time (minutes) — same join key as sheet P
LAT_COL          <- 2     # col 2 = MEP latency, Chan 1 (UNITS: milliseconds)

TZ               <- "America/Toronto"   # wall-clock zone for all timestamps

# Where to drop the QC scatter plot for this stage.
PLOT_PATH        <- "Y:/Neuro_Nav_App/data_analysis/mep_scatter.png"
# ---------------------------------------------------------------------

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(lubridate)
  library(stringr)
  library(ggplot2)
})
options(digits.secs = 3)   # print milliseconds on POSIXct

# ---- 1. QLG launch time-of-day (the wall-clock anchor t0) -----------
# First timestamped line, e.g. "11:40:12 AM 00000.002 000.000 :".
qlg_head  <- readLines(QLG_PATH, n = 20L, warn = FALSE)
tod_match <- str_match(qlg_head, "^\\s*(\\d{1,2}:\\d{2}:\\d{2})\\s*([AP]M)")
hit_i     <- which(!is.na(tod_match[, 1L]))[1L]
if (is.na(hit_i)) stop("No clock time found in QLG header: ", QLG_PATH)
launch_tod <- paste(tod_match[hit_i, 2L], tod_match[hit_i, 3L])   # "11:40:12 AM"

# Session date: explicit override, else the QLG file's modified date.
session_date <- if (is.na(SESSION_DATE)) {
  as_date(file.info(QLG_PATH)$mtime)
} else {
  as_date(SESSION_DATE)
}

# Combine date + 12-hour time-of-day -> POSIXct anchor.
hms24      <- format(strptime(launch_tod, "%I:%M:%S %p"), "%H:%M:%S")
launch_dt  <- as_datetime(paste(session_date, hms24), tz = TZ)

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
mep_clean <- mep |>
  mutate(actual_time = launch_dt + dminutes(elapsed_min)) %>%
  filter(elapsed_min >= WINDOW_LOW, elapsed_min <= WINDOW_HIGH) %>%
  mutate(corrected_time = actual_time - dseconds(CLOCK_OFFSET_SEC)) %>%  # = MEP time
  left_join(lat, by = "elapsed_min") %>%
  mutate(trigger_time = corrected_time - dminutes(latency_min)) %>%
  select(elapsed_min, actual_time, corrected_time, latency_ms, latency_min,
         trigger_time, ptp)

# ---- 4. report ------------------------------------------------------
message(sprintf("QLG launch anchor : %s  (date from %s)",
                format(launch_dt, "%Y-%m-%d %H:%M:%OS3"),
                if (is.na(SESSION_DATE)) "QLG mtime" else "config"))
message(sprintf("Elapsed window    : [%.8f, %.8f] min", WINDOW_LOW, WINDOW_HIGH))
message(sprintf("Clock offset       : %.6f s subtracted", CLOCK_OFFSET_SEC))
message(sprintf("MEPs kept          : %d of %d", nrow(mep_clean), nrow(mep)))
message(sprintf("Latency (ms)       : %.1f-%.1f  (mean %.1f)",
                min(mep_clean$latency_ms), max(mep_clean$latency_ms),
                mean(mep_clean$latency_ms)))
print(head(mep_clean, 10L))

# ---- 5. QC deliverable: scatter (time x, peak-to-peak y) ------------
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

# `mep_clean` is left in the R session for the next stage (no data export).
