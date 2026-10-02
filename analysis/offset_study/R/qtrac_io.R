# =====================================================================
# qtrac_io.R  --  QtracP export + QtracS run log + time-sync log readers
#
# Everything the offset study needs from the Windows (TMS/EMG) side:
#
#   os_read_qtrac_xlsx()  one row per pulse from the QtracP .xlsx export
#                         (elapsed_min, channel, mso, isi_ms, ptp_mv, latency_ms)
#   os_read_qlg()         QtracS launch time (sub-second) and the per-pulse
#                         "Trigger stim" lines with their REAL elapsed seconds
#   os_match_pulses()     pairs every xlsx row with its QLG trigger line
#   os_read_timesync()    the receiver's time-sync log(s) -> delta_s rows
#   os_pick_clock_offset() chooses the delta_s row for this session
#
# WHY THE QLG IS NEEDED FOR TIMING
# --------------------------------
# The xlsx "Elapsed Time (min)" column is NOT wall-clock time. It is Qtrac's
# nominal sweep clock: it advances by a fixed amount per sweep and drifts
# ahead of real time by ~1.5 s every few pulses (45 s over a 27-minute
# session in SNBR-188). The QLG, by contrast, stamps every line with real
# seconds since launch ("00224.801") plus, in its third column, the same
# nominal sweep clock the xlsx uses ("001.950"). That third column is the
# bridge: each xlsx row is matched to the trigger line whose nominal clock is
# nearest, and the trigger line's real elapsed seconds become the pulse time.
#
#   pulse_windows_time = QLG launch (wall clock) + trigger real elapsed seconds
#   pulse_mac_time     = pulse_windows_time - delta_s        (delta_s = Win - Mac)
# =====================================================================

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(tibble)
  library(stringr)
  library(lubridate)
})

# ---- QtracP export --------------------------------------------------

#' Read the long-format (Elapsed Time / Channel / Values) block of one sheet.
os_read_qtrac_sheet <- function(path, sheet, value_name) {
  raw <- suppressMessages(read_excel(path, sheet = sheet, col_names = FALSE,
                                     .name_repair = "minimal"))
  hdr <- as.character(unlist(raw[1, ]))
  i   <- which(!is.na(hdr) & hdr == "Elapsed Time (min)")
  if (length(i) == 0L)
    stop("Sheet '", sheet, "' of ", basename(path),
         " has no 'Elapsed Time (min)' column (QtracP long-format export expected).")
  i <- i[1L]
  out <- tibble(
    elapsed_min = suppressWarnings(as.numeric(raw[[i]][-1L])),
    channel     = suppressWarnings(as.numeric(raw[[i + 1L]][-1L])),
    value       = suppressWarnings(as.numeric(raw[[i + 2L]][-1L]))
  ) %>% filter(!is.na(elapsed_min), !is.na(channel))
  names(out)[3L] <- value_name
  out
}

#' One row per pulse: elapsed_min, channel, mso, isi_ms, ptp_mv, latency_ms.
#' Sheets: T = stimulator output (% MSO), P = MEP peak-to-peak (mV),
#'         D = conditioning delay / ISI (ms; 0 = unconditioned), L = latency (ms).
os_read_qtrac_xlsx <- function(path) {
  if (!file.exists(path)) stop("QtracP xlsx not found: ", path)
  sheets <- excel_sheets(path)
  need   <- c("T", "P", "D")
  miss   <- setdiff(need, sheets)
  if (length(miss)) stop(basename(path), " is missing sheet(s): ", paste(miss, collapse = ", "))

  t <- os_read_qtrac_sheet(path, "T", "mso")
  p <- os_read_qtrac_sheet(path, "P", "ptp_mv")
  d <- os_read_qtrac_sheet(path, "D", "isi_ms")
  pulses <- t %>%
    full_join(p, by = c("elapsed_min", "channel")) %>%
    full_join(d, by = c("elapsed_min", "channel"))
  if ("L" %in% sheets) {
    l <- os_read_qtrac_sheet(path, "L", "latency_ms")
    pulses <- left_join(pulses, l, by = c("elapsed_min", "channel"))
  } else {
    pulses$latency_ms <- NA_real_
  }
  pulses %>%
    arrange(elapsed_min, channel) %>%
    mutate(pulse_idx = row_number()) %>%
    select(pulse_idx, elapsed_min, channel, mso, isi_ms, ptp_mv, latency_ms)
}

# ---- QtracS run log -------------------------------------------------

#' Parse a QtracS .QLG run log.
#'
#' @param path         The .QLG file.
#' @param session_date Date of the session (the log carries only times of day).
#' @param tz           Time zone of the Windows machine.
#' @return list(launch_dt, launch_window_s, triggers, n_lines, n_triggers)
#'   triggers: trig_idx, el_s (real seconds since launch), rec_min (nominal
#'   sweep clock, minutes), th (stimulator intensity), win_time (POSIXct).
os_read_qlg <- function(path, session_date, tz = "America/Toronto") {
  if (!file.exists(path)) stop("QLG file not found: ", path)
  lines <- readLines(path, warn = FALSE, encoding = "latin1")
  m  <- str_match(lines,
                  "^\\s*(\\d{1,2}:\\d{2}:\\d{2} [AP]M)\\s+(\\d+\\.\\d+)\\s+(\\d+\\.\\d+)\\s*(.*)$")
  ok <- !is.na(m[, 1L])
  if (!any(ok)) stop("No timestamped lines found in QLG: ", path)
  tod     <- m[ok, 2L]
  el_s    <- as.numeric(m[ok, 3L])
  rec_min <- as.numeric(m[ok, 4L])
  msg     <- m[ok, 5L]

  # Seconds of day for every line (1 s resolution, truncated).
  hms <- strptime(tod, "%I:%M:%S %p", tz = "UTC")
  sod <- hour(hms) * 3600 + minute(hms) * 60 + second(hms)

  # The launch instant L satisfies floor(L + el_s) == sod for every line, so
  #   L in (sod - el_s, sod - el_s + 1]  -> intersect over all lines.
  # Thousands of lines shrink the window to a few milliseconds.
  # In practice the window collapses to ~1 ms and L = lo.
  lo <- max(sod - el_s)
  hi <- min(sod - el_s) + 1
  if (hi < lo - 0.05) {                 # clock stepped mid-session: fall back
    launch_sod <- sod[1L] - el_s[1L] + 0.5
    window_s   <- 1
  } else {
    launch_sod <- lo
    window_s   <- max(hi - lo, 0)
  }
  day0      <- as.POSIXct(paste(as.character(session_date), "00:00:00"),
                          format = "%Y-%m-%d %H:%M:%S", tz = tz)
  launch_dt <- day0 + launch_sod

  tm <- str_match(msg, "^:\\s*Trigger stim (\\d+),\\s*TH=\\s*([0-9.]+),\\s*CH=\\s*([0-9.]*)")
  is_trig <- !is.na(tm[, 1L])
  trig_el <- el_s[is_trig]
  triggers <- tibble(
    trig_idx = seq_along(trig_el),
    el_s     = trig_el,
    rec_min  = rec_min[is_trig],
    th       = suppressWarnings(as.numeric(tm[is_trig, 3L])),
    win_time = launch_dt + trig_el
  )
  list(launch_dt = launch_dt, launch_window_s = window_s,
       triggers = triggers, n_lines = sum(ok), n_triggers = nrow(triggers),
       first_tod = tod[1L])
}

#' Pair each xlsx pulse with a QLG trigger line.
#'
#' Both carry the nominal sweep clock (xlsx elapsed_min, QLG rec_min; the QLG
#' value is quantised to 0.025 min and sits ~0.02-0.04 min below the xlsx
#' value). Pairing is greedy and monotone in time: each trigger is used once.
#' Adds trig_idx, el_s, win_time, match_drec_min, th_agrees to `pulses`.
os_match_pulses <- function(pulses, triggers, tol_min = 0.08, lag_min = 0.025) {
  if (!"mso" %in% names(pulses)) pulses$mso <- NA_real_
  ord      <- order(pulses$elapsed_min)          # work in time order, return in input order
  pulses   <- pulses[ord, , drop = FALSE]
  triggers <- arrange(triggers, rec_min, el_s)
  n <- nrow(pulses); k <- nrow(triggers)
  idx  <- rep(NA_integer_, n)
  used <- logical(k)
  j0   <- 1L
  for (i in seq_len(n)) {
    target <- pulses$elapsed_min[i] - lag_min
    while (j0 <= k && triggers$rec_min[j0] < target - tol_min) j0 <- j0 + 1L
    j <- j0
    best <- NA_integer_; best_d <- Inf
    while (j <= k && triggers$rec_min[j] <= target + tol_min) {
      if (!used[j]) {
        d <- abs(triggers$rec_min[j] - target)
        if (d < best_d) { best_d <- d; best <- j }
      }
      j <- j + 1L
    }
    if (!is.na(best)) { idx[i] <- best; used[best] <- TRUE }
  }
  out <- pulses %>%
    mutate(
      trig_idx       = triggers$trig_idx[idx],
      el_s           = triggers$el_s[idx],
      win_time       = triggers$win_time[idx],
      match_drec_min = triggers$rec_min[idx] - elapsed_min,
      th_agrees      = !is.na(idx) & !is.na(mso) &
                       abs(round(triggers$th[idx]) - round(mso)) <= 1
    )
  out[order(ord), , drop = FALSE]
}

# ---- Time-sync log --------------------------------------------------

#' Read the receiver's time-sync log(s): a folder of per-connection files or
#' one .txt. Columns: win_local_time, delta_s, rtt_ms, mac_local_time,
#' participant (NA when unlabelled), log_file.
os_read_timesync <- function(path, tz = "America/Toronto") {
  if (!file.exists(path)) stop("Time-sync path not found: ", path)
  files <- if (dir.exists(path)) {
    sort(list.files(path, pattern = "^time_sync.*[.]txt$", full.names = TRUE))
  } else path
  if (length(files) == 0L) stop("No time_sync*.txt files in: ", path)

  read_one <- function(file) {
    raw  <- readLines(file, warn = FALSE)
    rows <- raw[!grepl("^\\s*#", raw) & nzchar(trimws(raw))]
    if (length(rows) == 0L) return(NULL)
    f <- strsplit(rows, "\t", fixed = TRUE)
    field <- function(i) vapply(f, function(x) if (length(x) >= i) x[[i]] else NA_character_,
                                character(1))
    tibble(
      win_local_time = ymd_hms(field(1), tz = tz),
      delta_s        = as.numeric(field(2)),
      rtt_ms         = as.numeric(field(3)),
      mac_local_time = ymd_hms(field(4), tz = tz),
      participant    = na_if(trimws(field(10)), ""),
      log_file       = basename(file)
    )
  }
  ts <- bind_rows(lapply(files, read_one))
  if (nrow(ts) == 0L) stop("Time-sync log(s) hold no data rows: ", path)
  arrange(ts, win_local_time)
}

#' Choose the delta_s row for a session.
#'
#' Rows labelled with this participant are preferred; among candidates the
#' row nearest the QtracS launch wins. Warns when the chosen row is on another
#' day or more than `max_sep_h` hours from the launch.
os_pick_clock_offset <- function(ts, participant, launch_dt, max_sep_h = 4) {
  lab <- !is.na(ts$participant) & toupper(ts$participant) == toupper(participant)
  cand <- if (any(lab)) ts[lab, ] else ts
  sep_h <- abs(as.numeric(difftime(cand$win_local_time, launch_dt, units = "hours")))
  i <- which.min(sep_h)
  row <- cand[i, ]
  same_day <- as_date(row$win_local_time) == as_date(launch_dt)
  warn <- character(0)
  if (!same_day)
    warn <- c(warn, sprintf("time-sync row is dated %s but the session is %s",
                            as_date(row$win_local_time), as_date(launch_dt)))
  if (sep_h[i] > max_sep_h)
    warn <- c(warn, sprintf("time-sync row is %.1f h from the QtracS launch", sep_h[i]))
  if (!any(lab))
    warn <- c(warn, "no time-sync row is labelled with this participant; nearest unlabelled row used")
  list(delta_s = row$delta_s, row = row, sep_h = sep_h[i], labelled = any(lab),
       n_candidates = nrow(cand), warnings = warn)
}
