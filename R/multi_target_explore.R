library(tidyverse)
library(plotly)

source("R/parse_brainsight.R")

tables <- parse_brainsight("data/Session 6_ Streamed Info.txt")


df_targets <- tables[["Target Selection"]]


df_polaris <- tables[["Polaris Tool"]]

unique(df_polaris$coord_system)

df_polaris_1 <- df_polaris |> 
  filter(coord_system == "MNI") |> 
  na.omit()
