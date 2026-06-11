rm(list = ls()); gc(); source(".Rprofile")

set.seed(42)
library(tidyverse)
library(readxl)

source("functions/spatial_deidentification_helpers.R")

# ── Load data ──────────────────────────────────────────────────────────────────
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

# ── Load Phase 1 bin definitions ──────────────────────────────────────────────
bin_defs_all    <- readRDS(file.path(path_temporary_files, "sdana02_bin_defs.rds"))
county_bin_defs <- bin_defs_all$county
zip_bin_defs    <- bin_defs_all$zip

# ── Variable metadata ──────────────────────────────────────────────────────────
# Exclude near_walmart if it failed the Phase 1 marginal check
walmart_passes <- zip_bin_defs[["near_walmart"]]$passes
if (!walmart_passes) {
  message("near_walmart excluded from Phase 2 (failed Phase 1 marginal check).")
  zip_bin_defs[["near_walmart"]] <- NULL
}

county_vars <- names(county_bin_defs)
zip_vars    <- names(zip_bin_defs)
all_vars    <- c(county_vars, zip_vars)

var_source <- c(
  setNames(rep("county", length(county_vars)), county_vars),
  setNames(rep("zip",    length(zip_vars)),    zip_vars)
)

# ══════════════════════════════════════════════════════════════════════════════
# 2.1  Apply Phase 1 bins to all data frames
# ══════════════════════════════════════════════════════════════════════════════

county_binned <- apply_all_bin_defs(county_data, county_bin_defs)
zip_binned    <- apply_all_bin_defs(zip_data,    zip_bin_defs)

merged_base   <- build_merged_dataset(county_data, zip_data, crosswalk)
merged_binned <- merged_base |>
  apply_all_bin_defs(county_bin_defs) |>
  apply_all_bin_defs(zip_bin_defs)

message(sprintf("Merged dataset: %s rows (%s unique ZCTAs, %s unique counties)",
                nrow(merged_binned),
                n_distinct(merged_binned$ZIP),
                n_distinct(merged_binned$COUNTY)))

# ══════════════════════════════════════════════════════════════════════════════
# 2.2  Apriori-style subset search with re-coarsening
# ══════════════════════════════════════════════════════════════════════════════

# Helper: canonical string key for a set of variable names
subset_key <- function(vars) paste(sort(vars), collapse = "|||")

# Helper: split a variable vector into county and zip parts
split_vars <- function(vars) {
  list(
    county = vars[var_source[vars] == "county"],
    zip    = vars[var_source[vars] == "zip"]
  )
}

# Helper: assign dataset_type label from a split-vars list
dtype_label <- function(sv) {
  if (length(sv$county) > 0L && length(sv$zip) > 0L) "county+zip"
  else if (length(sv$zip) > 0L) "zip"
  else "county"
}

# ── Verify singletons pass ────────────────────────────────────────────────────
singleton_results <- lapply(all_vars, function(v) {
  sv  <- split_vars(v)
  res <- test_subset(county_binned, zip_binned, merged_binned, sv$county, sv$zip)
  list(var = v, passes = res$passes, n_fail = res$n_fail)
})

failing_singletons <- Filter(function(x) !x$passes, singleton_results)
if (length(failing_singletons) > 0L) {
  fail_names <- vapply(failing_singletons, `[[`, character(1L), "var")
  message("⚑ Singletons failing Phase 2 check (unexpected after Phase 1): ",
          paste(fail_names, collapse = ", "))
  # Remove them from the search space
  all_vars   <- setdiff(all_vars, fail_names)
  var_source <- var_source[all_vars]
  county_vars <- intersect(county_vars, all_vars)
  zip_vars    <- intersect(zip_vars,    all_vars)
}

# ── Search state ──────────────────────────────────────────────────────────────
# invalid_set: hash-keys of subsets known to have at least one failing cell
# (any superset can be pruned without evaluation)
invalid_set <- character(0L)

# search_log: row per candidate tested → becomes the deliverable summary table
search_log  <- list()

# Record singletons as iteration 0
for (v in all_vars) {
  sv <- split_vars(v)
  search_log[[length(search_log) + 1L]] <- list(
    iteration   = 0L,
    vars        = v,
    n_vars      = 1L,
    passes      = TRUE,
    n_fail      = 0L,
    dataset_type = dtype_label(sv),
    coarsened    = FALSE,
    coarsened_var = NA_character_
  )
}

# current_valid: list of character vectors (each = a passing subset of size k)
current_valid <- as.list(all_vars)          # singletons are all valid after check above
best_valid    <- current_valid
best_k        <- 1L
iteration_ctr <- 1L   # increments each time we test a new candidate level

# ── Level-by-level Apriori search ────────────────────────────────────────────
for (k in seq_len(length(all_vars) - 1L)) {
  # Generate (k+1)-candidates: extend each valid k-subset by one new variable,
  # deduplicating via hash keys.
  seen_keys  <- character(0L)
  candidates <- list()

  for (s in current_valid) {
    for (v in setdiff(all_vars, s)) {
      cand <- sort(c(s, v))
      key  <- subset_key(cand)
      if (key %in% seen_keys) next
      seen_keys <- c(seen_keys, key)

      # Apriori pruning: skip if any k-subset of cand is in invalid_set
      k_sub_keys <- apply(
        combn(length(cand), k), 2L,
        function(idx) subset_key(cand[idx])
      )
      if (any(k_sub_keys %in% invalid_set)) next

      candidates[[length(candidates) + 1L]] <- cand
    }
  }

  if (length(candidates) == 0L) {
    message(sprintf("Level %d: no valid candidates after pruning — search complete.", k + 1L))
    break
  }

  message(sprintf("Level %d: testing %d candidate(s)...", k + 1L, length(candidates)))

  next_valid <- list()

  for (cand in candidates) {
    sv  <- split_vars(cand)
    res <- test_subset(county_binned, zip_binned, merged_binned, sv$county, sv$zip)

    if (res$passes) {
      # ── Candidate passes with current bins ────────────────────────────────
      next_valid <- c(next_valid, list(cand))
      search_log[[length(search_log) + 1L]] <- list(
        iteration     = iteration_ctr,
        vars          = paste(cand, collapse = ", "),
        n_vars        = length(cand),
        passes        = TRUE,
        n_fail        = 0L,
        dataset_type  = res$dataset_type,
        coarsened     = FALSE,
        coarsened_var = NA_character_
      )
    } else {
      # ── Try re-coarsening one variable at a time ───────────────────────────
      # Monotonicity: coarsening can only enlarge cells → safe to update globally
      found_coarsening <- FALSE

      for (v_coarsen in cand) {
        src     <- var_source[v_coarsen]
        cur_def <- if (src == "county") county_bin_defs[[v_coarsen]]
                   else                 zip_bin_defs[[v_coarsen]]

        for (new_def in coarsen_one_step(cur_def)) {
          # Temporarily apply the coarsened bin to all three data frames
          bin_col <- paste0(v_coarsen, "_bin")

          cb_tmp <- county_binned
          zb_tmp <- zip_binned
          mb_tmp <- merged_binned

          if (src == "county") {
            new_col                  <- apply_bin_def(county_binned[[v_coarsen]], new_def)
            cb_tmp[[bin_col]]        <- new_col
            mb_tmp[[bin_col]]        <- apply_bin_def(merged_binned[[v_coarsen]], new_def)
          } else {
            new_col                  <- apply_bin_def(zip_binned[[v_coarsen]], new_def)
            zb_tmp[[bin_col]]        <- new_col
            mb_tmp[[bin_col]]        <- apply_bin_def(merged_binned[[v_coarsen]], new_def)
          }

          res2 <- test_subset(cb_tmp, zb_tmp, mb_tmp, sv$county, sv$zip)

          if (res2$passes) {
            # Accept — commit the coarsened bins globally (monotone: safe)
            if (src == "county") {
              county_bin_defs[[v_coarsen]] <- new_def
              county_binned[[bin_col]]     <- cb_tmp[[bin_col]]
              merged_binned[[bin_col]]     <- mb_tmp[[bin_col]]
            } else {
              zip_bin_defs[[v_coarsen]]    <- new_def
              zip_binned[[bin_col]]        <- zb_tmp[[bin_col]]
              merged_binned[[bin_col]]     <- mb_tmp[[bin_col]]
            }

            next_valid <- c(next_valid, list(cand))
            search_log[[length(search_log) + 1L]] <- list(
              iteration     = iteration_ctr,
              vars          = paste(cand, collapse = ", "),
              n_vars        = length(cand),
              passes        = TRUE,
              n_fail        = 0L,
              dataset_type  = res2$dataset_type,
              coarsened     = TRUE,
              coarsened_var = v_coarsen
            )
            found_coarsening <- TRUE
            break
          }
        }
        if (found_coarsening) break
      }

      if (!found_coarsening) {
        invalid_set <- c(invalid_set, subset_key(cand))
        search_log[[length(search_log) + 1L]] <- list(
          iteration     = iteration_ctr,
          vars          = paste(cand, collapse = ", "),
          n_vars        = length(cand),
          passes        = FALSE,
          n_fail        = res$n_fail,
          dataset_type  = res$dataset_type,
          coarsened     = FALSE,
          coarsened_var = NA_character_
        )
      }
    }

    iteration_ctr <- iteration_ctr + 1L
  }

  if (length(next_valid) == 0L) {
    message(sprintf("Level %d: no valid subsets — search complete.", k + 1L))
    break
  }

  best_valid    <- next_valid
  best_k        <- k + 1L
  current_valid <- next_valid
  message(sprintf("Level %d: %d valid subset(s) found.", k + 1L, length(next_valid)))
}

# ══════════════════════════════════════════════════════════════════════════════
# 2.3  Priority tie-breaking
# County+Zip > Zip-only > County-only; within a tier, more cross-source vars wins
# ══════════════════════════════════════════════════════════════════════════════

priority_score <- function(s) {
  sv    <- split_vars(s)
  tier  <- if (length(sv$county) > 0L && length(sv$zip) > 0L) 1L
           else if (length(sv$zip)    > 0L)                    2L
           else                                                 3L
  # Secondary: more variables from the non-dominant source → richer combination
  cross <- length(sv$county) * length(sv$zip)   # 0 for single-source
  c(tier, -cross)  # lower = better
}

best_valid_sorted <- best_valid[
  order(
    vapply(best_valid, function(s) priority_score(s)[1L], integer(1L)),
    vapply(best_valid, function(s) priority_score(s)[2L], integer(1L))
  )
]

top_subset  <- best_valid_sorted[[1L]]
top_sv      <- split_vars(top_subset)
top_dtype   <- dtype_label(top_sv)

message(sprintf("\n══ Phase 2 complete ══════════════════════════════════════════════════════════"))
message(sprintf("Largest valid subset: %d variable(s)", best_k))
message(sprintf("Top subset type:      %s", top_dtype))
message(sprintf("Top subset variables: %s", paste(top_subset, collapse = ", ")))

# ══════════════════════════════════════════════════════════════════════════════
# 2.4  Deliverables
# ══════════════════════════════════════════════════════════════════════════════

# ── Final bin definitions ─────────────────────────────────────────────────────
bin_defs_final <- list(county = county_bin_defs, zip = zip_bin_defs)
saveRDS(bin_defs_final,
        file.path(path_temporary_files, "sdana03_bin_defs_final.rds"))

# ── Per-cell pass/fail report for the top subset ─────────────────────────────
top_result <- test_subset(
  county_binned, zip_binned, merged_binned,
  top_sv$county, top_sv$zip
)

write_csv(
  top_result$cells,
  file.path(path_temporary_files, "sdana03_top_subset_cells.csv")
)

# ── Per-cell reports for all top-k valid subsets ──────────────────────────────
all_top_cells <- imap(best_valid_sorted, function(s, i) {
  sv  <- split_vars(s)
  res <- test_subset(county_binned, zip_binned, merged_binned, sv$county, sv$zip)
  res$cells |>
    mutate(
      subset_rank  = i,
      subset_vars  = paste(s, collapse = ", "),
      dataset_type = res$dataset_type,
      .before      = 1L
    )
}) |>
  bind_rows()

write_csv(all_top_cells,
          file.path(path_temporary_files, "sdana03_all_top_subsets_cells.csv"))

# ── Search log ────────────────────────────────────────────────────────────────
search_log_tbl <- bind_rows(lapply(search_log, as_tibble))
write_csv(search_log_tbl,
          file.path(path_temporary_files, "sdana03_search_log.csv"))

# ── Summary table (per master.agents.md §Best Possible Subset) ────────────────
# Wide table: one row per tested candidate that passed.
# One column per variable → categories used (as string) or NA if not in subset.
# Columns: iteration, search_type, n_identifiable_combinations.
all_bin_defs_current <- c(county_bin_defs, zip_bin_defs)

format_bin_labels <- function(bin_def) paste(bin_def$bin_labels, collapse = " | ")

# Build one row per passing candidate (from the search log + best singletons)
passing_log <- Filter(function(x) x$passes, search_log)

summary_table <- map(passing_log, function(entry) {
  cand_vars <- strsplit(entry$vars, ", ", fixed = TRUE)[[1L]]

  var_cols <- setNames(
    lapply(all_vars, function(v) {
      if (v %in% cand_vars) format_bin_labels(all_bin_defs_current[[v]])
      else NA_character_
    }),
    paste0(all_vars, "_categories")
  )

  c(
    list(
      iteration                = entry$iteration,
      n_vars                   = entry$n_vars,
      variables_included       = entry$vars,
      search_type              = entry$dataset_type,
      n_identifiable_combinations = entry$n_fail,
      coarsened                = entry$coarsened,
      coarsened_var            = entry$coarsened_var
    ),
    var_cols
  )
}) |>
  bind_rows()

write_csv(summary_table,
          file.path(path_temporary_files, "sdana03_summary_table.csv"))

message(sprintf("Search log saved:   sdana03_search_log.csv      (%d rows)", nrow(search_log_tbl)))
message(sprintf("Summary table saved: sdana03_summary_table.csv  (%d rows)", nrow(summary_table)))
message(sprintf("Top-subset cells:   sdana03_top_subset_cells.csv (%d cells, %d fail)",
                nrow(top_result$cells), top_result$n_fail))

summary_table
