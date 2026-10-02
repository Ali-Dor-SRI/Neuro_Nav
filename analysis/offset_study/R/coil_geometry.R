# =====================================================================
# coil_geometry.R  --  6-DoF coil offset relative to a target pose
#
# CONVENTION (verified on SNBR-157/169/179/188): Brainsight writes each pose
# as a position plus nine direction cosines m0n0..m2n2 in ROW-MAJOR order.
# Read as a 3x3 matrix M, the ROWS of M are the tool's own x, y, z axes
# expressed in world (MNI) coordinates, and row 3 is the coil's outward
# normal (it points away from the head centre, dot ~ +1.0 in every
# recording). So for a vector v:
#     v_local = M %*% v_world          v_world = t(M) %*% v_local
#
# The offset of a coil pose (p_c, M_c) from a target pose (p_t, M_t) is
# expressed in the TARGET's frame, which makes the six numbers physical:
#
#   dx_mm, dy_mm   in-plane shift along the target's own x and y axes
#   dz_mm          shift along the target normal (+ = coil lifted away from
#                  the head, - = pressed in / deeper than the target)
#   rx_deg, ry_deg tilt of the coil about the target's x and y axes
#   rz_deg         twist (yaw) of the coil about the target normal, i.e. a
#                  rotation of the handle within the tangent plane
#
# The rotation R = M_t %*% t(M_c) maps coil-local to target-local coordinates;
# (rx, ry, rz) is its rotation vector (axis x angle) in the target frame. Its
# length is the single geodesic angle between the two orientations, the same
# `ang_dist_deg` the rest of the repo reports; sqrt(dx^2+dy^2+dz^2) is the
# same `trans_dist_mm`.
# =====================================================================

OS_ROT_COLS <- c("m0n0", "m0n1", "m0n2", "m1n0", "m1n1", "m1n2", "m2n0", "m2n1", "m2n2")

os_mat <- function(m9) matrix(as.numeric(m9), nrow = 3L, ncol = 3L, byrow = TRUE)

#' Rotation matrix -> rotation vector (degrees), axis x angle.
os_rotvec_deg <- function(R) {
  cos_t <- (sum(diag(R)) - 1) / 2
  theta <- acos(max(-1, min(1, cos_t)))
  skew  <- c(R[3, 2] - R[2, 3], R[1, 3] - R[3, 1], R[2, 1] - R[1, 2])
  if (theta < 1e-6) return(skew / 2 * 180 / pi)             # small-angle limit
  if (abs(pi - theta) < 1e-4) {                              # ~180 deg: axis from R + I
    A <- (R + diag(3)) / 2
    ax <- sqrt(pmax(diag(A), 0)); ax <- ax / sqrt(sum(ax^2))
    return(ax * theta * 180 / pi)
  }
  (skew / (2 * sin(theta))) * theta * 180 / pi
}

#' 6-DoF offset of one coil pose from a target pose (see header).
#' @param p_c,m9_c coil position (3) and 9 row-major cosines
#' @param p_t,m9_t target position (3) and 9 row-major cosines
os_offset_6dof <- function(p_c, m9_c, p_t, m9_t) {
  Mt <- os_mat(m9_t); Mc <- os_mat(m9_c)
  d_local <- as.numeric(Mt %*% (as.numeric(p_c) - as.numeric(p_t)))
  rv      <- os_rotvec_deg(Mt %*% t(Mc))
  c(dx_mm = d_local[1], dy_mm = d_local[2], dz_mm = d_local[3],
    rx_deg = rv[1], ry_deg = rv[2], rz_deg = rv[3])
}

#' Chordal (L2) mean of rotation matrices on SO(3), via orthogonal Procrustes:
#' average the matrices element-wise, then project back to the nearest proper
#' rotation with an SVD (the raw element-wise mean is not itself a rotation).
#' `mats` is a list of 3x3 matrices; returns a single 3x3 rotation matrix.
os_rot_average <- function(mats) {
  M <- Reduce(`+`, mats) / length(mats)
  s <- svd(M)
  R <- s$u %*% t(s$v)
  if (det(R) < 0) {                 # reflection -> flip least-significant axis
    s$u[, 3] <- -s$u[, 3]
    R <- s$u %*% t(s$v)
  }
  R
}

#' Average a set of pose rows (columns loc_x, loc_y, loc_z, m0n0..m2n2) into
#' one pose: position = arithmetic mean, orientation = chordal SVD mean.
#' @return list(pos = c(x, y, z), rot = 9 row-major cosines)
os_avg_pose <- function(rows) {
  mats <- lapply(seq_len(nrow(rows)), function(k) os_mat(as.numeric(rows[k, OS_ROT_COLS])))
  list(pos = c(mean(rows$loc_x), mean(rows$loc_y), mean(rows$loc_z)),
       rot = as.numeric(t(os_rot_average(mats))))
}

#' Vectorised over a pose table (columns loc_x, loc_y, loc_z, m0n0..m2n2).
#' Returns a data.frame with the six DoF plus the collapsed magnitudes.
os_offsets_table <- function(poses, target) {
  n <- nrow(poses)
  out <- matrix(NA_real_, n, 6L,
                dimnames = list(NULL, c("dx_mm", "dy_mm", "dz_mm", "rx_deg", "ry_deg", "rz_deg")))
  if (n == 0L) return(as.data.frame(out))
  P  <- as.matrix(poses[, c("loc_x", "loc_y", "loc_z")])
  Ms <- as.matrix(poses[, OS_ROT_COLS])
  Mt <- os_mat(target$rot); pt <- as.numeric(target$pos)
  for (i in seq_len(n)) {
    Mc <- matrix(Ms[i, ], 3L, 3L, byrow = TRUE)
    d  <- Mt %*% (P[i, ] - pt)
    rv <- os_rotvec_deg(Mt %*% t(Mc))
    out[i, ] <- c(d, rv)
  }
  out <- as.data.frame(out)
  out$trans_dist_mm <- sqrt(out$dx_mm^2 + out$dy_mm^2 + out$dz_mm^2)
  out$tangential_mm <- sqrt(out$dx_mm^2 + out$dy_mm^2)
  out$ang_dist_deg  <- sqrt(out$rx_deg^2 + out$ry_deg^2 + out$rz_deg^2)
  out$tilt_deg      <- sqrt(out$rx_deg^2 + out$ry_deg^2)
  out$twist_deg     <- abs(out$rz_deg)
  out
}

# The six signed DoF, the |DoF| forms, and the collapsed magnitudes, with the
# labels the plots and tables use.
OS_DOF <- tibble::tibble(
  var   = c("dx_mm", "dy_mm", "dz_mm", "rx_deg", "ry_deg", "rz_deg"),
  label = c("x shift (in-plane, coil x)", "y shift (in-plane, coil y)",
            "z shift (along normal; + = lifted)",
            "tilt about x", "tilt about y", "twist about normal"),
  unit  = c("mm", "mm", "mm", "deg", "deg", "deg")
)
OS_MAG <- tibble::tibble(
  var   = c("trans_dist_mm", "tangential_mm", "ang_dist_deg", "tilt_deg", "twist_deg"),
  label = c("total distance", "in-plane distance", "total angle", "tilt", "twist"),
  unit  = c("mm", "mm", "deg", "deg", "deg")
)
