rm(list = ls()); gc(); source(".Rprofile")

set.seed(42)
library(tidyverse)
library(readxl)

source("functions/spatial_deidentification_helpers.R")

# ── Data ───────────────────────────────────────────────────────────────────────
county_data <- read_csv("data/ktdat13_county.csv")
zip_data    <- read_csv("data/ktdat13_zip_v2.csv")

crosswalk <- read_xlsx(
  file.path(path_crosswalk_files, "COUNTY_ZIP_122025.xlsx")
) |>
  select(-matches("RATIO")) |>
  mutate(
    COUNTY     = str_pad(as.character(COUNTY), width = 5, side = "left", pad = "0"),
    state_fips = str_sub(COUNTY, 1L, 2L)
  )

# ── Variable lists ─────────────────────────────────────────────────────────────
county_continuous_vars <- c(
  "OBESITY", "BPHIGH", "HIGHCHOL", "ISOLATION", "STROKE",
  "COPD", "CASTHMA", "median_income", "HI_coverage", "no_HS_rate", "UE_rate"
)
county_ordinal_vars <- "RUCC_2023"

zip_continuous_vars <- c("RPL_THEME1", "RPL_THEME2", "RPL_THEME3", "RPL_THEME4", "RPL_THEMES")
zip_ordinal_vars    <- "PrimaryRUCA"
zip_binary_vars     <- "near_walmart"

INIT_PROBS <- c(0.10, 0.25, 0.50, 0.75, 0.90)

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — DERIVE CATEGORICAL VARIABLES
# ══════════════════════════════════════════════════════════════════════════════

# ── 1.1  Continuous county variables ──────────────────────────────────────────
county_bin_defs <- list()

for (v in county_continuous_vars) {
  breaks <- quantile_breaks(county_data[[v]], INIT_PROBS)
  result <- merge_continuous_bins(
    data        = county_data,
    var         = v,
    init_breaks = breaks,
    eval_fn     = eval_marginal_county
  )
  county_bin_defs[[v]] <- result
  message(sprintf(
    "[county | continuous] %-15s  %d bins after %d merge(s) — passes: %s",
    v, length(result$bin_labels), result$n_merges, result$passes
  ))
}

# ── 1.2  Ordinal county variable: RUCC_2023 (1–9) ────────────────────────────
for (v in county_ordinal_vars) {
  result <- merge_ordinal_bins(
    data    = county_data,
    var     = v,
    eval_fn = eval_marginal_county
  )
  county_bin_defs[[v]] <- result
  message(sprintf(
    "[county | ordinal]    %-15s  %d groups after %d merge(s) — passes: %s",
    v, length(result$groups), result$n_merges, result$passes
  ))
}

# ── 1.3  Continuous zip variables ─────────────────────────────────────────────
zip_bin_defs <- list()

for (v in zip_continuous_vars) {
  breaks <- quantile_breaks(zip_data[[v]], INIT_PROBS)
  result <- merge_continuous_bins(
    data        = zip_data,
    var         = v,
    init_breaks = breaks,
    eval_fn     = eval_marginal_zip
  )
  zip_bin_defs[[v]] <- result
  message(sprintf(
    "[zip   | continuous] %-15s  %d bins after %d merge(s) — passes: %s",
    v, length(result$bin_labels), result$n_merges, result$passes
  ))
}

# ── 1.4  Ordinal zip variable: PrimaryRUCA (1–10) ─────────────────────────────
for (v in zip_ordinal_vars) {
  result <- merge_ordinal_bins(
    data    = zip_data,
    var     = v,
    eval_fn = eval_marginal_zip
  )
  zip_bin_defs[[v]] <- result
  message(sprintf(
    "[zip   | ordinal]    %-15s  %d groups after %d merge(s) — passes: %s",
    v, length(result$groups), result$n_merges, result$passes
  ))
}

# ── 1.5  Binary zip variable: near_walmart ────────────────────────────────────
# Binary variables cannot be merged; evaluate each level as-is and flag failures.
zip_data[["near_walmart_bin"]] <- factor(
  as.character(zip_data[["near_walmart"]]),
  levels = c("0", "1"),
  ordered = TRUE
)

binary_eval   <- eval_marginal_zip(zip_data, "near_walmart_bin")
walmart_passes <- all(binary_eval$passes)

zip_bin_defs[["near_walmart"]] <- list(
  type        = "binary",
  var         = "near_walmart",
  levels      = c("0", "1"),
  bin_labels  = c("0", "1"),
  eval_result = binary_eval,
  passes      = walmart_passes,
  n_merges    = 0L
)

message(sprintf(
  "[zip   | binary]     %-15s  passes: %s", "near_walmart", walmart_passes
))

if (!walmart_passes) {
  fail_levels <- binary_eval |> filter(!passes) |> pull(bin) |> as.character()
  message("  ⚑ near_walmart level(s) failing: ",
          paste(fail_levels, collapse = ", "),
          " — flagged for possible exclusion in Phase 2")
}

# ══════════════════════════════════════════════════════════════════════════════
# 1.6  Marginal pass/fail summary table
# ══════════════════════════════════════════════════════════════════════════════

format_bin_labels <- function(bin_def) {
  paste(bin_def$bin_labels, collapse = " | ")
}

marginal_summary <- c(
  imap(county_bin_defs, function(def, nm) {
    tibble(
      variable    = nm,
      dataset     = "county",
      var_type    = def$type,
      n_bins      = length(def$bin_labels),
      n_merges    = def$n_merges,
      passes      = def$passes,
      n_fail_bins = sum(!def$eval_result$passes),
      categories  = format_bin_labels(def)
    )
  }),
  imap(zip_bin_defs, function(def, nm) {
    tibble(
      variable    = nm,
      dataset     = "zip",
      var_type    = def$type,
      n_bins      = length(def$bin_labels),
      n_merges    = def$n_merges,
      passes      = def$passes,
      n_fail_bins = sum(!def$eval_result$passes),
      categories  = format_bin_labels(def)
    )
  })
) |>
  bind_rows()

write_csv(marginal_summary,
          file.path(path_temporary_files, "sdana02_marginal_summary.csv"))

# ── 1.7  Detailed per-bin marginal tables ─────────────────────────────────────
marginal_detail <- c(
  imap(county_bin_defs, function(def, nm) {
    def$eval_result |>
      mutate(bin = as.character(bin), variable = nm, dataset = "county", .before = 1)
  }),
  imap(zip_bin_defs, function(def, nm) {
    def$eval_result |>
      mutate(bin = as.character(bin), variable = nm, dataset = "zip", .before = 1)
  })
) |>
  bind_rows()

write_csv(marginal_detail,
          file.path(path_temporary_files, "sdana02_marginal_detail.csv"))

# ── 1.8  Persist bin definitions for Phase 2 ──────────────────────────────────
bin_defs_all <- list(county = county_bin_defs, zip = zip_bin_defs)
saveRDS(bin_defs_all, file.path(path_temporary_files, "sdana02_bin_defs.rds"))

message("\n── Phase 1 complete ─────────────────────────────────────────────────────────")
message(sprintf("County variables binned: %d", length(county_bin_defs)))
message(sprintf("Zip    variables binned: %d", length(zip_bin_defs)))
message(sprintf("All pass marginal check: %s", all(marginal_summary$passes)))

marginal_summary
