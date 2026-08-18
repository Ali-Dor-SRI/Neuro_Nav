# =====================================================================
# coil_to_sample_delta.R   (neuronav side of the MEP analysis)
#
# Goal: load a Brainsight streamed-info .txt, pull the coil's 6-DoF pose over
# time, and express every frame as a delta from a reference target. The result
# feeds the per-MEP analysis in mep_vs_coil_distance.R. No export here -- the
# data frames are left in the R session for the next stage.
#
# TWO COORDINATE FRAMES (COORD_SYSTEM) -------------------------------------
#   "Polaris" (default, current workflow):
#       The coil = a raw optical tracker (LCT650 or CT4661), expressed RELATIVE
#       TO the head tracker (ST893). Only raw `Polaris Tool` rows carry Polaris
#       data (samples / targets / crosshairs are MNI-only), so the coil must
#       come from a tracker. Expressing it in the head frame cancels subject
#       head motion -- like MNI, but without the anatomical (nonlinear) warp:
#           p_rel = R_head^T (p_coil - p_head)      R_rel = R_head^T R_coil
#       The coil tracker is AUTO-DETECTED among {LCT650, CT4661}; if the session
#       swaps coils (each tracked in a disjoint time block, e.g. CT4661 then
#       LCT650), BOTH are kept, each frame tagged with its coil.
#       NOTE: "coil position" here is the tracker marker array on the coil body
#       relative to the head, NOT the crosshairs aim-point on the cortex (that
#       point is MNI-only). It measures coil-body drift relative to the head.
#       Because LCT650 and CT4661 are DIFFERENT marker arrays on different
#       coils, their head-relative poses are NOT directly comparable -- so in a
#       swap each coil is measured against its OWN target (see below).
#
#   "MNI" (legacy): the navigated coil pose (`Crosshairs Position`, driver
#       "Coil B LCT" / "Coil A CT") in MNI space, as the earlier pipeline did.
#       Crosshairs ARE comparable across coils, so a single target is used.
#
# TWO TARGET DEFINITIONS (TARGET_MODE) -------------------------------------
#   "sample_average" (default, current workflow):
#       The target is the AVERAGE coil pose over N_SAMPLES_AVG consecutive
#       `Polaris Tool` tracker frames (raw 20 Hz coil samples). Position =
#       arithmetic mean; orientation = chordal (SVD) mean on SO(3).
#         * In Polaris with a coil swap, each coil block gets its OWN target.
#           The block that CONTAINS SAMPLE_START is averaged from SAMPLE_START
#           (a New Sample / Target Selection name -> that event's time, or a
#           timestamp, or a frame_number) + next N-1. Every OTHER coil block
#           auto-uses the first N frames of its own tracked segment.
#         * With a single coil (or MNI), the one target is built from
#           SAMPLE_START + next N-1.
#
#   "target_selection" (legacy): the target is looked up directly from the
#       `Target Selection` row named SAMPLE_NAME (MNI only; one target, all coils).
#
# Output data frame `coil_delta` columns:
#   time                                  POSIXct (ms precision)
#   coil                                  source coil for the frame
#   x, y, z                               coil position (mm, chosen frame)
#   yaw, pitch, roll                      coil orientation (deg, ZYX)
#   dx, dy, dz                            coil - target position    (mm)
#   dyaw, dpitch, droll                   coil - target orientation (deg, wrapped)
# Output data frame `coil_dist` columns:
#   time, coil, trans_dist_mm, ang_dist_deg  (each vs the frame's coil's target)
#
# All CONFIG below is injectable via `if (!exists())` so the orchestrator
# (run_analysis.R) can set it first.
# =====================================================================

# ---- CONFIG (edit per session) --------------------------------------
if (!exists("NEURONAV_PATH")) NEURONAV_PATH <- "Y:/Neuro_Nav_App/data/SNBR-169.txt"
if (!exists("PARSER_PATH"))   PARSER_PATH   <- "Y:/Neuro_Nav_App/data_analysis/R/parse_brainsight.R"

# Coordinate frame for every pose.  "Polaris" (new) | "MNI" (legacy).
if (!exists("COORD_SYSTEM"))  COORD_SYSTEM  <- "Polaris"

# How the reference target is built.  "sample_average" (new) | "target_selection" (legacy).
if (!exists("TARGET_MODE"))   TARGET_MODE   <- "sample_average"

# -- Polaris trackers -----------------------------------------------
# The head tracker (common to both coils) and whether to express the coil in
# the head frame. HEAD_RELATIVE = TRUE (recommended) cancels head motion;
# FALSE keeps the raw camera-frame coil. The COIL tracker(s) are auto-detected
# among the Polaris candidates below (COIL_NAME = "auto"), or pinned to one.
if (!exists("HEAD_TRACKER"))  HEAD_TRACKER  <- "ST893"
if (!exists("HEAD_RELATIVE")) HEAD_RELATIVE <- TRUE

# -- sample-average target ------------------------------------------
# SAMPLE_START anchors the target on the moment the coil was on target; the
# coil block it falls in is averaged from there (start + next N-1 Polaris Tool
# frames). Accepted forms, in priority order:
#   * a New Sample / Target Selection NAME (e.g. "Sample 1") -> that event's time
#   * a timestamp ("12:21:13.545" or "2026-06-25 12:21:13.545")
#   * a Polaris Tool frame_number ("145929606")
# Any OTHER coil block auto-uses the first N frames of its own segment. Fewer
# frames than N_SAMPLES_AVG -> use them all and warn.
if (!exists("SAMPLE_START"))  SAMPLE_START  <- "Sample 1"
if (!exists("N_SAMPLES_AVG")) N_SAMPLES_AVG <- 5L

# Legacy target_selection only: the Target Selection name to look up (MNI).
if (!exists("SAMPLE_NAME"))   SAMPLE_NAME   <- "Sample 5"

# -- coil selection --------------------------------------------------
# COIL_NAME "auto" auto-detects the coil(s); or pin one name to force it.
#   Polaris candidates (raw trackers): "LCT650" (Coil B), "CT4661" (Coil A).
#   MNI/legacy row type + candidates (navigated crosshairs / raw tracker):
if (!exists("COIL_ROW_TYPE")) COIL_ROW_TYPE <- "Crosshairs Position"   # MNI mode only
if (!exists("COIL_NAME"))     COIL_NAME     <- "auto"

COIL_CANDIDATES <- list(
  "Polaris Tool"        = c("LCT650", "CT4661"),
  "Crosshairs Position" = c("Coil B LCT", "Coil A CT")
)

# If >1 coil is present, decide sequential swap vs simultaneous tracking: a
# frame is "coincident" with the other coil if it falls within COIL_OVERLAP_TOL_S
# of one of its frames. If more than COIL_OVERLAP_MAX_FRAC of frames are
# coincident, the coils were tracked at the same time (ambiguous) -> stop and
# ask for an explicit COIL_NAME. Otherwise they were swapped sequentially and
# both are kept (each frame tagged with its coil).
COIL_OVERLAP_TOL_S    <- 0.10
COIL_OVERLAP_MAX_FRAC <- 0.02
# ---------------------------------------------------------------------

suppressPackageStartupMessages({
  library(dplyr)
})
options(digits.secs = 3)   # show milliseconds on POSIXct

source(PARSER_PATH)

# Nine direction-cosine columns, row-major: m{i}n{j} = R[i+1, j+1].
rot_cols <- c("m0n0", "m0n1", "m0n2", "m1n0", "m1n1", "m1n2", "m2n0", "m2n1", "m2n2")

# ---- guard invalid combinations -------------------------------------
if (!COORD_SYSTEM %in% c("Polaris", "MNI"))
  stop("COORD_SYSTEM must be 'Polaris' or 'MNI' (got '", COORD_SYSTEM, "').")
if (!TARGET_MODE %in% c("sample_average", "target_selection"))
  stop("TARGET_MODE must be 'sample_average' or 'target_selection' (got '", TARGET_MODE, "').")
if (TARGET_MODE == "target_selection" && COORD_SYSTEM != "MNI")
  stop("TARGET_MODE='target_selection' requires COORD_SYSTEM='MNI' (Target Selection ",
       "rows are MNI-only). Use TARGET_MODE='sample_average' for Polaris.")

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

# Chordal (L2) mean of rotation matrices on SO(3), via orthogonal Procrustes:
# average the matrices element-wise, then project back to the nearest proper
# rotation with an SVD. This is the correct small-spread average -- the raw
# element-wise mean is not itself a rotation. `mats` is a list of 3x3 matrices;
# returns a single 3x3 rotation matrix.
rot_average <- function(mats) {
  M <- Reduce(`+`, mats) / length(mats)
  s <- svd(M)
  R <- s$u %*% t(s$v)
  if (det(R) < 0) {                 # reflection -> flip least-significant axis
    s$u[, 3] <- -s$u[, 3]
    R <- s$u %*% t(s$v)
  }
  R
}

# Average a set of pose rows -> list(pos = c(x,y,z), rot = 9 row-major cosines).
avg_pose <- function(rows) {
  mats <- lapply(seq_len(nrow(rows)),
                 function(k) matrix(as.numeric(rows[k, rot_cols]), 3, 3, byrow = TRUE))
  list(pos = c(x = mean(rows$x), y = mean(rows$y), z = mean(rows$z)),
       rot = as.numeric(t(rot_average(mats))))
}

# Resolve SAMPLE_START to a row index into a time-ordered pose table (columns
# $time, $frame). Timestamp (has ":") -> first frame at/after it (nearest if
# none after). All-digit -> exact frame_number match.
resolve_start_idx <- function(tbl, key) {
  key <- trimws(as.character(key))
  if (grepl(":", key)) {
    tt <- if (grepl("-", key))
            as.POSIXct(key, format = "%Y-%m-%d %H:%M:%OS", tz = "")
          else
            as.POSIXct(paste(format(as.Date(tbl$time[1L]), "%Y-%m-%d"), key),
                       format = "%Y-%m-%d %H:%M:%OS", tz = "")
    if (is.na(tt)) stop("Could not parse SAMPLE_START as a timestamp: '", key, "'")
    aa <- which(tbl$time >= tt)
    if (length(aa)) aa[1L]
    else which.min(abs(as.numeric(difftime(tbl$time, tt, units = "secs"))))
  } else if (grepl("^[0-9]+$", key)) {
    i <- which(tbl$frame == key)
    if (length(i) == 0L)
      stop("SAMPLE_START frame_number '", key, "' not found among usable coil frames.")
    i[1L]
  } else {
    stop("SAMPLE_START must be a Polaris Tool frame_number or a timestamp (got '", key, "').")
  }
}
start_label <- function(key) {
  key <- trimws(as.character(key))
  if (grepl("^[0-9]+$", key)) paste0("frame ", key) else key
}

# Resolve SAMPLE_START to a value the frame lookup understands + a label.
# Priority: a `New Sample` / `Target Selection` event NAME (e.g. "Sample 1") is
# looked up and converted to that event's timestamp (so the target anchors on
# the moment that sample/target was taken); otherwise a timestamp or a
# frame_number passes through unchanged.
resolve_anchor <- function(key, tables) {
  key <- trimws(as.character(key))
  ns  <- tables[["New Sample"]]
  ts  <- tables[["Target Selection"]]
  hit <- NULL; kind <- NULL
  if (nrow(ns) > 0L && "sample_name" %in% names(ns)) {
    r <- ns[!is.na(ns$datetime) & ns$sample_name %in% key, , drop = FALSE]
    if (nrow(r) > 0L) { hit <- r$datetime[1L]; kind <- "New Sample" }
  }
  if (is.null(hit) && nrow(ts) > 0L && "target_name" %in% names(ts)) {
    r <- ts[!is.na(ts$datetime) & ts$target_name %in% key, , drop = FALSE]
    if (nrow(r) > 0L) { hit <- r$datetime[1L]; kind <- "Target Selection" }
  }
  if (!is.null(hit))
    return(list(val = format(hit, "%Y-%m-%d %H:%M:%OS3"),
                lbl = sprintf("%s '%s' @ %s", kind, key, format(hit, "%H:%M:%OS3"))))
  if (grepl(":", key) || grepl("^[0-9]+$", key))
    return(list(val = key, lbl = start_label(key)))
  nm <- unique(c(ns$sample_name, ts$target_name)); nm <- nm[!is.na(nm)]
  stop("SAMPLE_START '", key, "' is not a known event name, a timestamp, or a ",
       "frame number. Known New Sample / Target Selection names: {",
       paste(nm, collapse = ", "), "}")
}

# Express the coil pose in the head-tracker frame, frame by frame.
#   R_rel = R_head^T %*% R_coil        p_rel = R_head^T %*% (p_coil - p_head)
# `j` is coil|head joined on frame_number with suffixes _c (coil) and _h (head).
# Returns an n x 12 matrix: cols 1:3 = x,y,z (mm); cols 4:12 = rotation row-major.
head_relative_pose <- function(j, rot_cols) {
  Rc_all <- as.matrix(j[, paste0(rot_cols, "_c")])
  Rh_all <- as.matrix(j[, paste0(rot_cols, "_h")])
  Pc_all <- as.matrix(j[, c("x_c", "y_c", "z_c")])
  Ph_all <- as.matrix(j[, c("x_h", "y_h", "z_h")])
  n <- nrow(j)
  out <- matrix(NA_real_, n, 12L)
  for (i in seq_len(n)) {
    Rc  <- matrix(Rc_all[i, ], 3, 3, byrow = TRUE)
    Rht <- t(matrix(Rh_all[i, ], 3, 3, byrow = TRUE))
    out[i, ] <- c(Rht %*% (Pc_all[i, ] - Ph_all[i, ]),   # p_rel  (x,y,z)
                  as.numeric(t(Rht %*% Rc)))             # R_rel  row-major
  }
  out
}

# ---- 1. parse the streamed file -------------------------------------
tables <- parse_brainsight(NEURONAV_PATH, parse_datetime = TRUE,
                           drop_null_rows = TRUE)

# =====================================================================
# 2. COIL POSE OVER TIME  ->  pose_tbl (time, frame, coil, x, y, z, m0n0..m2n2)
#    Auto-detects the coil(s); keeps both across a sequential swap, each frame
#    tagged with its coil.
# =====================================================================
if (COORD_SYSTEM == "Polaris") {
  pol <- tables[["Polaris Tool"]]
  if (nrow(pol) == 0L) stop("No 'Polaris Tool' rows in: ", NEURONAV_PATH)

  valid_polaris <- function(name) {
    pol %>%
      filter(tracker_name == name, coord_system == "Polaris",
             if_all(all_of(c("x", "y", "z")), ~ !is.na(.))) %>%
      distinct(frame_number, .keep_all = TRUE)   # 1 pose per frame
  }

  # Auto-detect the coil tracker(s) with valid Polaris frames (or pin COIL_NAME).
  candidates <- COIL_CANDIDATES[["Polaris Tool"]]
  if (!identical(COIL_NAME, "auto")) candidates <- COIL_NAME
  vlist   <- setNames(lapply(candidates, valid_polaris), candidates)
  present <- candidates[vapply(vlist, nrow, integer(1)) > 0L]
  if (length(present) == 0L)
    stop("No coil among {", paste(candidates, collapse = ", "),
         "} has valid Polaris frames in: ", NEURONAV_PATH)

  # Sequential swap vs simultaneous tracking?
  if (length(present) > 1L) {
    worst <- 0
    for (i in seq_along(present)) for (k in seq_len(i - 1L)) {
      ti <- as.numeric(vlist[[present[i]]]$datetime)
      tk <- as.numeric(vlist[[present[k]]]$datetime)
      worst <- max(worst, coincidence_frac(ti, tk, COIL_OVERLAP_TOL_S),
                          coincidence_frac(tk, ti, COIL_OVERLAP_TOL_S))
    }
    if (worst > COIL_OVERLAP_MAX_FRAC)
      stop(sprintf(paste0("Coils tracked at overlapping times (%.1f%% coincident ",
                          "frames). Cannot separate automatically; set COIL_NAME ",
                          "to one of: %s"), 100 * worst, paste(present, collapse = ", ")))
    message(sprintf("Auto-detected coil swap; keeping both: %s",
                    paste(sprintf("'%s'=%d", present, vapply(vlist[present], nrow, integer(1))),
                          collapse = ", ")))
  } else {
    message(sprintf("Auto-detected coil: '%s' (%d valid Polaris frames)",
                    present, nrow(vlist[[present]])))
  }

  # Build each coil's pose stream (head-relative to HEAD_TRACKER, or raw).
  head_pol <- if (isTRUE(HEAD_RELATIVE)) valid_polaris(HEAD_TRACKER) else NULL
  if (isTRUE(HEAD_RELATIVE) && nrow(head_pol) == 0L)
    stop("Head tracker '", HEAD_TRACKER, "' has no valid Polaris frames in: ", NEURONAV_PATH)

  build_coil_pose <- function(cn) {
    coil_pol <- vlist[[cn]]
    if (isTRUE(HEAD_RELATIVE)) {
      j <- inner_join(coil_pol, head_pol, by = "frame_number",
                      suffix = c("_c", "_h")) %>% arrange(datetime_c)
      if (nrow(j) == 0L)
        stop("Coil '", cn, "' shares no Polaris frames with head '", HEAD_TRACKER, "'.")
      hr <- head_relative_pose(j, rot_cols)
      rot_df <- as.data.frame(hr[, 4:12, drop = FALSE]); names(rot_df) <- rot_cols
      bind_cols(tibble(time = j$datetime_c, frame = j$frame_number, coil = cn,
                       x = hr[, 1], y = hr[, 2], z = hr[, 3]), rot_df)
    } else {
      coil_pol <- arrange(coil_pol, datetime)
      bind_cols(tibble(time = coil_pol$datetime, frame = coil_pol$frame_number, coil = cn,
                       x = coil_pol$x, y = coil_pol$y, z = coil_pol$z),
                coil_pol[, rot_cols])
    }
  }
  pose_tbl <- bind_rows(lapply(present, build_coil_pose)) %>% arrange(time)
  coil_label <- sprintf("{%s} rel. %s (Polaris%s)", paste(present, collapse = ", "),
                        HEAD_TRACKER, if (isTRUE(HEAD_RELATIVE)) ", head-relative" else " NONE, raw")

} else {
  # ---- MNI (legacy): navigated coil from Crosshairs / Polaris Tool ----
  coil_raw <- tables[[COIL_ROW_TYPE]]
  if (nrow(coil_raw) == 0L)
    stop("No '", COIL_ROW_TYPE, "' rows found in: ", NEURONAV_PATH)

  # Normalise the name column (driver vs tracker) and position columns.
  name_col <- if (COIL_ROW_TYPE == "Polaris Tool") "tracker_name" else "crosshairs_driver"
  pos_cols <- if (COIL_ROW_TYPE == "Polaris Tool") c("x", "y", "z") else c("loc_x", "loc_y", "loc_z")

  candidates <- COIL_CANDIDATES[[COIL_ROW_TYPE]]
  valid_all  <- coil_raw %>%
    filter(.data[[name_col]] %in% candidates, coord_system == "MNI",
           if_all(all_of(pos_cols), ~ !is.na(.)))
  present <- intersect(candidates, unique(valid_all[[name_col]]))

  if (!identical(COIL_NAME, "auto")) {
    coil_names <- COIL_NAME
  } else if (length(present) == 0L) {
    stop("Auto-detect found no tracked coil among {",
         paste(candidates, collapse = ", "), "} with valid MNI frames in: ", NEURONAV_PATH)
  } else if (length(present) == 1L) {
    coil_names <- present
    message(sprintf("Auto-detected coil: '%s' (%d valid MNI frames)",
                    present, sum(valid_all[[name_col]] == present)))
  } else {
    worst <- 0
    for (i in seq_along(present)) for (k in seq_len(i - 1L)) {
      ti <- as.numeric(valid_all$datetime[valid_all[[name_col]] == present[i]])
      tk <- as.numeric(valid_all$datetime[valid_all[[name_col]] == present[k]])
      worst <- max(worst, coincidence_frac(ti, tk, COIL_OVERLAP_TOL_S),
                          coincidence_frac(tk, ti, COIL_OVERLAP_TOL_S))
    }
    if (worst > COIL_OVERLAP_MAX_FRAC)
      stop(sprintf(paste0("Multiple coils tracked at overlapping times (%.1f%% ",
                          "coincident frames). Set COIL_NAME to one of: %s"),
                   100 * worst, paste(present, collapse = ", ")))
    coil_names <- present
    counts     <- table(valid_all[[name_col]])[present]
    message(sprintf("Auto-detected sequential coil swap; keeping both: %s",
                    paste(sprintf("'%s'=%d", present, counts), collapse = ", ")))
  }

  coil_f <- coil_raw %>%
    filter(.data[[name_col]] %in% coil_names, coord_system == "MNI") %>%
    filter(if_all(all_of(pos_cols), ~ !is.na(.))) %>%
    arrange(datetime)
  if (nrow(coil_f) == 0L)
    stop("No frames for {", paste(coil_names, collapse = ", "), "} in MNI space.")

  frame_vec <- if ("frame_number" %in% names(coil_f)) coil_f$frame_number else NA_character_
  pose_tbl <- bind_cols(
    tibble(time = coil_f$datetime, frame = frame_vec, coil = coil_f[[name_col]],
           x = coil_f[[pos_cols[1]]], y = coil_f[[pos_cols[2]]], z = coil_f[[pos_cols[3]]]),
    coil_f[, rot_cols]
  )
  coil_label <- sprintf("%s / {%s} (MNI)", COIL_ROW_TYPE, paste(coil_names, collapse = ", "))
}

coils_present <- unique(pose_tbl$coil)

# =====================================================================
# 3. REFERENCE TARGET  ->  tgt_map: coil name -> list(pos = c(x,y,z), rot = 9)
#    Polaris + sample_average: one target PER coil (trackers not comparable).
#    MNI (either target mode): a single target shared by all coils.
# =====================================================================
tgt_desc_map <- list()

if (TARGET_MODE == "target_selection") {
  # ---- legacy: one MNI Target Selection, shared by all coils --------
  tgt_tbl <- tables[["Target Selection"]] %>%
    filter(target_name == SAMPLE_NAME, coord_system == "MNI",
           if_all(all_of(c("loc_x", "loc_y", "loc_z")), ~ !is.na(.)))
  if (nrow(tgt_tbl) == 0L)
    stop("Target '", SAMPLE_NAME, "' not found among MNI Target Selection rows in: ",
         NEURONAV_PATH)
  if (n_distinct(round(tgt_tbl$loc_x, 6), tgt_tbl$loc_y, tgt_tbl$loc_z) > 1L)
    warning("Target '", SAMPLE_NAME, "' is logged with differing poses (",
            nrow(tgt_tbl), " rows); using the first.")
  T0 <- list(pos = c(x = tgt_tbl$loc_x[1L], y = tgt_tbl$loc_y[1L], z = tgt_tbl$loc_z[1L]),
             rot = as.numeric(tgt_tbl[1L, rot_cols]))
  tgt_map <- setNames(rep(list(T0), length(coils_present)), coils_present)
  for (cn in coils_present) tgt_desc_map[[cn]] <- sprintf("Target Selection '%s' (MNI)", SAMPLE_NAME)

} else if (COORD_SYSTEM == "Polaris") {
  # ---- sample_average, per coil block -------------------------------
  anc          <- resolve_anchor(SAMPLE_START, tables)   # name -> event time, else pass-through
  start_row    <- resolve_start_idx(pose_tbl, anc$val)
  started_coil <- pose_tbl$coil[start_row]
  tgt_map <- list()
  for (cn in coils_present) {
    sub <- pose_tbl[pose_tbl$coil == cn, ]   # time-ordered (pose_tbl is sorted)
    if (identical(cn, started_coil)) {
      si  <- resolve_start_idx(sub, anc$val)
      src <- anc$lbl
    } else {
      si  <- 1L
      src <- "auto: first frames of block"
    }
    ei  <- min(si + N_SAMPLES_AVG - 1L, nrow(sub))
    sel <- sub[si:ei, ]
    if (nrow(sel) < N_SAMPLES_AVG)
      warning(sprintf("Coil '%s': only %d frame(s) from its start (asked for %d); averaging %d.",
                      cn, nrow(sel), N_SAMPLES_AVG, nrow(sel)))
    tgt_map[[cn]]      <- avg_pose(sel)
    tgt_desc_map[[cn]] <- sprintf("avg %d frames [%s] %s..%s", nrow(sel), src,
                                  format(sel$time[1L], "%H:%M:%OS3"),
                                  format(sel$time[nrow(sel)], "%H:%M:%OS3"))
  }

} else {
  # ---- sample_average in MNI: single pooled target, shared by all ---
  anc       <- resolve_anchor(SAMPLE_START, tables)   # name -> event time, else pass-through
  start_row <- resolve_start_idx(pose_tbl, anc$val)
  ei  <- min(start_row + N_SAMPLES_AVG - 1L, nrow(pose_tbl))
  sel <- pose_tbl[start_row:ei, ]
  if (nrow(sel) < N_SAMPLES_AVG)
    warning(sprintf("Only %d frame(s) from the start point (asked for %d); averaging %d.",
                    nrow(sel), N_SAMPLES_AVG, nrow(sel)))
  T0 <- avg_pose(sel)
  tgt_map <- setNames(rep(list(T0), length(coils_present)), coils_present)
  d0 <- sprintf("avg %d frames [%s] %s..%s", nrow(sel), anc$lbl,
                format(sel$time[1L], "%H:%M:%OS3"), format(sel$time[nrow(sel)], "%H:%M:%OS3"))
  for (cn in coils_present) tgt_desc_map[[cn]] <- d0
}

# =====================================================================
# 4/5. per-DoF delta + collapsed distances, EACH coil vs ITS OWN target
# =====================================================================
# Translational distance = Euclidean norm of the position delta (mm).
# Angular distance       = the geodesic rotation angle between the coil and
#                          target orientations (deg), from the raw matrices.
parts <- lapply(coils_present, function(cn) {
  sub    <- pose_tbl[pose_tbl$coil == cn, ]
  tp     <- tgt_map[[cn]]$pos
  tr     <- tgt_map[[cn]]$rot
  tr_ypr <- rot_to_ypr(tr)
  ypr    <- t(apply(as.matrix(sub[, rot_cols]), 1, rot_to_ypr))   # n x 3 (deg)
  ang    <- apply(as.matrix(sub[, rot_cols]), 1, function(r) rot_angle_deg(r, tr))
  dx <- sub$x - tp["x"]; dy <- sub$y - tp["y"]; dz <- sub$z - tp["z"]
  tibble(
    time = sub$time, coil = cn, x = sub$x, y = sub$y, z = sub$z,
    yaw = ypr[, "yaw"], pitch = ypr[, "pitch"], roll = ypr[, "roll"],
    dx = dx, dy = dy, dz = dz,
    dyaw   = wrap_deg(ypr[, "yaw"]   - tr_ypr["yaw"]),
    dpitch = wrap_deg(ypr[, "pitch"] - tr_ypr["pitch"]),
    droll  = wrap_deg(ypr[, "roll"]  - tr_ypr["roll"]),
    trans_dist_mm = sqrt(dx^2 + dy^2 + dz^2),
    ang_dist_deg  = ang
  )
})
combined <- bind_rows(parts) %>% arrange(time)

coil_delta <- combined %>%
  select(time, coil, x, y, z, yaw, pitch, roll, dx, dy, dz, dyaw, dpitch, droll)
coil_dist <- combined %>%
  select(time, coil, trans_dist_mm, ang_dist_deg)

# ---- report ---------------------------------------------------------
message(sprintf("Coil frame   : %s", coil_label))
cc <- table(combined$coil)
message(sprintf("Coil frames  : %d  [%s]", nrow(combined),
                paste(sprintf("%s:%d", names(cc), cc), collapse = ", ")))
for (cn in coils_present) {
  tp <- tgt_map[[cn]]$pos; ty <- rot_to_ypr(tgt_map[[cn]]$rot)
  message(sprintf("Target[%s] : %s", cn, tgt_desc_map[[cn]]))
  message(sprintf("   pos x=%.3f y=%.3f z=%.3f mm | ypr yaw=%.2f pitch=%.2f roll=%.2f deg",
                  tp["x"], tp["y"], tp["z"], ty["yaw"], ty["pitch"], ty["roll"]))
}
message(sprintf("Distances    : trans %.1f-%.1f mm | ang %.1f-%.1f deg",
                min(coil_dist$trans_dist_mm), max(coil_dist$trans_dist_mm),
                min(coil_dist$ang_dist_deg),  max(coil_dist$ang_dist_deg)))
if (!exists("ORCHESTRATED")) {
  print(head(coil_delta, 10L))
  print(head(coil_dist, 10L))
}

# `coil_delta` (per-DoF) and `coil_dist` (collapsed translational + angular
# distance, each frame vs its coil's target) are left in the R session for the
# next stage (no data export).
