# =====================================================================
# sync_mep_times.R
#
# Build a Mac-clock-synced MEP table from three data-collection files:
#   * QtracS run log (.QLG)        -> session start wall-clock (the anchor t0)
#   * QtracP export  (.xlsx, "P")  -> elapsed-time (min) + MEP amplitude
#   * Neuro_Nav time-sync log      -> delta_s (Windows_clock - Mac_clock)
#
# Pipeline (per MEP sample):
#   windows_time = t0(QtracS launch) + elapsed_minutes
#   mac_time     = windows_time - delta_s        # mac = windows - delta_s
#
# Output: data frame `synced` with the Mac-synced time + MEP. This script is
# a first stage -- later steps will join the neuronav coil-distance stream --
# so nothing is exported yet.
# =====================================================================

# ---- CONFIG (edit these) --------------------------------------------
QLG_PATH          <- "Y:/Merged Data/Data/TSTC60622B.QLG"
XLSX_PATH         <- "Y:/Merged Data/xlsx Data/TSTC60622B.xlsx"
TIMESYNC_LOG_PATH <- "X:/temp_files/Ali_testing/time_sync_log.txt"

XLSX_SHEET        <- "P"   # sheet holding elapsed-time + MEP (sheet "P")
ELAPSED_COL       <- 1     # 1st column = Elapsed Time (minutes, decimal)
MEP_COL           <- 2     # 2nd column = MEP amplitude

TZ                <- "America/Toronto"  # local wall-clock zone for ALL times
ANCHOR_OFFSET_SEC <- 0     # shift the QtracS-launch anchor (+/- s) if the
                           # elapsed-time origin turns out not to be row 1
DELTA_SELECT      <- "nearest"  # which sync row to use:
                                #   "nearest" -> closest to the QtracS launch
                                #   "first"   -> first row in the log
                                #   "last"    -> most recent row
# ---------------------------------------------------------------------

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(lubridate)
  library(stringr)
  library(tibble)
})
options(digits.secs = 3)   # show milliseconds when printing POSIXct

# ---- helpers --------------------------------------------------------

# Parse the time-sync log (tab-separated, '#'-commented header).
# Columns: win_local_time, delta_s, rtt_ms, mac_local_time, peer, t1..t4
read_timesync <- function(path) {
  raw  <- readLines(path, warn = FALSE)
  rows <- raw[!grepl("^\\s*#", raw) & nzchar(trimws(raw))]
  if (length(rows) == 0L) stop("No data rows in time-sync log: ", path)
  m <- read.table(text = rows, sep = "\t", stringsAsFactors = FALSE,
                  quote = "", comment.char = "")
  tibble(
    win_local_time = ymd_hms(m[[1]], tz = TZ),
    delta_s        = as.numeric(m[[2]]),
    mac_local_time = ymd_hms(m[[4]], tz = TZ)
  )
}

# Grab the QtracS launch time-of-day from the first timestamped QLG line,
# e.g. "11:35:28 AM 00000.001  000.000  :" -> list(time="11:35:28", ampm="AM")
read_qlg_launch_tod <- function(path) {
  head_lines <- readLines(path, n = 20L, warn = FALSE)
  hit <- str_match(head_lines, "^\\s*(\\d{1,2}:\\d{2}:\\d{2})\\s*([AP]M)")
  i   <- which(!is.na(hit[, 1L]))[1L]
  if (is.na(i)) stop("Could not find a clock time in QLG header: ", path)
  list(time = hit[i, 2L], ampm = hit[i, 3L])
}

# Combine a calendar Date with a "HH:MM:SS AM/PM" time-of-day -> POSIXct (TZ).
make_datetime_local <- function(date, tod) {
  hms24 <- format(strptime(paste(tod$time, tod$ampm), "%I:%M:%S %p"), "%H:%M:%S")
  as_datetime(paste(date, hms24), tz = TZ)
}

# ---- 1. read inputs -------------------------------------------------
ts     <- read_timesync(TIMESYNC_LOG_PATH)
launch <- read_qlg_launch_tod(QLG_PATH)

# ---- 2. pick the sync row (delta_s) + session date ------------------
# For "nearest", compare each row's Windows wall-clock to the QtracS launch
# reconstructed on that row's own date (handles a multi-day log cleanly).
cand_launch <- make_datetime_local(as_date(ts$win_local_time), launch)
row_i <- switch(
  DELTA_SELECT,
  first   = 1L,
  last    = nrow(ts),
  nearest = which.min(abs(as.numeric(ts$win_local_time - cand_launch))),
  stop("Unknown DELTA_SELECT: ", DELTA_SELECT)
)

delta_s      <- ts$delta_s[row_i]
session_date <- as_date(ts$win_local_time[row_i])
launch_dt    <- make_datetime_local(session_date, launch) +
                  seconds(ANCHOR_OFFSET_SEC)   # absolute Windows-clock anchor

# ---- 3. elapsed time + MEP from sheet "P" ---------------------------
# First two columns: [1] Elapsed Time (min), [2] MEP amplitude. (Columns D/F
# of the sheet are the same data, labelled "Elapsed Time (min)" / "Values".)
xlsx_raw <- read_excel(XLSX_PATH, sheet = XLSX_SHEET, col_names = FALSE, skip = 1L)
mep_tbl  <- tibble(
  elapsed_min = as.numeric(xlsx_raw[[ELAPSED_COL]]),
  mep         = as.numeric(xlsx_raw[[MEP_COL]])
) %>% filter(!is.na(elapsed_min))

# ---- 4. compute Windows-clock time, then Mac-synced time ------------
synced <- mep_tbl %>%
  mutate(
    windows_time = launch_dt + dminutes(elapsed_min),
    mac_time     = windows_time - dseconds(delta_s)   # mac = windows - delta_s
  ) %>%
  select(elapsed_min, windows_time, mac_time, mep)

# ---- report ---------------------------------------------------------
message(sprintf("Time-sync: row %d/%d  delta_s = %+.6f s (Windows - Mac)  |  session %s",
                row_i, nrow(ts), delta_s, format(session_date)))
message(sprintf("QtracS launch anchor (Windows clock): %s  (anchor offset %+g s)",
                format(launch_dt, "%Y-%m-%d %H:%M:%OS3"), ANCHOR_OFFSET_SEC))
message(sprintf("MEP samples synced: %d", nrow(synced)))
print(head(synced, 10L))
