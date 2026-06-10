# Plan to achieve master.agents.md

## Original Prompt

Read #master.agents.md for the full spec. Work in phases and stop for my review after Phase 0.

Phase 0 — Recon (stop here):
- Inspect ~/data and COUNTY_ZIP_122025.xlsx. Report the
  schema of each: variable names, dtypes, how each record links to a ZIP
  and/or county, and how many counties/states a ZIP maps to in the crosswalk.

- State back to me, in your own words: the pass/fail rule for a cell, how
  you'll derive state, and how you'll handle ZIPs that span multiple
  counties/states (since we're ignoring the *_RATIO columns).
- List any assumptions you're forced to make and flag anything ambiguous.
  Do NOT write the binning or search code yet.

Phase 1 — Derive categorical variables:
- For each continuous var, bin by quantiles (start 10/25/50/75/90),
  then merge/adjust until its OWN marginal passes the objective.
  Binary: ensure each level passes; ordinal: only merge consecutive levels.
- Output the chosen bin definitions per variable.

Phase 2 — Largest valid subset:
- Find the largest subset of derived variables whose FULL cross-tabulation
  passes the objective for every cell.
- Exploit monotonicity: a failing subset implies all supersets fail, so
  prune (Apriori-style) instead of enumerating all 2^N subsets.
- Tie-break per the Priority list in AGENTS.md (County+Zip > Zip > County).

Deliverables: bin definitions, the maximal valid subset(s), and a per-cell
pass/fail report demonstrating the constraint holds. Set a fixed random seed
and make the pipeline reproducible.

## Plan

### Phase 0 — Recon

**0.1 Load all sources**
- `county_data` and `zip_data` are already in-session.
- Load `COUNTY_ZIP_122025.xlsx` from `path_crosswalk_files`. Inspect all column names; drop any `*_RATIO` columns immediately.

**0.2 Schema inventory**
- `county_data` (3,234 × 15): key = `FIPS` (chr); state = `state_code`
  - Ordinal: `RUCC_2023` (Rural-Urban Continuum Code, 1–9)
  - Continuous rates: `OBESITY`, `BPHIGH`, `HIGHCHOL`, `ISOLATION`, `STROKE`, `COPD`, `CASTHMA`, `HI_coverage`, `no_HS_rate`, `UE_rate`
  - Continuous dollar: `median_income`
- `zip_data` (41,149 × 9): key = `zcta` (chr); state = `State`
  - Ordinal: `PrimaryRUCA`
  - Continuous rank (0–1): `RPL_THEME1`, `RPL_THEME2`, `RPL_THEME3`, `RPL_THEME4`, `RPL_THEMES`
  - Binary: `near_walmart`
- Crosswalk: report column names, row count, and how FIPS and ZIP are represented.

**0.3 Crosswalk analysis**
- Derive state from the first two characters of the (zero-padded, 5-digit) county FIPS code — no `*_RATIO` columns used at any point.
- Report:
  - Unique ZCTAs and counties in the crosswalk vs. in each dataset.
  - Distribution of counties-per-ZCTA and states-per-ZCTA (how many ZCTAs span >1 county and >1 state).

**0.4 Pass/fail rule — in plain language**
- A **cell** is one combination of category levels (e.g., OBESITY = "Low" AND RUCC_2023 = "Metro").
- A cell **passes** if it satisfies **either**:
  - ≥ 2 distinct ZCTAs drawn from ≥ 2 distinct states, **or**
  - ≥ 2 distinct county FIPS drawn from ≥ 2 distinct states.
- **State derivation**: for ZIP records use `State`; for county records use `state_code`; for crosswalk joins use the FIPS-prefix rule above.
- **Multi-county ZIPs**: because RATIO columns are ignored, a ZCTA is treated as belonging to *all* counties in the crosswalk that list it. When evaluating a cell that crosses both county and ZIP variables, the ZCTA contributes the full set of states from all its crosswalk-matched counties.

**0.5 Assumptions & ambiguities to flag**
- List forced assumptions (e.g., FIPS state codes are standard 2-digit FIPS prefixes; any ZCTA absent from the crosswalk is treated as unmatchable and excluded from county-side checks).
- Flag anything ambiguous discovered during inspection.

> ⛔ **Stop here for review before Phase 1.**

---

### Phase 1 — Derive Categorical Variables

**1.1 Continuous variables**
For each of `OBESITY`, `BPHIGH`, `HIGHCHOL`, `ISOLATION`, `STROKE`, `COPD`, `CASTHMA`, `median_income`, `HI_coverage`, `no_HS_rate`, `UE_rate`, `RPL_THEME1`–`RPL_THEME4`, `RPL_THEMES`:
1. Cut into 5 bins at the 10th/25th/50th/75th/90th percentiles.
2. Evaluate the marginal pass/fail for each bin using the crosswalk and the pass/fail rule.
3. Iteratively merge adjacent failing bins into the nearer passing neighbor until every bin passes.
4. Record final break-points.

**1.2 Ordinal variables — `RUCC_2023`, `PrimaryRUCA`**
- Treat existing integer levels as an ordered factor.
- Evaluate each level; merge only *consecutive* failing levels (preserve order).
- Record final level groupings.

**1.3 Binary variable — `near_walmart`**
- Evaluate each level {0, 1}.
- If either level fails and cannot be remedied by combining with another variable, flag it for exclusion from Phase 2.

**1.4 Output**
- Named list of bin definitions: break-points (continuous) or level-to-group maps (ordinal/binary).
- Per-variable marginal pass/fail summary.

---

### Phase 2 — Largest Valid Subset

**2.1 Cell validator**
Build a reusable function `cell_passes(records)` that:
- Counts unique ZCTAs in the cell and checks ≥ 2 from ≥ 2 states.
- Counts unique county FIPS in the cell and checks ≥ 2 from ≥ 2 states.
- Returns `TRUE` if either condition holds.

**2.2 Apriori-style subset search**
- Seed: `set.seed(42)`.
- Enumerate candidate subsets bottom-up (singletons → pairs → triples → …).
- If subset *S* has any failing cell → mark *S* and all its supersets as invalid (monotonicity prune).
- Track the largest *S* where every cell passes.
- During the search, allow re-coarsening of bins (merge adjacent bins one step) before discarding a candidate subset.

**2.3 Priority tie-breaking**
Among subsets of equal size, rank by:
1. County + Zip combinations (variables from both datasets)
2. Zip-only combinations
3. County-only combinations

**2.4 Deliverables**
- Final bin definitions per variable.
- Maximal valid subset(s) with variable names and bin labels.
- Per-cell pass/fail report for the chosen subset(s).
- Summary table (per `master.agents.md §Best Possible Subset`):
  - 1 row per variable × binning iteration
  - 1 column per variable (categories as a string)
  - Column: search type (`county + zip` / `zip` / `county`)
  - Column: number of identifiable combinations (cells that fail the objective)