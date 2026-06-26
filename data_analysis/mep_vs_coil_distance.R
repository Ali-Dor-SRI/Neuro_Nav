# =====================================================================
# mep_vs_coil_distance.R   (stage 3: MEP amplitude vs coil placement)
#
# Brings together the two earlier stages:
#   * clean_mep_times.R      -> `mep_clean`  (MEP ptp + trigger_time)
#   * coil_to_sample_delta.R -> `coil_dist`  (coil trans/ang distance to Sample 5
#                                             over time)
#
# For each MEP, the TMS pulse fired at `trigger_time`. We look up the coil's
# distance-from-target at that instant (nearest coil frame), then ask whether
# MEP amplitude depends on how far / how tilted the coil was from the target.
#
# Both clocks are aligned upstream (trigger_time and the coil stream are both on
# the Mac/Brainsight wall clock), so trigger_time is directly comparable to the
# coil frame timestamps.
#
# This stage stops at the LOESS plots on purpose -- the linear fits are gated
# behind FIT_MODELS so the shape can be eyeballed before assuming linearity.
# =====================================================================

# ---- CONFIG ---------------------------------------------------------
# Injectable via `if (!exists())` so run_analysis.R can drive this stage.
if (!exists("SCRIPT_MEP"))  SCRIPT_MEP  <- "Y:/Neuro_Nav_App/data_analysis/clean_mep_times.R"
if (!exists("SCRIPT_COIL")) SCRIPT_COIL <- "Y:/Neuro_Nav_App/data_analysis/coil_to_sample_delta.R"

if (!exists("PLOT_TRANS_PATH")) PLOT_TRANS_PATH <- "Y:/Neuro_Nav_App/data_analysis/logmep_vs_trans.png"
if (!exists("PLOT_ANG_PATH"))   PLOT_ANG_PATH   <- "Y:/Neuro_Nav_App/data_analysis/logmep_vs_ang.png"

# Largest acceptable gap (s) between a trigger time and its nearest coil frame.
# Triggers matched beyond this are flagged (tracker dropout / clock mismatch).
if (!exists("MAX_MATCH_GAP_S")) MAX_MATCH_GAP_S <- 0.10

# Fit the linear models? (LOESS plots reviewed -> fitting on the clean set.)
if (!exists("FIT_MODELS")) FIT_MODELS <- TRUE
# ---------------------------------------------------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
})
options(digits.secs = 3)

# ---- 1. pull in the data frames from both earlier scripts -----------
source(SCRIPT_MEP)    # -> mep_clean
source(SCRIPT_COIL)   # -> coil_delta, coil_dist

# ---- 2. match each TMS trigger to the nearest coil frame ------------
trig <- mep_clean %>%
  filter(!is.na(trigger_time), !is.na(ptp), ptp > 0)

# Nearest coil frame (by time) for each trigger; record the matching gap.
near_idx <- vapply(
  trig$trigger_time,
  function(tt) which.min(abs(as.numeric(difftime(coil_dist$time, tt, units = "secs")))),
  integer(1)
)
match_gap_s <- abs(as.numeric(difftime(coil_dist$time[near_idx],
                                       trig$trigger_time, units = "secs")))

# ---- 3. analysis table: log(MEP) vs coil distances ------------------
analysis_all <- tibble(
  trigger_time  = trig$trigger_time,
  mep           = trig$ptp,
  log_mep       = log(trig$ptp),          # MEP ptp is ~lognormal -> log it
  coil          = coil_dist$coil[near_idx],   # coil active at the trigger
  trans_dist_mm = coil_dist$trans_dist_mm[near_idx],
  ang_dist_deg  = coil_dist$ang_dist_deg[near_idx],
  match_gap_s   = match_gap_s
)

# Drop MEPs with no trustworthy coil pose at trigger time (tracker dropout /
# the coil stream ending before the last MEPs -> nearest frame far away).
analysis <- analysis_all %>% filter(match_gap_s <= MAX_MATCH_GAP_S)
n_bad    <- nrow(analysis_all) - nrow(analysis)

message(sprintf("Triggers matched : %d  |  match gap median %.3f s, max %.3f s",
                nrow(analysis_all), median(analysis_all$match_gap_s),
                max(analysis_all$match_gap_s)))
message(sprintf("Kept (gap <= %.2fs): %d  |  dropped (no valid coil pose): %d",
                MAX_MATCH_GAP_S, nrow(analysis), n_bad))

# ---- 4. scatter + LOESS (no straight line -- don't prejudge shape) --
# Standalone only -- under run_analysis.R the orchestrator owns the plots/CSV.
if (!exists("ORCHESTRATED")) {
p_trans <- ggplot(analysis, aes(x = trans_dist_mm, y = log_mep)) +
  geom_point(size = 2, alpha = 0.75, colour = "#2c7fb8") +
  geom_smooth(method = "loess", se = TRUE, colour = "#d95f0e", fill = "#fec44f") +
  labs(
    title = "log(MEP) vs. translational distance from target",
    x     = "Translational distance from target (mm)",
    y     = "log(MEP peak-to-peak)"
  ) +
  theme_minimal(base_size = 12)

p_ang <- ggplot(analysis, aes(x = ang_dist_deg, y = log_mep)) +
  geom_point(size = 2, alpha = 0.75, colour = "#2c7fb8") +
  geom_smooth(method = "loess", se = TRUE, colour = "#d95f0e", fill = "#fec44f") +
  labs(
    title = "log(MEP) vs. angular distance from target",
    x     = "Angular distance from target (deg)",
    y     = "log(MEP peak-to-peak)"
  ) +
  theme_minimal(base_size = 12)

ggsave(PLOT_TRANS_PATH, p_trans, width = 7, height = 5, dpi = 150)
ggsave(PLOT_ANG_PATH,   p_ang,   width = 7, height = 5, dpi = 150)
message(sprintf("Plots written    : %s | %s", PLOT_TRANS_PATH, PLOT_ANG_PATH))

# ---- 5. linear fits -- GATED until the plots are reviewed -----------
# Flip FIT_MODELS to TRUE only after the LOESS shapes look roughly linear.
if (isTRUE(FIT_MODELS)) {
  report_lm <- function(m, predictor) {
    s  <- summary(m)
    co <- s$coefficients[2, ]   # the slope row
    message(sprintf("%-22s slope = %+.4f   p = %.3g   R2 = %.3f",
                    predictor, co[["Estimate"]], co[["Pr(>|t|)"]], s$r.squared))
  }
  m_trans <- lm(log_mep ~ trans_dist_mm, data = analysis)
  m_ang   <- lm(log_mep ~ ang_dist_deg,  data = analysis)
  message("\n--- linear fits (log_mep ~ distance) ---")
  report_lm(m_trans, "translational (mm)")
  report_lm(m_ang,   "angular (deg)")
}

}  # end if(!exists("ORCHESTRATED"))

# `analysis` is left in the session for the next stage.
