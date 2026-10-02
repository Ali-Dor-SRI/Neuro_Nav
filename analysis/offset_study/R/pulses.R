# =====================================================================
# pulses.R  --  classify pulses, attach the coil offset at each pulse,
#               and label the phase of the session each pulse belongs to
#
# PULSE CLASSES (from the QtracP conditioning delay, sheet D)
#   isi_ms == 0            "single"   an unconditioned test pulse: hotspotting,
#                                     RMT tracking, the test-alone pulses of a
#                                     paired-pulse run, 1 mV tracking
#   isi_ms != 0             "paired"   a conditioned pulse, any delay; isi_ms
#                                     keeps its sign because Qtrac uses the
#                                     sign to tell threshold-tracked (+,
#                                     T-SICI) from fixed-intensity (-,
#                                     A-SICI/SICF) runs
#
# PHASES (os_label_phases)
#   nav_phase   "pre-target"  the pulse fired before the coil's assigned
#                             target had been selected in Brainsight -- the
#                             operator was still searching (hotspotting) or
#                             had not registered the spot yet
#               "on-target"   the target existed; the coil was meant to hold it
#   run_phase   "hotspot_rmt" single pulses before the first T-SICI pulse
#               "tsici"       the threshold-tracked block: paired pulses with a
#                             positive ISI and the single test pulses among them
#               "fixed_int"   fixed-intensity paired runs (negative ISI)
#               "post"        single pulses after the T-SICI block (1 mV etc.)
#   tracked     TRUE for pulses whose intensity was being tracked (T-SICI and
#               the RMT tracking inside it). For these the tracker holds the
#               MEP near 0.2 mV by CHANGING THE INTENSITY, so MSO -- not MEP
#               size -- is the outcome a coil offset would move.
#
# A STRATUM is the set of pulses that are the same stimulus:
#   participant x pulse_class x isi_ms x mso
# The coils are NOT part of it: both coils, and their targets, count as ONE
# for the offset-vs-EMG comparison (log MEP, MEP present). A pulse's offset
# is still measured from ITS coil's own target (os_offset_stream /
# os_offset_stream_polaris), but pulses fired with either coil at the same
# MSO and ISI share a stratum, so the effect is estimated across both coils.
# ci_stratum (participant x coil x pulse_class x isi_ms) is the exception: it
# is the baseline of the tracked-INTENSITY model, whose outcome is the
# stimulator output itself, not an EMG value. % MSO depends on the coil, and
# pooling it without a coil term turns a between-coil difference into a
# spurious offset effect (analysis.R).
# The user-facing rule "MSO and ISI must stay the same" is enforced by
# estimating every offset effect WITHIN strata (see analysis.R). The primary
# analysis set is the ON-TARGET phase; pre-target pulses are kept in the
# tables (for placement QC) but excluded from the effect models.
# =====================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
})

os_classify_pulses <- function(pulses) {
  pulses %>%
    mutate(
      isi_ms      = ifelse(is.na(isi_ms), NA_real_, round(isi_ms, 2)),
      pulse_class = case_when(
        is.na(isi_ms) ~ "unknown",
        isi_ms == 0   ~ "single",
        TRUE          ~ "paired"),
      paradigm_hint = case_when(
        pulse_class == "single"              ~ "single pulse (hotspot / RMT / test alone)",
        pulse_class == "paired" & isi_ms > 0 ~ "paired, threshold-tracked (T-SICI style)",
        pulse_class == "paired" & isi_ms < 0 ~ "paired, fixed test intensity (A-SICI/SICF style)",
        TRUE                                  ~ "unknown"),
      isi_abs_ms = abs(isi_ms)
    )
}

#' Nearest coil frame for each pulse (by Mac-clock time).
#' Adds coil, target, offsets, match_gap_s, in_stream_window, kept + drop_reason.
os_join_pulses <- function(pulses, stream, max_gap_s = 0.15, max_offset_mm = 25, max_angle_deg = 30) {
  stream <- arrange(stream, t)
  st <- as.numeric(stream$t); pt <- as.numeric(pulses$mac_time)
  j  <- findInterval(pt, st)
  lo <- pmax(j, 1L); hi <- pmin(j + 1L, length(st))
  idx <- ifelse(abs(pt - st[lo]) <= abs(pt - st[hi]), lo, hi)
  idx[is.na(pt)] <- NA_integer_
  gap <- abs(pt - st[idx])
  cols <- c("coil", "target", "target_at_frame", OS_DOF$var, OS_MAG$var)
  picked <- stream[ifelse(is.na(idx), 1L, idx), cols]
  picked[is.na(idx), ] <- NA
  bind_cols(pulses, picked) %>%
    mutate(
      match_gap_s      = gap,
      in_stream_window = !is.na(pt) & pt >= min(st) & pt <= max(st),
      drop_reason      = case_when(
        is.na(win_time)              ~ "no QLG trigger matched",
        is.na(mac_time)              ~ "no time",
        !in_stream_window            ~ "outside the neuronav recording",
        match_gap_s > max_gap_s      ~ sprintf("coil not visible (gap > %.2f s)", max_gap_s),
        trans_dist_mm > max_offset_mm | ang_dist_deg > max_angle_deg ~
          sprintf("coil off the head (> %g mm or > %g deg from target)", max_offset_mm, max_angle_deg),
        TRUE                         ~ "kept"),
      kept = drop_reason == "kept"
    )
}

#' Label nav_phase, run_phase and tracked (see header).
#' @param events     os_selection_events() output
#' @param assignment os_assign_targets()$assignment
os_label_phases <- function(joined, events, assignment) {
  asg <- os_target_first_selected(events, assignment)
  d <- joined %>% left_join(asg %>% select(coil, target_first_selected = t_first), by = "coil")

  pos_paired <- d %>% filter(pulse_class == "paired", isi_ms > 0, !is.na(mac_time))
  span <- if (nrow(pos_paired)) range(as.numeric(pos_paired$mac_time)) else c(Inf, -Inf)
  tt <- as.numeric(d$mac_time)

  d %>%
    mutate(
      nav_phase = case_when(
        is.na(coil) | is.na(mac_time)                    ~ NA_character_,
        is.na(target_first_selected)                     ~ "pre-target",
        mac_time < target_first_selected                 ~ "pre-target",
        TRUE                                             ~ "on-target"),
      in_tsici_span = is.finite(tt) & tt >= span[1] & tt <= span[2],
      run_phase = case_when(
        pulse_class == "paired" & isi_ms > 0             ~ "tsici",
        pulse_class == "paired" & isi_ms < 0             ~ "fixed_int",
        pulse_class == "single" & in_tsici_span          ~ "tsici",
        pulse_class == "single" & is.finite(tt) & tt < span[1] ~ "hotspot_rmt",
        pulse_class == "single" & is.finite(tt) & tt > span[2] ~ "post",
        pulse_class == "single"                          ~ "hotspot_rmt",
        TRUE                                             ~ "unknown"),
      tracked = run_phase == "tsici"
    ) %>% select(-in_tsici_span)
}

#' Add the modelling columns: log MEP with a noise floor, MEP-present flag,
#' |DoF| forms, the stratum key and the analysis-set flag.
#' @param analysis_phase "on-target" (default) restricts the effect models to
#'   pulses fired after the coil's target existed; "all" uses every kept pulse.
os_prepare_pulses <- function(joined, participant, log_floor_mv = 0.02, present_mv = 0.05,
                              analysis_phase = "on-target") {
  d <- joined %>%
    mutate(participant  = participant,
           log_ptp      = log(pmax(ptp_mv, log_floor_mv)),
           ptp_floored  = !is.na(ptp_mv) & ptp_mv < log_floor_mv,
           mep_present  = !is.na(ptp_mv) & ptp_mv >= present_mv,
           stratum      = paste(participant, pulse_class, isi_ms, mso, sep = "|"),
           ci_stratum   = paste(participant, coil, pulse_class, isi_ms, sep = "|"),
           analysis_set = kept & (analysis_phase == "all" |
                                  (!is.na(nav_phase) & nav_phase == analysis_phase)))
  for (v in OS_DOF$var) d[[paste0("abs_", v)]] <- abs(d[[v]])
  d
}
