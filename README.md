# Spatial De-identifier

Turns county- and ZIP-level variables into categories so that no combination of categories identifies a State-ZIP or State-County.

**Pass rule.** Every cell (one combination of categories) must contain:
- at least 2 ZIPs in each of at least 2 states, **or**
- at least 2 counties in each of at least 2 states.

The app then finds the largest set of variables that can be released together under this rule.

## Run the app

- Windows: double-click `app/launch.bat`
- macOS/Linux: `bash app/launch.sh`

The launcher checks for Python 3.9 or newer and opens the app at `http://127.0.0.1:8765`. In the app:

1. **Load files:** the county file, the ZIP file and the ZIP↔county crosswalk (`.csv`, `.xlsx` or `.parquet`).
2. **Output folder:** click **Browse…** to pick or create the folder where results are saved, or type a path.
3. **Columns:** choose the ID and state columns.
4. **Variables:** pick the variables and their types (`continuous`, `ordinal`, `binary` or `auto`).
5. **Run:** check Python and the packages, install any that are missing, then run. When it finishes, the app shows the top subset and download links for every output file.

Everything runs on your machine. Files you load in the app are copied to `uploads/` in this folder, which is git-ignored.

## Command line

```
python app/deidentify.py --config app/example_config.json [--workers N]
```

Requires `numpy`, `pandas` and `openpyxl`. `pyarrow` is optional and only needed for `.parquet` files.

## Custom percentiles and cutoffs

By default, continuous variables start from the 10/25/50/75/90th percentiles. You can change this in the app (section 4, **Binning** column) or in the config:

```json
"percentiles": [20, 40, 60, 80],
"county_vars": {
  "OBESITY":       {"type": "continuous", "percentiles": [10, 30, 50, 70, 90]},
  "median_income": {"type": "continuous", "cutoffs": [40000, 60000, 80000], "fixed": true},
  "RUCC_2023":     "ordinal"
}
```

- **Top-level `percentiles`:** the default for every continuous variable. Values are 0–100; fractions such as `0.25` also work.
- **`percentiles` on a variable:** that variable's own starting percentiles.
- **`cutoffs` on a variable:** break-points in the variable's own units. Each bin includes its lower bound and excludes its upper bound, so `[40000, 60000, 80000]` gives `<40000`, `40000–59999`, `60000–79999` and `≥80000`.
- **`fixed: true`:** the categories are used exactly as given. They are never merged in Phase 1 or coarsened in Phase 2. If any category fails the pass rule, the variable is excluded.
  - Without `fixed`, percentiles and cutoffs are only starting points, and failing categories are merged as usual.

Use either `percentiles` or `cutoffs` on a variable, not both. Giving either one implies the variable is continuous. On the command line, `--percentiles 20 40 60 80` sets the default.

## How it works

- **Phase 1: categorise each variable on its own.**
  - Continuous variables start from the 10/25/50/75/90th percentiles. Any category that fails the pass rule is merged with its neighbour. At least 4 categories are always kept.
  - Ordinal variables merge adjacent levels only, keeping at least 4.
  - Binary variables are never merged.
  - A variable that still fails is excluded.
- **Phase 2: combine variables.**
  - Sets of variables are tested in increasing size (pairs, then triples, and so on). A set is skipped if any smaller set inside it already failed.
  - When a set fails, the app tries merging one more pair of adjacent categories in one of its variables. If that makes the set pass, the coarser categories are kept for all later tests.
  - The search stops when no set of the next size passes.
- **Ranking ties.** Among the largest passing sets, priority goes to county + ZIP, then ZIP only, then county only. Within the same tier, sets with more cross-source pairs rank higher.

## Output files

All files are written to the chosen output folder, and each file name starts with the prefix (default `deid_`).

### Final results

| File | What it contains |
|---|---|
| `run_summary.json` | One-page overview of the run (fields below). |
| `top_subset_cells.csv` | One row per cell of the **top-ranked subset**, with its counts and pass flags. |
| `all_top_subsets_cells.csv` | The same cell table for **every** subset tied at the largest size. |
| `county_binned.csv` | The county file with each surviving county variable replaced by its final category. |
| `zip_binned.csv` | The same for the ZIP file. |
| `bin_defs_final.json` | Final category definitions for every variable, after Phase 2 coarsening. |

Only the variables in the top subset (or any subset in `all_top_subsets_cells.csv`) are guaranteed safe **together**. The binned files include every variable that passed Phase 1, so keep only the columns of the chosen subset before releasing data.

### Diagnostics

| File | What it contains |
|---|---|
| `config.json` | The exact configuration used for the run. Re-run with `--config`, or load it back into the app. |
| `marginal_summary.csv` | Phase 1 result: one row per variable. |
| `bin_defs_phase1.json` | Category definitions after Phase 1, before any Phase 2 coarsening. |
| `search_log.csv` | Every candidate set tested in Phase 2, whether it passed or failed. |
| `summary_table.csv` | Wide table with one row per passing set, and a column per variable listing its categories. |

### Column reference

**`run_summary.json`**
- `config`: settings used.
- `variable_types`: type used for each variable after `auto` detection.
- `excluded_phase1`: variables dropped because they failed on their own.
- `largest_valid_k`: number of variables in the largest passing set.
- `top_subset`, `top_subset_type`: the top-ranked set and its type (`county+zip`, `zip` or `county`).
- `all_top_subsets`: every set tied at the largest size, in rank order.

**`marginal_summary.csv`**
- `variable`, `dataset`: variable name and source (`county` or `zip`).
- `var_type`: continuous, ordinal or binary.
- `n_bins`: number of categories after Phase 1.
- `n_merges`: merges needed to reach that.
- `passes`: whether every category meets the pass rule.
- `n_fail_bins`: categories still failing (0 if `passes`).
- `binning`, `binning_values`, `fixed`: for continuous variables, how the starting bins were set (`percentiles` or `cutoffs`), the values used, and whether the bins were fixed.
- `categories`: category labels, separated by `|`.

**`top_subset_cells.csv` / `all_top_subsets_cells.csv`**
- `subset_rank`, `subset_vars`, `dataset_type`: only in the all-subsets file; identify which subset each row belongs to.
- `<variable>_bin`: the category of each variable that defines the cell.
- `n_zip_states_with_2plus`: states contributing at least 2 ZIPs to the cell.
- `n_county_states_with_2plus`: states contributing at least 2 counties to the cell.
- `zip_passes`, `county_passes`: whether that count is at least 2.
- `passes`: `zip_passes OR county_passes`. This is always TRUE for a valid subset.

Mixed county + ZIP subsets are counted over crosswalk ZIP–county pairs. Single-source subsets are counted directly on that file.

**`search_log.csv`**
- `iteration`: order in which the candidate was tested. 0 means a single variable.
- `vars`, `n_vars`: the variables in the candidate.
- `passes`: whether it passed, possibly after coarsening.
- `n_fail`: number of failing cells (identifiable combinations) when it failed.
- `dataset_type`: `county+zip`, `zip` or `county`.
- `coarsened`, `coarsened_var`: whether a variable was coarsened to make it pass, and which one.

**`summary_table.csv`**
- `iteration`, `n_vars`, `variables_included`, `search_type`, `coarsened`, `coarsened_var`: as in the search log, for passing sets only.
- `n_identifiable_combinations`: failing cells. Always 0 here, because only passing sets are listed.
- `<variable>_categories`: the categories used for that variable, or blank if the variable is not in the set. These are the **final** categories, so they may be coarser than what was tested at that iteration.

**`county_binned.csv` / `zip_binned.csv`**
- The ID column (e.g. `FIPS` / `zcta`).
- `state`.
- One `<variable>_bin` column per variable. Continuous categories are labelled like `[0.25,0.5)`: the lower bound is included, the upper bound is excluded, and the last category also includes its upper bound. Ordinal categories are labelled like `3` or `3–5` (a merged range).

**`bin_defs_*.json`**, one entry per variable:
- `type`.
- `breaks` (continuous: the inner cut-points), `groups` (ordinal: the original levels in each category) or `levels` (binary).
- `bin_labels`.
- `n_merges`.
- `passes`.

Use these to apply the same categories to new data.

## Files

| File | Purpose |
|---|---|
| `app/deidentify.py` | De-identification pipeline (Phase 1 binning, Phase 2 subset search) |
| `app/server.py` | Local server (standard library only) that serves the UI, lists folders, and runs the pipeline |
| `app/index.html` | The app UI: builds the config and runs the pipeline |
| `app/launch.bat`, `app/launch.sh` | Launchers that check for Python |
| `app/example_config.json` | Config template |
