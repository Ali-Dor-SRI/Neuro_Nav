# parse_brainsight.R
# ------------------
# Parser for Brainsight streamed-info text files (.txt).
#
# Usage
# -----
#   source("parse_brainsight.R")
#
#   tables     <- parse_brainsight("Session 3  Streamed Info.txt")
#
#   df_coil    <- tables[["Polaris Tool"]]
#   df_samples <- tables[["New Sample"]]
#   df_emg     <- tables[["New EMG"]]
#
# Returns
# -------
# Named list of data.frames, one per row type (see BRAINSIGHT_SCHEMAS).
# Absent row types return a zero-row data.frame with the correct columns.
# "(null)" values become NA.
# Numeric columns are cast to double.
# An extra "_metadata" element holds the key-value pairs from the header.


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

BRAINSIGHT_SCHEMAS <- list(
  "Polaris Tool" = c(
    "row_type", "date", "time", "frame_number", "tracker_name",
    "coord_system", "x", "y", "z",
    "m0n0", "m0n1", "m0n2",
    "m1n0", "m1n1", "m1n2",
    "m2n0", "m2n1", "m2n2"
  ),
  "TTL Trigger" = c(
    "row_type", "date", "time", "trigger_name"
  ),
  "New Sample" = c(
    "row_type", "date", "time", "sample_name", "index",
    "coord_system", "loc_x", "loc_y", "loc_z",
    "m0n0", "m0n1", "m0n2",
    "m1n0", "m1n1", "m1n2",
    "m2n0", "m2n1", "m2n2",
    "assoc_target"
  ),
  "New EMG" = c(
    "row_type", "date", "time", "sample_name", "index",
    "emg_peak_to_peak_1", "emg_peak_to_peak_2",
    "emg_latency_1", "emg_latency_2",
    "emg_window_start", "emg_window_end",
    "emg_data_1", "emg_data_2"
  ),
  "Target Selection" = c(
    "row_type", "date", "time", "target_name",
    "coord_system", "loc_x", "loc_y", "loc_z",
    "m0n0", "m0n1", "m0n2",
    "m1n0", "m1n1", "m1n2",
    "m2n0", "m2n1", "m2n2"
  ),
  "Crosshairs Position" = c(
    "row_type", "date", "time", "crosshairs_driver",
    "coord_system", "loc_x", "loc_y", "loc_z",
    "m0n0", "m0n1", "m0n2",
    "m1n0", "m1n1", "m1n2",
    "m2n0", "m2n1", "m2n2"
  )
)

.BRAINSIGHT_FLOAT_COLS <- c(
  "x", "y", "z",
  "loc_x", "loc_y", "loc_z",
  "m0n0", "m0n1", "m0n2",
  "m1n0", "m1n1", "m1n2",
  "m2n0", "m2n1", "m2n2",
  "emg_peak_to_peak_1", "emg_peak_to_peak_2",
  "emg_latency_1", "emg_latency_2",
  "emg_window_start", "emg_window_end"
)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#' Parse a Brainsight streamed-info text file.
#'
#' @param path         Path to the .txt file exported by Brainsight.
#' @param parse_datetime  If TRUE (default), combine 'date' and 'time' into a
#'                     single POSIXct 'datetime' column (ms precision).
#' @param drop_null_rows  If TRUE, drop rows where all positional columns
#'                     (x/y/z or loc_x/loc_y/loc_z) are NA — i.e. frames
#'                     where the tracker was not visible.
#'
#' @return Named list of data.frames, one per row type, plus "_metadata".

parse_brainsight <- function(path,
                             parse_datetime   = TRUE,
                             drop_null_rows   = FALSE) {

  raw_lines  <- readLines(path, encoding = "UTF-8", warn = FALSE)
  meta_lines <- raw_lines[startsWith(raw_lines, "#")]
  data_lines <- raw_lines[!startsWith(raw_lines, "#") & nzchar(raw_lines)]

  metadata <- .parse_bs_metadata(meta_lines)

  result <- lapply(names(BRAINSIGHT_SCHEMAS), function(rt) {
    cols <- BRAINSIGHT_SCHEMAS[[rt]]
    rows <- data_lines[startsWith(data_lines, rt)]

    if (length(rows) == 0L) {
      # Return empty data.frame with correct columns
      empty <- as.data.frame(
        matrix(character(0), nrow = 0, ncol = length(cols)),
        stringsAsFactors = FALSE
      )
      colnames(empty) <- cols
      return(empty)
    }

    parsed <- lapply(rows, function(r) {
      parts <- strsplit(r, "\t", fixed = TRUE)[[1L]]
      length(parts) <- length(cols)   # pad / trim to schema width
      parts
    })

    df <- as.data.frame(
      do.call(rbind, parsed),
      stringsAsFactors = FALSE
    )
    colnames(df) <- cols

    # "(null)" -> NA
    df[df == "(null)"] <- NA

    # Cast numeric columns
    for (col in intersect(cols, .BRAINSIGHT_FLOAT_COLS)) {
      df[[col]] <- as.numeric(df[[col]])
    }

    # Combine date + time into a datetime column
    if (isTRUE(parse_datetime) &&
        all(c("date", "time") %in% names(df))) {
      dt <- as.POSIXct(
        paste(df$date, df$time),
        format = "%Y-%m-%d %H:%M:%OS",
        tz     = ""
      )
      # Insert datetime as 4th column (after row_type, date, time)
      df <- cbind(df[, 1:3, drop = FALSE],
                  datetime = dt,
                  df[, 4:ncol(df), drop = FALSE])
    }

    if (isTRUE(drop_null_rows)) {
      pos_cols <- intersect(c("x", "y", "z", "loc_x", "loc_y", "loc_z"),
                            names(df))
      if (length(pos_cols) > 0L) {
        keep <- !apply(is.na(df[, pos_cols, drop = FALSE]), 1, all)
        df   <- df[keep, , drop = FALSE]
      }
    }

    df
  })

  names(result) <- names(BRAINSIGHT_SCHEMAS)
  result[["_metadata"]] <- metadata
  result
}


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

.parse_bs_metadata <- function(comment_lines) {
  meta <- list()
  for (line in comment_lines) {
    m <- regmatches(line, regexpr("^#\\s*([^:]+):\\s*(.+)", line))
    if (length(m) == 1L) {
      parts        <- strsplit(sub("^#\\s*", "", m), ":\\s*")[[1L]]
      if (length(parts) >= 2L)
        meta[[trimws(parts[1L])]] <- trimws(paste(parts[-1L], collapse = ": "))
    }
  }
  meta
}
