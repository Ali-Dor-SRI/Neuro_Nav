# =====================================================================
# coil_to_sample_delta.R   (neuronav side of the MEP analysis)
#
# Goal: load a Brainsight streamed-info .txt, pull the coil's 6-DoF pose in
# MNI space over time, and express every frame as a delta from a chosen
# reference sample (here "Sample 5"). Keeps the data frame in R -- no export
# yet; later stages will bind this to the MEP table from clean_mep_times.R.
#
# The coil (Coil B LCT / Coil A CT) is auto-detected from whichever is tracked.
# If a file swaps coils sequentially, both are kept and each frame is tagged
# with its coil; if both are tracked simultaneously the script stops and asks
# for an explicit COIL_NAME.
#
# Output data frame `coil_delta` columns:
#   time                                  POSIXct (ms precision)
#   coil                                  source coil for the frame
#   x, y, z                               coil position, MNI millimetres
#   yaw, pitch, roll                      coil orientation, degrees (ZYX)
#   dx, dy, dz                            coil - sample position    (mm)
#   dyaw, dpitch, droll                   coil - sample orientation (deg, wrapped)
#
# NOTE: the reference target (SAMPLE_NAME) and the coil selection in CONFIG are
# SPECIFIC TO THIS FILE/SESSION. Injectable inputs use `if (!exists())` so the
# orchestrator (run_analysis.R) can set them first. Each run tracks one target.
# =====================================================================

# ---- CONFIG (edit per session) --------------------------------------
if (!exists("NEURONAV_PATH")) NEURONAV_PATH <- "Y:/Neuro_Nav_App/data/SNBR-169.txt"
if (!exists("PARSER_PATH"))   PARSER_PATH   <- "Y:/Neuro_Nav_App/data_analysis/R/parse_brainsight.R"

# Which streamed object is "the coil", and in which coordinate system.
#   Crosshairs Position -> the navigated coil pose (default; matches a Sample)
#   Polaris Tool        -> the raw coil-tracker pose
# Only one coil is tracked at a time, so COIL_NAME can stay "auto" to pick
# whichever candidate actually has valid MNI frames; or pin a specific name.
if (!exists("COIL_ROW_TYPE")) COIL_ROW_TYPE <- "Crosshairs Position"
if (!exists("COIL_NAME"))     COIL_NAME     <- "auto"   # "auto", or pin a name
if (!exists("COORD_SYSTEM"))  COORD_SYSTEM  <- "MNI"

# Candidate coil names per row type (auto-detect picks whichever is present).
#   "Coil B LCT" is driven by the LCT650 tracker; "Coil A CT" by CT4661.
COIL_CANDIDATES <- list(
  "Crosshairs Position" = c("Coil B LCT", "Coil A CT"),
  "Polaris Tool"        = c("LCT650", "CT4661")
)

# If auto-detect finds >1 coil with valid frames, decide sequential vs
# simultaneous: a frame is "coincident" with the other coil if it falls within
# COIL_OVERLAP_TOL_S of one of its frames. If more than COIL_OVERLAP_MAX_FRAC of
# frames are coincident, the coils were tracked at the same time (ambiguous) and
# the script stops, asking for an explicit COIL_NAME. Otherwise the coils were
# swapped sequentially and both are kept (each frame tagged with its coil).
COIL_OVERLAP_TOL_S    <- 0.10
COIL_OVERLAP_MAX_FRAC <- 0.02

# Reference target. Each run tracks exactly ONE target. Set SAMPLE_NAME to the
# Target Selection name to look up in the neuronav file; its MNI pose (position +
# 3x3 direction-cosine matrix) becomes the reference everything is measured from.
if (!exists("SAMPLE_NAME")) SAMPLE_NAME <- "Sample 5"
# ---------------------------------------------------------------------

suppressPackageStartupMessages({
  library(dplyr)
})
options(digits.secs = 3)   # show milliseconds on POSIXct

source(PARSER_PATH)

# ---- helpers --------------------------------------------------------

# Rotation matrix (3x3) -> Tait-Bryan ZYX angles (yaw, pitch, roll) in degrees.
# R is built row-major from the 9 direction cosines. atan2 throughout for
# numerical stability; pitch is clamped through sqrt of the first column.
rot_to_ypr <- function(m9) {
  R <- matrix(m9, nrow = 3, byrow = TRUE)   # R[i, j] = m{i-1}n{j-1}
  yaw   <- atan2(R[2, 1], R[1, 1])
  pitch <- atan2(-R[3, 1], sqrt(R[1, 1]^2 + R[2, 1]^2))
  roll  <- atan2(R[3, 2], R[3, 3])
  c(yaw = yaw, pitch = pitch, roll = roll) * 180 / pi
}

# Shortest signed angular difference, wrapped to (-180, 180] degrees.
wrap_deg <- function(d) ((d + 180) %% 360) - 180

# Single rotation angle between two orientations (the geodesic angle on SO(3)),
# in degrees. Frame-independent: angle = acos((trace(Ra' Rb) - 1) / 2). Both
# args are 9 direction cosines in row-major order.
rot_angle_deg <- function(m9_a, m9_b) {
  Ra <- matrix(m9_a, nrow = 3, byrow = TRUE)
  Rb <- matrix(m9_b, nrow = 3, byrow = TRUE)
  cos_t <- (sum(diag(crossprod(Ra, Rb))) - 1) / 2   # crossprod = t(Ra) %*% Rb
  acos(max(-1, min(1, cos_t))) * 180 / pi           # clamp for numerical safety
}

# Fraction of timestamps in `ta` that have a timestamp in `tb` within `tol`
# seconds. ~0 when two coils are swapped sequentially (disjoint in time); high
# when both are tracked at the same instants. ta/tb are numeric epoch seconds.
coincidence_frac <- function(ta, tb, tol) {
  if (!length(ta) || !length(tb)) return(0)
  tb <- sort(tb)
  j  <- findInterval(ta, tb)
  lo <- ifelse(j >= 1L,        abs(ta - tb[pmax(j, 1L)]),               Inf)
  hi <- ifelse(j < length(tb), abs(ta - tb[pmin(j + 1L, length(tb))]), Inf)
  mean(pmin(lo, hi) <= tol)
}

# ---- 1. parse the streamed file -------------------------------------
tables <- parse_brainsight(NEURONAV_PATH, parse_datetime = TRUE,
                           drop_null_rows = TRUE)

coil_raw <- tables[[COIL_ROW_TYPE]]
if (nrow(coil_raw) == 0L)
  stop("No '", COIL_ROW_TYPE, "' rows found in: ", NEURONAV_PATH)

# Normalise the name column (driver vs tracker) and position columns
# (loc_x/y/z vs x/y/z) across the possible coil row types.
name_col <- if (COIL_ROW_TYPE == "Polaris Tool") "tracker_name" else "crosshairs_driver"
pos_cols <- if (COIL_ROW_TYPE == "Polaris Tool") c("x", "y", "z") else c("loc_x", "loc_y", "loc_z")
rot_cols <- c("m0n0", "m0n1", "m0n2", "m1n0", "m1n1", "m1n2", "m2n0", "m2n1", "m2n2")

# Resolve which coil(s) to use. With COIL_NAME = "auto", detect whichever
# candidate(s) carry valid (non-null) frames. One coil -> use it. Several:
#   * swapped sequentially (disjoint in time) -> keep them all, tagged per
#     frame; the per-trigger time-match downstream picks the active one.
#   * tracked at the same times (ambiguous)   -> stop and ask for a COIL_NAME.
candidates <- COIL_CANDIDATES[[COIL_ROW_TYPE]]
valid_all  <- coil_raw %>%
  filter(.data[[name_col]] %in% candidates,
         coord_system == COORD_SYSTEM,
         if_all(all_of(pos_cols), ~ !is.na(.)))
present <- intersect(candidates, unique(valid_all[[name_col]]))

if (!identical(COIL_NAME, "auto")) {
  coil_names <- COIL_NAME
} else if (length(present) == 0L) {
  stop("Auto-detect found no tracked coil among {",
       paste(candidates, collapse = ", "), "} with valid ",
       COORD_SYSTEM, " frames in: ", NEURONAV_PATH)
} else if (length(present) == 1L) {
  coil_names <- present
  message(sprintf("Auto-detected coil: '%s' (%d valid %s frames)",
                  present, sum(valid_all[[name_col]] == present), COORD_SYSTEM))
} else {
  # More than one coil present: sequential swap (keep all) or simultaneous?
  worst <- 0
  for (i in seq_along(present)) for (k in seq_len(i - 1L)) {
    ti <- as.numeric(valid_all$datetime[valid_all[[name_col]] == present[i]])
    tk <- as.numeric(valid_all$datetime[valid_all[[name_col]] == present[k]])
    worst <- max(worst, coincidence_frac(ti, tk, COIL_OVERLAP_TOL_S),
                        coincidence_frac(tk, ti, COIL_OVERLAP_TOL_S))
  }
  if (worst > COIL_OVERLAP_MAX_FRAC)
    stop(sprintf(paste0("Multiple coils tracked at overlapping times (%.1f%% ",
                        "coincident frames). Cannot pick automatically; set ",
                        "COIL_NAME to one of: %s"),
                 100 * worst, paste(present, collapse = ", ")))
  coil_names <- present
  counts     <- table(valid_all[[name_col]])[present]
  message(sprintf("Auto-detected sequential coil swap; keeping both: %s",
                  paste(sprintf("'%s'=%d", present, counts), collapse = ", ")))
}

# ---- 2. coil 6-DoF pose over time (MNI) -----------------------------
# (named coil_f to avoid colliding with the "coil" column built below)
coil_f <- coil_raw %>%
  filter(.data[[name_col]] %in% coil_names, coord_system == COORD_SYSTEM) %>%
  filter(if_all(all_of(pos_cols), ~ !is.na(.))) %>%
  arrange(datetime)

if (nrow(coil_f) == 0L)
  stop("No frames for {", paste(coil_names, collapse = ", "), "} in ",
       COORD_SYSTEM, " space.")

ypr <- t(apply(as.matrix(coil_f[, rot_cols]), 1, rot_to_ypr))   # n x 3 (deg)

coil6 <- tibble(
  time  = coil_f$datetime,
  coil  = coil_f[[name_col]],     # which coil this frame came from
  x     = coil_f[[pos_cols[1]]],
  y     = coil_f[[pos_cols[2]]],
  z     = coil_f[[pos_cols[3]]],
  yaw   = ypr[, "yaw"],
  pitch = ypr[, "pitch"],
  roll  = ypr[, "roll"]
)

# ---- 3. reference target 6-DoF (Target Selection lookup) ------------
# Look up SAMPLE_NAME in the file's Target Selection rows and take its pose
# (position + 3x3 rotation) in COORD_SYSTEM as the reference target.
tgt_tbl <- tables[["Target Selection"]] %>%
  filter(target_name == SAMPLE_NAME, coord_system == COORD_SYSTEM,
         if_all(all_of(c("loc_x", "loc_y", "loc_z")), ~ !is.na(.)))
if (nrow(tgt_tbl) == 0L)
  stop("Target '", SAMPLE_NAME, "' not found among ", COORD_SYSTEM,
       " Target Selection rows in: ", NEURONAV_PATH)
if (n_distinct(round(tgt_tbl$loc_x, 6), tgt_tbl$loc_y, tgt_tbl$loc_z) > 1L)
  warning("Target '", SAMPLE_NAME, "' is logged with differing poses (",
          nrow(tgt_tbl), " rows); using the first.")

SAMPLE_POS <- c(x = tgt_tbl$loc_x[1L], y = tgt_tbl$loc_y[1L], z = tgt_tbl$loc_z[1L])
SAMPLE_ROT <- as.numeric(tgt_tbl[1L, rot_cols])
sample_ypr <- rot_to_ypr(SAMPLE_ROT)

# ---- 4. per-DoF delta: coil - sample --------------------------------
coil_delta <- coil6 %>%
  mutate(
    dx     = x     - SAMPLE_POS["x"],
    dy     = y     - SAMPLE_POS["y"],
    dz     = z     - SAMPLE_POS["z"],
    dyaw   = wrap_deg(yaw   - sample_ypr["yaw"]),
    dpitch = wrap_deg(pitch - sample_ypr["pitch"]),
    droll  = wrap_deg(roll  - sample_ypr["roll"])
  )

# ---- 5. collapse the 6 DoF into two intuitive distances -------------
# Translational distance = Euclidean norm of the position delta (mm).
# Angular distance       = the single rotation angle between the coil and
#                          sample orientations (deg), from the raw rotation
#                          matrices (not the Euler columns).
ang_dist <- apply(as.matrix(coil_f[, rot_cols]), 1,
                  function(r) rot_angle_deg(r, SAMPLE_ROT))

coil_dist <- tibble(
  time          = coil6$time,
  coil          = coil6$coil,
  trans_dist_mm = sqrt(coil_delta$dx^2 + coil_delta$dy^2 + coil_delta$dz^2),
  ang_dist_deg  = ang_dist
)

# ---- report ---------------------------------------------------------
message(sprintf("Coil source  : %s / {%s}  (%s)",
                COIL_ROW_TYPE, paste(coil_names, collapse = ", "), COORD_SYSTEM))
if (length(coil_names) > 1L) {
  cc <- table(coil6$coil)
  message(sprintf("Coil frames  : %d  [%s]", nrow(coil_delta),
                  paste(sprintf("%s:%d", names(cc), cc), collapse = ", ")))
} else {
  message(sprintf("Coil frames  : %d", nrow(coil_delta)))
}
message(sprintf("Target '%s' pos : x=%.3f  y=%.3f  z=%.3f  (mm)",
                SAMPLE_NAME, SAMPLE_POS["x"], SAMPLE_POS["y"], SAMPLE_POS["z"]))
message(sprintf("Target '%s' ypr : yaw=%.2f  pitch=%.2f  roll=%.2f  (deg)",
                SAMPLE_NAME, sample_ypr["yaw"], sample_ypr["pitch"], sample_ypr["roll"]))
message(sprintf("Collapsed distances (coil_dist): trans %.1f-%.1f mm | ang %.1f-%.1f deg",
                min(coil_dist$trans_dist_mm), max(coil_dist$trans_dist_mm),
                min(coil_dist$ang_dist_deg),  max(coil_dist$ang_dist_deg)))
if (!exists("ORCHESTRATED")) {
  print(head(coil_delta, 10L))
  print(head(coil_dist, 10L))
}

# `coil_delta` (per-DoF) and `coil_dist` (collapsed translational + angular
# distance) are left in the R session for the next stage (no data export).
