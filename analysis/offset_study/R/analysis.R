# =====================================================================
# analysis.R  --  statistics for the coil-offset study
#
# THE QUESTION: does the coil's offset from its target change the MEP, once
# the stimulus itself (MSO, ISI) is held fixed? And for threshold-tracked
# runs, does it change the intensity the tracker needs? For the EMG outcomes
# (log MEP, MEP present) both coils, and their targets, count as ONE: each
# pulse's offset is measured from its own coil's target, and the effect is
# estimated across both coils together. The tracked-intensity outcome keeps
# a coil baseline (see below).
#
# PREDICTORS. Each of the six DoF enters in two forms:
#   abs     |dx|, |dy|, ... "how far off along this axis" (primary: an offset
#           in either direction should shrink the MEP, so the signed value
#           would average out to nothing even for a strong effect)
#   signed  dx, dy, ...     tests asymmetry (is one direction worse?)
# plus the collapsed magnitudes (total distance, in-plane distance, total
# angle, tilt, twist).
#
# PER PARTICIPANT (os_participant_stats), on the ANALYSIS SET (on-target
# pulses by default), for each pulse class (and class x ISI) and predictor:
#   log_mep     lm(log(MEP) ~ predictor + stratum)     stratum = ISI x MSO
#               (pulses from either coil at the same ISI and MSO share one)
#               The slope is the WITHIN-stratum effect: MEP change per mm or
#               per degree at identical stimulation. Reported with 95% CI,
#               p, and as % MEP change per unit = 100*(exp(slope)-1).
#   rho_within  Spearman correlation inside each stratum (>= 4 pulses),
#               pooled with weights n-3: a distribution-free check.
#   mep_present logistic regression of "an MEP was present" (>= present_mv)
#               on the predictor + stratum; log odds per unit.
#   tracked_mso PRIMARY for threshold-tracked pulses (T-SICI block):
#               lm(MSO ~ predictor + elapsed_min + coil:ISI). The tracker
#               raises the intensity when the coil is off target, so the
#               tracked intensity is the sensitive outcome there. The time
#               trend absorbs slow drift of the threshold; coil:ISI absorbs
#               the SICI effect on threshold and the coils' different
#               efficiency. The coils do NOT count as one here: the outcome
#               is a stimulator setting, not an EMG value, and without the
#               coil term a between-coil difference in intensity reads as an
#               offset effect whenever the coils sat differently. Reported in
#               % MSO per unit.
#
# GROUP (os_group_two_stage, os_group_mixed)
#   two_stage   per-participant slopes combined two ways: their plain mean
#               (SE, one-sample t test) and a DerSimonian-Laird random-effects
#               mean weighted by each slope's precision (tau^2, I^2).
#   mixed       lmerTest::lmer on the pooled pulses:
#                 log_mep ~ pred + (1 + pred | participant) + (1 | stratum)
#                 mso     ~ pred + elapsed_min + (1 + pred | participant) + (1 | ci_stratum)
#               falling back to a random intercept per participant when the
#               random slope is singular.
# =====================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
  library(purrr)
})

os_predictors <- function() {
  bind_rows(
    OS_DOF %>% mutate(predictor = paste0("abs_", var), form = "abs",
                      pred_label = paste0("|", label, "|")),
    OS_DOF %>% mutate(predictor = var, form = "signed", pred_label = label),
    OS_MAG %>% mutate(predictor = var, form = "magnitude", pred_label = label)
  ) %>% select(predictor, dof = var, form, pred_label, unit)
}

.os_empty_stat <- function() tibble(
  outcome = character(), n = integer(), n_strata = integer(), estimate = double(),
  se = double(), ci_lo = double(), ci_hi = double(), p = double(),
  pct_change_per_unit = double(), rho_within = double(), n_strata_rho = integer(),
  note = character())

.os_lm_row <- function(m, term, outcome, n, n_strata, pct = TRUE, rho = NA_real_,
                       n_rho = NA_integer_, note = "") {
  co <- summary(m)$coefficients
  if (!term %in% rownames(co) || !is.finite(co[term, "Estimate"])) return(NULL)
  ci <- tryCatch(suppressMessages(confint(m)[term, ]),
                 error = function(e) co[term, "Estimate"] + c(-1.96, 1.96) * co[term, "Std. Error"])
  pcol <- grep("^Pr\\(", colnames(co), value = TRUE)[1L]
  tibble(outcome = outcome, n = n, n_strata = n_strata,
         estimate = co[term, "Estimate"], se = co[term, "Std. Error"],
         ci_lo = ci[[1L]], ci_hi = ci[[2L]], p = co[term, pcol],
         pct_change_per_unit = if (pct) 100 * (exp(co[term, "Estimate"]) - 1) else NA_real_,
         rho_within = rho, n_strata_rho = n_rho, note = note)
}

#' Fit the within-stratum models for one predictor on one subset of pulses.
os_fit_predictor <- function(d, predictor, min_pulses = 8L) {
  d <- d %>% filter(is.finite(.data[[predictor]])) %>%
    mutate(pred = .data[[predictor]], stratum_f = factor(stratum), ci_f = factor(ci_stratum))
  rows <- list()

  # -- log MEP, stratum-adjusted --------------------------------------
  da <- d %>% filter(is.finite(log_ptp))
  n <- nrow(da); ns <- n_distinct(da$stratum_f)
  if (n >= min_pulses && sd(da$pred) > 0) {
    f <- if (ns > 1L) log_ptp ~ pred + stratum_f else log_ptp ~ pred
    m <- try(lm(f, data = da), silent = TRUE)
    if (!inherits(m, "try-error")) {
      rho <- da %>% group_by(stratum_f) %>%
        filter(n() >= 4L, sd(pred) > 0, sd(log_ptp) > 0) %>%
        summarise(r = suppressWarnings(cor(pred, log_ptp, method = "spearman")), w = n() - 3,
                  .groups = "drop")
      rows$log_mep <- .os_lm_row(m, "pred", "log_mep", n, ns,
                                 rho = if (nrow(rho)) sum(rho$r * rho$w) / sum(rho$w) else NA_real_,
                                 n_rho = nrow(rho))
    }
    if (is.null(rows$log_mep))
      rows$log_mep <- .os_empty_stat() %>%
        add_row(outcome = "log_mep", n = n, n_strata = ns, note = "lm failed / collinear with strata")

    # -- MEP present (logistic) ---------------------------------------
    if (n_distinct(da$mep_present) == 2L) {
      fg <- if (ns > 1L) mep_present ~ pred + stratum_f else mep_present ~ pred
      g <- suppressWarnings(try(glm(fg, data = da, family = binomial()), silent = TRUE))
      if (!inherits(g, "try-error")) {
        co <- summary(g)$coefficients
        if ("pred" %in% rownames(co) && is.finite(co["pred", "Std. Error"]) && co["pred", "Std. Error"] < 50) {
          rows$present <- tibble(
            outcome = "mep_present", n = n, n_strata = ns,
            estimate = co["pred", "Estimate"], se = co["pred", "Std. Error"],
            ci_lo = co["pred", "Estimate"] - 1.96 * co["pred", "Std. Error"],
            ci_hi = co["pred", "Estimate"] + 1.96 * co["pred", "Std. Error"],
            p = co["pred", "Pr(>|z|)"], pct_change_per_unit = 100 * (exp(co["pred", "Estimate"]) - 1),
            rho_within = NA_real_, n_strata_rho = NA_integer_,
            note = "log odds per unit; pct = odds change")
        }
      }
    }
  } else {
    rows$log_mep <- .os_empty_stat() %>%
      add_row(outcome = "log_mep", n = n, n_strata = ns, note = "too few pulses")
  }

  # -- tracked intensity (threshold-tracked pulses only) ---------------
  dt <- d %>% filter(tracked, is.finite(mso), is.finite(elapsed_min))
  if (nrow(dt) >= min_pulses && n_distinct(dt$mso) >= 3L && sd(dt$pred) > 0) {
    nci <- n_distinct(dt$ci_f)
    f <- if (nci > 1L) mso ~ pred + elapsed_min + ci_f else mso ~ pred + elapsed_min
    mm <- try(lm(f, data = dt), silent = TRUE)
    if (!inherits(mm, "try-error")) {
      r <- .os_lm_row(mm, "pred", "tracked_mso", nrow(dt), nci, pct = FALSE,
                      rho = suppressWarnings(cor(dt$pred, dt$mso, method = "spearman")),
                      note = "% MSO per unit; time-trend and coil:ISI adjusted; tracked pulses only")
      if (!is.null(r)) rows$mso <- r
    }
  }
  bind_rows(rows)
}

#' All predictors x (class, class x ISI) for one participant's analysis set.
os_participant_stats <- function(pulses, min_pulses = 8L, min_mso = 5) {
  d <- pulses %>% filter(analysis_set, pulse_class %in% c("single", "paired"),
                         !is.na(mso), mso >= min_mso)
  preds <- os_predictors()
  if (nrow(d) == 0L) return(tibble())
  levels <- bind_rows(
    d %>% distinct(pulse_class) %>% mutate(isi_ms = NA_real_, level = "class"),
    d %>% distinct(pulse_class, isi_ms) %>% mutate(level = "condition")
  )
  out <- pmap_dfr(levels, function(pulse_class, isi_ms, level) {
    sub <- if (level == "class") d[d$pulse_class == pulse_class, ]
           else d[d$pulse_class == pulse_class & d$isi_ms == isi_ms, ]
    if (nrow(sub) < min_pulses) return(NULL)
    pmap_dfr(preds, function(predictor, dof, form, pred_label, unit) {
      os_fit_predictor(sub, predictor, min_pulses) %>%
        mutate(predictor = predictor, dof = dof, form = form, pred_label = pred_label, unit = unit)
    }) %>% mutate(level = level, pulse_class = pulse_class, isi_ms = isi_ms)
  })
  if (nrow(out) == 0L) return(out)
  out %>% mutate(participant = pulses$participant[1L]) %>%
    select(participant, level, pulse_class, isi_ms, predictor, dof, form, unit, outcome,
           n, n_strata, estimate, se, ci_lo, ci_hi, p, pct_change_per_unit,
           rho_within, n_strata_rho, note, pred_label)
}

#' Where the coil actually was at each kept pulse, per coil and phase.
os_placement_summary <- function(pulses, tol_mm = c(2, 3, 5), tol_deg = c(5, 10)) {
  d <- pulses %>% filter(kept, !is.na(nav_phase))
  if (nrow(d) == 0L) return(tibble())
  q <- function(x, p) as.numeric(quantile(x, p, na.rm = TRUE))
  out <- d %>% group_by(participant, coil, target, nav_phase) %>%
    summarise(
      n_pulses        = n(),
      dist_median_mm  = median(trans_dist_mm), dist_p90_mm = q(trans_dist_mm, .9),
      inplane_median_mm = median(tangential_mm),
      dz_median_mm    = median(dz_mm),
      ang_median_deg  = median(ang_dist_deg), ang_p90_deg = q(ang_dist_deg, .9),
      tilt_median_deg = median(tilt_deg), twist_median_deg = median(twist_deg),
      abs_dx_median   = median(abs(dx_mm)), abs_dy_median = median(abs(dy_mm)),
      abs_dz_median   = median(abs(dz_mm)),
      abs_rx_median   = median(abs(rx_deg)), abs_ry_median = median(abs(ry_deg)),
      abs_rz_median   = median(abs(rz_deg)),
      .groups = "drop")
  for (t in tol_mm)
    out[[sprintf("pct_within_%gmm", t)]] <- (d %>% group_by(participant, coil, target, nav_phase) %>%
      summarise(v = 100 * mean(trans_dist_mm <= t), .groups = "drop"))$v
  for (t in tol_deg)
    out[[sprintf("pct_angle_within_%gdeg", t)]] <- (d %>% group_by(participant, coil, target, nav_phase) %>%
      summarise(v = 100 * mean(ang_dist_deg <= t), .groups = "drop"))$v
  out
}

# ---- group level ----------------------------------------------------

os_meta_dl <- function(est, se) {
  ok <- is.finite(est) & is.finite(se) & se > 0
  est <- est[ok]; se <- se[ok]; k <- length(est)
  if (k == 0L) return(tibble(k = 0L))
  w <- 1 / se^2; mu_f <- sum(w * est) / sum(w)
  Q <- sum(w * (est - mu_f)^2); dfree <- k - 1
  C <- sum(w) - sum(w^2) / sum(w)
  tau2 <- if (k > 1L) max(0, (Q - dfree) / C) else 0
  w2 <- 1 / (se^2 + tau2); mu <- sum(w2 * est) / sum(w2); se_mu <- sqrt(1 / sum(w2))
  tibble(k = k, re_estimate = mu, re_se = se_mu, re_ci_lo = mu - 1.96 * se_mu,
         re_ci_hi = mu + 1.96 * se_mu, re_p = 2 * pnorm(-abs(mu / se_mu)),
         tau2 = tau2, i2 = if (k > 1L && Q > 0) max(0, (Q - dfree) / Q) else NA_real_,
         mean_slope = mean(est), sd_slope = if (k > 1L) sd(est) else NA_real_,
         se_mean = if (k > 1L) sd(est) / sqrt(k) else NA_real_,
         t_p = if (k > 2L) t.test(est)$p.value else NA_real_,
         n_positive = sum(est > 0), n_negative = sum(est < 0))
}

#' Two-stage summary of the participant-level class slopes.
.os_empty_two_stage <- function() tibble(
  pulse_class = character(), predictor = character(), dof = character(), form = character(),
  unit = character(), outcome = character(), pred_label = character(), k = integer(),
  re_estimate = double(), re_se = double(), re_ci_lo = double(), re_ci_hi = double(),
  re_p = double(), tau2 = double(), i2 = double(), mean_slope = double(), sd_slope = double(),
  se_mean = double(), t_p = double(), n_positive = integer(), n_negative = integer(),
  pct_change_per_unit = double())

.os_empty_mixed <- function() tibble(
  outcome = character(), pulse_class = character(), predictor = character(), dof = character(),
  form = character(), unit = character(), pred_label = character(), spec = character(),
  n_pulses = integer(), n_participants = integer(), n_strata = integer(), estimate = double(),
  se = double(), df = double(), p = double(), ci_lo = double(), ci_hi = double(),
  pct_change_per_unit = double(), slope_sd_between_participants = double())

os_group_two_stage <- function(stats) {
  if (nrow(stats) == 0L) return(.os_empty_two_stage())
  s <- stats %>% filter(level == "class", is.finite(estimate), is.finite(se))
  if (nrow(s) == 0L) return(.os_empty_two_stage())
  s %>% group_by(pulse_class, predictor, dof, form, unit, outcome, pred_label) %>%
    group_modify(~ os_meta_dl(.x$estimate, .x$se)) %>% ungroup() %>%
    mutate(pct_change_per_unit = ifelse(outcome %in% c("log_mep", "mep_present"),
                                        100 * (exp(re_estimate) - 1), NA_real_)) %>%
    arrange(outcome, pulse_class, form, dof)
}

#' Pooled mixed models per class x predictor, for log MEP and tracked MSO.
os_group_mixed <- function(pulses, min_participants = 3L, min_mso = 5) {
  if (!requireNamespace("lmerTest", quietly = TRUE)) {
    message("lmerTest not installed; skipping the mixed models."); return(.os_empty_mixed())
  }
  base <- pulses %>% filter(analysis_set, pulse_class %in% c("single", "paired"),
                            !is.na(mso), mso >= min_mso)
  preds <- os_predictors()
  out <- list()
  fit_one <- function(dd, formula_slope, formula_int) {
    spec <- "random slope"
    fit <- suppressMessages(suppressWarnings(try(
      lmerTest::lmer(formula_slope, data = dd,
                     control = lme4::lmerControl(check.conv.singular = "ignore")), silent = TRUE)))
    if (inherits(fit, "try-error") || lme4::isSingular(fit)) {
      spec <- "random intercept"
      fit <- suppressMessages(suppressWarnings(try(lmerTest::lmer(formula_int, data = dd), silent = TRUE)))
    }
    if (inherits(fit, "try-error")) return(NULL)
    list(fit = fit, spec = spec)
  }
  for (outcome in c("log_mep", "tracked_mso")) {
    d <- if (outcome == "log_mep") base %>% filter(is.finite(log_ptp))
         else base %>% filter(tracked, is.finite(mso), is.finite(elapsed_min))
    for (cl in unique(d$pulse_class)) {
      sub <- d[d$pulse_class == cl, ]
      if (n_distinct(sub$participant) < min_participants || nrow(sub) < 30L) next
      for (k in seq_len(nrow(preds))) {
        pr <- preds$predictor[k]
        dd <- sub %>% filter(is.finite(.data[[pr]])) %>%
          mutate(pred = .data[[pr]], participant = factor(participant),
                 stratum = factor(stratum), ci_stratum = factor(ci_stratum))
        if (nrow(dd) < 30L || sd(dd$pred) == 0) next
        r <- if (outcome == "log_mep") {
          fit_one(dd, log_ptp ~ pred + (1 + pred | participant) + (1 | stratum),
                      log_ptp ~ pred + (1 | participant) + (1 | stratum))
        } else {
          fit_one(dd, mso ~ pred + elapsed_min + (1 + pred | participant) + (1 | ci_stratum),
                      mso ~ pred + elapsed_min + (1 | participant) + (1 | ci_stratum))
        }
        if (is.null(r)) next
        co <- summary(r$fit)$coefficients
        if (!"pred" %in% rownames(co)) next
        vc <- as.data.frame(lme4::VarCorr(r$fit))
        sl_sd <- vc$sdcor[vc$grp == "participant" & vc$var1 == "pred" & is.na(vc$var2)]
        out[[length(out) + 1L]] <- tibble(
          outcome = outcome, pulse_class = cl, predictor = pr, dof = preds$dof[k],
          form = preds$form[k], unit = preds$unit[k], pred_label = preds$pred_label[k],
          spec = r$spec, n_pulses = nrow(dd), n_participants = n_distinct(dd$participant),
          n_strata = if (outcome == "log_mep") n_distinct(dd$stratum) else n_distinct(dd$ci_stratum),
          estimate = co["pred", "Estimate"], se = co["pred", "Std. Error"],
          df = co["pred", "df"], p = co["pred", "Pr(>|t|)"],
          ci_lo = co["pred", "Estimate"] - 1.96 * co["pred", "Std. Error"],
          ci_hi = co["pred", "Estimate"] + 1.96 * co["pred", "Std. Error"],
          pct_change_per_unit = if (outcome == "log_mep") 100 * (exp(co["pred", "Estimate"]) - 1) else NA_real_,
          slope_sd_between_participants = if (length(sl_sd)) sl_sd else NA_real_)
      }
    }
  }
  if (!length(out)) return(.os_empty_mixed())
  bind_rows(out)
}
