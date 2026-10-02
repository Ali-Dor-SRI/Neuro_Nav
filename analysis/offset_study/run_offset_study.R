# =====================================================================
# run_offset_study.R  --  coil offset (6 DoF) vs MEP, per participant + group
#
# Runs every participant listed in manifest.csv through the same steps and
# then pools them. Open Neuro_Nav.Rproj first (or run from the repo root):
#
#   source("analysis/offset_study/run_offset_study.R")
#   Rscript analysis/offset_study/run_offset_study.R [manifest.csv]
#
# Per participant (analysis/output/offset_study/<id>/):
#   <id>_pulses.csv       one row per pulse: timing, class, phase, MSO, ISI,
#                         MEP, coil, target, 6 DoF + magnitudes, gap, kept/why not
#   <id>_stats.csv        within-stratum offset effects (see R/analysis.R)
#   <id>_placement.csv    where the coil was at the kept pulses, per phase
#   <id>_targets.csv      coil -> target assignment and the time table behind it
#   <id>_stream_2hz.csv   the 6-DoF coil stream, 0.5 s means (for the dashboard)
#   <id>_timeline.png     6 DoF over the session
#   <id>_dof_vs_mep.png   MEP vs |DoF| per pulse class (analysis set)
#   <id>_qc.txt           timing, sync, matching, phases and drop report -- read it
# Group (analysis/output/offset_study/group/):
#   all_pulses.csv, all_stats.csv, all_placement.csv
#   group_two_stage.csv   participant slopes combined (mean, random effects)
#   group_mixed.csv       pooled mixed models (log MEP and tracked MSO)
#   forest_*.png, pooled_dof_vs_mep.png, placement.png
#   offset_study_report.md  the human-readable summary
#   run_info.json         settings, timestamp, participants, failures
#
# MANIFEST COLUMNS
#   participant   study code (also matched against the time-sync label)
#   xlsx          QtracP export        qlg   QtracS run log
#   brainsight    Brainsight .txt      timesync  time_sync folder or one file
#   clock_offset_s  optional: overrides the time-sync lookup (Windows - Mac, s)
#   session_date  optional: YYYY-MM-DD (default: the Brainsight recording date)
#   coord_system  optional: "MNI" (default) or "Polaris" -- head-relative coil
#                 tracker instead of the navigated crosshairs. Polaris needs
#                 EVERY coil in the session to have its own target (see
#                 os_targets_per_coil() in R/brainsight_targets.R); a
#                 participant that doesn't meet this fails with a clear error
#                 (caught below, doesn't stop the rest of the batch).
#   include       TRUE/FALSE           notes  free text
# =====================================================================

suppressPackageStartupMessages({
  library(dplyr); library(tibble); library(readr); library(purrr); library(stringr)
})
options(digits.secs = 3, warn = 1)

# ---- locate the repo ------------------------------------------------
os_find_root <- function() {
  cands <- c(getwd(), dirname(getwd()), "Y:/Neuro_Nav_App",
             "C:/Users/Ali D/Desktop/Projects/Neuro_Nav_App")
  args <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", args[grepl("^--file=", args)])
  if (length(f)) cands <- c(normalizePath(file.path(dirname(f), "..", ".."), mustWork = FALSE), cands)
  for (c in cands) if (file.exists(file.path(c, "Neuro_Nav.Rproj"))) return(c)
  stop("Cannot find Neuro_Nav.Rproj -- open the project or run from the repo root.")
}
PROJECT_ROOT <- if (exists("PROJECT_ROOT")) PROJECT_ROOT else os_find_root()
STUDY_DIR    <- file.path(PROJECT_ROOT, "analysis", "offset_study")
PARSER_PATH  <- file.path(PROJECT_ROOT, "analysis", "R", "parse_brainsight.R")
OUT_DIR      <- if (exists("OUT_DIR")) OUT_DIR else
                file.path(PROJECT_ROOT, "analysis", "output", "offset_study")
cli_args     <- commandArgs(trailingOnly = TRUE)
MANIFEST     <- if (exists("MANIFEST")) MANIFEST else
                if (length(cli_args)) cli_args[1L] else file.path(STUDY_DIR, "manifest.csv")

for (f in c("qtrac_io.R", "coil_geometry.R", "brainsight_targets.R", "polaris_targets.R",
            "pulses.R", "analysis.R", "plots.R"))
  source(file.path(STUDY_DIR, "R", f))
source(PARSER_PATH)

# ---- settings -------------------------------------------------------
CFG_DEFAULT <- list(
  tz              = "America/Toronto",
  match_tol_min   = 0.08,   # xlsx sweep clock vs QLG sweep clock tolerance (min)
  max_gap_s       = 0.15,   # pulse-to-coil-frame tolerance (s); 20 Hz stream
  max_offset_mm   = 25,     # beyond this distance / angle the coil was off the head,
  max_angle_deg   = 30,     #   not "slightly off target": such pulses are excluded
  analysis_phase  = "on-target",  # effect models use pulses fired after the coil's
                                  #   target existed ("all" = every kept pulse)
  tol_mm          = c(2, 3, 5),   # placement tolerances reported (% of pulses within)
  tol_deg         = c(5, 10),
  log_floor_mv    = 0.02,   # MEP values below this are noise -> floored before log
  present_mv      = 0.05,   # "an MEP was present" threshold
  min_mso         = 5,      # ignore dummy pulses at MSO < 5
  min_pulses      = 8L,     # minimum pulses for a model
  block_gap_s     = 30,     # gap that splits a coil block in the timeline
  head_tracker    = "ST893",  # Polaris only: coil frames are expressed relative to this tracker
  n_samples_avg   = 5L        # Polaris only: frames averaged into each coil's own target
)
CFG <- if (exists("CFG_OVERRIDE")) modifyList(CFG_DEFAULT, CFG_OVERRIDE) else CFG_DEFAULT

# ---- one participant ------------------------------------------------
os_run_participant <- function(row, cfg, out_root) {
  id  <- row$participant
  dir <- file.path(out_root, id); dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  qc  <- character(0)
  say <- function(...) { line <- sprintf(...); message("  ", line); qc <<- c(qc, line) }
  warns <- character(0)
  withCallingHandlers({
    say("== %s ==", id)

    # 1. Brainsight (defines the session date)
    bs <- os_load_brainsight(row$brainsight, PARSER_PATH, cfg$tz)
    session_date <- if (!is.na(row$session_date) && nzchar(row$session_date))
                      as.Date(row$session_date) else attr(bs, "session_date")
    span <- attr(bs, "span")
    say("Brainsight      : %s  (%s .. %s)", basename(row$brainsight),
        format(span[1], "%Y-%m-%d %H:%M:%S"), format(span[2], "%H:%M:%S"))

    # 2. QLG launch + per-pulse triggers
    qlg <- os_read_qlg(row$qlg, session_date, cfg$tz)
    qlg_mdate <- as.Date(file.info(row$qlg)$mtime)
    say("QtracS launch   : %s  (launch pinned to %.0f ms; %d trigger lines; QLG modified %s%s)",
        format(qlg$launch_dt, "%Y-%m-%d %H:%M:%OS3"), 1000 * qlg$launch_window_s,
        qlg$n_triggers, qlg_mdate, if (qlg_mdate != session_date) "  ** DATE DIFFERS **" else "")

    # 3. xlsx pulses matched to triggers
    pulses <- os_read_qtrac_xlsx(row$xlsx)
    pulses <- os_match_pulses(pulses, qlg$triggers, cfg$match_tol_min)
    n_m <- sum(!is.na(pulses$trig_idx))
    drift <- pulses %>% filter(!is.na(el_s)) %>% mutate(off = el_s - elapsed_min * 60)
    say("QtracP pulses   : %d rows, %d matched to a QLG trigger (%.0f%%), intensity agrees on %.0f%%",
        nrow(pulses), n_m, 100 * n_m / nrow(pulses), 100 * mean(pulses$th_agrees[!is.na(pulses$trig_idx)]))
    say("Sweep-clock drift: xlsx elapsed vs real time differs by %.1f s at the start and %.1f s at the end",
        first(drift$off), last(drift$off))

    # 4. clock offset
    if (!is.na(row$clock_offset_s) && nzchar(as.character(row$clock_offset_s))) {
      delta <- as.numeric(row$clock_offset_s); sync_note <- "manifest override"
    } else {
      ts   <- os_read_timesync(row$timesync, cfg$tz)
      pick <- os_pick_clock_offset(ts, id, qlg$launch_dt)
      delta <- pick$delta_s
      sync_note <- sprintf("%s row at %s (%s, %.1f h from launch)", pick$row$log_file,
                           format(pick$row$win_local_time, "%H:%M:%S"),
                           if (pick$labelled) "labelled" else "unlabelled", pick$sep_h)
      for (w in pick$warnings) say("  ** %s", w)
    }
    say("Clock offset    : delta_s = %+.6f s (Windows - Mac) from %s", delta, sync_note)
    pulses$mac_time <- pulses$win_time - delta

    # 5. targets and offset stream
    coord_system <- if (!is.na(row$coord_system) && nzchar(trimws(row$coord_system)))
                       trimws(row$coord_system) else "MNI"
    if (!coord_system %in% c("MNI", "Polaris"))
      stop("coord_system must be 'MNI' or 'Polaris' (got '", coord_system, "').")

    events <- os_selection_events(bs)
    poses  <- os_target_poses(events)
    frames <- os_coil_frames(bs, events)
    asg    <- os_assign_targets(frames, events, poses)
    blocks <- os_coil_blocks(frames, cfg$block_gap_s)
    say("Targets in file : %s", if (nrow(poses)) paste(poses$target_name, collapse = ", ") else "none")
    for (k in seq_len(nrow(asg$assignment)))
      say("  coil %-12s -> %-12s (%.0f s selected while in use, %.0f%%; %s)",
          asg$assignment$coil[k], asg$assignment$target[k], asg$assignment$seconds[k],
          100 * asg$assignment$share[k], asg$assignment$rule[k])
    say("Coordinate frame: %s", coord_system)
    stream <- if (coord_system == "Polaris")
                os_offset_stream_polaris(bs, asg$assignment, events, cfg$head_tracker, cfg$n_samples_avg)
              else
                os_offset_stream(frames, asg$assignment, poses)

    # 6. classify + join + phases
    pulses <- os_classify_pulses(pulses)
    joined <- os_join_pulses(pulses, stream, cfg$max_gap_s, cfg$max_offset_mm, cfg$max_angle_deg)
    joined <- os_label_phases(joined, events, asg$assignment)
    joined <- os_prepare_pulses(joined, id, cfg$log_floor_mv, cfg$present_mv, cfg$analysis_phase)
    joined$coord_system <- coord_system
    drops  <- joined %>% count(drop_reason) %>% arrange(desc(n))
    say("Pulses joined   : %d kept of %d  [%s]", sum(joined$kept), nrow(joined),
        paste(sprintf("%s: %d", drops$drop_reason, drops$n), collapse = "; "))
    ph <- joined %>% filter(kept) %>% count(nav_phase, run_phase)
    say("Phases (kept)   : %s", paste(sprintf("%s/%s: %d", ph$nav_phase, ph$run_phase, ph$n), collapse = "; "))
    say("Analysis set    : %d pulses (%s phase)", sum(joined$analysis_set), cfg$analysis_phase)
    mism <- joined %>% filter(kept, !is.na(target_at_frame), target_at_frame != target)
    if (nrow(mism)) say("  ** %d kept pulses fired while a different target than the coil's assigned one was selected", nrow(mism))
    cls <- joined %>% filter(analysis_set) %>% count(pulse_class, isi_ms) %>% arrange(pulse_class, isi_ms)
    say("Analysis by class: %s", paste(sprintf("%s@%g:%d", cls$pulse_class, cls$isi_ms, cls$n), collapse = " "))
    gap <- joined %>% filter(kept)
    if (nrow(gap)) say("Match gap       : median %.3f s, max %.3f s", median(gap$match_gap_s), max(gap$match_gap_s))

    # 7. stats + plots
    stats <- os_participant_stats(joined, cfg$min_pulses, cfg$min_mso)
    place <- os_placement_summary(joined, cfg$tol_mm, cfg$tol_deg)
    pct_cols <- grep("^pct_within_[0-9.]+mm$", names(place), value = TRUE)   # one per cfg$tol_mm
    for (k in seq_len(nrow(place)))
      say("Placement %-12s %-10s: n=%3d median %.1f mm (p90 %.1f), %s; angle median %.1f deg",
          place$coil[k], place$nav_phase[k], place$n_pulses[k], place$dist_median_mm[k],
          place$dist_p90_mm[k],
          paste(sprintf("%.0f%% within %s mm", unlist(place[k, pct_cols]),
                        sub("^pct_within_([0-9.]+)mm$", "\\1", pct_cols)), collapse = ", "),
          place$ang_median_deg[k])

    fmt_t <- function(x) format(x, "%Y-%m-%d %H:%M:%OS3")
    write_csv(joined %>% mutate(across(c(win_time, mac_time, target_first_selected), fmt_t)),
              file.path(dir, paste0(id, "_pulses.csv")))
    write_csv(stats, file.path(dir, paste0(id, "_stats.csv")))
    write_csv(place, file.path(dir, paste0(id, "_placement.csv")))
    write_csv(bind_rows(asg$assignment %>% mutate(kind = "assignment"),
                        asg$table %>% mutate(kind = "time_table") %>% rename(target = target_at_frame)),
              file.path(dir, paste0(id, "_targets.csv")))
    s2 <- stream %>% mutate(bin = floor(as.numeric(t) / 0.5)) %>%
      group_by(coil, target, bin) %>%
      summarise(t = first(t), across(all_of(c(OS_DOF$var, OS_MAG$var)), mean), .groups = "drop") %>%
      arrange(t) %>% select(-bin) %>% mutate(t = fmt_t(t))
    write_csv(s2, file.path(dir, paste0(id, "_stream_2hz.csv")))
    write_csv(events %>% mutate(t = fmt_t(t)) %>% select(t, target_name),
              file.path(dir, paste0(id, "_target_events.csv")))
    write_csv(blocks %>% mutate(across(c(start, end), fmt_t)), file.path(dir, paste0(id, "_coil_blocks.csv")))
    suppressWarnings({   # LOESS / empty-facet chatter from ggplot is not a data warning
      os_save(os_plot_timeline(stream, joined, blocks, events, id, asg$assignment,
                               clip_mm = cfg$max_offset_mm, clip_deg = cfg$max_angle_deg),
              file.path(dir, paste0(id, "_timeline.png")), width = 11, height = 10)
      os_save(os_plot_dof_vs_mep(joined, id),
              file.path(dir, paste0(id, "_dof_vs_mep.png")), width = 14, height = 7)
    })
  }, warning = function(w) { warns <<- c(warns, conditionMessage(w)); invokeRestart("muffleWarning") })

  if (length(warns)) qc <- c(qc, "Warnings:", paste0("  - ", unique(warns)))
  writeLines(qc, file.path(dir, paste0(id, "_qc.txt")))
  list(participant = id, pulses = joined, stats = stats, placement = place,
       assignment = asg$assignment, qc = qc, warnings = unique(warns))
}

# ---- run everything -------------------------------------------------
manifest <- read_csv(MANIFEST, show_col_types = FALSE,
                     col_types = cols(.default = col_character())) %>%
  mutate(include = is.na(include) | toupper(include) %in% c("TRUE", "T", "YES", "1"))
dir.create(file.path(OUT_DIR, "group"), recursive = TRUE, showWarnings = FALSE)
message(sprintf("Offset study: %d participants in %s (%d included)", nrow(manifest), MANIFEST,
                sum(manifest$include)))

results <- list(); failures <- list()
for (i in which(manifest$include)) {
  row <- manifest[i, ]
  res <- tryCatch(os_run_participant(row, CFG, OUT_DIR),
                  error = function(e) { message("  !! ", row$participant, ": ", conditionMessage(e)); e })
  if (inherits(res, "error")) failures[[row$participant]] <- conditionMessage(res)
  else results[[row$participant]] <- res
}
if (length(results) == 0L) stop("No participant completed.")

# ---- group stage ----------------------------------------------------
all_pulses <- bind_rows(map(results, "pulses"))

cs_by_participant <- sapply(results, function(r) r$pulses$coord_system[1L])
cs <- unique(cs_by_participant)
if (length(cs) > 1L) {
  groups <- sapply(cs, function(x) paste(names(cs_by_participant)[cs_by_participant == x], collapse = ", "))
  warning(sprintf(paste0("Participants were analysed in different coordinate frames (%s). ",
                         "Group-level pooling (forest plots, two-stage summaries, mixed models) ",
                         "will mix MNI and Polaris offsets as if they were the same measurement -- ",
                         "run coord_system consistently across a manifest you intend to pool."),
                 paste(sprintf("%s: %s", cs, groups), collapse = "; ")), call. = FALSE)
}
all_stats  <- bind_rows(map(results, "stats"))
all_place  <- bind_rows(map(results, "placement"))
two_stage  <- os_group_two_stage(all_stats)
mixed      <- os_group_mixed(all_pulses, min_mso = CFG$min_mso)

gdir <- file.path(OUT_DIR, "group")
fmt_t <- function(x) format(x, "%Y-%m-%d %H:%M:%OS3")
write_csv(all_pulses %>% mutate(across(c(win_time, mac_time, target_first_selected), fmt_t)),
          file.path(gdir, "all_pulses.csv"))
write_csv(all_stats, file.path(gdir, "all_stats.csv"))
write_csv(all_place, file.path(gdir, "all_placement.csv"))
write_csv(two_stage, file.path(gdir, "group_two_stage.csv"))
write_csv(mixed,     file.path(gdir, "group_mixed.csv"))
for (cl in intersect(c("single", "paired"), unique(all_stats$pulse_class))) {
  os_save(os_plot_forest(all_stats, two_stage, cl), file.path(gdir, sprintf("forest_%s_abs.png", cl)),
          width = 11, height = 7)
  if (any(all_stats$outcome == "tracked_mso" & all_stats$pulse_class == cl))
    os_save(os_plot_forest(all_stats, two_stage, cl, outcome = "tracked_mso"),
            file.path(gdir, sprintf("forest_%s_tracked_mso.png", cl)), width = 11, height = 7)
}
os_save(os_plot_pooled(all_pulses), file.path(gdir, "pooled_dof_vs_mep.png"), width = 14, height = 6)
os_save(os_plot_placement(all_pulses), file.path(gdir, "placement.png"), width = 10, height = 7)

if (requireNamespace("jsonlite", quietly = TRUE)) {
  jsonlite::write_json(list(run_time = format(Sys.time(), "%Y-%m-%d %H:%M:%S"), manifest = MANIFEST,
                            cfg = CFG, participants = names(results),
                            failures = if (length(failures)) failures else list(),
                            n_pulses = nrow(all_pulses), n_analysis = sum(all_pulses$analysis_set)),
                       file.path(gdir, "run_info.json"), auto_unbox = TRUE, pretty = TRUE)
}

# ---- report ---------------------------------------------------------
fmt_tab <- function(df) {
  if (nrow(df) == 0L) return("_(none)_")
  df <- df %>% mutate(across(where(is.numeric), ~ signif(.x, 3)))
  c(paste0("| ", paste(names(df), collapse = " | "), " |"),
    paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|"),
    apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |")))
}
rep <- c(
  "# Coil offset vs MEP: run report", "",
  sprintf("Generated %s from `%s`. Effect models use the **%s** phase.",
          format(Sys.time(), "%Y-%m-%d %H:%M"), MANIFEST, CFG$analysis_phase), "",
  sprintf("Participants completed: %s.", paste(names(results), collapse = ", ")),
  if (length(failures)) c("", "Failed:", sprintf("- %s: %s", names(failures), unlist(failures))) else NULL,
  "", "## Per-participant QC", "",
  unlist(lapply(results, function(r) c(sprintf("### %s", r$participant), "```", r$qc, "```", ""))),
  "## Placement at the kept pulses, by phase", "",
  fmt_tab(all_place %>% select(participant, coil, target, nav_phase, n_pulses,
      dist_median_mm, dist_p90_mm, starts_with("pct_within_"),
      ang_median_deg, starts_with("pct_angle_within_"))),
  "", "## Group: within-stratum effect of |offset| on log(MEP)", "",
  "Random-effects mean of the participant slopes (log MEP per mm or per degree, MSO and ISI fixed; both coils and their targets count as one).",
  "`pct_change_per_unit` = % change in MEP per mm or per degree of offset. `n_positive`/`n_negative` count participants by sign.", "",
  fmt_tab(two_stage %>% filter(outcome == "log_mep", form == "abs") %>%
            select(pulse_class, dof, k, re_estimate, re_ci_lo, re_ci_hi, re_p, pct_change_per_unit,
                   i2, n_positive, n_negative)),
  "", "## Group: tracked intensity (threshold-tracked pulses; % MSO per unit |offset|)", "",
  "Two-stage random-effects mean of the participant slopes from `MSO ~ |offset| + time + coil:ISI` (the coils do not count as one here: % MSO is a stimulator setting that depends on the coil).", "",
  fmt_tab(two_stage %>% filter(outcome == "tracked_mso", form == "abs") %>%
            select(pulse_class, dof, k, re_estimate, re_ci_lo, re_ci_hi, re_p, i2, n_positive, n_negative)),
  "", "## Group: pooled mixed models", "",
  "log MEP: `log(MEP) ~ |offset| + (1 + |offset| | participant) + (1 | stratum)`;",
  "tracked MSO: `MSO ~ |offset| + time + (1 + |offset| | participant) + (1 | coil:ISI)`.", "",
  fmt_tab(mixed %>% filter(form == "abs") %>%
            select(outcome, pulse_class, dof, spec, n_pulses, n_participants, n_strata, estimate, ci_lo, ci_hi, p,
                   pct_change_per_unit, slope_sd_between_participants)),
  "", "## Group: collapsed magnitudes (mixed models)", "",
  fmt_tab(mixed %>% filter(form == "magnitude") %>%
            select(outcome, pulse_class, dof, n_pulses, n_participants, estimate, ci_lo, ci_hi, p, pct_change_per_unit)),
  "", "## Group: signed offsets (asymmetry check, mixed models)", "",
  fmt_tab(mixed %>% filter(form == "signed") %>%
            select(outcome, pulse_class, dof, n_pulses, n_participants, estimate, ci_lo, ci_hi, p, pct_change_per_unit)),
  "", "## Group: MEP presence (two-stage, |offset|, log odds per unit)", "",
  fmt_tab(two_stage %>% filter(outcome == "mep_present", form == "abs") %>%
            select(pulse_class, dof, k, re_estimate, re_ci_lo, re_ci_hi, re_p, n_positive, n_negative))
)
writeLines(rep, file.path(gdir, "offset_study_report.md"))
message(sprintf("\nDone. Report: %s", file.path(gdir, "offset_study_report.md")))
# Last lines of the log on purpose: the group outputs hold only the participants
# that completed, so a partial run must not look like a full one.
if (length(failures))
  message(sprintf("\n** %d of %d included participants FAILED and are NOT in the group outputs:\n%s",
                  length(failures), sum(manifest$include),
                  paste(sprintf("   - %s: %s", names(failures), unlist(failures)), collapse = "\n")))
