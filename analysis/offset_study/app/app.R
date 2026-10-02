# =====================================================================
# Coil Offset Dashboard  --  Shiny front end for the offset study
#
# Reads what run_offset_study.R wrote to analysis/output/offset_study/
# and lets you browse it, compare participants, test tolerances and re-run
# the pipeline. Start it with:
#
#   shiny::runApp("analysis/offset_study/app")      # from the repo root
#   Rscript -e "shiny::runApp('analysis/offset_study/app', port = 3838)"
#
# Every page carries a "How to read this" panel; the Methods page holds the
# full glossary. Nothing here recomputes statistics: the tables are the
# pipeline's CSVs, the figures are rebuilt from them for interactivity.
# =====================================================================

# =====================================================================
# PATHS  --  EDIT HERE, or on the Run page ("1. Data folders")
#
# The four folders the participants' raw files live in. On the Run page you
# type a study ID and the app finds that participant's xlsx, QLG, Brainsight
# file and the time-sync folder from these (see R/data_locator.R for how),
# adds them to the manifest, and runs the analysis.
#
# What you type on the Run page overrides these values and is remembered in
# data_paths.json (next to manifest.csv); "Reset to script defaults" there
# deletes that file so these values apply again.
# =====================================================================
DATA_DIRS_DEFAULT <- list(
  xlsx       = "Y:/Merged Data/xlsx Data",              # QtracP exports, <ID>-...-<code>.xlsx
  qlg        = "Y:/Merged Data/Data",                   # QtracS run logs, <code>.QLG
  brainsight = "Y:/Neuro_Nav_App/data/BS_Recordings",   # Brainsight streamed-info .txt
  timesync   = "Y:/Neuro_Nav_App/data/time_sync"        # receiver's time_sync*.txt files
)
# Where the repo (the folder holding Neuro_Nav.Rproj) may live, if the app is
# not started from it. The current directory is tried first.
PROJECT_ROOT_FALLBACKS <- c("Y:/Neuro_Nav_App",
                            "C:/Users/Ali D/Desktop/Projects/Neuro_Nav_App")

suppressPackageStartupMessages({
  library(shiny); library(bslib); library(DT); library(plotly)
  library(dplyr); library(tidyr); library(readr); library(ggplot2); library(htmltools)
})

# ---- locate the repo and the outputs --------------------------------
find_root <- function() {
  here <- tryCatch(normalizePath(dirname(sys.frame(1)$ofile)), error = function(e) getwd())
  cands <- c(getwd(), file.path(here, "..", "..", ".."), PROJECT_ROOT_FALLBACKS)
  for (c in cands) if (file.exists(file.path(c, "Neuro_Nav.Rproj"))) return(normalizePath(c))
  stop("Cannot find Neuro_Nav.Rproj")
}
PROJECT_ROOT <- find_root()
STUDY_DIR <- file.path(PROJECT_ROOT, "analysis", "offset_study")
OUT_DIR   <- file.path(PROJECT_ROOT, "analysis", "output", "offset_study")
RSCRIPT   <- file.path(R.home("bin"), "Rscript")
source(file.path(STUDY_DIR, "R", "coil_geometry.R"))
source(file.path(STUDY_DIR, "R", "plots.R"))
source(file.path(STUDY_DIR, "R", "data_locator.R"))
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)   # a first run creates its contents
addResourcePath("osout", OUT_DIR)

# Folders in use = the defaults above, overridden by what was last saved on the Run page.
DATA_DIRS_FILE <- file.path(STUDY_DIR, "data_paths.json")
load_data_dirs <- function() {
  d <- DATA_DIRS_DEFAULT
  if (file.exists(DATA_DIRS_FILE) && requireNamespace("jsonlite", quietly = TRUE)) {
    s <- tryCatch(jsonlite::read_json(DATA_DIRS_FILE, simplifyVector = TRUE), error = function(e) NULL)
    for (k in intersect(names(s), names(d)))
      if (is.character(s[[k]]) && length(s[[k]]) == 1L && nzchar(s[[k]])) d[[k]] <- s[[k]]
  }
  d
}
DATA_DIRS0 <- load_data_dirs()

DOF_LABELS <- setNames(paste0(OS_DOF$label, " (", OS_DOF$unit, ")"), OS_DOF$var)   # code -> label
DOF_CHOICES <- setNames(OS_DOF$var, DOF_LABELS)                                    # label -> code (for inputs)
DOF_SHORT <- c(dx_mm = "x shift", dy_mm = "y shift", dz_mm = "z shift",
               rx_deg = "tilt x", ry_deg = "tilt y", rz_deg = "twist")
DOF_SHORT_LABELS <- setNames(paste0(DOF_SHORT[OS_DOF$var], " (", OS_DOF$unit, ")"), OS_DOF$var)  # compact axis titles: the full DOF_LABELS text overlaps when rotated in a short per-DoF row
MAG_LABELS <- setNames(paste0(OS_MAG$label, " (", OS_MAG$unit, ")"), OS_MAG$var)
CLASS_LABELS <- c(single = "Single pulses", paired = "Paired pulses")
CLASS_CHOICES <- setNames(names(CLASS_LABELS), CLASS_LABELS)
STATUS <- list(good = "#0ca30c", warning = "#fab219", critical = "#d03b3b")

# ---- data loading ----------------------------------------------------
# The pipeline writes every timestamp as local wall-clock text (Toronto, the
# lab's clock). read_csv turns such columns into POSIXct, and by default it
# assumes UTC; the locale below makes it read them as Toronto local time, so a
# pulse fired at 12:04 shows as 12:04 and not 08:04. Do NOT relabel the zone
# afterwards with as.POSIXct(x, tz = ...): on a POSIXct that only changes the
# label and shifts the clock time by the UTC offset.
APP_TZ <- "America/Toronto"
read_or_null <- function(p) if (file.exists(p)) suppressMessages(read_csv(p, show_col_types = FALSE,
                                                                        guess_max = 10000,
                                                                        locale = locale(tz = APP_TZ))) else NULL
# A timestamp column as Toronto-local POSIXct, whether readr already parsed it
# (POSIXct, read in APP_TZ above) or left it as text (e.g. an all-NA column).
as_local_time <- function(x) {
  if (inherits(x, "POSIXct")) return(x)
  as.POSIXct(as.character(x), format = "%Y-%m-%d %H:%M:%OS", tz = APP_TZ)
}
load_outputs <- function() {
  g <- file.path(OUT_DIR, "group")
  info <- if (file.exists(file.path(g, "run_info.json")) && requireNamespace("jsonlite", quietly = TRUE))
    jsonlite::read_json(file.path(g, "run_info.json"), simplifyVector = TRUE) else NULL
  pulses <- read_or_null(file.path(g, "all_pulses.csv"))
  if (!is.null(pulses)) {
    pulses <- pulses %>% mutate(
      mac_time = as_local_time(mac_time),
      pulse_class = factor(pulse_class, levels = c("single", "paired", "unknown")))
  }
  parts <- sort(setdiff(list.dirs(OUT_DIR, full.names = FALSE, recursive = FALSE), "group"))
  list(info = info, pulses = pulses,
       stats = read_or_null(file.path(g, "all_stats.csv")),
       place = read_or_null(file.path(g, "all_placement.csv")),
       two_stage = read_or_null(file.path(g, "group_two_stage.csv")),
       mixed = read_or_null(file.path(g, "group_mixed.csv")),
       participants = parts,
       report = if (file.exists(file.path(g, "offset_study_report.md"))) file.path(g, "offset_study_report.md") else NULL)
}
load_participant <- function(id) {
  d <- file.path(OUT_DIR, id)
  f <- function(s) file.path(d, paste0(id, "_", s))
  st <- read_or_null(f("stream_2hz.csv"))
  if (!is.null(st)) st$t <- as_local_time(st$t)
  ev <- read_or_null(f("target_events.csv"))
  if (!is.null(ev)) ev$t <- as_local_time(ev$t)
  bl <- read_or_null(f("coil_blocks.csv"))
  if (!is.null(bl)) { bl$start <- as_local_time(bl$start)
                      bl$end <- as_local_time(bl$end) }
  list(stream = st, events = ev, blocks = bl,
       qc = if (file.exists(f("qc.txt"))) readLines(f("qc.txt"), warn = FALSE) else "no QC file",
       targets = read_or_null(f("targets.csv")),
       timeline_png = if (file.exists(f("timeline.png"))) paste0("osout/", id, "/", id, "_timeline.png") else NULL)
}

# ---- helpers ---------------------------------------------------------
fmt_p <- function(p) ifelse(is.na(p), "", ifelse(p < 0.001, "<0.001", formatC(p, digits = 2, format = "g")))
sig_mark <- function(p) ifelse(is.na(p), "", ifelse(p < 0.01, "**", ifelse(p < 0.05, "*", "")))
dt_opts <- function(pageLength = 12) list(pageLength = pageLength, scrollX = TRUE, dom = "tip",
                                          order = list())
info_card <- function(title, ...) {
  accordion(open = FALSE, accordion_panel(title, icon = icon("circle-info"), ...))
}
status_badge <- function(level, text) {
  col <- STATUS[[level]]; icon <- switch(level, good = "\u2714", warning = "\u26A0", critical = "\u2716")
  span(style = sprintf("color:%s;font-weight:600", col), icon, " ", text)
}
# A folder text box with a live "does it exist / what does it hold" line under it.
dir_input <- function(id, label, value)
  tagList(textInput(id, label, value, width = "100%"), uiOutput(paste0(id, "_status"), class = "small-note"))
tbl_or_msg <- function(df, msg = "Run the pipeline first (Run page).") {
  if (is.null(df) || nrow(df) == 0L) return(datatable(data.frame(note = msg), options = list(dom = "t")))
  datatable(df, options = dt_opts(), rownames = FALSE, filter = "top")
}
# Rounds numeric columns for display.
disp <- function(df, digits = 3) { if (is.null(df)) return(df); df %>% mutate(across(where(is.numeric), ~ signif(.x, digits))) }

# Rule-based findings from the group tables, in plain language.
make_findings <- function(D) {
  out <- character(0)
  if (is.null(D$mixed) || nrow(D$mixed) == 0L) return("No group results yet.")
  m <- D$mixed %>% filter(form == "abs")
  lab <- function(dof) OS_DOF$label[match(dof, OS_DOF$var)]
  s <- m %>% filter(outcome == "log_mep", pulse_class == "single")
  if (nrow(s)) {
    sig  <- s %>% filter(p < 0.05, estimate < 0)
    grow <- s %>% filter(p < 0.05, estimate > 0)
    out <- c(out, if (nrow(sig)) sprintf(
      "Single pulses: at fixed intensity the MEP shrinks with %s (%s).",
      paste(sprintf("%s (%.1f%% per %s)", lab(sig$dof), sig$pct_change_per_unit, sig$unit), collapse = ", "),
      "pooled mixed model, p < 0.05") else
      "Single pulses: no degree of freedom made the MEP shrink at p < 0.05 at fixed intensity.")
    if (nrow(grow)) out <- c(out, sprintf(
      "Single pulses: the MEP got larger, not smaller, with %s (%s); check the signed offset and the coil before reading it as an effect.",
      paste(sprintf("%s (+%.1f%% per %s)", lab(grow$dof), grow$pct_change_per_unit, grow$unit), collapse = ", "),
      "pooled mixed model, p < 0.05"))
  }
  tm <- m %>% filter(outcome == "tracked_mso", pulse_class == "paired")
  if (nrow(tm)) {
    sig <- tm %>% filter(p < 0.05, estimate > 0)
    out <- c(out, if (nrow(sig)) sprintf(
      "Threshold tracking (T-SICI): the tracker needed more intensity as the coil drifted in %s.",
      paste(sprintf("%s (+%.2f %% MSO per %s)", lab(sig$dof), sig$estimate, sig$unit), collapse = ", ")) else
      "Threshold tracking: no degree of freedom reached p < 0.05 for the tracked intensity.")
  }
  pm <- m %>% filter(outcome == "log_mep", pulse_class == "paired", p < 0.05)
  out <- c(out, if (nrow(pm) == 0L)
    "Paired-pulse MEP size did not change with offset. This is expected: the tracker holds it constant, so look at the tracked intensity instead." else
    sprintf("Paired-pulse MEP size changed with %s; interpret with care because tracking clamps this outcome.",
            paste(lab(pm$dof), collapse = ", ")))
  if (!is.null(D$place)) {
    p <- D$place %>% filter(nav_phase == "on-target")
    # the 3 and 5 mm SOP tolerances when the run reported them, else whatever it did report
    pc <- intersect(c("pct_within_3mm", "pct_within_5mm"), names(p))
    if (!length(pc)) pc <- grep("^pct_within_[0-9.]+mm$", names(p), value = TRUE)
    if (nrow(p) && length(pc)) out <- c(out, sprintf(
      "Placement: across %d participant-coil blocks the median distance from target was %.1f mm (range %.1f to %.1f); on average %s.",
      nrow(p), median(p$dist_median_mm), min(p$dist_median_mm), max(p$dist_median_mm),
      paste(sprintf("%.0f%% of pulses were inside %s mm", sapply(pc, function(cn) mean(p[[cn]], na.rm = TRUE)),
                    sub("^pct_within_([0-9.]+)mm$", "\\1", pc)), collapse = ", ")))
  }
  out
}

# ---- static text ------------------------------------------------------
TXT <- list(
  overview = "This dashboard answers one question: when the stimulus is held fixed (same % MSO, same ISI), does the coil's offset from its neuronavigation target change the response? For MEP size, both coils and their targets count as one: each pulse is measured from its own coil's target and the effect is estimated across both coils together. It reports the answer for each participant and for the group, and shows how well the coil was actually held. All numbers come from `run_offset_study.R`; nothing is recomputed here.",
  phases = "**Phases.** Every pulse is labelled *pre-target* (fired before the coil's target existed in Brainsight: hotspotting, searching) or *on-target* (the target existed and the coil was meant to hold it). Effect models use on-target pulses only. *Run phase* splits the session by protocol: hotspot/RMT, the threshold-tracked T-SICI block (paired pulses with positive ISI and the single test pulses among them), fixed-intensity runs (negative-ISI paired pulses), and post-block single pulses.",
  dof = "**Six degrees of freedom, in the target's frame.** *x/y shift*: sliding of the coil in the plane of the scalp along the target's own axes. *z shift*: movement along the coil normal (+ = lifted off the head). *Tilt about x/y*: the coil face tilting away from the target orientation. *Twist*: rotation of the handle about the normal. Effects are reported for the absolute offset (how far off, either direction), with a signed check for asymmetry, plus the collapsed total distance and angle.",
  strata = "**Holding the stimulus fixed.** A *stratum* is one participant, pulse class, ISI and % MSO. The coils are not part of it: both coils, and their targets, count as one, so pulses fired with either coil at the same setting share a stratum. Every slope is estimated within strata, so it compares pulses given the same stimulus setting that differ in where the coil was. The one exception is tracked intensity (% MSO): it is a stimulator setting that depends on the coil, so its model keeps a coil x ISI baseline.",
  outcomes = "**Outcomes.** *log MEP*: MEP size, as % change per mm or degree. *MEP present*: odds that any MEP (>= 0.05 mV) appeared. *Tracked MSO*: for threshold-tracked runs the tracker holds the MEP at 0.2 mV by changing the intensity, so a coil offset shows up as a higher % MSO, not a smaller MEP. This is the primary outcome for the T-SICI block, adjusted for a time trend and coil x ISI (the coils do not count as one here, because % MSO depends on the coil).",
  reading_stats = "**Reading a slope.** `estimate` is per mm or per degree. For log MEP, `pct_change_per_unit` converts it to % MEP change; negative = the MEP shrinks as the coil drifts. For tracked MSO the estimate is % MSO per unit; positive = more intensity was needed. `ci_lo`/`ci_hi` are 95% limits, `p` the p-value, `n_strata` how many distinct stimulus settings contributed (2 to 3 is fragile), `rho_within` a rank correlation inside strata as a distribution-free check.",
  group = "**Group estimates.** *Two-stage*: each participant's slope is estimated separately, then combined by a random-effects mean (DerSimonian-Laird; `i2` is the share of variation due to real between-participant differences) and by a plain mean with a t test. `n_positive`/`n_negative` count participants by sign: 7 of 8 in one direction is convincing even when the pooled p is modest. *Mixed model*: all pulses in one model with a random slope per participant and a random intercept per stratum; `spec` says whether the random slope was kept or fell back to a random intercept.",
  decisions = "**Using the tolerance explorer.** Choose a distance and an angle. The table shows, per participant and coil, what share of on-target pulses would have passed, and the traffic light judges the median placement against the tolerance. The expected-loss line uses the group single-pulse slope to translate the tolerance into an MEP change; use it to pick a tolerance where the expected loss is small compared with normal MEP variability (a factor of two between successive pulses is common).",
  caveats = "**Caveats.** Offsets are measured at the nearest 20 Hz frame (within 0.15 s), not averaged. Pulses with the coil more than 25 mm or 30 degrees off are excluded as 'off the head'. MEPs below 0.02 mV are floored before the log. Crosshairs positions come from Brainsight's MNI registration on a model head; absolute mm are therefore approximate but consistent within a participant. Tracked-MSO slopes are confounded by the tracking dynamics and slow threshold drift; the time trend absorbs part of that."
)

# ---- UI ----------------------------------------------------------------
ui <- page_navbar(
  title = "Coil offset vs MEP",
  theme = bs_theme(version = 5, bootswatch = "flatly", primary = "#2a78d6", base_font = font_google("Inter")),
  fillable = FALSE,
  header = tags$head(tags$style(HTML("
    .value-box .value-box-title{font-size:0.85rem} .card{margin-bottom:1rem}
    .qc pre{font-size:0.78rem;white-space:pre-wrap} .small-note{color:#52514e;font-size:0.85rem}"))),

  nav_panel("Overview", icon = icon("gauge-high"),
    layout_columns(col_widths = c(3, 3, 3, 3),
      value_box("Participants", textOutput("vb_n", inline = TRUE), showcase = icon("users")),
      value_box("Pulses analysed", textOutput("vb_pulses", inline = TRUE), showcase = icon("bolt")),
      value_box("Pulses within 3 mm (on-target)", textOutput("vb_3mm", inline = TRUE), showcase = icon("bullseye")),
      value_box("Last run", textOutput("vb_run", inline = TRUE), showcase = icon("clock"))),
    layout_columns(col_widths = c(7, 5),
      card(card_header("What the data say"), uiOutput("findings"),
           p(class = "small-note", "Generated from the group tables by fixed rules (p < 0.05 in the pooled mixed models). Check the Group page before quoting.")),
      card(card_header("What this dashboard is"), markdown(TXT$overview), markdown(TXT$phases))),
    card(card_header("Where the coil was when each pulse fired (on-target phase)"),
         plotlyOutput("ov_placement", height = 520),
         info_card("How to read this", markdown("One box per participant and coil. The horizontal lines mark 3 mm and 5 mm, the SOP tolerances. A box sitting above 5 mm means most pulses of that block fired off target; a tall box means the coil wandered. Angle is the total rotation between coil and target orientation.")))
  ),

  nav_panel("Participant", icon = icon("user"),
    layout_sidebar(sidebar = sidebar(width = 280,
        selectInput("pp", "Participant", choices = NULL),
        selectInput("pp_dof", "Degrees of freedom to show", choices = DOF_CHOICES, selected = OS_DOF$var, multiple = TRUE),
        checkboxGroupInput("pp_class", "Pulse classes", choices = CLASS_CHOICES, selected = names(CLASS_LABELS)),
        radioButtons("pp_phase", "Phase", choices = c("On-target only" = "on-target", "All kept pulses" = "all")),
        markdown(TXT$phases)),
      card(card_header(textOutput("pp_title")), verbatimTextOutput("pp_qc"),
           info_card("How to read the QC", markdown("*QtracS launch*: pinned from the run log. *Matched to a QLG trigger*: share of QtracP rows with a real pulse time; should be ~100%. *Sweep-clock drift*: how far the xlsx elapsed time is from real time (why the QLG is used). *Clock offset*: the time-sync row used and whether it was labelled with this participant. *Targets*: which target each coil was measured against and for how long it was selected while that coil was in use. *Pulses joined*: kept vs dropped and why. *Placement*: median and spread of the coil's distance from target at the pulses, per phase."))),
      card(card_header("Coil offset over the session"),
           plotlyOutput("pp_timeline", height = 900),
           info_card("How to read this", markdown("Grey lines: the coil stream (0.5 s means), one panel per degree of freedom, clipped to the off-head limits. Dots: pulses, coloured by class (blue single, orange paired); hover for MSO, ISI and MEP. Orange dashed verticals: target selections. Shaded bands: which coil was in use and which target it was measured against. A steady offset from zero is a systematic placement error; a wandering trace is drift."))),
      card(card_header("MEP against each offset"),
           plotlyOutput("pp_dof", height = 560),
           info_card("How to read this", markdown("Each dot is one pulse in the chosen phase, colour = % MSO (darker = stronger). Because MSO differs between dots, do not read a slope off this picture: the table below holds the within-MSO slopes. Look for a fan opening downwards as the offset grows, and for how far the coil was allowed to drift at all (the x range)."))),
      card(card_header("Within-stratum effects for this participant"),
           layout_columns(col_widths = c(3, 3, 3, 3),
             selectInput("pp_outcome", "Outcome", c("MEP size (log)" = "log_mep", "MEP present" = "mep_present", "Tracked intensity (% MSO)" = "tracked_mso")),
             selectInput("pp_form", "Predictor form", c("|offset|" = "abs", "signed" = "signed", "magnitudes" = "magnitude")),
             selectInput("pp_level", "Level", c("Per class (ISIs pooled in strata)" = "class", "Per class x ISI" = "condition")),
             div()),
           DTOutput("pp_stats"), markdown(TXT$reading_stats)),
      card(card_header("Placement and targets"), DTOutput("pp_place"), DTOutput("pp_targets"))
    )),

  nav_panel("Group", icon = icon("chart-line"),
    layout_sidebar(sidebar = sidebar(width = 280,
        selectInput("g_class", "Pulse class", CLASS_CHOICES, selected = "single"),
        selectInput("g_outcome", "Outcome", c("MEP size (log)" = "log_mep", "Tracked intensity (% MSO)" = "tracked_mso", "MEP present" = "mep_present")),
        selectInput("g_form", "Predictor form", c("|offset|" = "abs", "signed" = "signed", "magnitudes" = "magnitude")),
        markdown(TXT$group)),
      card(card_header("Per-participant slopes and the group mean"), plotlyOutput("g_forest", height = 620),
           info_card("How to read this", markdown("One row per participant, the orange diamond is the random-effects mean. Bars are 95% confidence intervals; a bar crossing zero means that participant's data alone cannot tell the sign. Agreement in sign across most participants matters more than any single p-value. For MEP size, left of zero = MEP shrinks with offset. For tracked intensity, right of zero = more intensity needed."))),
      card(card_header("Pooled: MEP deviation from its stratum mean vs |offset|"), plotlyOutput("g_pooled", height = 560),
           info_card("How to read this", markdown("y is log(MEP) minus the mean of the pulses fired at the same MSO and ISI (both coils pooled), so intensity is removed. Thin blue lines: one per participant; orange: pooled. Slopes are shallow by design; a consistent downward tilt across panels is the signal."))),
      card(card_header("Two-stage summary (participant slopes combined)"), DTOutput("g_two"),
           markdown("`k` participants contributed. `re_*` random-effects mean, CI and p. `i2` heterogeneity. `n_positive`/`n_negative` sign counts.")),
      card(card_header("Pooled mixed models"), DTOutput("g_mixed"),
           markdown("`spec` random slope or fallback; `slope_sd_between_participants` how much the effect varies between people, in the same units as `estimate`."))
    )),

  nav_panel("Decisions", icon = icon("sliders"),
    layout_sidebar(sidebar = sidebar(width = 300,
        sliderInput("tol_mm", "Distance tolerance (mm)", min = 1, max = 10, value = 3, step = 0.5),
        sliderInput("tol_deg", "Angle tolerance (deg)", min = 1, max = 20, value = 10, step = 1),
        markdown(TXT$decisions)),
      layout_columns(col_widths = c(6, 6),
        card(card_header("Expected effect at this tolerance"), uiOutput("dec_expect")),
        card(card_header("Recommendations"), uiOutput("dec_reco"))),
      card(card_header("Would the pulses have passed? (on-target phase)"),
           info_card("How to read this", markdown("For each participant and coil: the share of on-target pulses inside BOTH tolerances, the median distance and angle, and a traffic light. Good: median inside tolerance and at least 80% of pulses pass. Warning: median inside tolerance but fewer than 80% pass. Critical: median outside tolerance. Blocks with fewer than 10 pulses are marked as thin evidence.")),
           plotlyOutput("dec_bar", height = 420), DTOutput("dec_tbl"))
    )),

  nav_panel("Methods & glossary", icon = icon("book"),
    layout_columns(col_widths = c(6, 6),
      card(card_header("Pipeline, step by step"), markdown("
1. **Pulse times.** The QtracP xlsx elapsed time is a sweep counter that drifts ahead of real time. Each xlsx row is paired with its `Trigger stim` line in the QtracS `.QLG`, whose elapsed seconds are real. The launch instant is pinned to a few ms from the log's wall-clock stamps. `mac_time = launch + elapsed - delta_s`, with `delta_s` (Windows minus Mac) read with its sign from the time-sync log.
2. **Targets.** Every visible Brainsight crosshairs frame is attributed to the target selected at that instant. Per coil, the target selected for the longest visible time while that coil was in use is its target (one target: shared; one per coil: own; more: longest wins). All in MNI.
3. **Six DoF** in the target's frame (rows of Brainsight's rotation matrix are the coil axes; row 3 is the outward normal).
4. **Pulse classes** from sheet D: single (ISI 0), paired (any other ISI, sign kept: + threshold-tracked T-SICI, - fixed-intensity A-SICI/SICF).
5. **Join.** Nearest coil frame within 0.15 s; pulses outside the recording, with the coil hidden, or > 25 mm / 30 deg off are dropped and counted.
6. **Phases** and the analysis set (on-target).
7. **Models** within strata; group by two-stage random effects and mixed models."),
           markdown(TXT$dof), markdown(TXT$strata), markdown(TXT$outcomes), markdown(TXT$caveats)),
      card(card_header("Glossary of columns"), DTOutput("glossary"))),
    card(card_header("Full run report (offset_study_report.md)"), uiOutput("report_md"))
  ),

  nav_panel("Run", icon = icon("play"),
    layout_columns(col_widths = c(5, 7),
      card(card_header("1. Data folders"),
           p(class = "small-note", "Where each kind of file lives. The starting values are at the top of app.R. What you type here is used at once and is remembered (data_paths.json) when you press Save, Add or Run."),
           dir_input("dir_xlsx", "QtracP exports (.xlsx)", DATA_DIRS0$xlsx),
           dir_input("dir_qlg", "QtracS run logs (.QLG)", DATA_DIRS0$qlg),
           dir_input("dir_bs", "Brainsight recordings (.txt)", DATA_DIRS0$brainsight),
           dir_input("dir_sync", "Time-sync logs (time_sync*.txt)", DATA_DIRS0$timesync),
           div(actionButton("save_dirs", "Save folders", icon = icon("save")),
               actionButton("reset_dirs", "Reset to script defaults", icon = icon("rotate-left")))),
      card(card_header("2. Participants to add"),
           p(class = "small-note", "Pick or type study IDs (a bare number such as 227 becomes SNBR-227). For each one the app finds the xlsx, the QLG (named by the code at the end of the xlsx name), the Brainsight file and the time-sync folder. Ready participants are added to the manifest when you press Add or Run; one already in the manifest only has its four paths refreshed."),
           selectizeInput("add_ids", NULL, choices = NULL, multiple = TRUE, width = "100%",
                          options = list(create = TRUE, placeholder = "SNBR-227, SNBR-191 ...")),
           DTOutput("staged"),
           actionButton("add_staged", "Add to manifest", icon = icon("plus")),
           hr(),
           checkboxInput("auto_add", "When I run the pipeline, also add every participant whose files are all found", TRUE),
           p(class = "small-note", "The folders are swept for every participant with a Brainsight recording. One is added when its xlsx, QLG, Brainsight file and time-sync folder are all found, the Brainsight recording and a time-sync row are dated the session day, and it is not in the manifest yet. A participant you set to include = FALSE is never switched back on."),
           uiOutput("auto_pending"))),
    layout_columns(col_widths = c(7, 5),
      card(card_header("3. Manifest (one row per participant)"),
           p(class = "small-note", "Double-click a cell to edit. include = TRUE/FALSE. clock_offset_s (optional) replaces the time-sync lookup. coord_system = MNI (default, blank) or Polaris (needs every coil in that session to have its own target). Run saves the manifest for you."),
           DTOutput("manifest"),
           div(actionButton("save_manifest", "Save manifest", icon = icon("save")),
               actionButton("del_rows", "Delete selected rows", icon = icon("trash")))),
      card(card_header("4. Settings for this run"),
           radioButtons("run_phase", "Effect models use", c("On-target pulses (recommended)" = "on-target", "All kept pulses" = "all")),
           numericInput("run_max_mm", "Off-head distance limit (mm)", 25, min = 5, max = 100),
           numericInput("run_max_deg", "Off-head angle limit (deg)", 30, min = 5, max = 90),
           textInput("run_tol_mm", "Placement tolerances reported (mm, comma-separated)", "2,3,5"),
           textInput("run_tol_deg", "Angle tolerances reported (deg)", "5,10"),
           actionButton("run_pipeline", "Add & run pipeline", class = "btn-primary", icon = icon("play")),
           actionButton("reload", "Reload outputs", icon = icon("arrows-rotate")),
           p(class = "small-note", "Run adds any ready participants from step 2, saves the manifest, then analyses every participant with include = TRUE and pools them. It takes a few minutes per participant (large Brainsight files). The log below updates live; outputs reload when it finishes."))),
    card(card_header("Run log"), verbatimTextOutput("run_log"))
  )
)

# ---- server ---------------------------------------------------------------
server <- function(input, output, session) {
  D <- reactiveVal(load_outputs())
  observeEvent(input$reload, D(load_outputs()))
  observe({
    ids <- D()$participants
    updateSelectInput(session, "pp", choices = ids, selected = if (length(ids)) ids[1] else NULL)
  })

  # -- overview ------------------------------------------------------
  output$vb_n <- renderText(length(D()$participants))
  output$vb_pulses <- renderText({ p <- D()$pulses; if (is.null(p)) "0" else format(sum(p$analysis_set, na.rm = TRUE), big.mark = ",") })
  output$vb_3mm <- renderText({ p <- D()$pulses; if (is.null(p)) "-" else sprintf("%.0f%%", 100 * mean(p$trans_dist_mm[p$analysis_set] <= 3, na.rm = TRUE)) })
  output$vb_run <- renderText({ i <- D()$info; if (is.null(i)) "never" else i$run_time })
  output$findings <- renderUI(tags$ul(lapply(make_findings(D()), tags$li)))
  output$ov_placement <- renderPlotly({
    p <- D()$pulses; req(p)
    g <- os_plot_placement(p %>% mutate(nav_phase = as.character(nav_phase)), phase = "on-target")
    req(g); ggplotly(g + labs(title = NULL, subtitle = NULL), tooltip = c("x", "y", "colour")) %>% layout(legend = list(orientation = "h", y = 1.08))
  })

  # -- participant --------------------------------------------------
  P <- reactive({ req(input$pp); load_participant(input$pp) })
  pp_pulses <- reactive({
    p <- D()$pulses; req(p, input$pp)
    p %>% filter(participant == input$pp, kept, pulse_class %in% input$pp_class,
                 input$pp_phase == "all" | nav_phase == input$pp_phase)
  })
  output$pp_title <- renderText(sprintf("%s: quality control", input$pp))
  output$pp_qc <- renderText(paste(P()$qc, collapse = "\n"))

  output$pp_timeline <- renderPlotly({
    st <- P()$stream; req(st, length(input$pp_dof) > 0)
    pl <- pp_pulses(); ev <- P()$events; bl <- P()$blocks
    cfg <- D()$info$cfg; cmm <- if (!is.null(cfg)) cfg$max_offset_mm else 25; cdg <- if (!is.null(cfg)) cfg$max_angle_deg else 30
    dofs <- input$pp_dof
    plots <- lapply(dofs, function(v) {
      lim <- if (grepl("_mm$", v)) cmm else cdg
      s <- st %>% mutate(y = pmax(pmin(.data[[v]], lim), -lim))
      q <- pl %>% mutate(y = pmax(pmin(.data[[v]], lim), -lim),
                         txt = sprintf("%s<br>%s  MSO %g  ISI %g ms<br>MEP %.3f mV<br>%s = %.2f", format(mac_time, "%H:%M:%S"),
                                       pulse_class, mso, isi_ms, ptp_mv, v, .data[[v]]))
      fig <- plot_ly()
      if (!is.null(bl)) for (k in seq_len(nrow(bl)))
        fig <- fig %>% add_segments(x = bl$start[k], xend = bl$end[k], y = lim * 0.95, yend = lim * 0.95,
                                    line = list(color = "#c8c6bf", width = 6), hoverinfo = "text",
                                    text = paste(bl$coil[k], "in use"), showlegend = FALSE)
      fig <- fig %>%
        add_lines(data = s, x = ~t, y = ~y, split = ~coil, line = list(color = "#52514e", width = 1),
                  hoverinfo = "skip", showlegend = FALSE) %>%
        add_markers(data = q, x = ~mac_time, y = ~y, color = ~pulse_class, colors = OS_CLASS_COL,
                    text = ~txt, hoverinfo = "text", marker = list(size = 6), showlegend = (v == dofs[1]), legendgroup = ~pulse_class)
      if (!is.null(ev) && nrow(ev)) fig <- fig %>% add_segments(data = ev %>% filter(!is.na(target_name)), x = ~t, xend = ~t, y = -lim, yend = lim,
                    line = list(color = OS_COL$orange, width = 1, dash = "dot"), hoverinfo = "text",
                    text = ~paste("target selected:", target_name), showlegend = FALSE)
      fig %>% layout(yaxis = list(title = DOF_SHORT_LABELS[[v]], zeroline = TRUE, zerolinecolor = "#b8b6ae"),
                     shapes = list(list(type = "line", x0 = 0, x1 = 1, xref = "paper", y0 = 0, y1 = 0, line = list(color = "#b8b6ae", width = 1))))
    })
    subplot(plots, nrows = length(plots), shareX = TRUE, titleY = TRUE) %>%
      layout(hovermode = "closest", legend = list(orientation = "h", y = 1.02), margin = list(l = 70))
  })

  output$pp_dof <- renderPlotly({
    q <- pp_pulses(); req(nrow(q) > 0)
    vars <- paste0("abs_", OS_DOF$var)
    dl <- q %>% select(participant, pulse_class, mso, isi_ms, ptp_mv, mac_time, all_of(vars)) %>%
      pivot_longer(all_of(vars), names_to = "dof", values_to = "value") %>%
      mutate(dof = factor(dof, levels = vars, labels = paste0("|", OS_DOF$label, "| (", OS_DOF$unit, ")")),
             txt = sprintf("%s  MSO %g  ISI %g<br>MEP %.3f mV  offset %.2f", pulse_class, mso, isi_ms, ptp_mv, value))
    g <- ggplot(dl, aes(value, ptp_mv, text = txt)) +
      geom_point(aes(colour = mso), size = 1.3, alpha = 0.8) +
      facet_grid(pulse_class ~ dof, scales = "free_x") + scale_y_log10() +
      scale_colour_gradientn(colours = OS_MSO_RAMP, name = "% MSO") +
      labs(x = "offset from target", y = "MEP (mV, log)") + os_theme(9)
    ggplotly(g, tooltip = "text")
  })

  output$pp_stats <- renderDT({
    s <- D()$stats; req(s, input$pp)
    s <- s %>% filter(participant == input$pp, outcome == input$pp_outcome, form == input$pp_form, level == input$pp_level) %>%
      mutate(sig = sig_mark(p), p = fmt_p(p)) %>%
      select(pulse_class, isi_ms, predictor = pred_label, n, n_strata, estimate, ci_lo, ci_hi, p, sig, pct_change_per_unit, rho_within, note)
    tbl_or_msg(disp(s), "No model for this selection (too few pulses).")
  })
  output$pp_place <- renderDT({
    p <- D()$place; req(p, input$pp)
    tbl_or_msg(disp(p %>% filter(participant == input$pp) %>% select(-participant)))
  })
  output$pp_targets <- renderDT({ t <- P()$targets; tbl_or_msg(disp(t), "no target table") })

  # -- group ----------------------------------------------------------
  output$g_forest <- renderPlotly({
    s <- D()$stats; ts <- D()$two_stage; req(s, ts)
    g <- os_plot_forest(s, ts, input$g_class, outcome = input$g_outcome, form = input$g_form)
    validate(need(!is.null(g), "No estimates for this selection."))
    ggplotly(g + labs(title = NULL, subtitle = NULL), tooltip = c("x", "y", "xmin", "xmax"))
  })
  output$g_pooled <- renderPlotly({
    p <- D()$pulses; req(p)
    g <- os_plot_pooled(p %>% mutate(pulse_class = as.character(pulse_class)))
    validate(need(!is.null(g), "No pooled data yet."))
    ggplotly(g + labs(title = NULL, subtitle = NULL), tooltip = c("x", "y"))
  })
  output$g_two <- renderDT({
    t <- D()$two_stage; req(t)
    t <- t %>% filter(pulse_class == input$g_class, outcome == input$g_outcome, form == input$g_form) %>%
      mutate(sig = sig_mark(re_p), re_p = fmt_p(re_p), t_p = fmt_p(t_p)) %>%
      select(predictor = pred_label, k, re_estimate, re_ci_lo, re_ci_hi, re_p, sig, pct_change_per_unit, i2, mean_slope, se_mean, t_p, n_positive, n_negative)
    tbl_or_msg(disp(t))
  })
  output$g_mixed <- renderDT({
    m <- D()$mixed; req(m)
    m <- m %>% filter(pulse_class == input$g_class, outcome == input$g_outcome, form == input$g_form) %>%
      mutate(sig = sig_mark(p), p = fmt_p(p)) %>%
      select(predictor = pred_label, spec, n_pulses, n_participants, n_strata, estimate, ci_lo, ci_hi, p, sig, pct_change_per_unit, slope_sd_between_participants)
    tbl_or_msg(disp(m), "No mixed model for this selection (needs >= 3 participants).")
  })

  # -- decisions ------------------------------------------------------
  dec_tbl <- reactive({
    p <- D()$pulses; req(p)
    p %>% filter(analysis_set) %>% group_by(participant, coil) %>%
      summarise(n = n(), median_mm = median(trans_dist_mm), median_deg = median(ang_dist_deg),
                pct_pass = 100 * mean(trans_dist_mm <= input$tol_mm & ang_dist_deg <= input$tol_deg),
                pct_pass_dist = 100 * mean(trans_dist_mm <= input$tol_mm),
                pct_pass_ang = 100 * mean(ang_dist_deg <= input$tol_deg), .groups = "drop") %>%
      mutate(status = case_when(median_mm > input$tol_mm | median_deg > input$tol_deg ~ "critical",
                                pct_pass < 80 ~ "warning", TRUE ~ "good"),
             evidence = ifelse(n < 10, "thin (< 10 pulses)", "ok"))
  })
  output$dec_bar <- renderPlotly({
    d <- dec_tbl(); req(nrow(d) > 0)
    g <- ggplot(d, aes(participant, pct_pass, fill = coil, text = sprintf("%s %s: %.0f%% pass (n=%d)", participant, coil, pct_pass, n))) +
      geom_col(position = position_dodge(width = 0.7), width = 0.6) +
      geom_hline(yintercept = 80, colour = "#b8b6ae") +
      scale_fill_manual(values = c(OS_COL$blue, OS_COL$orange, OS_COL$aqua), name = "Coil") +
      scale_y_continuous(limits = c(0, 100)) +
      labs(x = NULL, y = sprintf("%% of pulses within %g mm and %g deg", input$tol_mm, input$tol_deg)) + os_theme()
    ggplotly(g, tooltip = "text") %>% layout(legend = list(orientation = "h", y = 1.1))
  })
  output$dec_tbl <- renderDT({
    d <- dec_tbl() %>% mutate(across(c(median_mm, median_deg, pct_pass, pct_pass_dist, pct_pass_ang), ~ round(.x, 1)))
    d$status <- sprintf('<span style="color:%s;font-weight:600">%s %s</span>',
                        unlist(STATUS[d$status]),
                        c(good = "\u2714", warning = "\u26A0", critical = "\u2716")[d$status], d$status)
    datatable(d, escape = FALSE, rownames = FALSE, options = dt_opts(20))
  })
  output$dec_expect <- renderUI({
    m <- D()$mixed; req(m)
    s <- m %>% filter(outcome == "log_mep", pulse_class == "single", form == "magnitude", dof == "trans_dist_mm")
    a <- m %>% filter(outcome == "log_mep", pulse_class == "single", form == "magnitude", dof == "ang_dist_deg")
    t <- m %>% filter(outcome == "tracked_mso", pulse_class == "paired", form == "magnitude", dof == "trans_dist_mm")
    li <- list()
    if (nrow(s)) li <- c(li, list(tags$li(sprintf("Single pulses: a coil %g mm off target gives an expected MEP change of %.0f%% (95%% CI %.0f%% to %.0f%%), from the pooled slope of %.1f%% per mm.",
      input$tol_mm, 100 * (exp(s$estimate * input$tol_mm) - 1), 100 * (exp(s$ci_lo * input$tol_mm) - 1), 100 * (exp(s$ci_hi * input$tol_mm) - 1), s$pct_change_per_unit))))
    if (nrow(a)) li <- c(li, list(tags$li(sprintf("Single pulses: %g deg of rotation gives an expected MEP change of %.0f%% (CI %.0f%% to %.0f%%).",
      input$tol_deg, 100 * (exp(a$estimate * input$tol_deg) - 1), 100 * (exp(a$ci_lo * input$tol_deg) - 1), 100 * (exp(a$ci_hi * input$tol_deg) - 1)))))
    if (nrow(t)) li <- c(li, list(tags$li(sprintf("Threshold tracking: %g mm off target shifts the tracked intensity by %+.1f %% MSO (CI %+.1f to %+.1f).",
      input$tol_mm, t$estimate * input$tol_mm, t$ci_lo * input$tol_mm, t$ci_hi * input$tol_mm))))
    if (!length(li)) li <- list(tags$li("No pooled slopes yet."))
    tagList(tags$ul(li), p(class = "small-note", "Linear extrapolation of the pooled slopes; MEP size varies by a factor of two between successive pulses even with a fixed coil, so a few percent is within noise."))
  })
  output$dec_reco <- renderUI({
    d <- dec_tbl(); req(nrow(d) > 0)
    nc <- sum(d$status == "critical"); nw <- sum(d$status == "warning")
    worst <- d %>% arrange(desc(median_mm)) %>% slice(1)
    tags$ul(
      tags$li(sprintf("%d of %d participant-coil blocks would be flagged critical and %d warning at %g mm / %g deg.", nc, nrow(d), nw, input$tol_mm, input$tol_deg)),
      tags$li(sprintf("Worst block: %s %s, median %.1f mm.", worst$participant, worst$coil, worst$median_mm)),
      tags$li("Register the target in Brainsight before the first pulse of each coil, and start the Brainsight recording before hotspotting, so every pulse is analysable."),
      tags$li("For threshold-tracked runs judge drift by the tracked intensity, not by MEP size."),
      tags$li("Set the live monitor's linear threshold to the distance chosen here and add an angular threshold; re-run this pipeline on later sessions to confirm the placement figures improve."))
  })

  # -- methods ---------------------------------------------------------
  output$glossary <- renderDT({
    g <- tribble(~column, ~meaning,
      "pulse_class", "single (ISI 0), paired (any other ISI, sign kept)",
      "isi_ms", "conditioning delay from sheet D; + threshold-tracked, - fixed intensity",
      "mso", "stimulator output (% MSO) of the test pulse", "ptp_mv", "MEP peak-to-peak (mV)",
      "log_ptp", "log(MEP) after flooring at 0.02 mV", "mep_present", "MEP >= 0.05 mV",
      "nav_phase", "pre-target / on-target (was the coil's target already selected?)",
      "run_phase", "hotspot_rmt / tsici / fixed_int / post", "tracked", "intensity was being tracked (T-SICI block)",
      "coil", "crosshairs driver in Brainsight (Coil A CT, Coil B LCT)", "target", "target assigned to that coil",
      "target_at_frame", "target selected at the pulse instant (QC)",
      "dx_mm, dy_mm", "in-plane shift along the target's x and y axes", "dz_mm", "shift along the normal (+ = lifted)",
      "rx_deg, ry_deg", "tilt about the target's x and y axes", "rz_deg", "twist about the normal",
      "trans_dist_mm", "sqrt(dx^2 + dy^2 + dz^2)", "tangential_mm", "sqrt(dx^2 + dy^2)",
      "ang_dist_deg", "total rotation angle between coil and target", "tilt_deg", "sqrt(rx^2 + ry^2)", "twist_deg", "|rz|",
      "abs_*", "absolute value of the DoF (primary predictor)", "match_gap_s", "time between pulse and the coil frame used",
      "drop_reason / kept", "why a pulse was excluded from the join", "analysis_set", "kept and in the analysis phase",
      "stratum", "participant | class | ISI | MSO (both coils share one)", "ci_stratum", "participant | coil | class | ISI (baseline of the tracked-intensity model)",
      "estimate", "slope per mm or per degree", "pct_change_per_unit", "100*(exp(estimate)-1) for log outcomes",
      "rho_within", "pooled within-stratum Spearman correlation", "n_strata", "distinct stimulus settings in the model",
      "re_estimate / re_p", "random-effects mean of participant slopes and its p", "i2", "heterogeneity between participants",
      "spec", "mixed model: random slope kept or random intercept fallback",
      "pct_within_Xmm", "share of kept pulses within X mm of target (per phase)")
    datatable(g, rownames = FALSE, options = list(pageLength = 40, dom = "ft"))
  })
  output$report_md <- renderUI({ r <- D()$report; if (is.null(r)) p("No report yet.") else includeMarkdown(r) })

  # -- run -------------------------------------------------------------
  # 1. data folders: typed values are used at once; saved on Save / Add / Run
  dirs <- reactive(list(xlsx = os_norm_dir(input$dir_xlsx), qlg = os_norm_dir(input$dir_qlg),
                        brainsight = os_norm_dir(input$dir_bs), timesync = os_norm_dir(input$dir_sync)))
  dirs_d <- debounce(dirs, 600)      # the file lists below are not rebuilt on every keystroke
  dir_status <- function(dir, pattern, what) {
    if (!nzchar(dir)) return(status_badge("critical", "no folder set"))
    if (!dir.exists(dir)) return(status_badge("critical", "folder not found"))
    n <- length(os_list_dir(dir, pattern))
    if (n == 0L) status_badge("warning", paste("no", what, "in this folder")) else status_badge("good", paste(n, what))
  }
  output$dir_xlsx_status <- renderUI(dir_status(dirs_d()$xlsx, "[.]xlsx$", ".xlsx files"))
  output$dir_qlg_status  <- renderUI(dir_status(dirs_d()$qlg, "[.]qlg$", ".QLG files"))
  output$dir_bs_status   <- renderUI(dir_status(dirs_d()$brainsight, "[.]txt$", ".txt files"))
  output$dir_sync_status <- renderUI(dir_status(dirs_d()$timesync, "^time_sync.*[.]txt$", "time_sync files"))
  persist_dirs <- function() {
    if (!requireNamespace("jsonlite", quietly = TRUE)) {
      showNotification("Install the 'jsonlite' package to remember the folders between sessions.", type = "warning")
      return(invisible(FALSE))
    }
    ok <- tryCatch({ jsonlite::write_json(dirs(), DATA_DIRS_FILE, auto_unbox = TRUE, pretty = TRUE); TRUE },
                   error = function(e) { showNotification(paste("Could not save the folders:", conditionMessage(e)), type = "error"); FALSE })
    invisible(ok)
  }
  observeEvent(input$save_dirs, if (persist_dirs()) showNotification("Folders saved.", type = "message"))
  observeEvent(input$reset_dirs, {
    if (file.exists(DATA_DIRS_FILE)) file.remove(DATA_DIRS_FILE)
    updateTextInput(session, "dir_xlsx", value = DATA_DIRS_DEFAULT$xlsx)
    updateTextInput(session, "dir_qlg", value = DATA_DIRS_DEFAULT$qlg)
    updateTextInput(session, "dir_bs", value = DATA_DIRS_DEFAULT$brainsight)
    updateTextInput(session, "dir_sync", value = DATA_DIRS_DEFAULT$timesync)
    showNotification("Folders reset to the defaults at the top of app.R.", type = "message")
  })

  # 2. participants to add: IDs -> their files, previewed live
  observe({
    ids <- os_scan_ids(dirs_d()$xlsx)
    keep <- isolate(input$add_ids)
    updateSelectizeInput(session, "add_ids", choices = union(ids, keep), selected = keep)
  })
  staged <- reactive({
    ids <- os_norm_id(input$add_ids)
    if (!length(ids)) NULL else os_locate_files(ids, dirs_d())
  })
  output$staged <- renderDT({
    s <- staged()
    if (is.null(s))
      return(datatable(data.frame(note = "Nothing to add yet: pick or type a study ID above."),
                       rownames = FALSE, selection = "none", options = list(dom = "t")))
    nm <- function(x) ifelse(is.na(x), "—", basename(x))
    disp <- data.frame(Participant = s$participant,
                       Status = ifelse(s$status == "ok", "✔ ready", paste0("✖ ", s$status)),
                       xlsx = nm(s$xlsx), QLG = nm(s$qlg), Brainsight = nm(s$brainsight),
                       `Time sync` = ifelse(s$n_sync > 0, paste(s$n_sync, "files"), "—"),
                       Note = trimws(paste0(ifelse(nzchar(s$hold), paste0("CHECK: ", s$hold, ". "), ""), s$note)),
                       check.names = FALSE)
    datatable(disp, rownames = FALSE, selection = "none", options = list(dom = "t", scrollX = TRUE, pageLength = 50))
  })

  # 3. manifest
  man_path <- file.path(STUDY_DIR, "manifest.csv")
  man <- reactiveVal(if (file.exists(man_path)) read_csv(man_path, show_col_types = FALSE, col_types = cols(.default = col_character()))
                     else os_merge_manifest(NULL, os_locate_files(character(0), list())))
  write_man <- function(m) write_csv(m, man_path, na = "")
  output$manifest <- renderDT(datatable(man(), editable = TRUE, rownames = FALSE, selection = "multiple",
                                        options = list(pageLength = 15, dom = "t", scrollX = TRUE)))
  observeEvent(input$manifest_cell_edit, {
    m <- man(); e <- input$manifest_cell_edit
    m[e$row, e$col + 1L] <- as.character(e$value); man(m)
  })
  observeEvent(input$save_manifest, {
    write_man(man())
    showNotification("Manifest saved.", type = "message")
  })
  observeEvent(input$del_rows, {
    i <- input$manifest_rows_selected; req(length(i) > 0L)
    m <- man()[-i, , drop = FALSE]; man(m); write_man(m)
    showNotification(sprintf("Removed %d row(s) from the manifest.", length(i)), type = "message")
  })

  # Add the ready participants from step 2 to the manifest (paths refreshed for
  # one already listed). The ones that could not be completed stay in the box.
  commit_staged <- function() {
    ids <- os_norm_id(input$add_ids)
    if (!length(ids)) return(invisible(0L))
    s <- os_locate_files(ids, dirs())           # fresh, not the debounced preview
    ok <- s[s$status == "ok", , drop = FALSE]; bad <- s[s$status != "ok", , drop = FALSE]
    if (nrow(ok)) {
      m <- os_merge_manifest(man(), ok); man(m); write_man(m)
      showNotification(paste("Added to the manifest:", paste(ok$participant, collapse = ", ")), type = "message")
    }
    if (nrow(bad))
      showNotification(paste0("Not added: ", paste(sprintf("%s (%s)", bad$participant, bad$status), collapse = " | ")),
                       type = "warning", duration = 15)
    updateSelectizeInput(session, "add_ids", choices = union(os_scan_ids(dirs()$xlsx), bad$participant),
                         selected = bad$participant)
    persist_dirs()
    invisible(nrow(ok))
  }
  observeEvent(input$add_staged, {
    if (!length(os_norm_id(input$add_ids))) showNotification("Pick or type a study ID first.", type = "warning")
    else commit_staged()
  })

  # Automatic sweep: every participant with a Brainsight recording whose files
  # are all found (os_scan_folders), shown live and applied when Run is pressed.
  # Only the manifest's ids and include flags matter to the sweep, so it is
  # recomputed when those change, not on every cell edit.
  man_state <- reactiveVal(NULL)
  observe(man_state(paste(toupper(man()$participant), toupper(man()$include))))
  sweep <- reactive({
    man_state()
    invalidateLater(30000)          # files copied in while the page is open show up (a sweep takes ~0.3 s)
    os_scan_folders(dirs_d(), isolate(man()))
  })
  id_list <- function(d) paste(d$participant, collapse = ", ")
  reason_list <- function(d) paste(sprintf("%s (%s)", d$participant, d$reason), collapse = "; ")
  output$auto_pending <- renderUI({
    s <- sweep()
    tagList(
      if (!isTRUE(input$auto_add)) p(class = "small-note", "Automatic adding is off.")
      else if (nrow(s$add)) p(status_badge("good", sprintf("%d ready to add when you run: %s", nrow(s$add), id_list(s$add))))
      else p(class = "small-note", "No new participant with all files found."),
      if (nrow(s$excluded)) p(status_badge("warning", sprintf("Complete, but include = FALSE in the manifest (not added): %s", id_list(s$excluded)))),
      if (nrow(s$waiting)) p(status_badge("warning", sprintf("Recording found, still waiting for files: %s", reason_list(s$waiting))))
    )
  })
  # Add what the sweep finds. Returns how many were added.
  auto_add_ready <- function() {
    s <- os_scan_folders(dirs(), man())            # fresh, not the debounced preview
    if (nrow(s$add)) {
      add <- s$add
      add$note <- paste0("auto-added ", Sys.Date(), ifelse(nzchar(add$note), paste0("; ", add$note), ""))
      m <- os_merge_manifest(man(), add); man(m); write_man(m)
      showNotification(paste("Added automatically (all files found):", id_list(add)), type = "message", duration = 12)
    }
    if (nrow(s$excluded))
      showNotification(paste0("Complete but excluded (include = FALSE), so not run: ", id_list(s$excluded),
                              ". Set include = TRUE in the manifest to analyse them."), type = "warning", duration = 20)
    if (nrow(s$waiting))
      showNotification(paste("Not added yet, waiting for files:", reason_list(s$waiting)), type = "warning", duration = 20)
    invisible(nrow(s$add))
  }

  # 4. run
  included <- function(m) os_is_included(m$include)
  # What would make an included participant fail: reported before starting, not blocking.
  manifest_problems <- function(m) {
    unlist(lapply(which(included(m)), function(i) {
      r <- m[i, ]; p <- character(0)
      for (cl in c("xlsx", "qlg", "brainsight"))
        if (is.na(r[[cl]]) || !file.exists(r[[cl]])) p <- c(p, paste(cl, "file not found"))
      if ((is.na(r$clock_offset_s) || !nzchar(r$clock_offset_s)) && (is.na(r$timesync) || !file.exists(r$timesync)))
        p <- c(p, "time-sync path not found (and no clock_offset_s)")
      if (length(p)) sprintf("%s: %s", r$participant, paste(p, collapse = ", "))
    }))
  }
  num_list <- function(x) { v <- suppressWarnings(as.numeric(strsplit(x, ",")[[1L]])); v[!is.na(v)] }
  run_proc <- reactiveVal(NULL); run_logfile <- reactiveVal(NULL)
  observeEvent(input$run_pipeline, {
    req(is.null(run_proc()) || !run_proc()$is_alive())
    if (isTRUE(input$auto_add)) auto_add_ready()
    commit_staged()
    m <- man()
    if (!any(included(m))) {
      showNotification("Nothing to run: no participant in the manifest has include = TRUE.", type = "error"); return()
    }
    write_man(m); persist_dirs()
    probs <- manifest_problems(m)
    if (length(probs))
      showNotification(paste0("These will fail and be skipped: ", paste(probs, collapse = " | ")), type = "warning", duration = 20)
    lf <- tempfile("offset_run_", fileext = ".log"); run_logfile(lf)
    ovr <- list(analysis_phase = input$run_phase, max_offset_mm = input$run_max_mm, max_angle_deg = input$run_max_deg)
    if (length(num_list(input$run_tol_mm))) ovr$tol_mm <- num_list(input$run_tol_mm)
    if (length(num_list(input$run_tol_deg))) ovr$tol_deg <- num_list(input$run_tol_deg)
    proc <- callr::r_bg(function(root, ovr) {
      # run_offset_study.R picks these up with exists(), which only sees the
      # global environment; plain local variables here would be ignored.
      assign("PROJECT_ROOT", root, envir = globalenv())
      assign("CFG_OVERRIDE", ovr, envir = globalenv())
      source(file.path(root, "analysis", "offset_study", "run_offset_study.R"))
    }, args = list(root = PROJECT_ROOT, ovr = ovr), stdout = lf, stderr = "2>&1", wd = PROJECT_ROOT)
    run_proc(proc)
    showNotification("Pipeline started.", type = "message")
  })
  log_text <- reactivePoll(1500, session,
    checkFunc = function() { lf <- run_logfile(); if (is.null(lf) || !file.exists(lf)) 0 else file.info(lf)$size },
    valueFunc = function() { lf <- run_logfile(); if (is.null(lf) || !file.exists(lf)) "No run yet." else paste(tail(readLines(lf, warn = FALSE), 60), collapse = "\n") })
  output$run_log <- renderText({
    pr <- run_proc()
    txt <- log_text()
    if (!is.null(pr) && !pr$is_alive() && !isTRUE(session$userData$reloaded)) {
      session$userData$reloaded <- TRUE; D(load_outputs())
      txt <- paste(txt, "\n\n[finished: outputs reloaded]")
    }
    if (!is.null(pr) && pr$is_alive()) { session$userData$reloaded <- FALSE; invalidateLater(2000) }
    txt
  })
}

shinyApp(ui, server)
