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
#   brainsight_info("Session 3  Streamed Info.txt")   # summary of a file
#   brainsight_info(tables)                           # ... or of a parsed one
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
  # Carried as an attribute rather than a list element so that names(), length()
  # and tables[[...]] are unchanged; brainsight_info() uses it to name the file.
  attr(result, "path") <- path
  result
}


# ---------------------------------------------------------------------------
# Recording summary
# ---------------------------------------------------------------------------

# Trackers this lab mounts on a TMS coil. The .txt has no field saying what a
# tracker is attached to, so this is convention, not data -- pass
# brainsight_info(coils = ...) for a session that used something else. Kept in
# step with COIL_CANDIDATES in data_analysis/coil_to_sample_delta.R.
BRAINSIGHT_COILS <- c("LCT650", "CT4661")


#' One-screen summary of a Brainsight recording.
#'
#' @param x      Path to a .txt export, or the list returned by
#'               parse_brainsight() (summarized without re-reading the file).
#' @param coils  Tracker names to report as coils (default BRAINSIGHT_COILS).
#' @param print  Print the summary. The values are returned either way.
#'
#' @param max_samples  Samples to print before "... and N more". All of them
#'               are returned regardless.
#'
#' @return Invisibly, a list: file, created_by, start, end, duration_s,
#'   duration, trackers (data.frame: name, frames, visible, first, last),
#'   tracker_names, n_trackers, coils, n_coils, other_trackers,
#'   unseen_trackers, drivers, n_drivers, samples (data.frame), n_samples,
#'   counts.
#'
#' A tracker counts as *used* only when at least one of its frames carries a
#' position. Brainsight writes a row for every configured tracker on every
#' frame whether or not the camera can see it, so counting rows would report
#' pointers and calibration blocks that were never in view.

brainsight_info <- function(x, coils = BRAINSIGHT_COILS, print = TRUE,
                            max_samples = 12L) {

  if (is.character(x) && length(x) == 1L) {
    file   <- x
    tables <- parse_brainsight(x, parse_datetime = TRUE, drop_null_rows = FALSE)
  } else if (is.list(x) && all(names(BRAINSIGHT_SCHEMAS) %in% names(x))) {
    file   <- attr(x, "path")
    tables <- x
  } else {
    stop("brainsight_info() takes a path to a Brainsight .txt, or the list ",
         "returned by parse_brainsight().")
  }
  if (is.null(file)) file <- "(parsed object)"

  polaris <- tables[["Polaris Tool"]]
  cross   <- tables[["Crosshairs Position"]]
  meta    <- tables[["_metadata"]]

  # ---- recording span: first to last timestamped row, any row type ----
  epochs <- unlist(lapply(names(BRAINSIGHT_SCHEMAS),
                          function(rt) as.numeric(.bs_times(tables[[rt]]))))
  epochs <- epochs[is.finite(epochs)]
  start  <- if (length(epochs)) .bs_epoch(min(epochs)) else as.POSIXct(NA)
  end    <- if (length(epochs)) .bs_epoch(max(epochs)) else as.POSIXct(NA)
  duration_s <- if (length(epochs)) max(epochs) - min(epochs) else NA_real_

  # ---- per-tracker frames and visible span ----
  trackers <- .bs_tracker_table(polaris)
  seen     <- trackers$name[trackers$visible > 0L]
  unseen   <- trackers$name[trackers$visible == 0L]

  coil_names  <- intersect(seen, coils)
  other_names <- setdiff(seen, coil_names)

  drivers <- if (nrow(cross) > 0L) {
    sort(unique(cross$crosshairs_driver[!is.na(cross$crosshairs_driver)]))
  } else character(0)

  samples <- .bs_sample_table(tables[["New Sample"]])

  counts <- vapply(names(BRAINSIGHT_SCHEMAS),
                   function(rt) nrow(tables[[rt]]), integer(1))

  info <- list(
    file            = file,
    created_by      = if (!is.null(meta[["Created by"]])) meta[["Created by"]] else NA_character_,
    start           = start,
    end             = end,
    duration_s      = duration_s,
    duration        = .bs_duration(duration_s),
    trackers        = trackers,
    tracker_names   = seen,
    n_trackers      = length(seen),
    coils           = coil_names,
    n_coils         = length(coil_names),
    other_trackers  = other_names,
    unseen_trackers = unseen,
    drivers         = drivers,
    n_drivers       = length(drivers),
    samples         = samples,
    n_samples       = nrow(samples),
    counts          = counts
  )

  if (isTRUE(print)) .bs_print_info(info, max_samples = max_samples)
  invisible(info)
}


# ---------------------------------------------------------------------------
# Helpers
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


# Timestamps of a row-type table, whether or not it was parsed with
# parse_datetime = TRUE.
.bs_times <- function(df) {
  if (is.null(df) || nrow(df) == 0L) return(as.POSIXct(character(0)))
  if ("datetime" %in% names(df)) return(df$datetime)
  as.POSIXct(paste(df$date, df$time), format = "%Y-%m-%d %H:%M:%OS", tz = "")
}

.bs_epoch <- function(secs) as.POSIXct(secs, origin = "1970-01-01", tz = "")


# Seconds -> "1h 04m 11s" / "40m 11s" / "7.4s".
.bs_duration <- function(secs) {
  if (!is.finite(secs)) return("unknown")
  h <- floor(secs / 3600)
  m <- floor((secs %% 3600) / 60)
  s <- secs %% 60
  if (h > 0)      sprintf("%dh %02dm %02ds", h, m, round(s))
  else if (m > 0) sprintf("%dm %02ds", m, round(s))
  else            sprintf("%.1fs", s)
}


# One row per tracker in the Polaris Tool stream: how many frames it appears
# in, how many of those carry a position, and the span it was actually visible
# for. The visible span is what exposes a coil swap mid-session.
.bs_tracker_table <- function(polaris) {
  empty <- data.frame(name = character(0), frames = integer(0),
                      visible = integer(0),
                      first = as.POSIXct(character(0)),
                      last  = as.POSIXct(character(0)),
                      stringsAsFactors = FALSE)
  if (is.null(polaris) || nrow(polaris) == 0L) return(empty)

  times <- .bs_times(polaris)
  pos   <- intersect(c("x", "y", "z"), names(polaris))
  has_pos <- if (length(pos) == 0L) rep(FALSE, nrow(polaris)) else
    !apply(is.na(polaris[, pos, drop = FALSE]), 1, all)

  by_name <- split(seq_len(nrow(polaris)), polaris$tracker_name)
  out <- do.call(rbind, lapply(names(by_name), function(nm) {
    idx <- by_name[[nm]]
    vis <- idx[has_pos[idx]]
    data.frame(name    = nm,
               frames  = length(idx),
               visible = length(vis),
               first   = if (length(vis)) min(times[vis]) else as.POSIXct(NA),
               last    = if (length(vis)) max(times[vis]) else as.POSIXct(NA),
               stringsAsFactors = FALSE)
  }))
  out <- out[order(out$name), , drop = FALSE]
  rownames(out) <- NULL
  out
}


# The samples registered during the recording ("New Sample" rows), in the
# order Brainsight wrote them. Not the same set as the targets *selected*
# during the session: a Target Selection can name a sample registered in an
# earlier session, and one sample can be selected many times over.
.bs_sample_table <- function(samples) {
  empty <- data.frame(name = character(0), index = character(0),
                      time = as.POSIXct(character(0)),
                      coord_system = character(0),
                      loc_x = numeric(0), loc_y = numeric(0), loc_z = numeric(0),
                      assoc_target = character(0),
                      stringsAsFactors = FALSE)
  if (is.null(samples) || nrow(samples) == 0L) return(empty)

  col <- function(nm, default = NA) {
    if (nm %in% names(samples)) samples[[nm]] else rep(default, nrow(samples))
  }
  out <- data.frame(
    name         = col("sample_name",  NA_character_),
    index        = col("index",        NA_character_),
    time         = .bs_times(samples),
    coord_system = col("coord_system", NA_character_),
    loc_x        = as.numeric(col("loc_x", NA_real_)),
    loc_y        = as.numeric(col("loc_y", NA_real_)),
    loc_z        = as.numeric(col("loc_z", NA_real_)),
    assoc_target = col("assoc_target", NA_character_),
    stringsAsFactors = FALSE
  )
  rownames(out) <- NULL
  out
}


.bs_print_info <- function(info, max_samples = 12L) {
  hms  <- function(t) if (is.na(t)) "?" else format(t, "%H:%M:%S")
  hmsf <- function(t) if (is.na(t)) "?" else format(t, "%H:%M:%OS3")
  line <- function(label, names_) {
    cat(sprintf("%-24s %s\n", label,
                if (length(names_)) paste(names_, collapse = ", ") else "none"))
  }

  cat(sprintf("\nBrainsight recording: %s\n", basename(info$file)))
  stamp <- c(if (!is.na(info$created_by)) info$created_by,
             if (!is.na(info$start)) format(info$start, "%Y-%m-%d"),
             sprintf("%d rows", sum(info$counts)))
  cat(sprintf("  %s\n\n", paste(stamp, collapse = "   |   ")))

  cat(sprintf("Recording length:  %s   (%s -> %s)\n\n",
              info$duration, hmsf(info$start), hmsf(info$end)))

  tr <- info$trackers
  seen <- tr[tr$visible > 0L, , drop = FALSE]
  cat(sprintf("Trackers used (%d of %d configured):\n",
              nrow(seen), nrow(tr)))
  if (nrow(seen) == 0L) {
    cat("  (none were ever visible to the camera)\n")
  } else {
    w_name <- max(nchar(seen$name))
    w_vis  <- max(nchar(format(seen$visible, big.mark = "")))
    for (i in seq_len(nrow(seen))) {
      cat(sprintf("  %-*s  %*d frames of %d   %s -> %s\n",
                  w_name, seen$name[i], w_vis, seen$visible[i],
                  seen$frames[i], hms(seen$first[i]), hms(seen$last[i])))
    }
  }
  if (length(info$unseen_trackers))
    cat(sprintf("  never visible:  %s\n",
                paste(info$unseen_trackers, collapse = ", ")))
  cat("\n")

  line(sprintf("Coils (%d):", info$n_coils),                info$coils)
  line(sprintf("Other trackers (%d):", length(info$other_trackers)),
       info$other_trackers)
  line(sprintf("Crosshairs drivers (%d):", info$n_drivers), info$drivers)
  cat("\n")

  sa <- info$samples
  cat(sprintf("Samples registered (%d):\n", nrow(sa)))
  if (nrow(sa) == 0L) {
    cat("  none\n")
  } else {
    shown  <- head(sa, max_samples)
    w_name <- max(nchar(shown$name), na.rm = TRUE)
    for (i in seq_len(nrow(shown))) {
      pos <- if (all(is.na(c(shown$loc_x[i], shown$loc_y[i], shown$loc_z[i])))) ""
             else sprintf("   %s (%.1f, %.1f, %.1f)",
                          ifelse(is.na(shown$coord_system[i]), "?",
                                 shown$coord_system[i]),
                          shown$loc_x[i], shown$loc_y[i], shown$loc_z[i])
      tgt <- if (is.na(shown$assoc_target[i])) ""
             else sprintf("  -> target %s", shown$assoc_target[i])
      cat(sprintf("  %-*s  idx %-3s  %s%s%s\n",
                  w_name, shown$name[i],
                  ifelse(is.na(shown$index[i]), "?", shown$index[i]),
                  hms(shown$time[i]), pos, tgt))
    }
    if (nrow(sa) > nrow(shown))
      cat(sprintf("  ... and %d more\n", nrow(sa) - nrow(shown)))
  }
  cat("\n")
  invisible(info)
}
