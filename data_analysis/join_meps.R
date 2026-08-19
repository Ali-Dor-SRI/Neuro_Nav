# =====================================================================
# join_meps.R   (ad-hoc MEP -> coil-placement join)
#
# Same time reconstruction and the same coil geometry as run_analysis.R, but
# the MEPs come from a data frame you already have in the session instead of a
# QtracP .xlsx export. Sourcing this file only DEFINES `join_MEPs()` -- nothing
# runs until you call it:
#
#   source("Y:/Neuro_Nav_App/data_analysis/join_meps.R")
#   out <- join_MEPs(diff     = 0.472957,
#                    QLG      = "Y:/Merged Data/Data/TP3C60702A.QLG",
#                    new_df   = df,
#                    neuronav = "Y:/Neuro_Nav_App/data/SNBR-179.txt",
#                    sample   = "Sample 1")
#
# `sample` is the REFERENCE the deltas are measured from -- the moment the coil
# was where you wanted it. Under the default target_mode = "sample_average" it
# anchors the average: that sample's timestamp plus the next n_samples_avg - 1
# coil frames become the target pose. It accepts, in priority order, a
# `New Sample` / `Target Selection` NAME ("Sample 1"), a timestamp
# ("12:21:13.545"), or a Polaris Tool frame_number. Under the legacy
# target_mode = "target_selection" it is instead the name of the
# `Target Selection` row to look up directly, so only a name is valid there.
#
# All five arguments are per-session, so none of them has a default.
# (`neuronav` and `sample` may be omitted only when you pass `coil_dist =` a
# coil stream from an earlier call, which already has a target baked in.)
#
# `new_df` is any data frame carrying an elapsed-time column (default "Time",
# decimal MINUTES since the QtracS launch). Every other column is carried
# through untouched, so
#
#   # A tibble: 6 x 4
#      Time   MSO Channel   PTP
#     <dbl> <dbl>   <dbl> <dbl>
#   1  2.77    52       1 0.239
#
# comes back as Time / MSO / Channel / PTP plus five new columns:
#
#   trigger_time    POSIXct, on the Mac / Brainsight clock
#   coil            the coil tracker active at that instant
#   trans_dist_mm   coil-to-target translational distance (mm)
#   ang_dist_deg    coil-to-target angular distance (deg)
#   match_gap_s     how far away in time the nearest coil frame was
#
# TIME MODEL -- `Time` is taken to be the TMS PULSE itself. No MEP latency is
# subtracted (clean_mep_times.R does that because it starts from the recorded
# response; here the input is already the stimulus):
#
#   trigger_time = QLG_launch + Time minutes - diff seconds
#
# `diff` is the same quantity as the pipeline's CLOCK_OFFSET_SEC: seconds,
# Windows - Mac, read off the receiver's time_sync_log.txt. Positive means the
# Windows clock runs ahead, so it is SUBTRACTED to land on the Mac clock.
#
# Unlike run_analysis.R there is no elapsed-time window filter -- every row you
# hand in is used. Rows whose nearest coil frame is further than `max_gap_s`
# away are dropped (tracker dropout / wrong clock offset) and the count is
# reported.
#
# The coil side is NOT reimplemented here: coil_to_sample_delta.R is sourced
# into a private environment with the arguments below injected into its
# `if (!exists())` config slots, so this file and the pipeline can never drift
# apart geometrically. Every injectable is set explicitly, so stray globals in
# your session can't leak in either.
# =====================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
  library(stringr)
  library(tibble)
})
options(digits.secs = 3)

# ---- defaults (edit here; all are overridable per call) --------------
# Prefixed so that sourcing this file can never collide with the pipeline's
# own globals (NEURONAV_PATH, COORD_SYSTEM, ...) in a shared R session.
JM_ANALYSIS_DIR <- "Y:/Neuro_Nav_App/data_analysis"
JM_TZ           <- "America/Toronto"
JM_MAX_GAP_S    <- 0.10
# Frame + target defaults follow coil_to_sample_delta.R's own documented
# defaults (head-relative Polaris, 5-frame averaged target), NOT whatever
# run_analysis.R happens to be set to for the last participant.
JM_COORD_SYSTEM  <- "Polaris"
JM_TARGET_MODE   <- "sample_average"
JM_N_SAMPLES_AVG <- 5L
JM_HEAD_TRACKER  <- "ST893"
# ---------------------------------------------------------------------


# ---- helpers ---------------------------------------------------------

# QLG -> POSIXct launch anchor. Accepts a path to the .QLG (scraped for the
# first "HH:MM:SS AM/PM" line, dated from the file's mtime unless session_date
# is given) or a POSIXct you already computed, which passes straight through.
jm_qlg_launch <- function(QLG, session_date = NA, tz = JM_TZ) {
  if (inherits(QLG, "POSIXct")) return(QLG)
  if (!is.character(QLG) || length(QLG) != 1L)
    stop("QLG must be a path to a .QLG file or a POSIXct launch time (got ",
         class(QLG)[1L], ").")
  if (!file.exists(QLG)) stop("QLG file not found: ", QLG)

  head_lines <- readLines(QLG, n = 20L, warn = FALSE)
  hit <- str_match(head_lines, "^\\s*(\\d{1,2}:\\d{2}:\\d{2})\\s*([AP]M)")
  i   <- which(!is.na(hit[, 1L]))[1L]
  if (is.na(i)) stop("No clock time found in the QLG header: ", QLG)

  date  <- if (all(is.na(session_date))) as_date(file.info(QLG)$mtime)
           else                          as_date(session_date)
  hms24 <- format(strptime(paste(hit[i, 2L], hit[i, 3L]), "%I:%M:%S %p"),
                  "%H:%M:%S")
  as_datetime(paste(date, hms24), tz = tz)
}

# Run coil_to_sample_delta.R in a private environment and hand back its
# `coil_dist` (time, coil, trans_dist_mm, ang_dist_deg).
jm_coil_dist <- function(neuronav, analysis_dir, coord_system, target_mode,
                         sample, n_samples_avg, head_tracker,
                         head_relative, coil_name, quiet) {
  script <- file.path(analysis_dir, "coil_to_sample_delta.R")
  parser <- file.path(analysis_dir, "R", "parse_brainsight.R")
  for (p in c(script, parser))
    if (!file.exists(p)) stop("Required script not found: ", p)
  if (!file.exists(neuronav)) stop("Neuronav file not found: ", neuronav)

  e <- new.env(parent = globalenv())
  e$NEURONAV_PATH <- neuronav
  e$PARSER_PATH   <- parser
  e$COORD_SYSTEM  <- coord_system
  e$TARGET_MODE   <- target_mode
  e$N_SAMPLES_AVG <- as.integer(n_samples_avg)
  e$HEAD_TRACKER  <- head_tracker
  e$HEAD_RELATIVE <- isTRUE(head_relative)
  e$COIL_NAME     <- coil_name
  e$COIL_ROW_TYPE <- "Crosshairs Position"   # MNI/legacy mode only
  # The reference sample lands in whichever slot the active target mode reads:
  # SAMPLE_START for "sample_average", SAMPLE_NAME for legacy
  # "target_selection". Both are set regardless, so an unrelated global of
  # either name can never leak in through the stage's if (!exists()) guards.
  e$SAMPLE_START  <- sample
  e$SAMPLE_NAME   <- sample
  e$ORCHESTRATED  <- TRUE                    # skip the stage's own prints

  run <- function() sys.source(script, envir = e)
  if (isTRUE(quiet)) suppressMessages(run()) else run()

  if (!exists("coil_dist", envir = e, inherits = FALSE))
    stop("coil_to_sample_delta.R did not produce `coil_dist`.")
  e$coil_dist
}

# Index of the nearest value in `coil_times` (ASCENDING, numeric) for each of
# `targets`. Ties resolve to the earlier frame, matching which.min() in
# mep_vs_coil_distance.R.
jm_nearest <- function(coil_times, targets) {
  ct <- as.numeric(coil_times)
  tt <- as.numeric(targets)
  j  <- findInterval(tt, ct)
  lo <- pmax(j, 1L)
  hi <- pmin(j + 1L, length(ct))
  ifelse(abs(tt - ct[lo]) <= abs(tt - ct[hi]), lo, hi)
}


# ---- the one call ----------------------------------------------------

#' Attach coil placement to a hand-built MEP table.
#'
#' @param diff          Clock offset in SECONDS, Windows - Mac (subtracted).
#' @param QLG           Path to the QtracS .QLG run log, or a POSIXct launch time.
#' @param new_df        Data frame with an elapsed-time column; all other
#'                      columns are passed through untouched.
#' @param neuronav      Path to THIS session's Brainsight streamed-info .txt.
#'                      Required unless `coil_dist` is supplied.
#' @param sample        The reference the deltas are measured from. Under
#'                      target_mode "sample_average" it anchors the averaged
#'                      target pose and accepts a New Sample / Target Selection
#'                      NAME ("Sample 1"), a timestamp, or a frame number;
#'                      under legacy "target_selection" it is the name of the
#'                      Target Selection row to use. Required unless
#'                      `coil_dist` is supplied.
#' @param time_col      Name of the elapsed-time column (decimal minutes).
#' @param max_gap_s     Drop MEPs whose nearest coil frame is further away.
#' @param coord_system  "Polaris" (head-relative) or "MNI" (legacy crosshairs).
#' @param target_mode   "sample_average" or "target_selection" (legacy, MNI).
#' @param n_samples_avg Coil frames averaged into the target, from `sample` on.
#' @param coil_dist     Optional precomputed coil stream; skips re-parsing the
#'                      neuronav file when calling repeatedly on one session.
#' @return A tibble: the input columns plus trigger_time, coil,
#'         trans_dist_mm, ang_dist_deg, match_gap_s.
join_MEPs <- function(diff,
                      QLG,
                      new_df,
                      neuronav      = NULL,   # required unless coil_dist is given
                      sample        = NULL,   # required unless coil_dist is given
                      time_col      = "Time",
                      max_gap_s     = JM_MAX_GAP_S,
                      coord_system  = JM_COORD_SYSTEM,
                      target_mode   = JM_TARGET_MODE,
                      n_samples_avg = JM_N_SAMPLES_AVG,
                      head_tracker  = JM_HEAD_TRACKER,
                      head_relative = TRUE,
                      coil_name     = "auto",
                      session_date  = NA,
                      tz            = JM_TZ,
                      coil_dist     = NULL,
                      analysis_dir  = JM_ANALYSIS_DIR,
                      quiet         = FALSE) {

  # ---- 1. validate the inputs ---------------------------------------
  if (!is.data.frame(new_df))
    stop("new_df must be a data frame / tibble (got ", class(new_df)[1L], ").")
  if (nrow(new_df) == 0L)
    stop("new_df has no rows.")
  if (!time_col %in% names(new_df))
    stop("new_df has no column '", time_col, "'. Columns present: ",
         paste(names(new_df), collapse = ", "),
         ". Pass time_col = <name> if the elapsed-time column is named differently.")
  if (!is.numeric(diff) || length(diff) != 1L || is.na(diff))
    stop("diff must be a single number: seconds, Windows - Mac.")
  if (!is.numeric(max_gap_s) || length(max_gap_s) != 1L || max_gap_s < 0)
    stop("max_gap_s must be a single non-negative number of seconds.")
  # The neuronav file and the reference sample both change every session, so
  # both are required -- the only way out is handing over an already-parsed
  # coil stream from a previous call, which has a target baked in already.
  if (is.null(coil_dist)) {
    if (is.null(neuronav) || !is.character(neuronav) ||
        length(neuronav) != 1L || !nzchar(neuronav))
      stop("neuronav must be the path to this session's Brainsight streamed-info ",
           ".txt file, e.g. neuronav = \"Y:/Neuro_Nav_App/data/<session>.txt\". ",
           "Pass coil_dist = <a previous result> to reuse an already-parsed ",
           "coil stream instead.")
    if (is.null(sample) || length(sample) != 1L || is.na(sample) ||
        !nzchar(trimws(as.character(sample))))
      stop("sample must name the reference the deltas are measured from, e.g. ",
           "sample = \"Sample 1\" (a New Sample / Target Selection name, a ",
           "timestamp, or a Polaris Tool frame number). Pass coil_dist = ",
           "<a previous result> to reuse a coil stream that already has one.")
    sample <- trimws(as.character(sample))
  }

  elapsed <- suppressWarnings(as.numeric(new_df[[time_col]]))
  if (all(is.na(elapsed)))
    stop("Column '", time_col, "' holds no usable numbers (expected decimal ",
         "minutes since the QtracS launch).")

  # ---- 2. elapsed -> wall clock -> Mac clock ------------------------
  launch_dt <- jm_qlg_launch(QLG, session_date, tz)
  mep <- as_tibble(new_df)
  mep$trigger_time <- launch_dt + dminutes(elapsed) - dseconds(diff)

  n_bad_time <- sum(is.na(mep$trigger_time))
  if (n_bad_time > 0L) {
    warning(n_bad_time, " row(s) dropped: '", time_col, "' was missing or unparseable.")
    mep <- mep[!is.na(mep$trigger_time), ]
  }
  if (nrow(mep) == 0L) stop("No rows left with a usable ", time_col, " value.")

  # ---- 3. coil distance/angle over time -----------------------------
  if (is.null(coil_dist)) {
    coil_dist <- jm_coil_dist(neuronav, analysis_dir, coord_system, target_mode,
                              sample, n_samples_avg, head_tracker,
                              head_relative, coil_name, quiet)
  }
  needed <- c("time", "coil", "trans_dist_mm", "ang_dist_deg")
  if (!all(needed %in% names(coil_dist)))
    stop("coil_dist is missing column(s): ",
         paste(setdiff(needed, names(coil_dist)), collapse = ", "))
  if (nrow(coil_dist) == 0L)
    stop("The coil stream is empty -- nothing to match against.")
  coil_dist <- arrange(coil_dist, time)   # jm_nearest() needs ascending time

  # ---- 4. nearest coil frame per pulse ------------------------------
  idx <- jm_nearest(coil_dist$time, mep$trigger_time)
  out <- mep %>%
    mutate(
      coil          = coil_dist$coil[idx],
      trans_dist_mm = coil_dist$trans_dist_mm[idx],
      ang_dist_deg  = coil_dist$ang_dist_deg[idx],
      match_gap_s   = abs(as.numeric(trigger_time) - as.numeric(coil_dist$time[idx]))
    )

  kept   <- out %>% filter(match_gap_s <= max_gap_s)
  n_drop <- nrow(out) - nrow(kept)

  # ---- 5. report -----------------------------------------------------
  if (!isTRUE(quiet)) {
    message(sprintf("QLG launch anchor : %s", format(launch_dt, "%Y-%m-%d %H:%M:%OS3")))
    message(sprintf("Reference sample  : %s",
                    if (is.null(sample)) "(target baked into the supplied coil_dist)"
                    else sprintf("'%s'", sample)))
    message(sprintf("Clock offset      : %+.6f s subtracted (Windows - Mac)", diff))
    message(sprintf("Pulse window      : %s .. %s",
                    format(min(mep$trigger_time), "%H:%M:%OS3"),
                    format(max(mep$trigger_time), "%H:%M:%OS3")))
    message(sprintf("Coil window       : %s .. %s  (%d frames)",
                    format(min(coil_dist$time), "%H:%M:%OS3"),
                    format(max(coil_dist$time), "%H:%M:%OS3"),
                    nrow(coil_dist)))
    message(sprintf("Match gap         : median %.3f s, max %.3f s",
                    median(out$match_gap_s), max(out$match_gap_s)))
    message(sprintf("Kept (gap <= %.2fs): %d  |  dropped (no valid coil pose): %d",
                    max_gap_s, nrow(kept), n_drop))
  }
  if (nrow(kept) == 0L)
    warning("Every row was dropped -- the pulse times and the coil stream do not ",
            "overlap. Check `diff`, the QLG date, and that the neuronav file is ",
            "from this session.")

  kept
}
