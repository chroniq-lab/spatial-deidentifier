# ══════════════════════════════════════════════════════════════════════════════
# Spatial De-identification — Helper Functions
# Source this file at the top of each analysis script.
# Requires: tidyverse (loaded by caller)
# ══════════════════════════════════════════════════════════════════════════════

# ── Pass/fail primitives ──────────────────────────────────────────────────────

#' Does a set of ZIP records pass the spatial de-identification threshold?
#' @param zctas  character vector of ZCTA codes (NAs ignored)
#' @param states character vector of corresponding state codes
#' @return logical
zip_side_passes <- function(zctas, states) {
  n_distinct(zctas[!is.na(zctas)]) >= 2L &&
    n_distinct(states[!is.na(states)]) >= 2L
}

#' Does a set of county records pass the spatial de-identification threshold?
#' @param fips   character vector of FIPS codes (NAs ignored)
#' @param states character vector of corresponding state codes
#' @return logical
county_side_passes <- function(fips, states) {
  n_distinct(fips[!is.na(fips)]) >= 2L &&
    n_distinct(states[!is.na(states)]) >= 2L
}

#' Does a cell pass? Either the ZIP side or the county side must pass.
#' @param zctas         character vector of ZCTAs (or NULL)
#' @param zip_states    character vector of states for ZIPs (or NULL)
#' @param fips          character vector of FIPS codes (or NULL)
#' @param county_states character vector of states for counties (or NULL)
#' @return logical
cell_passes <- function(zctas = NULL, zip_states = NULL,
                        fips  = NULL, county_states = NULL) {
  zip_ok    <- !is.null(zctas) && length(zctas) > 0 &&
    zip_side_passes(zctas, zip_states)
  county_ok <- !is.null(fips)  && length(fips)  > 0 &&
    county_side_passes(fips, county_states)
  zip_ok || county_ok
}

# ── Break-point / cut helpers ─────────────────────────────────────────────────

#' Compute unique interior quantile break-points for a numeric variable.
#' @param x     numeric vector (NAs ignored)
#' @param probs probability vector, e.g. c(0.10, 0.25, 0.50, 0.75, 0.90)
#' @return numeric vector of unique break-point values
quantile_breaks <- function(x, probs = c(0.10, 0.25, 0.50, 0.75, 0.90)) {
  unique(quantile(x, probs = probs, na.rm = TRUE, names = FALSE))
}

#' Cut a numeric vector using interior break-points into an ordered factor.
#' Intervals are left-closed: [b_k, b_{k+1}), with (-Inf, b1) and [bn, +Inf).
#' @param x       numeric vector
#' @param breaks  interior break-points (sorted automatically)
#' @param dig.lab precision for auto-generated labels
#' @return ordered factor
cut_with_breaks <- function(x, breaks, dig.lab = 5L) {
  cut(
    x,
    breaks         = c(-Inf, sort(unique(breaks)), Inf),
    include.lowest = TRUE,
    right          = FALSE,
    ordered_result = TRUE,
    dig.lab        = dig.lab
  )
}

#' Build an ordered factor from an integer ordinal variable using a group list.
#' Groups must cover all observed non-NA values.
#' @param x      integer/numeric vector
#' @param groups list of integer vectors (each = one ordered group of original levels)
#' @return ordered factor; labels like "3" (singleton) or "3–5" (merged range)
make_ordinal_factor <- function(x, groups) {
  flat     <- as.character(unlist(groups))
  idx_map  <- setNames(
    rep(seq_along(groups), lengths(groups)),
    flat
  )
  labels <- vapply(groups, function(g) {
    g <- sort(as.integer(g))
    if (length(g) == 1L) as.character(g) else sprintf("%s\u2013%s", g[1L], g[length(g)])
  }, character(1L))

  raw_chr <- as.character(as.integer(x))
  idx     <- idx_map[raw_chr]
  factor(labels[idx], levels = labels, ordered = TRUE)
}

# ── Marginal pass/fail evaluators ─────────────────────────────────────────────

#' Evaluate pass/fail for each bin of a county variable.
#' @param data    data frame containing FIPS, state_code, and the binned column
#' @param bin_col name of the binned column
#' @return tibble: bin | n_records | n_counties | n_states | passes
eval_marginal_county <- function(data, bin_col) {
  data |>
    filter(!is.na(.data[[bin_col]])) |>
    group_by(bin = .data[[bin_col]]) |>
    summarise(
      n_records  = n(),
      n_counties = n_distinct(FIPS),
      n_states   = n_distinct(state_code),
      .groups    = "drop"
    ) |>
    mutate(passes = n_counties >= 2L & n_states >= 2L)
}

#' Evaluate pass/fail for each bin of a ZIP variable.
#' @param data    data frame containing zcta, State, and the binned column
#' @param bin_col name of the binned column
#' @return tibble: bin | n_records | n_zctas | n_states | passes
eval_marginal_zip <- function(data, bin_col) {
  data |>
    filter(!is.na(.data[[bin_col]])) |>
    group_by(bin = .data[[bin_col]]) |>
    summarise(
      n_records = n(),
      n_zctas   = n_distinct(zcta),
      n_states  = n_distinct(State),
      .groups   = "drop"
    ) |>
    mutate(passes = n_zctas >= 2L & n_states >= 2L)
}

# ── Merge-until-valid engines ─────────────────────────────────────────────────

#' Merge adjacent bins (left→right) until all pass, for continuous variables.
#' Failing bin merges with its right neighbour; if it is the last bin, merges left.
#'
#' @param data        data frame with the raw variable and any join keys
#' @param var         character: raw variable column name
#' @param init_breaks numeric: initial interior break-points
#' @param eval_fn     function(data, bin_col) → tibble with a \code{passes} column
#' @param max_iter    integer: safety cap on merge iterations
#' @return list with elements:
#'   type, var, breaks, bin_labels, eval_result, passes, n_merges
merge_continuous_bins <- function(data, var, init_breaks, eval_fn, max_iter = 30L) {
  TMP <- ".SDEID_BIN_TMP."
  cur_breaks <- sort(unique(init_breaks))
  iter       <- 0L

  repeat {
    data[[TMP]] <- cut_with_breaks(data[[var]], cur_breaks)
    res         <- eval_fn(data, TMP)
    if (all(res$passes) || iter >= max_iter) break

    failing_idx <- which(!res$passes)[[1L]]
    n_bins      <- nrow(res)
    if (length(cur_breaks) == 0L) break

    # Merge failing bin with its right neighbour; last bin → merge left
    if (failing_idx < n_bins) {
      cur_breaks <- cur_breaks[-failing_idx]           # drop right bound → absorb right
    } else {
      cur_breaks <- cur_breaks[-length(cur_breaks)]    # drop left bound  → absorb left
    }
    iter <- iter + 1L
  }

  data[[TMP]] <- cut_with_breaks(data[[var]], cur_breaks)
  res         <- eval_fn(data, TMP)

  list(
    type        = "continuous",
    var         = var,
    breaks      = cur_breaks,
    bin_labels  = levels(data[[TMP]]),
    eval_result = res,
    passes      = all(res$passes),
    n_merges    = iter
  )
}

#' Merge adjacent bins until all pass, for ordinal integer variables.
#' Only consecutive levels are merged (order preserved).
#'
#' @param data      data frame with the raw ordinal variable and any join keys
#' @param var       character: raw variable column name (integer-valued)
#' @param eval_fn   function(data, bin_col) → tibble with a \code{passes} column
#' @param max_iter  integer: safety cap
#' @return list with elements:
#'   type, var, groups, bin_labels, eval_result, passes, n_merges
merge_ordinal_bins <- function(data, var, eval_fn, max_iter = 30L) {
  TMP <- ".SDEID_BIN_TMP."
  orig_levels <- sort(unique(na.omit(as.integer(data[[var]]))))
  groups      <- as.list(orig_levels)   # start: one group per unique level
  iter        <- 0L

  repeat {
    data[[TMP]] <- make_ordinal_factor(data[[var]], groups)
    res         <- eval_fn(data, TMP)
    if (all(res$passes) || iter >= max_iter || length(groups) <= 1L) break

    failing_idx <- which(!res$passes)[[1L]]
    n_bins      <- length(groups)

    if (failing_idx < n_bins) {
      # Merge failing group with right neighbour
      groups[[failing_idx + 1L]] <- sort(c(groups[[failing_idx]], groups[[failing_idx + 1L]]))
      groups[[failing_idx]]      <- NULL
    } else {
      # Last group: merge with left neighbour
      groups[[failing_idx - 1L]] <- sort(c(groups[[failing_idx - 1L]], groups[[failing_idx]]))
      groups[[failing_idx]]      <- NULL
    }
    iter <- iter + 1L
  }

  data[[TMP]] <- make_ordinal_factor(data[[var]], groups)
  res         <- eval_fn(data, TMP)

  labels <- vapply(groups, function(g) {
    g <- sort(as.integer(g))
    if (length(g) == 1L) as.character(g) else sprintf("%s\u2013%s", g[1L], g[length(g)])
  }, character(1L))

  list(
    type        = "ordinal",
    var         = var,
    groups      = groups,
    bin_labels  = labels,
    eval_result = res,
    passes      = all(res$passes),
    n_merges    = iter
  )
}

# ── Apply bin definitions ─────────────────────────────────────────────────────

#' Apply a bin definition (output of merge_*_bins) to a raw variable vector.
#' @param x       raw variable vector
#' @param bin_def list as returned by merge_continuous_bins, merge_ordinal_bins,
#'                or the binary stub produced in sdana02
#' @return ordered factor
apply_bin_def <- function(x, bin_def) {
  switch(
    bin_def$type,
    continuous = cut_with_breaks(x, bin_def$breaks),
    ordinal    = make_ordinal_factor(x, bin_def$groups),
    binary     = factor(as.character(x), levels = bin_def$levels, ordered = TRUE),
    stop("Unknown bin_def type: ", bin_def$type)
  )
}

#' Apply all bin definitions in a named list to matching columns of a data frame.
#' New columns are named <var>_bin.
#' @param data      data frame
#' @param bin_defs  named list of bin_def objects (names = variable names)
#' @return data frame with new *_bin columns appended
apply_all_bin_defs <- function(data, bin_defs) {
  for (nm in names(bin_defs)) {
    if (nm %in% names(data)) {
      data[[paste0(nm, "_bin")]] <- apply_bin_def(data[[nm]], bin_defs[[nm]])
    }
  }
  data
}

# ── Coarsening helpers ────────────────────────────────────────────────────────

#' Generate all one-step coarsenings of a bin_def (each merge of adjacent bins).
#' Binary defs return an empty list (cannot be coarsened).
#' A def with 1 bin returns an empty list (already maximally coarse).
#' @param bin_def list as returned by merge_*_bins
#' @return list of modified bin_defs (one per possible adjacent merge)
coarsen_one_step <- function(bin_def) {
  if (bin_def$type == "binary") return(list())

  if (bin_def$type == "continuous") {
    breaks <- bin_def$breaks
    if (length(breaks) <= 1L) return(list())   # 0 breaks = 1 bin, 1 break = 2 bins → removing gives 1 bin (ok, but no further steps)
    lapply(seq_along(breaks), function(i) {
      new_def          <- bin_def
      new_def$breaks   <- breaks[-i]
      new_def$n_merges <- bin_def$n_merges + 1L
      new_def
    })
  } else {   # ordinal
    groups <- bin_def$groups
    if (length(groups) <= 1L) return(list())
    lapply(seq_len(length(groups) - 1L), function(i) {
      new_groups           <- groups
      new_groups[[i + 1L]] <- sort(c(groups[[i]], groups[[i + 1L]]))
      new_groups[[i]]      <- NULL
      new_def              <- bin_def
      new_def$groups       <- new_groups
      new_def$n_merges     <- bin_def$n_merges + 1L
      new_def
    })
  }
}

# ── Cross-dataset evaluation ──────────────────────────────────────────────────

#' Build a merged dataset: one row per (ZCTA, COUNTY) crosswalk pair,
#' with county variable columns from county_data and zip variable columns from zip_data.
#' @param county_data data frame with FIPS, state_code (and county variables)
#' @param zip_data    data frame with zcta, State (and zip variables)
#' @param crosswalk   data frame with ZIP, COUNTY, state_fips
#' @return data frame; zip State column renamed to zip_State to avoid collision
build_merged_dataset <- function(county_data, zip_data, crosswalk) {
  crosswalk |>
    select(ZIP, COUNTY, state_fips) |>
    left_join(county_data, by = c("COUNTY" = "FIPS")) |>
    left_join(
      zip_data |> rename(zip_State = State),
      by = c("ZIP" = "zcta")
    )
}

#' Evaluate cells for a mixed (county + zip) combination using the merged dataset.
#' @param merged   merged dataset (from build_merged_dataset) with bin columns applied
#' @param bin_cols character vector of *_bin column names to group by
#' @return tibble: one row per cell with n_zctas, n_zip_states, n_counties,
#'   n_county_states, zip_passes, county_passes, passes
eval_cells_merged <- function(merged, bin_cols) {
  merged |>
    filter(if_all(all_of(bin_cols), ~ !is.na(.))) |>
    group_by(across(all_of(bin_cols))) |>
    summarise(
      n_zctas         = n_distinct(ZIP),
      n_zip_states    = n_distinct(zip_State),
      n_counties      = n_distinct(COUNTY),
      n_county_states = n_distinct(state_fips),
      .groups         = "drop"
    ) |>
    mutate(
      zip_passes    = n_zctas    >= 2L & n_zip_states    >= 2L,
      county_passes = n_counties >= 2L & n_county_states >= 2L,
      passes        = zip_passes | county_passes
    )
}

#' Evaluate county-only cells directly from county_data.
#' @param county_data data frame with FIPS, state_code, and bin columns
#' @param bin_cols    character vector of *_bin column names
#' @return tibble with standardised columns (n_zctas/n_zip_states = NA)
eval_cells_county <- function(county_data, bin_cols) {
  county_data |>
    filter(if_all(all_of(bin_cols), ~ !is.na(.))) |>
    group_by(across(all_of(bin_cols))) |>
    summarise(
      n_zctas         = NA_integer_,
      n_zip_states    = NA_integer_,
      n_counties      = n_distinct(FIPS),
      n_county_states = n_distinct(state_code),
      .groups         = "drop"
    ) |>
    mutate(
      zip_passes    = FALSE,
      county_passes = n_counties >= 2L & n_county_states >= 2L,
      passes        = county_passes
    )
}

#' Evaluate zip-only cells directly from zip_data.
#' @param zip_data data frame with zcta, State, and bin columns
#' @param bin_cols character vector of *_bin column names
#' @return tibble with standardised columns (n_counties/n_county_states = NA)
eval_cells_zip <- function(zip_data, bin_cols) {
  zip_data |>
    filter(if_all(all_of(bin_cols), ~ !is.na(.))) |>
    group_by(across(all_of(bin_cols))) |>
    summarise(
      n_zctas         = n_distinct(zcta),
      n_zip_states    = n_distinct(State),
      n_counties      = NA_integer_,
      n_county_states = NA_integer_,
      .groups         = "drop"
    ) |>
    mutate(
      zip_passes    = n_zctas >= 2L & n_zip_states >= 2L,
      county_passes = FALSE,
      passes        = zip_passes
    )
}

#' Test whether a candidate variable subset is globally valid.
#' Automatically routes to the correct evaluator based on which variable sources
#' are present in the candidate.
#'
#' @param county_data_b data frame: county_data with all *_bin columns applied
#' @param zip_data_b    data frame: zip_data with all *_bin columns applied
#' @param merged_b      data frame: merged dataset with all *_bin columns applied
#' @param county_vars   character: raw variable names from county_data in this candidate
#' @param zip_vars      character: raw variable names from zip_data in this candidate
#' @param bin_suffix    character: suffix appended to var name to make bin col name
#' @return list(passes, n_fail, cells, dataset_type)
test_subset <- function(county_data_b, zip_data_b, merged_b,
                        county_vars, zip_vars,
                        bin_suffix = "_bin") {
  c_cols   <- if (length(county_vars) > 0L) paste0(county_vars, bin_suffix) else character(0L)
  z_cols   <- if (length(zip_vars)   > 0L) paste0(zip_vars,   bin_suffix) else character(0L)
  all_cols <- c(c_cols, z_cols)
  has_c    <- length(county_vars) > 0L
  has_z    <- length(zip_vars)   > 0L

  if (has_c && has_z) {
    dtype <- "county+zip"
    cells <- eval_cells_merged(merged_b, all_cols)
  } else if (has_c) {
    dtype <- "county"
    cells <- eval_cells_county(county_data_b, all_cols)
  } else {
    dtype <- "zip"
    cells <- eval_cells_zip(zip_data_b, all_cols)
  }

  n_fail <- sum(!cells$passes, na.rm = TRUE)
  list(
    passes       = n_fail == 0L,
    n_fail       = n_fail,
    cells        = cells,
    dataset_type = dtype
  )
}
