library(tidyverse)
library(readxl)


df_t_0 <- read_excel("data/QTRAC_export/SNBR-179-MT-FU1-TP3C60702A.xlsx",
                  sheet = "T") |> 
  select("Elapsed Time (min)", Channel, Values)

df_t_1 <- df_t_0 |> 
  filter(Channel == 5)


df_p_0 <- read_excel("data/QTRAC_export/SNBR-179-MT-FU1-TP3C60702A.xlsx",
                               sheet = "P")
                     


df_D_0 <- read_excel("data/QTRAC_export/SNBR-179-MT-FU1-TP3C60702A.xlsx",
                  sheet = "D") |> 
  select(Time = "Elapsed Time (min)", Channel, Values)


df_D_1 <- df_D_0 |> 
  filter(Values == 0) |> 
  rename(Delay = Values) |> 
  select(Time)


t_sici_start <- min(df_D_1$Time)
t_sici_end <- max(df_D_1$Time)


df_p_1 <- df_p_0 |> 
  select(Time = ...1, Chan_1 = "Chan  1") |> 
  filter(Chan_1 <= 0.24 & Chan_1 >= 0.16) |> 
  filter(Time >= t_sici_start & Time <= t_sici_end)

hist(df_p_1$Chan_1, breaks = 50)


df_p_2 <- df_p_0 |> 
  select(Time = "Elapsed Time (min)", Channel, Values) |> 
  filter(Values <= 0.24 & Values >= 0.16) |> 
  rename(PTP = Values)



df_t_2 <- df_t_0 |> 
  rename(MSO = Values,
         Time = "Elapsed Time (min)")


df2 <- df_t_2 |> 
  select(-Channel) |> 
  filter(MSO>5) |> 
  inner_join(df_p_2, by = "Time")


df3 <- df2 |> 
  inner_join(df_D_1, by = "Time")


ggplot(df3, aes(x = MSO, y = PTP, color = Time)) +
  geom_point()+
  theme_minimal()



source("analysis/join_meps.R")


QLG_file <- ("data/QLG/TP3C60702A.QLG")
T_delta <- 0.472957
neuronav_path <- ("data/BS_Recordings/SNBR-179.txt")


merged_df <- join_MEPs(
  diff = T_delta,
  QLG = QLG_file,
  new_df = df2,
  neuronav = neuronav_path,
  sample = "Sample 1")

ggplot(merged_df,
       aes(
         x = trans_dist_mm,
         y = PTP,
         color = MSO,
         shape = coil))+
  geom_point()+
  theme_minimal()


#==== PT SNBR-188 ====

df_path <- "data/QTRAC_export/SNBR-188-FU1-TP3C60728A.xlsx"



df_t_0 <- read_excel(df_path,
                     sheet = "T") |> 
  select("Elapsed Time (min)", Channel, Values)

df_t_1 <- df_t_0 |> 
  filter(Channel == 5)


df_p_0 <- read_excel(df_path,
                     sheet = "P")



df_D_0 <- read_excel(df_path,
                     sheet = "D") |> 
  select(Time = "Elapsed Time (min)", Channel, Values)


df_D_1 <- df_D_0 |> 
  filter(Values == 0) |> 
  rename(Delay = Values) |> 
  select(Time)


t_sici_start <- min(df_D_1$Time)
t_sici_end <- max(df_D_1$Time)


df_p_1 <- df_p_0 |> 
  select(Time = ...1, Chan_1 = "Chan  1") |> 
  filter(Chan_1 <= 0.3 & Chan_1 >= 0.1) |> 
  filter(Time >= t_sici_start & Time <= t_sici_end)

hist(df_p_1$Chan_1, breaks = 50)


df_p_2 <- df_p_0 |> 
  select(Time = "Elapsed Time (min)", Channel, Values) |> 
  filter(Values <= 0.3 & Values >= 0.1) |> 
  rename(PTP = Values)



df_t_2 <- df_t_0 |> 
  rename(MSO = Values,
         Time = "Elapsed Time (min)")


df2 <- df_t_2 |> 
  select(-Channel) |> 
  filter(MSO>5) |> 
  inner_join(df_p_2, by = "Time")


df3 <- df2 |> 
  inner_join(df_D_1, by = "Time")


ggplot(df3, aes(x = MSO, y = PTP, color = Time)) +
  geom_point()+
  theme_minimal()



source("analysis/join_meps.R")


QLG_file <- ("data/QLG/TP3C60728A.QLG")
T_delta <- 0.081863
neuronav_path <- "data/SNBR-188.txt"


merged_df <- join_MEPs(
  diff = T_delta,
  QLG = QLG_file,
  new_df = df2,
  neuronav = neuronav_path,
  sample = "Sample 1")

average_PTP <- mean(merged_df$PTP)
average_dist_mm <- mean(merged_df$trans_dist_mm)

ggplot(merged_df,
       aes(
         x = trans_dist_mm,
         y = PTP,
         color = MSO,
         shape = coil))+
  geom_hline(yintercept = average_PTP, linetype = "dashed", color = "red")+
  geom_vline(xintercept = average_dist_mm, linetype = "dashed", color = "blue")+
  geom_point()+
  theme_minimal()


ggplot(merged_df,
       aes(
         x = ang_dist_deg,
         y = PTP,
         color = MSO,
         shape = coil))+
  geom_point()+
  theme_minimal()

