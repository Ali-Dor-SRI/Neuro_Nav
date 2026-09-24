# =====================================================================
# qtrac_mep_pipeline.R
#
# QtracP export -> MEP table -> joined to coil placement from Brainsight.
# Run it case by case: edit the CONFIG block, then step through the rest.
# Open Neuro_Nav.Rproj first -- all paths are relative to the project root.
# =====================================================================

library(tidyverse)
library(readxl)
source("data_analysis/R/parse_brainsight.R")

# =====================================================================
# CONFIG  -- everything you change per participant lives here
# =====================================================================

# ---- files ----------------------------------------------------------
neuronav_path <- "Y:/Neuro_Nav_App/data/BS_Recordings/SNBR-188.txt"
neuronav_info <- brainsight_info(neuronav_path)
QTRAC_path    <- "Y:/Merged Data/xlsx Data/SNBR-188-FU1-TP3C60728A.xlsx"
QLG_file      <- "Y:/Merged Data/Data/TP3C60728A.QLG"
join_meps_R   <- "data_analysis/join_meps.R"


# ---- sheets and columns ---------------------------------------------
QTRAC_cols  <- c(Time = "Elapsed Time (min)", Channel = "Channel", Values = "Values")
sheet_T     <- "T"          # stimulator output
sheet_P     <- "P"          # MEP peak-to-peak
sheet_D     <- "D"          # conditioning delay
P_time_col  <- "...1"       # wide-format columns on sheet P, used by the
P_chan_col  <- "Chan  1"    #   histogram check only

# ---- filters --------------------------------------------------------
QC_channel  <- 5            # channel isolated in df_t_1
delay_test  <- 0            # D value marking an unconditioned test pulse
PTP_min     <- 0.16         # MEP amplitude window (mV)
PTP_max     <- 0.24
MSO_min     <- 5            # keep pulses above this stimulator output
hist_breaks <- 50

# ---- neuronav join --------------------------------------------------
T_delta      <- 0.081863     # clock offset in SECONDS, Windows - Mac
sample_name  <- "Sample 1"   # target the coil deltas are measured from
coord_system <- "MNI"        # "MNI": navigated coil pose in anatomical space,
                             #   from Crosshairs Position -- ONE target shared by
                             #   both coils, so a coil swap stays comparable.
                             # "Polaris": raw coil tracker relative to the head
                             #   tracker; each coil then gets its OWN target
                             #   (the arrays are different rigid bodies), so
                             #   only the coil holding `sample_name` is anchored
                             #   to it and the other starts from its first frame.

# =====================================================================


df_t_0 <- read_excel(QTRAC_path,
                     sheet = sheet_T) |>
  select(all_of(QTRAC_cols))

df_t_1 <- df_t_0 |>
  filter(Channel == QC_channel)


df_p_0 <- read_excel(QTRAC_path,
                     sheet = sheet_P)



df_D_0 <- read_excel(QTRAC_path,
                     sheet = sheet_D) |>
  select(all_of(QTRAC_cols))


df_D_1 <- df_D_0 |>
  filter(Values == delay_test) |>
  rename(Delay = Values) |>
  select(Time)


t_sici_start <- min(df_D_1$Time)
t_sici_end <- max(df_D_1$Time)


df_p_1 <- df_p_0 |>
  select(Time = all_of(P_time_col), Chan_1 = all_of(P_chan_col)) |>
  filter(Chan_1 <= PTP_max & Chan_1 >= PTP_min) |>
  filter(Time >= t_sici_start & Time <= t_sici_end)

hist(df_p_1$Chan_1, breaks = hist_breaks)


df_p_2 <- df_p_0 |>
  select(all_of(QTRAC_cols)) |>
  filter(Values <= PTP_max & Values >= PTP_min) |>
  rename(PTP = Values)



df_t_2 <- df_t_0 |>
  rename(MSO = Values)


df2 <- df_t_2 |>
  select(-Channel) |>
  filter(MSO > MSO_min) |>
  inner_join(df_p_2, by = "Time")


df3 <- df2 |>
  inner_join(df_D_1, by = "Time")


ggplot(df3, aes(x = MSO, y = PTP, color = Time)) +
  geom_point()+
  theme_minimal()



source(join_meps_R)


merged_df <- join_MEPs(
  diff = T_delta,
  QLG = QLG_file,
  new_df = df2,
  neuronav = neuronav_path,
  sample = sample_name,
  coord_system = coord_system)

ggplot(merged_df,
       aes(
         x = trans_dist_mm,
         y = PTP,
         color = MSO,
         shape = coil))+
  geom_point()+
  theme_minimal()
