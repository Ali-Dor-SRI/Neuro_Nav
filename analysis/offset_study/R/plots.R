# =====================================================================
# plots.R  --  figures for the coil-offset study (ggplot2, static PNG)
#
# Colour roles (one job per colour, fixed per entity):
#   pulse class   single = blue, paired = orange
#   coil          blue / orange / aqua (third colour, sessions with >2 coils)
#   MSO           one-hue sequential blue ramp
#   group vs one participant: participants blue, the group estimate orange
#   signed offsets over time: zero line as a hairline, no diverging fill
# Text stays in neutral ink; grid and axes are solid hairlines.
# =====================================================================

suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(tidyr)
})

OS_COL <- list(blue = "#2a78d6", orange = "#eb6834", aqua = "#1baf7a",
               ink = "#0b0b0b", ink2 = "#52514e", grid = "#e9e8e4", zero = "#b8b6ae")
OS_CLASS_COL <- c(single = OS_COL$blue, paired = OS_COL$orange)
OS_MSO_RAMP  <- c("#86b6ef", "#3987e5", "#1c5cab", "#0d366b")

os_theme <- function(base_size = 10) {
  theme_minimal(base_size = base_size) +
    theme(panel.grid.minor = element_blank(),
          panel.grid.major = element_line(colour = OS_COL$grid, linewidth = 0.3),
          axis.text  = element_text(colour = OS_COL$ink2),
          axis.title = element_text(colour = OS_COL$ink2),
          strip.text = element_text(colour = OS_COL$ink, face = "bold", hjust = 0),
          plot.title = element_text(colour = OS_COL$ink, face = "bold"),
          plot.subtitle = element_text(colour = OS_COL$ink2),
          plot.caption  = element_text(colour = OS_COL$ink2, hjust = 0),
          legend.position = "top", legend.title = element_text(colour = OS_COL$ink2),
          legend.text = element_text(colour = OS_COL$ink2),
          plot.background = element_rect(fill = "white", colour = NA))
}

.os_dof_long <- function(df, vars = OS_DOF$var, lab = OS_DOF) {
  df %>% pivot_longer(all_of(vars), names_to = "dof", values_to = "value") %>%
    mutate(dof = factor(dof, levels = lab$var, labels = paste0(lab$label, " (", lab$unit, ")")))
}

#' Six DoF over the session with pulses marked and coil blocks shaded.
os_plot_timeline <- function(stream, pulses, blocks, events, participant, assignment,
                             downsample_s = 0.5, clip_mm = 25, clip_deg = 30) {
  clip <- function(df) df %>%
    mutate(across(c(dx_mm, dy_mm, dz_mm), ~ pmax(pmin(.x, clip_mm), -clip_mm)),
           across(c(rx_deg, ry_deg, rz_deg), ~ pmax(pmin(.x, clip_deg), -clip_deg)))
  s <- stream %>% mutate(bin = floor(as.numeric(t) / downsample_s)) %>%
    group_by(coil, bin) %>% summarise(t = first(t), across(all_of(OS_DOF$var), mean),
                                       .groups = "drop") %>% clip()
  sl <- .os_dof_long(s)
  pl <- .os_dof_long(pulses %>% filter(kept) %>% mutate(t = mac_time) %>% clip())
  ev <- events %>% filter(!is.na(target_name))
  blocks <- blocks %>% left_join(assignment %>% select(coil, target), by = "coil") %>%
    mutate(lab = ifelse(as.numeric(difftime(end, start, units = "secs")) > 90,
                        paste0(coil, " -> ", target), ""))
  ggplot() +
    geom_rect(data = blocks, aes(xmin = start, xmax = end, ymin = -Inf, ymax = Inf),
              fill = OS_COL$grid, alpha = 0.6) +
    geom_hline(yintercept = 0, colour = OS_COL$zero, linewidth = 0.3) +
    geom_line(data = sl, aes(t, value, group = coil), colour = OS_COL$ink2, linewidth = 0.35) +
    geom_point(data = pl, aes(t, value, colour = pulse_class), size = 1.3, alpha = 0.85) +
    geom_vline(data = ev, aes(xintercept = t), colour = OS_COL$orange, linewidth = 0.4) +
    geom_text(data = blocks, aes(x = start, y = Inf, label = lab), vjust = 1.4, hjust = 0,
              size = 2.6, colour = OS_COL$ink2, nudge_x = 5) +
    facet_wrap(~ dof, ncol = 1, scales = "free_y") +
    scale_colour_manual(values = OS_CLASS_COL, name = "Pulse") +
    scale_x_datetime(date_labels = "%H:%M") +
    labs(title = sprintf("%s  -  coil offset from its target over the session", participant),
         subtitle = sprintf("grey line: coil stream (0.5 s means); dots: analysed pulses; orange verticals: target selections; shaded: coil in use. Values clipped at +/-%g mm and +/-%g deg.",
                            clip_mm, clip_deg),
         x = "Time (Mac / Brainsight clock)", y = NULL) +
    os_theme()
}

#' log MEP against |DoF|, one facet per DoF and pulse class, coloured by MSO.
os_plot_dof_vs_mep <- function(pulses, participant) {
  d <- pulses %>% filter(analysis_set, pulse_class %in% c("single", "paired"))
  if (nrow(d) == 0L) return(NULL)
  vars <- paste0("abs_", OS_DOF$var)
  lab  <- OS_DOF %>% mutate(var = vars, label = paste0("|", label, "|"))
  dl <- .os_dof_long(d, vars, lab) %>%
    mutate(pulse_class = factor(pulse_class, levels = c("single", "paired")))
  ggplot(dl, aes(value, ptp_mv)) +
    geom_point(aes(colour = mso), size = 1.4, alpha = 0.8) +
    geom_smooth(method = "loess", se = TRUE, colour = OS_COL$ink2, fill = OS_COL$grid,
                linewidth = 0.6, span = 1, formula = y ~ x) +
    facet_grid(pulse_class ~ dof, scales = "free_x") +
    scale_y_log10() +
    scale_colour_gradientn(colours = OS_MSO_RAMP, name = "% MSO") +
    labs(title = sprintf("%s  -  MEP amplitude vs. coil offset, by degree of freedom", participant),
         subtitle = "analysis-set pulses only (coil's target already selected); LOESS for shape only - the stats table holds the within-MSO/ISI slopes",
         x = "offset from target", y = "MEP peak-to-peak (mV, log scale)") +
    os_theme()
}

#' Forest plot: per-participant class-level slopes and the group estimate.
os_plot_forest <- function(stats, two_stage, pulse_class, outcome = "log_mep", form = "abs") {
  s <- stats %>% filter(level == "class", pulse_class == !!pulse_class, outcome == !!outcome,
                        form == !!form, is.finite(estimate))
  g <- two_stage %>% filter(pulse_class == !!pulse_class, outcome == !!outcome, form == !!form)
  if (nrow(s) == 0L) return(NULL)
  ylab_unit <- if (outcome == "log_mep") "log(MEP) change per unit offset (mm or deg)" else
               if (outcome == "mep_present") "log odds of an MEP per unit offset" else "% MSO per unit offset"
  ttl <- if (outcome == "tracked_mso")
    sprintf("%s pulses  -  tracked intensity vs |offset| per participant and the group mean", pulse_class) else
    sprintf("%s pulses  -  within-stratum offset effect per participant and the group mean", pulse_class)
  sub <- if (outcome == "tracked_mso")
    "slope of % MSO on |offset| with a time trend and coil:ISI held fixed; positive = the tracker needed more intensity as the coil drifted" else
    "slope of log(MEP) on |offset| with MSO and ISI held fixed (both coils pooled); bars are 95% CI; negative = MEP shrinks as the coil drifts"
  s <- s %>% mutate(who = participant, kind = "participant")
  g <- g %>% transmute(dof, pred_label, who = "Group (random-effects mean)", kind = "group",
                       estimate = re_estimate, ci_lo = re_ci_lo, ci_hi = re_ci_hi)
  d <- bind_rows(s %>% select(dof, pred_label, who, kind, estimate, ci_lo, ci_hi), g) %>%
    mutate(who = factor(who, levels = rev(c(sort(unique(s$participant)), "Group (random-effects mean)"))),
           dof = factor(dof, levels = OS_DOF$var, labels = OS_DOF$label))
  ggplot(d, aes(estimate, who, colour = kind)) +
    geom_vline(xintercept = 0, colour = OS_COL$zero, linewidth = 0.3) +
    geom_errorbar(aes(xmin = ci_lo, xmax = ci_hi), orientation = "y", width = 0, linewidth = 0.5) +
    geom_point(aes(size = kind, shape = kind)) +
    facet_wrap(~ dof, scales = "free_x", ncol = 3) +
    scale_colour_manual(values = c(participant = OS_COL$blue, group = OS_COL$orange), guide = "none") +
    scale_size_manual(values = c(participant = 1.8, group = 3), guide = "none") +
    scale_shape_manual(values = c(participant = 16, group = 18), guide = "none") +
    labs(title = ttl, subtitle = sub, x = ylab_unit, y = NULL) +
    os_theme()
}

#' Pooled: stratum-centred log MEP vs |DoF|, thin line per participant, bold group line.
os_plot_pooled <- function(pulses) {
  d <- pulses %>% filter(analysis_set, pulse_class %in% c("single", "paired"))
  if (nrow(d) == 0L) return(NULL)
  d <- d %>% group_by(stratum) %>% filter(n() >= 3L) %>%
    mutate(log_ptp_c = log_ptp - mean(log_ptp)) %>% ungroup()
  vars <- paste0("abs_", OS_DOF$var)
  lab  <- OS_DOF %>% mutate(var = vars, label = paste0("|", label, "|"))
  dl <- .os_dof_long(d, vars, lab) %>% filter(is.finite(value))
  ggplot(dl, aes(value, log_ptp_c)) +
    geom_hline(yintercept = 0, colour = OS_COL$zero, linewidth = 0.3) +
    geom_point(colour = OS_COL$ink2, size = 0.7, alpha = 0.25) +
    geom_smooth(aes(group = participant), method = "lm", se = FALSE, colour = OS_COL$blue,
                linewidth = 0.45, alpha = 0.7, formula = y ~ x) +
    geom_smooth(method = "lm", se = TRUE, colour = OS_COL$orange, fill = OS_COL$grid,
                linewidth = 1.1, formula = y ~ x) +
    facet_grid(pulse_class ~ dof, scales = "free_x") +
    labs(title = "All participants  -  MEP deviation from its stratum mean vs. coil offset",
         subtitle = "y: log(MEP) minus the mean of pulses at the same MSO/ISI, both coils pooled (so stimulus intensity is removed); thin blue: one line per participant; orange: pooled",
         x = "offset from target", y = "log(MEP) - stratum mean") +
    os_theme()
}

#' Placement quality: distance and angle at the pulses, per participant.
os_plot_placement <- function(pulses, phase = "on-target") {
  d <- pulses %>% filter(kept, !is.na(nav_phase), phase == "all" | nav_phase == phase)
  if (nrow(d) == 0L) return(NULL)
  dl <- d %>% select(participant, coil, trans_dist_mm, ang_dist_deg) %>%
    pivot_longer(c(trans_dist_mm, ang_dist_deg), names_to = "measure", values_to = "value") %>%
    mutate(measure = factor(measure, levels = c("trans_dist_mm", "ang_dist_deg"),
                            labels = c("distance from target (mm)", "angle from target (deg)")))
  first_p <- sort(unique(dl$participant))[1L]
  ref <- tibble(measure = factor("distance from target (mm)", levels = levels(dl$measure)),
                y = c(3, 5), lab = c("3 mm", "5 mm"), participant = first_p)
  ggplot(dl, aes(participant, value, colour = coil)) +
    geom_hline(data = ref, aes(yintercept = y), colour = OS_COL$zero, linewidth = 0.4) +
    geom_text(data = ref, aes(x = participant, y = y, label = lab), inherit.aes = FALSE,
              hjust = 1.1, vjust = -0.4, size = 2.6, colour = OS_COL$ink2) +
    geom_boxplot(outlier.size = 0.6, linewidth = 0.4, position = position_dodge(width = 0.7),
                 fill = NA) +
    facet_wrap(~ measure, scales = "free_y", ncol = 1) +
    scale_colour_manual(values = c(OS_COL$blue, OS_COL$orange, OS_COL$aqua), name = "Coil") +
    labs(title = "Where the coil was when each pulse fired",
         subtitle = sprintf("%s pulses; one box per participant and coil; the SOP asks for < 5 mm (ideally < 3 mm)",
                            if (phase == "all") "all kept" else phase),
         x = NULL, y = NULL) +
    os_theme() + theme(axis.text.x = element_text(angle = 30, hjust = 1))
}

os_save <- function(p, path, width = 9, height = 6, dpi = 150) {
  if (is.null(p)) return(invisible(NULL))
  ggsave(path, p, width = width, height = height, dpi = dpi, bg = "white")
  invisible(path)
}
