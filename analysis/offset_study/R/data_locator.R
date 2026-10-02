# =====================================================================
# data_locator.R  --  find a participant's input files in the lab's data
#                     folders and add them to the manifest
#
# The dashboard's Run page uses this so a new participant needs only a study
# ID: the four data folders are configured once (top of app/app.R, or on the
# Run page) and every file is found from them.
#
#   os_scan_ids()        study IDs present in a folder (xlsx, or Brainsight)
#   os_locate_files()    one row per ID: xlsx, qlg, brainsight, timesync,
#                        a status ("ok" or what is missing), a `hold` (why a
#                        complete set still should not be analysed yet) and
#                        a note
#   os_scan_folders()    sweep the folders for every participant with a
#                        Brainsight recording: which are ready to add, which
#                        are still waiting, which are complete but excluded
#   os_merge_manifest()  add / update those rows in a manifest table
#
# HOW EACH FILE IS FOUND
#   xlsx        <xlsx folder>/<ID>-....xlsx (the ID, then - _ or .). Several
#               matches (follow-up sessions): the newest session wins; the
#               session date is read from the QtracS code, and the others
#               are named in the note.
#   qlg         <qlg folder>/<code>.QLG, where <code> is the 10-character
#               QtracS code that ends the xlsx name, e.g.
#               SNBR-196-TP3C60922B.xlsx -> TP3C60922B.QLG. The code also
#               carries the session date: TP3 C 6 09 22 B -> 2026-09-22.
#   brainsight  <brainsight folder>/<ID>.txt or <ID>-....txt. Several matches:
#               the one last written on the xlsx's session day, else the newest.
#   timesync    the time-sync FOLDER itself (the pipeline pools every
#               time_sync*.txt in it and picks the row nearest the launch).
#               Files named for the ID are reported; none is not an error.
#
# READY = all four found AND nothing on `hold`. The hold checks catch a set of
# files that exist but do not belong together, or are not usable yet:
#   * the Brainsight recording is dated (first data row) another day than the
#     session (the day the QtracS code carries), or has no data rows yet;
#   * the time-sync folder has no row dated the session day -- its clock
#     offset drifts by up to a second between days, so a row from another day
#     would silently misplace every pulse.
# Adding by hand (Add / staging) ignores the hold; the automatic sweep on Run
# (os_scan_folders) waits for it.
# =====================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
})

OS_MANIFEST_COLS <- c("participant", "xlsx", "qlg", "brainsight", "timesync",
                      "clock_offset_s", "session_date", "coord_system", "include", "notes")
OS_LOCAL_TZ <- "America/Toronto"

#' Study IDs: trimmed, upper-case, a bare number gets the SNBR- prefix.
os_norm_id <- function(x) {
  x <- toupper(trimws(as.character(x)))
  x <- x[!is.na(x) & nzchar(x)]
  num <- grepl("^[0-9]+$", x)
  x[num] <- paste0("SNBR-", x[num])
  unique(x)
}

#' A folder path as typed or pasted (Explorer's "Copy as path" adds quotes;
#' backslashes and a trailing slash are tidied; drive roots such as "Y:/" stay).
os_norm_dir <- function(p) {
  p <- trimws(as.character(p))
  p[is.na(p)] <- ""
  p <- gsub('^"|"$', "", p)
  p <- gsub("\\\\", "/", p)
  p <- sub("([^:])/+$", "\\1", p)
  ifelse(nzchar(p), path.expand(p), p)
}

# Files in `dir` matching `pattern` (Excel's ~$ lock files dropped). No per-file
# stat calls: on the lab share dir.exists() over ~1,700 QLGs alone took 7 s.
os_list_dir <- function(dir, pattern) {
  if (is.null(dir) || is.na(dir) || !nzchar(dir) || !dir.exists(dir)) return(character(0))
  f <- list.files(dir, pattern = pattern, full.names = TRUE, ignore.case = TRUE)
  f[!startsWith(basename(f), "~$")]
}

#' The QtracS code that ends a QtracP export name (NA if there is none).
os_qtrac_code <- function(xlsx_name) {
  vapply(xlsx_name, function(n) {
    m <- regmatches(n, regexec("([A-Za-z]{2}[0-9][Cc][0-9]{5}[A-Za-z])[.]xlsx$", n))[[1L]]
    if (length(m) == 2L) toupper(m[2L]) else NA_character_
  }, character(1), USE.NAMES = FALSE)
}

#' Session date encoded in a QtracS code: two letters, a digit, "C", then
#' year digit + MMDD + a letter (TP3C60922B -> 2026-09-22). NA if unreadable.
os_code_date <- function(code) {
  out <- vapply(code, function(cd) {
    if (is.na(cd)) return(NA_character_)
    m <- regmatches(cd, regexec("^[A-Z]{2}[0-9]C([0-9])([0-9]{2})([0-9]{2})[A-Z]$", cd))[[1L]]
    if (length(m) != 4L) return(NA_character_)
    d <- suppressWarnings(as.Date(sprintf("%d-%s-%s", 2020L + as.integer(m[2L]), m[3L], m[4L])))
    if (is.na(d)) NA_character_ else format(d)
  }, character(1), USE.NAMES = FALSE)
  as.Date(out)
}

#' Study IDs found in a folder (SNBR-xxx at the start of a file name).
#' @param pattern which files to read the IDs from (default: the xlsx exports)
os_scan_ids <- function(dir, pattern = "[.]xlsx$") {
  f <- basename(os_list_dir(dir, pattern))
  id <- toupper(sub("^(snbr-[A-Za-z0-9]+).*$", "\\1", f, ignore.case = TRUE))
  sort(unique(id[startsWith(id, "SNBR-")]))
}

#' The date a Brainsight recording was made: the date column of its first data
#' row (only the first few hundred lines are read; NA if there is no data row).
os_brainsight_date <- function(path) {
  ln <- tryCatch(readLines(path, n = 400L, warn = FALSE, encoding = "latin1"), error = function(e) character(0))
  ln <- ln[!startsWith(ln, "#") & nzchar(ln)]
  m <- regmatches(ln, regexec("^[^\t]+\t([0-9]{4}-[0-9]{2}-[0-9]{2})\t", ln))
  d <- vapply(m, function(x) if (length(x) == 2L) x[2L] else NA_character_, character(1))
  d <- d[!is.na(d)]
  if (length(d)) as.Date(d[1L]) else as.Date(NA)
}

#' The dates of every row in the given time-sync files (one row = one clock
#' comparison; each begins with the Windows local time "YYYY-MM-DD hh:mm:ss").
os_timesync_dates <- function(files) {
  d <- unlist(lapply(files, function(f) {
    ln <- tryCatch(readLines(f, warn = FALSE, encoding = "latin1"), error = function(e) character(0))
    ln <- ln[!startsWith(ln, "#") & nzchar(trimws(ln))]
    as.numeric(as.Date(substr(ln, 1L, 10L), format = "%Y-%m-%d"))
  }))
  as.Date(d[!is.na(d)], origin = "1970-01-01")
}

#' TRUE for manifest rows the pipeline will run (same rule as run_offset_study.R).
os_is_included <- function(x) is.na(x) | toupper(x) %in% c("TRUE", "T", "YES", "1")

# Does a file name start with the ID followed by - _ or . ?  (SNBR-14 must
# not match SNBR-140.)
.os_starts_with_id <- function(paths, id) {
  nm <- tolower(basename(paths)); id <- tolower(id)
  Reduce(`|`, lapply(c("-", "_", "."), function(s) startsWith(nm, paste0(id, s))),
         accumulate = FALSE, init = rep(FALSE, length(nm)))
}

#' Find each ID's files.
#' @param ids  study IDs (normalised here)
#' @param dirs list(xlsx, qlg, brainsight, timesync): the four folders
#' @return tibble: participant, status ("ok" or the problems), hold (why a
#'   complete set should still wait; "" if nothing), ready (status ok and no
#'   hold), xlsx, qlg, brainsight, timesync (paths, NA when not found), n_sync
#'   (time_sync files in the folder), session_date (from the QtracS code),
#'   bs_date (recording date of the Brainsight file), sync_on_day (time-sync
#'   rows dated the session day) and note (choices the locator made that you
#'   may want to check).
os_locate_files <- function(ids, dirs) {
  ids <- os_norm_id(ids)
  xl_all  <- os_list_dir(dirs$xlsx, "[.]xlsx$")
  bs_all  <- os_list_dir(dirs$brainsight, "[.]txt$")
  qlg_dir <- dirs$qlg      # looked up by name below: the folder holds thousands of logs
  ts_dir  <- dirs$timesync
  ts_all  <- os_list_dir(ts_dir, "^time_sync.*[.]txt$")
  sync_dates <- if (length(ids) && length(ts_all)) os_timesync_dates(ts_all) else as.Date(character(0))

  rows <- lapply(ids, function(id) {
    problems <- character(0); notes <- character(0); hold <- character(0)
    xlsx <- qlg <- bs <- NA_character_; sdate <- bdate <- as.Date(NA)

    # -- xlsx: newest session among the files named for this ID
    x <- xl_all[.os_starts_with_id(xl_all, id)]
    if (length(x) == 0L) {
      problems <- c(problems, if (length(xl_all)) "no xlsx for this ID" else "xlsx folder empty or not found")
    } else {
      xi <- tibble(path = x, code = os_qtrac_code(basename(x))) %>%
        mutate(date = os_code_date(code), mtime = file.mtime(path)) %>%
        arrange(desc(date), desc(mtime))
      xlsx <- xi$path[1L]; sdate <- xi$date[1L]
      if (nrow(xi) > 1L)
        notes <- c(notes, sprintf("%d xlsx files match; used %s (newest session). Others: %s",
                                  nrow(xi), basename(xlsx), paste(basename(xi$path[-1L]), collapse = ", ")))
      # -- qlg: named by the code that ends the xlsx name
      code <- xi$code[1L]
      if (is.na(code)) {
        problems <- c(problems, sprintf("no QtracS code at the end of '%s'", basename(xlsx)))
      } else {
        hit <- file.path(qlg_dir, paste0(code, c(".QLG", ".qlg")))
        hit <- hit[file.exists(hit)]
        if (length(hit)) qlg <- hit[1L]
        else problems <- c(problems, if (!is.null(qlg_dir) && nzchar(qlg_dir) && dir.exists(qlg_dir))
                                       sprintf("%s.QLG not found", code) else "QLG folder not found")
      }
    }

    # -- brainsight: the one recorded on the session day, else the newest
    b <- bs_all[.os_starts_with_id(bs_all, id)]
    if (length(b) == 0L) {
      problems <- c(problems, if (length(bs_all)) "no Brainsight .txt for this ID" else "Brainsight folder empty or not found")
    } else {
      bi <- tibble(path = b, mtime = file.mtime(b), rec = as.Date(vapply(b, function(p) format(os_brainsight_date(p)), "", USE.NAMES = FALSE))) %>%
        mutate(same_day = !is.na(sdate) & !is.na(rec) & rec == sdate) %>%
        arrange(desc(same_day), desc(mtime))
      bs <- bi$path[1L]; bdate <- bi$rec[1L]
      if (nrow(bi) > 1L)
        notes <- c(notes, sprintf("%d Brainsight files match; used %s. Others: %s", nrow(bi),
                                  basename(bs), paste(basename(bi$path[-1L]), collapse = ", ")))
      if (is.na(bdate)) hold <- c(hold, "the Brainsight file has no data rows yet")
      else if (!is.na(sdate) && bdate != sdate)
        hold <- c(hold, sprintf("the Brainsight recording is dated %s but the session is %s", bdate, sdate))
    }

    # -- time sync: the folder; a row from the session day is what makes it usable
    n_day <- NA_integer_
    if (length(ts_all) == 0L) {
      problems <- c(problems, if (!is.na(ts_dir) && nzchar(ts_dir) && dir.exists(ts_dir))
                                "no time_sync*.txt in the time-sync folder" else "time-sync folder not found")
    } else {
      if (!is.na(sdate)) {
        n_day <- sum(sync_dates == sdate, na.rm = TRUE)
        if (n_day == 0L) hold <- c(hold, sprintf("no time-sync row is dated %s", sdate))
      }
      if (!any(grepl(tolower(id), tolower(basename(ts_all)), fixed = TRUE)))
        notes <- c(notes, "no time-sync file is named for this ID; the nearest unlabelled row is used")
    }

    ok <- length(problems) == 0L
    ready <- ok && length(hold) == 0L          # before tibble(): its `hold` column would shadow the vector
    tibble(participant = id,
           status = if (ok) "ok" else paste(problems, collapse = "; "),
           hold = paste(hold, collapse = "; "), ready = ready,
           xlsx = xlsx, qlg = qlg, brainsight = bs,
           timesync = if (length(ts_all)) ts_dir else NA_character_,
           n_sync = length(ts_all), session_date = format(sdate),
           bs_date = format(bdate), sync_on_day = n_day,
           note = paste(notes, collapse = " | "))
  })
  if (length(rows) == 0L)
    return(tibble(participant = character(0), status = character(0), hold = character(0),
                  ready = logical(0), xlsx = character(0), qlg = character(0),
                  brainsight = character(0), timesync = character(0), n_sync = integer(0),
                  session_date = character(0), bs_date = character(0),
                  sync_on_day = integer(0), note = character(0)))
  bind_rows(rows)
}

#' Sweep the data folders for participants that can be added to the manifest.
#'
#' Every ID with a Brainsight recording in the Brainsight folder is looked up.
#' @param dirs list(xlsx, qlg, brainsight, timesync)
#' @param man  the current manifest table (or NULL)
#' @return list of tibbles from os_locate_files() plus `reason` (what is
#'   missing or on hold):
#'   found     everyone with a recording
#'   add       ready and not in the manifest: to be added
#'   waiting   not in the manifest and not ready (files still missing / on hold)
#'   excluded  ready, in the manifest, but include = FALSE (never overridden)
os_scan_folders <- function(dirs, man = NULL) {
  found <- os_locate_files(os_scan_ids(dirs$brainsight, "[.]txt$"), dirs)
  found$reason <- ifelse(found$status != "ok", found$status, found$hold)
  mid <- if (is.null(man) || is.null(man$participant)) character(0) else toupper(man$participant)
  inman <- toupper(found$participant) %in% mid
  incl <- rep(FALSE, nrow(found))
  if (any(inman)) {
    inc_col <- if (is.null(man$include)) rep(NA_character_, nrow(man)) else man$include
    incl[inman] <- os_is_included(inc_col[match(toupper(found$participant[inman]), mid)])
  }
  list(found = found,
       add = found[!inman & found$ready, , drop = FALSE],
       waiting = found[!inman & !found$ready, , drop = FALSE],
       excluded = found[inman & !incl & found$ready, , drop = FALSE])
}

#' Add the found participants to a manifest table (all-character columns).
#' An ID already in the manifest keeps its row and only has its four paths
#' refreshed (clock_offset_s, coord_system, include and notes are yours); a new
#' ID is appended with include = TRUE.
os_merge_manifest <- function(man, found) {
  if (is.null(man)) man <- as_tibble(setNames(rep(list(character(0)), length(OS_MANIFEST_COLS)), OS_MANIFEST_COLS))
  for (cl in setdiff(OS_MANIFEST_COLS, names(man))) man[[cl]] <- rep(NA_character_, nrow(man))
  man <- man %>% mutate(across(everything(), as.character))
  for (k in seq_len(nrow(found))) {
    f <- found[k, ]
    i <- match(toupper(f$participant), toupper(man$participant))
    if (is.na(i)) {
      new <- as_tibble(setNames(rep(list(NA_character_), ncol(man)), names(man)))
      new$participant <- f$participant
      new$include <- "TRUE"
      new$notes <- if (nzchar(f$note)) f$note else NA_character_
      man <- bind_rows(man, new); i <- nrow(man)
    }
    for (cl in c("xlsx", "qlg", "brainsight", "timesync")) man[[cl]][i] <- f[[cl]]
  }
  man[, c(OS_MANIFEST_COLS, setdiff(names(man), OS_MANIFEST_COLS))]
}
