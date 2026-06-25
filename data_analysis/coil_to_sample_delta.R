# =====================================================================
# coil_to_sample_delta.R   (neuronav side of the MEP analysis)
#
# Goal: load a Brainsight streamed-info .txt, pull the coil's 6-DoF pose in
# MNI space over time, and express every frame as a delta from a chosen
# reference sample (here "Sample 5"). Keeps the data frame in R -- no export
# yet; later stages will bind this to the MEP table from clean_mep_times.R.
#
# Output data frame `coil_delta` columns:
#   time                                  POSIXct (ms precision)
#   x, y, z                               coil position, MNI millimetres
#   yaw, pitch, roll                      coil orientation, degrees (ZYX)
#   dx, dy, dz                            coil - sample position    (mm)
#   dyaw, dpitch, droll                   coil - sample orientation (deg, wrapped)
#
# NOTE: the SAMPLE5 reference block and the coil selection in CONFIG are
# SPECIFIC TO THIS FILE/SESSION. They are hard-coded here on purpose; a later
# stage will import them automatically.
# =====================================================================

# ---- CONFIG (edit per session) --------------------------------------
NEURONAV_PATH <- "Y:/Neuro_Nav_App/data/SNBR-169.txt"
PARSER_PATH   <- "Y:/Neuro_Nav_App/R/parse_brainsight.R"

# Which streamed object is "the coil", and in which coordinate system.
#   Crosshairs Position / "Coil B LCT"  -> the navigated coil pose (default;
#                                          matches what a New Sample records)
#   Polaris Tool       / "LCT650"       -> the raw coil-tracker pose
COIL_ROW_TYPE <- "Crosshairs Position"
COIL_NAME     <- "Coil B LCT"
COORD_SYSTEM  <- "MNI"

# Reference sample ("Sample 5") -- pasted straight from the New Sample row.
# Position (MNI mm) then the 3x3 direction-cosine matrix in row-major order
# (m0n0, m0n1, m0n2, m1n0, ... m2n2), exactly as the file lists them.
#   New Sample  2026-06-25  12:21:14.764  Sample 2  2  MNI
#     -42.497776656  21.958414663  85.263902056
#      0.573941509 -0.556358560  0.600879603
#      0.718879569  0.693719589 -0.044331664
#     -0.392177651  0.457403852  0.798109270   Sample 5
SAMPLE5_POS <- c(x = -42.497776656, y = 21.958414663, z = 85.263902056)
SAMPLE5_ROT <- c( 0.573941509, -0.556358560,  0.600879603,
                  0.718879569,  0.693719589, -0.044331664,
                 -0.392177651,  0.457403852,  0.798109270)
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

# ---- 2. coil 6-DoF pose over time (MNI) -----------------------------
coil <- coil_raw %>%
  filter(.data[[name_col]] == COIL_NAME, coord_system == COORD_SYSTEM) %>%
  filter(if_all(all_of(pos_cols), ~ !is.na(.)))

if (nrow(coil) == 0L)
  stop("No frames for ", COIL_NAME, " in ", COORD_SYSTEM, " space.")

ypr <- t(apply(as.matrix(coil[, rot_cols]), 1, rot_to_ypr))   # n x 3 (deg)

coil6 <- tibble(
  time  = coil$datetime,
  x     = coil[[pos_cols[1]]],
  y     = coil[[pos_cols[2]]],
  z     = coil[[pos_cols[3]]],
  yaw   = ypr[, "yaw"],
  pitch = ypr[, "pitch"],
  roll  = ypr[, "roll"]
)

# ---- 3. reference sample ("Sample 5") 6-DoF -------------------------
s5_ypr <- rot_to_ypr(SAMPLE5_ROT)
sample5 <- c(SAMPLE5_POS["x"], SAMPLE5_POS["y"], SAMPLE5_POS["z"],
             yaw = s5_ypr["yaw"], pitch = s5_ypr["pitch"], roll = s5_ypr["roll"])

# ---- 4. per-DoF delta: coil - sample --------------------------------
coil_delta <- coil6 %>%
  mutate(
    dx     = x     - SAMPLE5_POS["x"],
    dy     = y     - SAMPLE5_POS["y"],
    dz     = z     - SAMPLE5_POS["z"],
    dyaw   = wrap_deg(yaw   - s5_ypr["yaw"]),
    dpitch = wrap_deg(pitch - s5_ypr["pitch"]),
    droll  = wrap_deg(roll  - s5_ypr["roll"])
  )

# ---- 5. collapse the 6 DoF into two intuitive distances -------------
# Translational distance = Euclidean norm of the position delta (mm).
# Angular distance       = the single rotation angle between the coil and
#                          sample orientations (deg), from the raw rotation
#                          matrices (not the Euler columns).
ang_dist <- apply(as.matrix(coil[, rot_cols]), 1,
                  function(r) rot_angle_deg(r, SAMPLE5_ROT))

coil_dist <- tibble(
  time          = coil6$time,
  trans_dist_mm = sqrt(coil_delta$dx^2 + coil_delta$dy^2 + coil_delta$dz^2),
  ang_dist_deg  = ang_dist
)

# ---- report ---------------------------------------------------------
message(sprintf("Coil source  : %s / '%s'  (%s)", COIL_ROW_TYPE, COIL_NAME, COORD_SYSTEM))
message(sprintf("Coil frames  : %d", nrow(coil_delta)))
message(sprintf("Sample 5 pos : x=%.3f  y=%.3f  z=%.3f  (mm)",
                SAMPLE5_POS["x"], SAMPLE5_POS["y"], SAMPLE5_POS["z"]))
message(sprintf("Sample 5 ypr : yaw=%.2f  pitch=%.2f  roll=%.2f  (deg)",
                s5_ypr["yaw"], s5_ypr["pitch"], s5_ypr["roll"]))
print(head(coil_delta, 10L))

message(sprintf("Collapsed distances (coil_dist): trans %.1f-%.1f mm | ang %.1f-%.1f deg",
                min(coil_dist$trans_dist_mm), max(coil_dist$trans_dist_mm),
                min(coil_dist$ang_dist_deg),  max(coil_dist$ang_dist_deg)))
print(head(coil_dist, 10L))

# `coil_delta` (per-DoF) and `coil_dist` (collapsed translational + angular
# distance) are left in the R session for the next stage (no data export).
