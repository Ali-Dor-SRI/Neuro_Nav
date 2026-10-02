# =====================================================================
# polaris_targets.R  --  the coil's 6-DoF offset stream in Polaris /
#                        head-relative space (alternative to os_offset_stream
#                        in brainsight_targets.R, which is MNI)
#
# The coil is its raw optical tracker (LCT650 or CT4661) expressed relative
# to the head tracker (ST893), cancelling head motion like MNI but without
# the anatomical (nonlinear) warp:
#     p_rel = R_head^T (p_coil - p_head)      R_rel = R_head^T R_coil
# ("coil position" here is the tracker's marker array on the coil body
# relative to the head -- a placement-repeatability measure, not the
# crosshairs aim-point on the cortex, which is MNI-only.)
#
# Brainsight never logs a Target Selection POSE in Polaris space (Target
# Selection rows are MNI-only -- see os_selection_events()), so there is no
# direct Polaris equivalent of "the target's pose". Instead, a coil's target
# here is the AVERAGE of that SAME coil's own head-relative frames over
# N_SAMPLES_AVG samples, starting at the moment its assigned target was
# FIRST selected (os_target_first_selected(), the same anchor
# os_label_phases() uses for nav_phase) -- i.e. "where the coil physically
# was when the operator confirmed it was on target".
#
# Because LCT650 and CT4661 are different marker arrays on different coils,
# their head-relative poses are NOT comparable to each other or to a target
# built from the other coil's frames. So Polaris mode only makes sense when
# EVERY coil present has its OWN target (os_targets_per_coil(), in
# brainsight_targets.R): as many distinct target names as coils, none
# shared. When two coils share one target, use MNI instead -- the anatomical
# frame makes a shared target directly comparable across coils.
# =====================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
})

OS_COIL_TRACKER <- c("Coil B LCT" = "LCT650", "Coil A CT" = "CT4661")   # crosshairs driver -> Polaris tracker

#' Raw Polaris Tool frames for one tracker, expressed relative to
#' `head_tracker` (position + 9 row-major cosines, one row per shared frame).
os_polaris_head_relative <- function(tables, tracker_name, head_tracker = "ST893") {
  pol <- tables[["Polaris Tool"]]
  valid <- function(name) pol %>%
    filter(tracker_name == !!name, coord_system == "Polaris", !is.na(t),
           if_all(all_of(c("x", "y", "z")), ~ !is.na(.))) %>%
    distinct(frame_number, .keep_all = TRUE)
  coil_pol <- valid(tracker_name)
  if (nrow(coil_pol) == 0L) return(coil_pol[0, ])
  head_pol <- valid(head_tracker)
  if (nrow(head_pol) == 0L)
    stop("Head tracker '", head_tracker, "' has no valid Polaris frames.")
  j <- inner_join(coil_pol, head_pol, by = "frame_number", suffix = c("_c", "_h")) %>%
    arrange(t_c)
  if (nrow(j) == 0L)
    stop("Tracker '", tracker_name, "' shares no Polaris frames with head '", head_tracker, "'.")

  n <- nrow(j)
  Rc_all <- as.matrix(j[, paste0(OS_ROT_COLS, "_c")]); Rh_all <- as.matrix(j[, paste0(OS_ROT_COLS, "_h")])
  Pc_all <- as.matrix(j[, c("x_c", "y_c", "z_c")]);      Ph_all <- as.matrix(j[, c("x_h", "y_h", "z_h")])
  out <- matrix(NA_real_, n, 12L)
  for (i in seq_len(n)) {
    Rc  <- matrix(Rc_all[i, ], 3L, 3L, byrow = TRUE)
    Rht <- t(matrix(Rh_all[i, ], 3L, 3L, byrow = TRUE))
    out[i, ] <- c(Rht %*% (Pc_all[i, ] - Ph_all[i, ]),   # p_rel  (x, y, z)
                  as.numeric(t(Rht %*% Rc)))             # R_rel  row-major
  }
  rot_df <- as.data.frame(out[, 4:12, drop = FALSE]); names(rot_df) <- OS_ROT_COLS
  bind_cols(tibble(t = j$t_c, frame_number = j$frame_number,
                   loc_x = out[, 1], loc_y = out[, 2], loc_z = out[, 3]), rot_df)
}

#' The coil's 6-DoF offset stream in Polaris/head-relative space: each coil
#' vs the average of its own first `n_samples_avg` frames at/after its
#' target's first selection (see header). Requires
#' os_targets_per_coil(assignment); stops with a clear message otherwise.
#' @param tables     os_load_brainsight() output
#' @param assignment os_assign_targets()$assignment
#' @param events     os_selection_events() output
os_offset_stream_polaris <- function(tables, assignment, events, head_tracker = "ST893",
                                     n_samples_avg = 5L) {
  if (!os_targets_per_coil(assignment))
    stop("Polaris coordinates need every coil to have its OWN target (got: ",
         paste(sprintf("%s -> %s", assignment$coil, ifelse(is.na(assignment$target), "(none)", assignment$target)),
               collapse = ", "),
         "). Use MNI, or register a separate target per coil.")
  anchors <- os_target_first_selected(events, assignment)

  parts <- lapply(seq_len(nrow(assignment)), function(k) {
    cn <- assignment$coil[k]; tn <- assignment$target[k]
    tracker <- OS_COIL_TRACKER[[cn]]
    if (is.null(tracker)) stop("No Polaris tracker known for coil driver '", cn, "'.")
    sub <- os_polaris_head_relative(tables, tracker, head_tracker) %>% arrange(t)
    if (nrow(sub) == 0L) stop("Coil '", cn, "' (tracker '", tracker, "') has no valid Polaris frames.")

    t0 <- anchors$t_first[anchors$coil == cn]
    si <- if (length(t0) && !is.na(t0[1L])) {
      i <- which(sub$t >= t0[1L]); if (length(i)) i[1L] else 1L
    } else 1L
    ei  <- min(si + n_samples_avg - 1L, nrow(sub))
    sel <- sub[si:ei, ]
    if (nrow(sel) < n_samples_avg)
      warning(sprintf("Coil '%s': only %d Polaris frame(s) to average for its target (asked for %d).",
                      cn, nrow(sel), n_samples_avg), call. = FALSE)

    tgt <- os_avg_pose(sel)
    off <- os_offsets_table(sub, tgt)
    bind_cols(
      tibble(t = sub$t, coil = cn, target = tn, target_at_frame = tn,
             x = sub$loc_x, y = sub$loc_y, z = sub$loc_z),
      off
    )
  })
  bind_rows(parts) %>% arrange(t)
}
