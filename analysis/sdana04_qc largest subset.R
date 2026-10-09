rm(list = ls());gc();source(".Rprofile")

top_subset = read_csv(file.path(path_temporary_files, "sdana03_top_subset_cells.csv"))


county_data <- read_csv("data/ktdat13_county.csv")
zip_data    <- read_csv("data/ktdat13_zip_v2.csv")

crosswalk <- readxl::read_xlsx(
  file.path(path_crosswalk_files, "COUNTY_ZIP_122025.xlsx")
) |>
  select(-matches("RATIO")) |>
  mutate(
    COUNTY     = str_pad(as.character(COUNTY), width = 5, side = "left", pad = "0"),
    state_fips = str_sub(COUNTY, 1L, 2L)
  ) |> 
    left_join(county_data |> dplyr::select(-state_code), by = c("COUNTY"="FIPS")) |>
    left_join(zip_data |> select(-State), by = c("ZIP" = "zcta")) 



selected_vars = top_subset |> 
  dplyr::select(-starts_with("n_"),-zip_passes,-county_passes,-passes) |>
  rename_all(~str_remove(.x,"_bin")) |> 
  map(~unique(.x))


includes_county <- any(names(selected_vars) %in% names(county_data))
includes_zip    <- any(names(selected_vars) %in% names(zip_data))


if(!includes_county && includes_zip){
  df = zip_data
} else if(includes_county && !includes_zip){
  df = county_data
} else if(includes_county && includes_zip){
  df = crosswalk
}


# Parse breaks from interval labels like "[-Inf,34.9)" -> c(-Inf, 34.9)
parse_breaks <- function(labels) {
  nums <- str_extract_all(labels, "-?Inf|-?[0-9]+\\.?[0-9]*")
  vals <- map(nums, ~as.numeric(.x)) |> unlist() |> unique() |> sort()
  # Ensure -Inf and Inf are present at the ends
  if (!is.infinite(vals[1]))        vals <- c(-Inf, vals)
  if (!is.infinite(vals[length(vals)])) vals <- c(vals, Inf)
  vals
}

# Determine bracket type (left-closed or right-closed) from first label
parse_right <- function(labels) {
  # "[" on left means left-closed -> right = FALSE; "(" on left means right = TRUE
  !startsWith(labels[1], "[")
}

df_updated <- df |>
  mutate(across(
    all_of(names(selected_vars)),
    ~ {
      var_name  <- cur_column()
      lbls      <- selected_vars[[var_name]]
      brks      <- parse_breaks(lbls)
      right_val <- parse_right(lbls)
      cut(.x, breaks = brks, labels = lbls,
          right = right_val, include.lowest = TRUE)
    },
    .names = "{.col}_bin"
  ))

df_updated |> select(ends_with("_bin")) |> map(~table(.x, useNA = "always"))

df_shared = df_updated |> 
  group_by_at(vars(ends_with("_bin"))) |> 
  summarize(n = n(),
            n_state = n_distinct(state_fips)) |> 
  dplyr::filter(n >= 4, n_state >= 2) |> 
  ungroup() 


df_updated |> 
  group_by_at(vars(ends_with("_bin"))) |> 
  summarize(n = n(),
            n_state = n_distinct(state_fips)) |> 
  dplyr::filter(n < 4 | n_state < 2) |> 
  ungroup() 


df_updated |>
  dplyr::select(one_of(c("COUNTY","ZIP","state_fips")),contains("_bin")) |> 
  write_csv(file.path(path_temporary_files, "sdana04_shared bins.csv"))
  