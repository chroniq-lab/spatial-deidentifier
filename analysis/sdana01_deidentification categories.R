rm(list = ls()); gc(); source(".Rprofile")

library(tidyverse)
library(readxl)

# ── Data ───────────────────────────────────────────────────────────────────────
county_data <- read_csv("data/ktdat13_county.csv")
zip_data    <- read_csv("data/ktdat13_zip_v2.csv")

county_vars  <- c("RUCC_2023", "OBESITY", "BPHIGH", "HIGHCHOL", "ISOLATION",
                  "STROKE", "COPD", "CASTHMA", "median_income", "HI_coverage",
                  "no_HS_rate", "UE_rate")

# NOTE: RPL_THEME5 corrected to RPL_THEMES — confirmed from zip_data schema
zip_vars     <- c("PrimaryRUCA", "RPL_THEME1", "RPL_THEME2", "RPL_THEME3",
                  "RPL_THEME4", "RPL_THEMES", "near_walmart")

binary_vars  <- c("near_walmart")
ordinal_vars <- c("RUCC_2023", "PrimaryRUCA")

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 0 — RECON
# ══════════════════════════════════════════════════════════════════════════════

# ── 0.1  Load County-ZIP crosswalk ────────────────────────────────────────────
# Assumption: HUD crosswalk uses columns named ZIP (ZCTA) and COUNTY (FIPS).
# Confirm column names in the cat() output below and adjust if they differ.
crosswalk_raw <- read_xlsx(
  file.path(path_crosswalk_files, "COUNTY_ZIP_122025.xlsx")
)

# Drop all *_RATIO columns immediately
crosswalk <- crosswalk_raw |>
  select(-matches("RATIO"))

write_csv(crosswalk, file.path(path_temporary_files, "sdana01_crosswalk_clean.csv"))

# ── 0.2  Schema inventory ─────────────────────────────────────────────────────
cat("=== county_data schema ===\n")
glimpse(county_data)

cat("\n=== zip_data schema ===\n")
glimpse(zip_data)

cat("\n=== crosswalk schema (post RATIO drop) ===\n")
glimpse(crosswalk)
cat("Columns retained:", paste(names(crosswalk), collapse = ", "), "\n")

# ── 0.3  Crosswalk analysis ───────────────────────────────────────────────────
# Derive state from the first 2 digits of the zero-padded 5-char county FIPS
crosswalk <- crosswalk |>
  mutate(
    COUNTY     = str_pad(as.character(COUNTY), width = 5, side = "left", pad = "0"),
    state_fips = str_sub(COUNTY, 1, 2)
  )

cat("\n=== Coverage: crosswalk vs source datasets ===\n")
cat("Unique ZCTAs   — crosswalk:", n_distinct(crosswalk$ZIP),         "\n")
cat("Unique ZCTAs   — zip_data: ", n_distinct(zip_data$zcta),          "\n")
cat("Unique counties— crosswalk:", n_distinct(crosswalk$COUNTY),       "\n")
cat("Unique counties— county_data:", n_distinct(county_data$FIPS),     "\n")
cat("ZCTAs matched (crosswalk ∩ zip_data):      ",
    length(intersect(crosswalk$ZIP,    zip_data$zcta)),    "\n")
cat("Counties matched (crosswalk ∩ county_data):",
    length(intersect(crosswalk$COUNTY, county_data$FIPS)), "\n")

# Save coverage summary
tibble(
  metric = c(
    "ZCTAs in crosswalk", "ZCTAs in zip_data",
    "Counties in crosswalk", "Counties in county_data",
    "ZCTAs matched (crosswalk ∩ zip_data)",
    "Counties matched (crosswalk ∩ county_data)"
  ),
  n = c(
    n_distinct(crosswalk$ZIP),    n_distinct(zip_data$zcta),
    n_distinct(crosswalk$COUNTY), n_distinct(county_data$FIPS),
    length(intersect(crosswalk$ZIP,    zip_data$zcta)),
    length(intersect(crosswalk$COUNTY, county_data$FIPS))
  )
) |>
  write_csv(file.path(path_temporary_files, "sdana01_coverage_summary.csv"))

# Distribution of counties-per-ZCTA and states-per-ZCTA
counties_per_zcta <- crosswalk |>
  group_by(ZIP) |>
  summarise(
    n_counties = n_distinct(COUNTY),
    n_states   = n_distinct(state_fips),
    .groups    = "drop"
  )

cat("\n=== Counties-per-ZCTA distribution ===\n")
counties_per_zcta |>
  count(n_counties, name = "n_zctas") |>
  arrange(n_counties) |>
  print(n = 20)

cat("\nZCTAs spanning > 1 county:", sum(counties_per_zcta$n_counties > 1), "\n")
cat("ZCTAs spanning > 1 state: ", sum(counties_per_zcta$n_states   > 1), "\n")

write_csv(counties_per_zcta, file.path(path_temporary_files, "sdana01_counties_per_zcta.csv"))

# ── 0.4  Pass/fail rule (documented, not enforced until Phase 1) ──────────────
# A CELL = one combination of category levels across selected variables.
#
# A cell PASSES if EITHER:
#   (a) ≥ 2 distinct ZCTAs  from ≥ 2 distinct states, OR
#   (b) ≥ 2 distinct county FIPS from ≥ 2 distinct states.
#
# State derivation:
#   ZIP records   → `State`      column in zip_data
#   County records→ `state_code` column in county_data
#   Crosswalk     → first 2 chars of zero-padded FIPS (state_fips, above)
#
# Multi-county ZIPs: a ZCTA is linked to ALL counties the crosswalk lists for it
# (no RATIO columns used). When evaluating cross-dataset cells, each ZCTA
# contributes every state from its crosswalk-matched counties.

# ── 0.5  Assumptions & flags ──────────────────────────────────────────────────
# [A1] FIPS state prefix: standard 2-digit numeric FIPS (01–56).
# [A2] Crosswalk ZIP column = "ZIP", county column = "COUNTY" (HUD standard).
#      ⚑  Verify these column names match the actual file.
# [A3] ZCTAs absent from crosswalk cannot pass the county-side check; they may
#      still satisfy the ZIP-side check if ≥ 2 ZCTAs from ≥ 2 states exist.
# [A4] RPL_THEME5 in the original script was a typo; corrected to RPL_THEMES.
# [A5] RUCC_2023 valid range is 1–9; values outside this range will be flagged.
# [A6] The crosswalk may contain ZIP codes not present in zip_data (e.g., PO Box
#      ZCTAs); these are retained in the crosswalk but irrelevant for analysis.
