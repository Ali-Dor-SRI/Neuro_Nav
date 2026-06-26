library(tidyverse)
library(readr)
library(zoo)      # for rollmean
library(plotly)

schemas <- list(
  "Polaris Tool"        = c("row_type","Date","Time","Polaris_Frame_Number","Calibration_Tracker_Name","Coordinate_System","x","y","z","m0n0","m0n1","m0n2","m1n0","m1n1","m1n2","m2n0","m2n1","m2n2"),
  "TTL Trigger"         = c("row_type","Date","Time","Trigger_Name"),
  "New Sample"          = c("row_type","Date","Time","Sample_Name","Index","Coordinate_System","Loc_X","Loc_Y","Loc_Z","m0n0","m0n1","m0n2","m1n0","m1n1","m1n2","m2n0","m2n1","m2n2","Assoc_Target"),
  "New EMG"             = c("row_type","Date","Time","Sample_Name","Index","EMG_Peak_to_peak_1","EMG_Peak_to_peak_2","EMG_Latency_1","EMG_Latency_2","EMG_Window_Start","EMG_Window_End","EMG_Data_1","EMG_Data_2"),
  "Target Selection"    = c("row_type","Date","Time","Target_Name","Coordinate_System","Loc_X","Loc_Y","Loc_Z","m0n0","m0n1","m0n2","m1n0","m1n1","m1n2","m2n0","m2n1","m2n2"),
  "Crosshairs Position" = c("row_type","Date","Time","Crosshairs_Driver","Coordinate_System","Loc_X","Loc_Y","Loc_Z","m0n0","m0n1","m0n2","m1n0","m1n1","m1n2","m2n0","m2n1","m2n2")
)

lines <- readLines(
  "Y:/Neuro_Nav_App/data/Session 3  Streamed Info.txt")
data_lines <- lines[!startsWith(lines, "#") & nzchar(lines)]

parse_rows <- function(row_type) {
  cols <- schemas[[row_type]]
  rows <- data_lines[startsWith(data_lines, row_type)]
  if (length(rows) == 0) return(NULL)

  rows |>
    lapply(\(r) {
      parts <- strsplit(r, "\t")[[1]]
      length(parts) <- length(cols)
      parts
    }) |>
    do.call(rbind, args = _) |>
    as.data.frame(stringsAsFactors = FALSE) |>
    setNames(cols) |>
    mutate(across(everything(), \(x) na_if(x, "(null)")))
}

dfs <- lapply(names(schemas), parse_rows) |>
  setNames(names(schemas))

df_polaris <- dfs[["Polaris Tool"]]
df_emg     <- dfs[["New EMG"]]
df_samples <- dfs[["New Sample"]]


# ── Coil tracker data (LCT650, MNI only) ──────────────────────────────────────

df_polaris_1 <- df_polaris |>
  drop_na() |>
  filter(Calibration_Tracker_Name == "LCT650",
         Coordinate_System == "MNI") |>
  mutate(
    x        = as.numeric(x),
    y        = as.numeric(y),
    z        = as.numeric(z),
    datetime = as.POSIXct(paste(Date, Time),
                          format = "%Y-%m-%d %H:%M:%OS",
                          tz = "America/Toronto")
  )


# ── Sample 2 location ─────────────────────────────────────────────────────────

sample_point    <- data.frame(x = -52.819846711, y = -1.268766935)
sample_point_3d <- data.frame(x = -52.819846711, y = -1.268766935, z = 69.895368163)
zoom            <- 200


# ── Distance to Sample 2, + sustained-closest window ─────────────────────────
#
#  "Held near" = centre of the window with the lowest *rolling-mean* distance.
#  Window size = 200 frames (~10 s at 20 Hz) — long enough to require sustained
#  proximity rather than just a brief pass-by.

df_polaris_1 <- df_polaris_1 |>
  mutate(
    dist_to_s2  = sqrt((x - sample_point_3d$x)^2 +
                       (y - sample_point_3d$y)^2 +
                       (z - sample_point_3d$z)^2),
    roll_dist   = rollmean(dist_to_s2, k = 200, fill = NA, align = "center")
  )

# Single frame that is the centre of the most sustained close window
held_frame  <- df_polaris_1 |> slice_min(roll_dist, n = 1, with_ties = FALSE)

# For printing
cat(sprintf(
  "Closest sustained approach to Sample 2:\n  time: %s\n  position: x=%.1f  y=%.1f  z=%.1f mm\n  distance: %.1f mm  (10-s rolling mean)\n",
  format(held_frame$datetime, "%H:%M:%S"),
  held_frame$x, held_frame$y, held_frame$z,
  held_frame$roll_dist
))


# ── 2D ggplot ─────────────────────────────────────────────────────────────────

held_point_2d <- data.frame(x = held_frame$x, y = held_frame$y)

df_polaris_graph <- df_polaris_1 |>
  ggplot(aes(x = x, y = y)) +
  geom_path(color  = "steelblue", alpha = 0.6) +
  geom_point(color = "steelblue", size = 0.8, alpha = 0.4) +
  # Sample 2 target
  geom_point(data = sample_point, aes(x = x, y = y),
             color = "red", shape = 4, size = 4, stroke = 2,
             inherit.aes = FALSE) +
  # Closest sustained position
  geom_point(data = held_point_2d, aes(x = x, y = y),
             color = "darkorange", shape = 17, size = 4,
             inherit.aes = FALSE) +
  annotate("text",
           x     = held_point_2d$x,
           y     = held_point_2d$y + 8,
           label = paste0("Held ~", format(held_frame$datetime, "%H:%M:%S")),
           color = "darkorange", size = 3.5, hjust = 0) +
  coord_fixed(xlim = c(sample_point$x - zoom, sample_point$x + zoom),
              ylim = c(sample_point$y - zoom, sample_point$y + zoom)) +
  labs(title    = "2D Coil Trajectory",
       subtitle = "Red ✗ = Sample 2 target   ▲ = closest sustained coil position",
       x        = "X (mm, MNI)",
       y        = "Y (mm, MNI)") +
  theme_minimal()

df_polaris_graph
ggplotly(df_polaris_graph)


# ── 3D rotatable trajectory ───────────────────────────────────────────────────

plot_ly() |>
  # Full coil trajectory, coloured by distance to Sample 2
  add_trace(
    data   = df_polaris_1,
    x = ~x, y = ~y, z = ~z,
    type   = "scatter3d",
    mode   = "lines",
    line   = list(
      color     = ~dist_to_s2,
      colorscale = list(
        c(0,   "orange"),
        c(0.5, "steelblue"),
        c(1,   "#1a1a4e")
      ),
      width      = 2,
      colorbar   = list(title = "Distance to\nSample 2 (mm)")
    ),
    name   = "Coil path"
  ) |>
  # Sample 2 target
  add_trace(
    data   = sample_point_3d,
    x = ~x, y = ~y, z = ~z,
    type   = "scatter3d",
    mode   = "markers+text",
    marker = list(color = "red", size = 7, symbol = "cross"),
    text   = "Sample 2",
    textposition = "top center",
    textfont     = list(color = "red"),
    name   = "Sample 2"
  ) |>
  # Closest sustained coil position
  add_trace(
    data   = held_frame,
    x = ~x, y = ~y, z = ~z,
    type   = "scatter3d",
    mode   = "markers+text",
    marker = list(color = "darkorange", size = 9, symbol = "diamond"),
    text   = ~paste0("Held nearest\n", format(datetime, "%H:%M:%S")),
    textposition = "top center",
    textfont     = list(color = "darkorange"),
    name   = "Held nearest"
  ) |>
  layout(
    title  = "3D Coil Trajectory (MNI) — coloured by distance to Sample 2",
    scene  = list(
      xaxis      = list(title = "X (mm)"),
      yaxis      = list(title = "Y (mm)"),
      zaxis      = list(title = "Z (mm)"),
      aspectmode = "data"
    )
  )
