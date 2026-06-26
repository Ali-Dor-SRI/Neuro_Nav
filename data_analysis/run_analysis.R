# =====================================================================
# run_analysis.R   (orchestrator for the neuronav + TMS MEP workflow)
#
# Single entry point. Set the seven per-session INPUTS and the OUTPUT paths
# below, then run this file. It drives the three stage scripts in order,
# reusing their math:
#   clean_mep_times.R       -> mep_clean   (MEP ptp + trigger_time)
#   coil_to_sample_delta.R  -> coil_dist   (coil distance/angle to the target)
#   mep_vs_coil_distance.R  -> analysis    (per-MEP, nearest coil pose at trigger)
#
# Outputs:
#   * a stats-ready CSV  (one row per clean MEP: delta distance, delta angle, ptp)
#   * MEP size vs time           (raw ptp)
#   * log(MEP) vs delta distance (LOESS)
#   * log(MEP) vs delta angle    (LOESS)
#
# To run another participant, change only the INPUTS and OUTPUTS blocks.
# =====================================================================

# ---- INPUTS (edit per participant / session) ------------------------
XLSX_PATH        <- "Y:/Merged Data/xlsx Data/SNBR-169-MT-FU1-TP3C60625B.xlsx"  # QtracP MEP export
QLG_PATH         <- "Y:/Merged Data/Data/TP3C60625B.QLG"                        # QtracS run log
NEURONAV_PATH    <- "Y:/Neuro_Nav_App/data/SNBR-169.txt"                        # Brainsight stream
WINDOW_LOW       <- 36.69168472    # elapsed-time window low  (minutes)
WINDOW_HIGH      <- 43.96465302    # elapsed-time window high (minutes)
CLOCK_OFFSET_SEC <- 0.837211       # Windows -> Mac clock offset (seconds)
SAMPLE_NAME      <- "Sample 5"     # Target Selection name to measure distance from

# ---- OUTPUTS (change paths freely) ----------------------------------
PROJECT_ROOT <- "Y:/Neuro_Nav_App"
PARTICIPANT  <- "SNBR-169"                                  # label for output filenames
OUT_DIR      <- file.path(PROJECT_ROOT, "data_analysis", "output")

OUT_CSV    <- file.path(OUT_DIR, paste0(PARTICIPANT, "_mep_coil.csv"))
PLOT_TIME  <- file.path(OUT_DIR, paste0(PARTICIPANT, "_mep_vs_time.png"))
PLOT_DIST  <- file.path(OUT_DIR, paste0(PARTICIPANT, "_logmep_vs_distance.png"))
PLOT_ANGLE <- file.path(OUT_DIR, paste0(PARTICIPANT, "_logmep_vs_angle.png"))
# ---------------------------------------------------------------------

# ---- remaining paths resolved from PROJECT_ROOT ---------------------
ANALYSIS_DIR <- file.path(PROJECT_ROOT, "data_analysis")
PARSER_PATH  <- file.path(ANALYSIS_DIR, "R", "parse_brainsight.R")
SCRIPT_MEP   <- file.path(ANALYSIS_DIR, "clean_mep_times.R")
SCRIPT_COIL  <- file.path(ANALYSIS_DIR, "coil_to_sample_delta.R")
SCRIPT_MERGE <- file.path(ANALYSIS_DIR, "mep_vs_coil_distance.R")

# Tell the stage scripts they are orchestrated: they compute their data frames
# but skip their own standalone plots/prints -- this script owns all outputs.
ORCHESTRATED <- TRUE
FIT_MODELS   <- FALSE

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
})
options(digits.secs = 3)

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- run the pipeline (reuses repo math) ----------------------------
# mep_vs_coil_distance.R sources the other two stages and builds `analysis`:
#   trigger_time, mep, log_mep, coil, trans_dist_mm, ang_dist_deg, match_gap_s
# (one row per MEP with a trustworthy coil pose at its trigger time).
source(SCRIPT_MERGE)

# ---- 1. stats-ready CSV ---------------------------------------------
out_tbl <- analysis %>%
  transmute(
    trigger_time      = format(trigger_time, "%Y-%m-%d %H:%M:%OS3"),
    coil,
    delta_distance_mm = trans_dist_mm,
    delta_angle_deg   = ang_dist_deg,
    mep_ptp           = mep
  )
write.csv(out_tbl, OUT_CSV, row.names = FALSE)
message(sprintf("CSV written      : %s  (%d MEPs)", OUT_CSV, nrow(out_tbl)))

# ---- 2. plots -------------------------------------------------------
# (a) MEP size across time -- RAW ptp, all windowed MEPs (mep_clean)
p_time <- ggplot(mep_clean, aes(x = corrected_time, y = ptp)) +
  geom_point(size = 2, alpha = 0.8, colour = "#2c7fb8") +
  scale_x_datetime(date_labels = "%H:%M:%OS1") +
  labs(title = sprintf("%s  -  MEP size across time", PARTICIPANT),
       x = "MEP time (wall clock)", y = "MEP peak-to-peak (mV)") +
  theme_minimal(base_size = 12)

# (b) log(MEP) vs delta distance, (c) log(MEP) vs delta angle -- LOESS, clean set
p_dist <- ggplot(analysis, aes(x = trans_dist_mm, y = log_mep)) +
  geom_point(size = 2, alpha = 0.75, colour = "#2c7fb8") +
  geom_smooth(method = "loess", se = TRUE, colour = "#d95f0e", fill = "#fec44f") +
  labs(title = sprintf("%s  -  log(MEP) vs. distance from target", PARTICIPANT),
       x = "Delta distance from target (mm)", y = "log(MEP peak-to-peak)") +
  theme_minimal(base_size = 12)

p_angle <- ggplot(analysis, aes(x = ang_dist_deg, y = log_mep)) +
  geom_point(size = 2, alpha = 0.75, colour = "#2c7fb8") +
  geom_smooth(method = "loess", se = TRUE, colour = "#d95f0e", fill = "#fec44f") +
  labs(title = sprintf("%s  -  log(MEP) vs. angle from target", PARTICIPANT),
       x = "Delta angle from target (deg)", y = "log(MEP peak-to-peak)") +
  theme_minimal(base_size = 12)

ggsave(PLOT_TIME,  p_time,  width = 8, height = 5, dpi = 150)
ggsave(PLOT_DIST,  p_dist,  width = 7, height = 5, dpi = 150)
ggsave(PLOT_ANGLE, p_angle, width = 7, height = 5, dpi = 150)
message(sprintf("Plots written    : %s | %s | %s", PLOT_TIME, PLOT_DIST, PLOT_ANGLE))
message("run_analysis.R done.")
