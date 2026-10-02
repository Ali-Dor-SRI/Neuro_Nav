# =====================================================================
# brainsight_targets.R  --  which target belongs to which coil, and the
#                           coil's 6-DoF offset stream (MNI)
#
# The target ASSIGNMENT below (which named target belongs to which coil, and
# when it was first selected) is coordinate-frame-independent: it comes from
# `Crosshairs Position` / `Target Selection`, the only rows that record which
# target was selected when, regardless of which frame the offset itself is
# later measured in (see polaris_targets.R for the Polaris/head-relative
# offset stream, which reuses this same assignment).
#
# The OFFSET STREAM below (os_offset_stream) is in MNI: the navigated
# `Crosshairs Position` pose is the coil, the `Target Selection` pose is the
# target. Both coils' crosshairs live in the same anatomical space, so a
# single MNI target is directly comparable across a coil swap, and each coil
# can still be given its own target when the operator created one per coil.
#
# TARGET ASSIGNMENT RULE (per coil)
#   Brainsight writes Crosshairs rows only for the coil currently selected,
#   and only with a position when the camera sees it. Every such frame is
#   attributed to the target that was selected at that instant (the most
#   recent `Target Selection` at or before the frame; `<No Selection>` and
#   null rows mean "none"). The target that was selected for the MOST
#   VISIBLE TIME while a coil was in use is that coil's target. This gives:
#     * one target in the file  -> both coils measured against it
#     * one target per coil     -> each coil against its own
#     * more than two targets   -> the longest-selected target per coil wins
#   Frames with no target selected are ignored; a coil that never overlapped
#   any selection falls back to the selection nearest in time (warned).
# =====================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
})

OS_NO_SELECTION <- c("<No Selection>", "(null)", "")

#' Parse a Brainsight file and rebuild timestamps in `tz`.
os_load_brainsight <- function(path, parser_path, tz = "America/Toronto") {
  if (!file.exists(path)) stop("Brainsight file not found: ", path)
  if (!exists("parse_brainsight", mode = "function")) source(parser_path)
  tables <- parse_brainsight(path, parse_datetime = FALSE, drop_null_rows = FALSE)
  stamp <- function(df) {
    if (nrow(df) == 0L) { df$t <- as.POSIXct(character(0), tz = tz); return(df) }
    df$t <- as.POSIXct(paste(df$date, df$time), format = "%Y-%m-%d %H:%M:%OS", tz = tz)
    df
  }
  for (nm in c("Crosshairs Position", "Target Selection", "New Sample", "Polaris Tool"))
    tables[[nm]] <- stamp(tables[[nm]])
  all_t <- c(tables[["Crosshairs Position"]]$t, tables[["Polaris Tool"]]$t)
  all_t <- all_t[!is.na(all_t)]
  attr(tables, "session_date") <- if (length(all_t)) as.Date(min(all_t), tz = tz) else NA
  attr(tables, "span") <- if (length(all_t)) range(all_t) else NULL
  tables
}

#' Target Selection events in time order: t, target_name (NA = none), pose.
os_selection_events <- function(tables) {
  ts <- tables[["Target Selection"]]
  if (nrow(ts) == 0L)
    return(tibble(t = as.POSIXct(character(0)), target_name = character(0)))
  ts %>%
    filter(!is.na(t)) %>%
    mutate(target_name = ifelse(is.na(target_name) | target_name %in% OS_NO_SELECTION |
                                  is.na(loc_x) | coord_system != "MNI",
                                NA_character_, target_name)) %>%
    arrange(t) %>%
    select(t, target_name, coord_system, loc_x, loc_y, loc_z, all_of(OS_ROT_COLS))
}

#' Named target poses: one row per distinct target name (first selection's
#' pose; warns when the same name is later selected with a different pose).
os_target_poses <- function(events) {
  ev <- events %>% filter(!is.na(target_name))
  if (nrow(ev) == 0L) return(ev[0, ])
  out <- ev %>% group_by(target_name) %>%
    mutate(n_sel = n(),
           moved = max(abs(loc_x - first(loc_x)), abs(loc_y - first(loc_y)),
                       abs(loc_z - first(loc_z))) > 0.01) %>%
    slice(1L) %>% ungroup()
  for (k in which(out$moved))
    warning(sprintf("Target '%s' was selected %d times with differing poses; using the first.",
                    out$target_name[k], out$n_sel[k]), call. = FALSE)
  out
}

#' Visible crosshairs frames (MNI) with the coil (driver) and the target
#' selected at that instant.
os_coil_frames <- function(tables, events) {
  cx <- tables[["Crosshairs Position"]] %>%
    filter(!is.na(t), coord_system == "MNI", !is.na(loc_x), !is.na(loc_y), !is.na(loc_z),
           !is.na(crosshairs_driver)) %>%
    arrange(t) %>%
    rename(coil = crosshairs_driver)
  if (nrow(cx) == 0L) stop("No visible MNI 'Crosshairs Position' frames in the Brainsight file.")
  idx <- findInterval(as.numeric(cx$t), as.numeric(events$t))
  cx$target_at_frame <- ifelse(idx > 0L, events$target_name[pmax(idx, 1L)], NA_character_)
  # seconds each frame stands for: gap to the next frame of the same coil, capped at 1 s
  cx <- cx %>% group_by(coil) %>% arrange(t, .by_group = TRUE) %>%
    mutate(dt_s = pmin(c(diff(as.numeric(t)), 0.05), 1)) %>% ungroup() %>% arrange(t)
  cx
}

#' Contiguous blocks of coil use (a gap > `gap_s` starts a new block).
os_coil_blocks <- function(frames, gap_s = 30) {
  frames %>% arrange(t) %>%
    mutate(new_block = coil != lag(coil, default = first(coil)) |
             c(FALSE, diff(as.numeric(t)) > gap_s),
           block = cumsum(new_block)) %>%
    group_by(block, coil) %>%
    summarise(start = min(t), end = max(t), n_frames = n(), .groups = "drop")
}

#' Assign a target to every coil by the time-weighted rule in the header.
#' @return list(assignment = tibble(coil, target, seconds, share, n_targets_seen, rule),
#'              table = tibble(coil, target_at_frame, seconds, n_frames))
os_assign_targets <- function(frames, events, poses) {
  tab <- frames %>% group_by(coil, target_at_frame) %>%
    summarise(seconds = sum(dt_s), n_frames = n(), .groups = "drop") %>%
    arrange(coil, desc(seconds))
  coils <- unique(frames$coil)
  named <- poses$target_name
  rows <- lapply(coils, function(cn) {
    tc <- tab %>% filter(coil == cn, !is.na(target_at_frame))
    tot <- sum(tab$seconds[tab$coil == cn])
    if (nrow(tc) > 0L) {
      w <- tc[1L, ]
      tibble(coil = cn, target = w$target_at_frame, seconds = w$seconds,
             share = w$seconds / tot, n_targets_seen = nrow(tc),
             rule = if (nrow(tc) == 1L) "only target selected while coil in use"
                    else "longest-selected target while coil in use")
    } else if (length(named) == 1L) {
      tibble(coil = cn, target = named, seconds = 0, share = 0, n_targets_seen = 0L,
             rule = "single target in file (never selected while this coil was in use)")
    } else if (length(named) == 0L) {
      tibble(coil = cn, target = NA_character_, seconds = 0, share = 0, n_targets_seen = 0L,
             rule = "no target in file")
    } else {
      mid <- mean(as.numeric(range(frames$t[frames$coil == cn])))
      ev  <- events %>% filter(!is.na(target_name))
      k   <- which.min(abs(as.numeric(ev$t) - mid))
      tibble(coil = cn, target = ev$target_name[k], seconds = 0, share = 0, n_targets_seen = 0L,
             rule = "fallback: selection nearest in time to the coil block")
    }
  })
  assignment <- bind_rows(rows)
  for (k in which(assignment$n_targets_seen == 0L))
    warning(sprintf("Coil '%s': no target was selected while it was in use (%s).",
                    assignment$coil[k], assignment$rule[k]), call. = FALSE)
  list(assignment = assignment, table = tab)
}

#' TRUE only if every coil in `assignment` has its OWN target: as many
#' distinct target names as coils, none shared, none missing. Two coils'
#' Polaris trackers are different physical bodies, so their head-relative
#' poses are only comparable to something measured on that SAME body -- a
#' Polaris offset stream (polaris_targets.R) requires this; MNI does not,
#' since the anatomical frame makes one shared target directly comparable.
os_targets_per_coil <- function(assignment) {
  tgt <- assignment$target
  length(tgt) > 0 && !anyNA(tgt) && !anyDuplicated(tgt)
}

#' The moment each coil's assigned target was FIRST selected. Shared by
#' os_label_phases() (nav_phase) and the Polaris target anchor
#' (polaris_targets.R), so both agree on "when the coil went on-target".
os_target_first_selected <- function(events, assignment) {
  first_sel <- events %>% filter(!is.na(target_name)) %>%
    group_by(target_name) %>% summarise(t_first = min(t), .groups = "drop")
  assignment %>% select(coil, target) %>%
    left_join(first_sel, by = c("target" = "target_name"))
}

#' The coil's 6-DoF offset stream: every visible frame vs its coil's target.
os_offset_stream <- function(frames, assignment, poses) {
  parts <- lapply(seq_len(nrow(assignment)), function(k) {
    cn <- assignment$coil[k]; tn <- assignment$target[k]
    sub <- frames %>% filter(coil == cn)
    if (is.na(tn)) return(NULL)
    tp  <- poses %>% filter(target_name == tn)
    tgt <- list(pos = c(tp$loc_x, tp$loc_y, tp$loc_z), rot = as.numeric(tp[1L, OS_ROT_COLS]))
    off <- os_offsets_table(sub, tgt)
    bind_cols(
      tibble(t = sub$t, coil = cn, target = tn, target_at_frame = sub$target_at_frame,
             x = sub$loc_x, y = sub$loc_y, z = sub$loc_z),
      off
    )
  })
  bind_rows(parts) %>% arrange(t)
}
