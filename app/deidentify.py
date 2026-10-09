"""
Spatial de-identifier: categorise COUNTY- and ZIP-level variables so that no
combination of categories identifies a State-ZIP or State-County.

Phase 1: derive categorical variables (merge bins until each marginal bin passes).
Phase 2: Apriori-style search for the largest valid subset, with re-coarsening.

Implementation notes:
  * Variables are stored as integer bin codes (-1 = NA); no factors / data-frame copies.
  * Cell pass/fail is a few vectorised numpy passes (unique on packed int64 keys).
  * Merged (county x zip) data are never copied: codes are gathered via crosswalk indices.
  * Candidate evaluation and coarsening trials run in a process pool; workers are
    stateless w.r.t. bin definitions (defs travel with each task, codes are cached),
    so no worker re-sync is needed when a coarsening is committed.

Pass rule: a cell passes if >=2 ZIPs in each of >=2 states OR
>=2 counties in each of >=2 states.

Generic inputs (any COUNTY-level and ZIP-level file + a ZIP<->COUNTY crosswalk):
  * Files may be .csv, .xlsx/.xls or .parquet.
  * ID / state column names are configurable. County state defaults to the first two
    digits of the 5-digit county FIPS if no county state column is given.
  * Variables: give "NAME" or "NAME:type" (type = continuous | ordinal | binary | auto).
    If no variables are given, every numeric non-ID column is used with type "auto":
      2 distinct values -> binary; integer with <= ORDINAL_MAX_LEVELS values -> ordinal;
      otherwise continuous.
  * Any variable failing its Phase 1 marginal check is excluded from Phase 2.
  * Continuous binning (config only): a variable spec may be an object, e.g.
      "OBESITY": {"type": "continuous", "percentiles": [20, 40, 60, 80]}
      "median_income": {"type": "continuous", "cutoffs": [40000, 60000, 80000], "fixed": true}
    percentiles: 0-100 (or 0-1); cutoffs: raw-value break-points (left-closed bins).
    fixed: true -> never merge/coarsen this variable (it is excluded if it fails).
    Top-level "percentiles" sets the default for all continuous variables
    (default 10, 25, 50, 75, 90).

Usage:
    python app/deidentify.py --config app/example_config.json
    python app/deidentify.py \
        --county-file county.csv --zip-file zip.csv --crosswalk-file COUNTY_ZIP.xlsx \
        --county-id FIPS --zip-id zcta --zip-state State --out-dir output \
        --county-vars OBESITY RUCC_2023:ordinal --zip-vars RPL_THEMES near_walmart:binary
CLI flags override values from --config. Relative paths resolve against the working dir.
Requires: numpy, pandas, openpyxl (for Excel inputs).
"""
from __future__ import annotations

import argparse
import json
import os
import time
from concurrent.futures import ProcessPoolExecutor
from itertools import combinations
from pathlib import Path

import numpy as np
import pandas as pd

INIT_PROBS = [0.10, 0.25, 0.50, 0.75, 0.90]
MAX_ITER = 30
ORDINAL_MAX_LEVELS = 12   # "auto": integer variables with <= this many levels -> ordinal
VAR_TYPES = ("continuous", "ordinal", "binary", "auto")

DEFAULTS = dict(
    county_file=None, zip_file=None, crosswalk_file=None,
    out_dir="output", prefix="deid_",
    county_id="FIPS", county_state=None,      # None -> state = first 2 digits of FIPS
    zip_id="zcta", zip_state="State",
    cw_zip="ZIP", cw_county="COUNTY",
    county_vars=None, zip_vars=None,           # None -> all numeric non-ID columns (auto)
    percentiles=None,                          # None -> INIT_PROBS for continuous variables
)


def norm_probs(p, label):
    """Percentiles given as 0-100 or 0-1 -> sorted unique fractions in (0, 1)."""
    try:
        p = [float(v) for v in p]
    except (TypeError, ValueError):
        raise SystemExit(f"{label}: percentiles must be numbers, got {p!r}")
    if any(v > 1 for v in p):
        p = [v / 100 for v in p]
    if not p or any(not 0 < v < 1 for v in p):
        raise SystemExit(f"{label}: percentiles must be strictly between 0 and 100")
    return sorted(set(p))


# ══════════════════════════════════════════════════════════════════════════════
# Core counting primitive
# ══════════════════════════════════════════════════════════════════════════════
def states_with_2plus(cell, state, unit, ncell, n_state, n_unit):
    """Per cell: number of states having >=2 distinct units."""
    m = (state >= 0) & (unit >= 0) & (cell >= 0)
    if not m.any():
        return np.zeros(ncell, dtype=np.int64)
    key = (cell[m].astype(np.int64) * n_state + state[m]) * n_unit + unit[m]
    pair = np.unique(key) // n_unit            # distinct (cell, state, unit) -> (cell, state)
    p, cnt = np.unique(pair, return_counts=True)
    c = p[cnt >= 2] // n_state
    return np.bincount(c, minlength=ncell)


def pack_cells(cols):
    """Combine integer code columns (all >=0) into dense cell ids. Returns (cell, ncell)."""
    cell = np.zeros(len(cols[0]), dtype=np.int64)
    for c in cols:
        cell = cell * (int(c.max()) + 1) + c
        _, cell = np.unique(cell, return_inverse=True)
        cell = cell.astype(np.int64)
    return cell, int(cell.max()) + 1 if len(cell) else 0


# ══════════════════════════════════════════════════════════════════════════════
# Bin definitions (dicts: type, var, breaks | groups, bin_labels, n_merges, passes)
# ══════════════════════════════════════════════════════════════════════════════
def fmt(v):
    return "Inf" if v == np.inf else "-Inf" if v == -np.inf else f"{v:.5g}"


def continuous_labels(breaks):
    edges = [-np.inf] + list(breaks) + [np.inf]
    labs = [f"[{fmt(edges[i])},{fmt(edges[i + 1])})" for i in range(len(edges) - 1)]
    labs[-1] = labs[-1][:-1] + "]"
    return labs


def ordinal_labels(groups):
    return [fmt(g[0]) if len(g) == 1 else f"{fmt(g[0])}\u2013{fmt(g[-1])}" for g in groups]


def make_def(kind, var, n_merges=0, passes=None, **kw):
    d = dict(type=kind, var=var, n_merges=n_merges, passes=passes, **kw)
    if kind == "continuous":
        d["bin_labels"] = continuous_labels(d["breaks"])
    elif kind == "ordinal":
        d["bin_labels"] = ordinal_labels(d["groups"])
    else:
        d["bin_labels"] = [fmt(v) for v in d["levels"]]
    return d


def def_sig(d):
    if d["type"] == "continuous":
        return ("c", tuple(d["breaks"]))
    if d["type"] == "ordinal":
        return ("o", tuple(tuple(g) for g in d["groups"]))
    return ("b", tuple(d["levels"]))


def _lookup(x, values, ids):
    """Map x onto ids where x exactly matches one of values; else -1."""
    values = np.asarray(values, dtype=float)
    ids = np.asarray(ids, dtype=np.int64)
    o = np.argsort(values)
    values, ids = values[o], ids[o]
    pos = np.clip(np.searchsorted(values, x), 0, len(values) - 1)
    return np.where(values[pos] == x, ids[pos], -1)


def apply_def(x, d):
    """Raw float array (NaN = NA) -> int bin codes (-1 = NA). Left-closed intervals."""
    x = np.asarray(x, dtype=float)
    na = np.isnan(x)
    if d["type"] == "continuous":
        codes = np.searchsorted(np.asarray(d["breaks"], dtype=float), x, side="right")
    elif d["type"] == "ordinal":
        vals = [v for g in d["groups"] for v in g]
        ids = [gi for gi, g in enumerate(d["groups"]) for _ in g]
        codes = _lookup(x, vals, ids)
    else:
        codes = _lookup(x, d["levels"], range(len(d["levels"])))
    return np.where(na, -1, codes).astype(np.int64)


def coarsen_one_step(d):
    if d["type"] == "binary" or d.get("fixed"):
        return []
    keep = {k: v for k, v in d.items() if k != "eval_result"}   # carry init/fixed metadata
    out = []
    if d["type"] == "continuous":
        b = list(d["breaks"])
        if len(b) <= 3:
            return []
        for i in range(len(b)):
            out.append({**keep, **make_def("continuous", d["var"], d["n_merges"] + 1, None,
                                           breaks=b[:i] + b[i + 1:])})
    else:
        g = [list(x) for x in d["groups"]]
        if len(g) <= 3:
            return []
        for i in range(len(g) - 1):
            ng = g[:i] + [sorted(g[i] + g[i + 1])] + g[i + 2:]
            out.append({**keep, **make_def("ordinal", d["var"], d["n_merges"] + 1, None,
                                           groups=ng)})
    return out


def def_to_json(d):
    return {k: (list(map(float, v)) if k == "breaks" else v) for k, v in d.items()
            if k != "eval_result"}


# ══════════════════════════════════════════════════════════════════════════════
# Marginal evaluation + merge engines (Phase 1)
# ══════════════════════════════════════════════════════════════════════════════
def eval_marginal(codes, unit, state, n_state, n_unit):
    """Per observed bin: stats + pass flag (>=2 units in each of >=2 states)."""
    ok = codes >= 0
    bins, inv = np.unique(codes[ok], return_inverse=True)
    nb = len(bins)
    cell = np.full(len(codes), -1, dtype=np.int64)
    cell[ok] = inv
    n2 = states_with_2plus(cell, state, unit, nb, n_state, n_unit)
    df = pd.DataFrame({"bin": inv, "unit": unit[ok], "state": state[ok]})
    g = df.groupby("bin")
    res = pd.DataFrame({
        "bin_code": bins,
        "n_records": g.size().values,
        "n_units": g["unit"].nunique().values,
        "n_states": g["state"].nunique().values,
        "n_states_with_2plus": n2,
    })
    res["passes"] = res["n_states_with_2plus"] >= 2
    return res


def merge_continuous(x, var, init_breaks, ev, fixed=False):
    breaks = sorted(set(init_breaks))
    it = 0
    while True:
        d = make_def("continuous", var, it, None, breaks=breaks)
        res = ev(apply_def(x, d))
        if fixed or res["passes"].all() or it >= MAX_ITER or len(breaks) < 3:
            break
        i = int(np.flatnonzero(~res["passes"].values)[0])
        breaks = breaks[:i] + breaks[i + 1:] if i < len(res) - 1 else breaks[:-1]
        it += 1
    d["passes"] = bool(res["passes"].all())
    d["eval_result"] = res
    return d


def merge_ordinal(x, var, ev):
    vals = np.unique(x[~np.isnan(x)]).tolist()
    groups = [[v] for v in vals]
    it = 0
    while True:
        d = make_def("ordinal", var, it, None, groups=groups)
        res = ev(apply_def(x, d))
        if res["passes"].all() or it >= MAX_ITER or len(groups) <= 4:
            break
        i = int(np.flatnonzero(~res["passes"].values)[0])
        if i < len(groups) - 1:
            groups = groups[:i] + [sorted(groups[i] + groups[i + 1])] + groups[i + 2:]
        else:
            groups = groups[:i - 1] + [sorted(groups[i - 1] + groups[i])]
        it += 1
    d["passes"] = bool(res["passes"].all())
    d["eval_result"] = res
    return d


# ══════════════════════════════════════════════════════════════════════════════
# Data container + subset evaluation engine (Phase 2)
# ══════════════════════════════════════════════════════════════════════════════
class Engine:
    """Holds raw arrays; evaluates subsets given bin defs. Safe to build per worker."""

    def __init__(self, raw):
        self.r = raw
        self.cache = {}

    def codes(self, var, d):
        key = (var, def_sig(d))
        hit = self.cache.get(key)
        if hit is None:
            if len(self.cache) > 600:
                self.cache.clear()
            r = self.r
            if r["source"][var] == "county":
                src = apply_def(r["county_raw"][var], d)
                idx = r["cw_cidx"]
            else:
                src = apply_def(r["zip_raw"][var], d)
                idx = r["cw_zidx"]
            merged = np.where(idx >= 0, src[np.clip(idx, 0, None)], -1)
            hit = (src, merged)
            self.cache[key] = hit
        return hit

    def test(self, cand, defs, detail=False):
        r = self.r
        cv = [v for v in cand if r["source"][v] == "county"]
        zv = [v for v in cand if r["source"][v] == "zip"]
        if cv and zv:
            dtype = "county+zip"
            cols = [self.codes(v, defs[v])[1] for v in cv + zv]
            keep = np.all([c >= 0 for c in cols], axis=0)
            cols = [c[keep] for c in cols]
            cell, n = pack_cells(cols) if keep.any() else (np.zeros(0, np.int64), 0)
            zn = states_with_2plus(cell, r["m_zstate"][keep], r["m_zunit"][keep], n,
                                   r["n_zstate"], r["n_zunit"])
            cn = states_with_2plus(cell, r["m_cstate"][keep], r["m_cunit"][keep], n,
                                   r["n_cstate"], r["n_cunit"])
            zok, cok = zn >= 2, cn >= 2
        elif cv:
            dtype = "county"
            cols = [self.codes(v, defs[v])[0] for v in cv]
            keep = np.all([c >= 0 for c in cols], axis=0)
            cols = [c[keep] for c in cols]
            cell, n = pack_cells(cols) if keep.any() else (np.zeros(0, np.int64), 0)
            cn = states_with_2plus(cell, r["c_state"][keep], r["c_unit"][keep], n,
                                   r["n_cstate"], r["n_cunit"])
            zn = np.zeros(n, dtype=np.int64)
            zok, cok = np.zeros(n, bool), cn >= 2
        else:
            dtype = "zip"
            cols = [self.codes(v, defs[v])[0] for v in zv]
            keep = np.all([c >= 0 for c in cols], axis=0)
            cols = [c[keep] for c in cols]
            cell, n = pack_cells(cols) if keep.any() else (np.zeros(0, np.int64), 0)
            zn = states_with_2plus(cell, r["z_state"][keep], r["z_unit"][keep], n,
                                   r["n_zstate"], r["n_zunit"])
            cn = np.zeros(n, dtype=np.int64)
            zok, cok = zn >= 2, np.zeros(n, bool)
        passed = zok | cok
        n_fail = int((~passed).sum())
        out = dict(passes=n_fail == 0, n_fail=n_fail, dtype=dtype)
        if detail:
            _, first = np.unique(cell, return_index=True)
            cols_df = {f"{v}_bin": np.array(defs[v]["bin_labels"])[cols[i][first]]
                       for i, v in enumerate(cv + zv)}
            sub = pd.DataFrame(cols_df)
            sub["n_zip_states_with_2plus"] = zn
            sub["n_county_states_with_2plus"] = cn
            sub["zip_passes"], sub["county_passes"], sub["passes"] = zok, cok, passed
            out["cells"] = sub
        return out


ENGINE: Engine | None = None


def _init_worker(raw):
    global ENGINE
    ENGINE = Engine(raw)


def eval_task(args):
    cand, defs = args
    res = ENGINE.test(cand, defs)
    return res["passes"], res["n_fail"], res["dtype"]


# ══════════════════════════════════════════════════════════════════════════════
# I/O helpers
# ══════════════════════════════════════════════════════════════════════════════
def read_table(path, id_cols=()):
    path = Path(path)
    if not path.exists():
        raise SystemExit(f"File not found: {path}")
    suf = path.suffix.lower()
    dtype = {c: str for c in id_cols}
    if suf in (".xlsx", ".xls"):
        return pd.read_excel(path, dtype=dtype)
    if suf == ".parquet":
        return pd.read_parquet(path)
    return pd.read_csv(path, dtype=dtype)


def clean_id(s, width=5):
    """Normalise geographic IDs: string, strip, drop trailing '.0', left-pad zeros."""
    return (s.astype("string").str.strip()
             .str.replace(r"\.0$", "", regex=True).str.zfill(width))


def require_cols(df, cols, label):
    miss = [c for c in cols if c and c not in df.columns]
    if miss:
        raise SystemExit(f"{label}: column(s) not found: {miss}. Available: {list(df.columns)}")


def infer_type(x):
    u = np.unique(x[~np.isnan(x)])
    if len(u) < 2:
        return None
    if len(u) == 2:
        return "binary"
    if np.all(u == np.round(u)) and len(u) <= ORDINAL_MAX_LEVELS:
        return "ordinal"
    return "continuous"


def parse_var_spec(spec):
    """None | list['NAME' or 'NAME:type'] | dict{NAME: type | {type, percentiles|cutoffs, fixed}}
    -> {NAME: {"type": ..., ...}} or None."""
    if spec is None:
        return None
    out = {}
    if isinstance(spec, dict):
        for name, s in spec.items():
            if isinstance(s, dict):
                out[name] = {**s, "type": s.get("type") or "auto"}
            else:
                out[name] = {"type": s or "auto"}
        return out
    for s in spec:
        name, _, t = s.partition(":")
        out[name] = {"type": t or "auto"}
    return out


def resolve_vars(df, spec, exclude, label):
    """Return {var: (type, float array, binning opts)} for requested (or auto) variables."""
    spec = parse_var_spec(spec)
    if not spec:
        spec = {c: {"type": "auto"} for c in df.columns
                if c not in exclude and pd.api.types.is_numeric_dtype(df[c])}
    require_cols(df, list(spec), label)
    out = {}
    for v, s in spec.items():
        t = s["type"]
        if t not in VAR_TYPES:
            raise SystemExit(f"{label}: unknown type '{t}' for '{v}' (use {VAR_TYPES})")
        x = pd.to_numeric(df[v], errors="coerce").to_numpy(float)
        auto = infer_type(x)
        if auto is None:
            print(f"  skipping {label} variable '{v}': fewer than 2 distinct values")
            continue
        has_p, has_c = s.get("percentiles") is not None, s.get("cutoffs") is not None
        if has_p and has_c:
            raise SystemExit(f"{label}: '{v}' has both percentiles and cutoffs; use one.")
        if t == "auto" and (has_p or has_c):
            t = "continuous"                      # explicit binning implies continuous
        typ = auto if t == "auto" else t
        opts = {}
        if typ == "continuous":
            if has_p:
                opts["percentiles"] = norm_probs(s["percentiles"], f"{label}: '{v}'")
            if has_c:
                try:
                    cuts = sorted(set(float(c) for c in s["cutoffs"]))
                except (TypeError, ValueError):
                    raise SystemExit(f"{label}: '{v}' cutoffs must be numbers")
                if not cuts:
                    raise SystemExit(f"{label}: '{v}' cutoffs list is empty")
                opts["cutoffs"] = cuts
            opts["fixed"] = bool(s.get("fixed", False))
        elif has_p or has_c or s.get("fixed"):
            print(f"  note: binning options ignored for {typ} variable '{v}'")
        out[v] = (typ, x, opts)
    return out


def load_raw(cfg):
    cid, cst = cfg["county_id"], cfg.get("county_state")
    zid, zst = cfg["zip_id"], cfg["zip_state"]

    county = read_table(cfg["county_file"], [cid])
    zipd = read_table(cfg["zip_file"], [zid])
    require_cols(county, [cid, cst], "county_file")
    require_cols(zipd, [zid, zst], "zip_file")

    county[cid] = clean_id(county[cid])
    zipd[zid] = clean_id(zipd[zid])
    for df, col, label in ((county, cid, "county_file"), (zipd, zid, "zip_file")):
        nd = int(df[col].duplicated().sum())
        if nd:
            print(f"  {label}: dropping {nd} duplicate '{col}' row(s) (first kept)")
    county = county.drop_duplicates(cid).reset_index(drop=True)
    zipd = zipd.drop_duplicates(zid).reset_index(drop=True)
    c_state_lab = county[cst].astype(str) if cst else county[cid].str[:2]
    z_state_lab = zipd[zst].astype(str)

    c_vars = resolve_vars(county, cfg.get("county_vars"), {cid, cst}, "county_file")
    z_vars = resolve_vars(zipd, cfg.get("zip_vars"), {zid, zst}, "zip_file")
    clash = sorted(set(c_vars) & set(z_vars))
    if clash:
        raise SystemExit(f"Variable name(s) in both files: {clash}. Rename one, or restrict "
                         "with county_vars / zip_vars.")
    if not c_vars and not z_vars:
        raise SystemExit("No usable variables found.")

    cw_raw = read_table(cfg["crosswalk_file"], [cfg["cw_zip"], cfg["cw_county"]])
    require_cols(cw_raw, [cfg["cw_zip"], cfg["cw_county"]], "crosswalk_file")
    cw = pd.DataFrame({"ZIP": clean_id(cw_raw[cfg["cw_zip"]]),
                       "COUNTY": clean_id(cw_raw[cfg["cw_county"]])}).dropna().drop_duplicates()
    cw["state_fips"] = cw["COUNTY"].str[:2]

    f = lambda s: pd.factorize(s)[0].astype(np.int64)
    c_state_codes = f(c_state_lab)
    z_state_codes = f(z_state_lab)
    cw_cidx = pd.Index(county[cid]).get_indexer(cw["COUNTY"]).astype(np.int64)
    cw_zidx = pd.Index(zipd[zid]).get_indexer(cw["ZIP"]).astype(np.int64)
    m_zstate = np.where(cw_zidx >= 0, z_state_codes[np.clip(cw_zidx, 0, None)], -1)

    print(f"  county rows: {len(county)}, zip rows: {len(zipd)}, crosswalk pairs: {len(cw)} "
          f"({(cw_cidx >= 0).mean():.0%} matched county, {(cw_zidx >= 0).mean():.0%} matched zip)")

    raw = dict(
        county_raw={v: x for v, (_, x, _) in c_vars.items()},
        zip_raw={v: x for v, (_, x, _) in z_vars.items()},
        types={v: t for v, (t, _, _) in {**c_vars, **z_vars}.items()},
        opts={v: o for v, (_, _, o) in {**c_vars, **z_vars}.items()},
        default_percentiles=norm_probs(cfg.get("percentiles") or INIT_PROBS, "percentiles"),
        source={**{v: "county" for v in c_vars}, **{v: "zip" for v in z_vars}},
        county_ids=county[cid].to_numpy(), zip_ids=zipd[zid].to_numpy(),
        county_state_lab=c_state_lab.to_numpy(), zip_state_lab=z_state_lab.to_numpy(),
        county_id_col=cid, zip_id_col=zid,
        c_unit=f(county[cid]), c_state=c_state_codes,
        z_unit=f(zipd[zid]), z_state=z_state_codes,
        cw_cidx=cw_cidx, cw_zidx=cw_zidx,
        m_zunit=f(cw["ZIP"]), m_zstate=m_zstate.astype(np.int64),
        m_cunit=f(cw["COUNTY"]), m_cstate=f(cw["state_fips"]),
    )
    raw["n_cunit"] = int(max(raw["c_unit"].max(), raw["m_cunit"].max())) + 1
    raw["n_cstate"] = int(max(raw["c_state"].max(), raw["m_cstate"].max())) + 1
    raw["n_zunit"] = int(max(raw["z_unit"].max(), raw["m_zunit"].max())) + 1
    raw["n_zstate"] = int(max(raw["z_state"].max(), raw["m_zstate"].max())) + 1
    return raw


# ══════════════════════════════════════════════════════════════════════════════
# Phase 1
# ══════════════════════════════════════════════════════════════════════════════
def phase1(raw):
    ev = {
        "county": lambda codes: eval_marginal(codes, raw["c_unit"], raw["c_state"],
                                              raw["n_cstate"], raw["n_cunit"]),
        "zip": lambda codes: eval_marginal(codes, raw["z_unit"], raw["z_state"],
                                           raw["n_zstate"], raw["n_zunit"]),
    }
    defs = {}
    for v, t in raw["types"].items():
        src = raw["source"][v]
        x = raw[f"{src}_raw"][v]
        if t == "continuous":
            o = raw["opts"].get(v, {})
            if "cutoffs" in o:
                init, how, vals = o["cutoffs"], "cutoffs", o["cutoffs"]
            else:
                probs = o.get("percentiles") or raw["default_percentiles"]
                init, how, vals = quantile_breaks(x, probs), "percentiles", [p * 100 for p in probs]
            d = merge_continuous(x, v, init, ev[src], fixed=o.get("fixed", False))
            d.update(init=how, init_values=vals, fixed=o.get("fixed", False))
        elif t == "ordinal":
            d = merge_ordinal(x, v, ev[src])
        else:
            d = make_def("binary", v, 0, None, levels=np.unique(x[~np.isnan(x)]).tolist())
            res = ev[src](apply_def(x, d))
            d["passes"], d["eval_result"] = bool(res["passes"].all()), res
        defs[v] = d
        print(f"[{src:6s}|{t:10s}] {v:20s} {len(d['bin_labels'])} bins, "
              f"{d['n_merges']} merge(s), passes={d['passes']}")
    return defs


def quantile_breaks(x, probs=INIT_PROBS):
    return sorted(set(np.nanquantile(x, probs).tolist()))


# ══════════════════════════════════════════════════════════════════════════════
# Phase 2
# ══════════════════════════════════════════════════════════════════════════════
def phase2(raw, defs, pool_map, engine):
    source = raw["source"]
    all_vars = list(defs.keys())

    def dtype_label(c):
        has_c = any(source[v] == "county" for v in c)
        has_z = any(source[v] == "zip" for v in c)
        return "county+zip" if has_c and has_z else "zip" if has_z else "county"

    def sub(c, over=None):
        d = {v: defs[v] for v in c}
        if over:
            d.update(over)
        return d

    log = []

    def add_log(it, cand, passes, n_fail, dtype, coarsened=False, cvar=None):
        log.append(dict(iteration=it, vars=", ".join(cand), n_vars=len(cand), passes=passes,
                        n_fail=n_fail, dataset_type=dtype, coarsened=coarsened,
                        coarsened_var=cvar))

    # singletons
    failing = []
    for v in list(all_vars):
        if not engine.test((v,), sub((v,)))["passes"]:
            failing.append(v)
    if failing:
        print("Singletons failing Phase 2 check:", ", ".join(failing))
        all_vars = [v for v in all_vars if v not in failing]
    for v in all_vars:
        add_log(0, (v,), True, 0, dtype_label((v,)))

    current_valid = [(v,) for v in all_vars]
    best_valid, best_k = current_valid, 1
    it_ctr = 1

    for k in range(1, len(all_vars)):
        valid_set = set(current_valid)
        seen, cands = set(), []
        for s in current_valid:
            for v in all_vars:
                if v in s:
                    continue
                c = tuple(sorted(s + (v,)))
                if c in seen:
                    continue
                seen.add(c)
                if all(sc in valid_set for sc in combinations(c, k)):
                    cands.append(c)
        if not cands:
            print(f"Level {k + 1}: no candidates after pruning - search complete.")
            break
        t0 = time.time()
        print(f"Level {k + 1}: testing {len(cands)} candidate(s)...", end=" ", flush=True)
        results = list(pool_map(eval_task, [(c, sub(c)) for c in cands]))

        next_valid, fail_batch = [], []
        for c, (ok, nf, dt) in zip(cands, results):
            if ok:
                next_valid.append(c)
                add_log(it_ctr, c, True, 0, dt)
            else:
                fail_batch.append((c, it_ctr))
            it_ctr += 1

        for c, it in fail_batch:
            cur = engine.test(c, sub(c))
            if cur["passes"]:
                next_valid.append(c)
                add_log(it, c, True, 0, cur["dtype"])
                continue
            committed = None
            for v in c:
                trials = coarsen_one_step(defs[v])
                if not trials:
                    continue
                res = list(pool_map(eval_task, [(c, sub(c, {v: nd})) for nd in trials]))
                hit = next((i for i, r in enumerate(res) if r[0]), None)
                if hit is not None:
                    defs[v] = trials[hit]       # monotone: safe to commit globally
                    committed = v
                    break
            if committed:
                next_valid.append(c)
                add_log(it, c, True, 0, dtype_label(c), True, committed)
            else:
                add_log(it, c, False, cur["n_fail"], cur["dtype"])

        print(f"{len(next_valid)} valid ({time.time() - t0:.1f}s)")
        if not next_valid:
            break
        best_valid, best_k, current_valid = next_valid, k + 1, next_valid

    return all_vars, best_valid, best_k, log, dtype_label


# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
def load_config(argv=None):
    ap = argparse.ArgumentParser(description="Spatial de-identification of COUNTY + ZIP files.")
    ap.add_argument("--config", help="JSON file with any of the keys below")
    ap.add_argument("--county-file", help="COUNTY-level file (.csv/.xlsx/.parquet)")
    ap.add_argument("--zip-file", help="ZIP-level file (.csv/.xlsx/.parquet)")
    ap.add_argument("--crosswalk-file", help="ZIP<->COUNTY crosswalk file")
    ap.add_argument("--out-dir", help="Output directory (created if missing)")
    ap.add_argument("--prefix", help="Output file-name prefix")
    ap.add_argument("--county-id", help="County FIPS column in county file")
    ap.add_argument("--county-state", help="State column in county file (default: FIPS[:2])")
    ap.add_argument("--zip-id", help="ZIP/ZCTA column in zip file")
    ap.add_argument("--zip-state", help="State column in zip file")
    ap.add_argument("--cw-zip", help="ZIP column in crosswalk")
    ap.add_argument("--cw-county", help="County FIPS column in crosswalk")
    ap.add_argument("--county-vars", nargs="+", help="NAME or NAME:type ...")
    ap.add_argument("--zip-vars", nargs="+", help="NAME or NAME:type ...")
    ap.add_argument("--percentiles", nargs="+", type=float,
                    help="Default starting percentiles for continuous variables (0-100)")
    ap.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    a = ap.parse_args(argv)

    cfg = dict(DEFAULTS)
    if a.config:
        with open(a.config, encoding="utf-8") as fh:
            user = json.load(fh)
        unknown = set(user) - set(DEFAULTS)
        if unknown:
            raise SystemExit(f"Unknown config key(s): {sorted(unknown)}")
        cfg.update(user)
    for k in DEFAULTS:
        val = getattr(a, k, None)
        if val is not None:
            cfg[k] = val
    missing = [k for k in ("county_file", "zip_file", "crosswalk_file") if not cfg.get(k)]
    if missing:
        ap.error(f"missing required setting(s): {missing} (via --config or CLI flags)")
    return cfg, a.workers


def main():
    cfg, workers = load_config()
    out_dir = Path(cfg["out_dir"])
    out_dir.mkdir(parents=True, exist_ok=True)
    prefix = cfg["prefix"]
    out = lambda name: out_dir / f"{prefix}{name}"

    t_start = time.time()
    print(f"County file:    {cfg['county_file']}\nZIP file:       {cfg['zip_file']}\n"
          f"Crosswalk file: {cfg['crosswalk_file']}\nOutput dir:     {out_dir}")
    raw = load_raw(cfg)
    print(f"Loaded data in {time.time() - t_start:.1f}s")

    # ── Phase 1
    defs = phase1(raw)
    rows = []
    for v, d in defs.items():
        res = d["eval_result"]
        rows.append(dict(variable=v, dataset=raw["source"][v], var_type=d["type"],
                         n_bins=len(d["bin_labels"]), n_merges=d["n_merges"],
                         passes=d["passes"], n_fail_bins=int((~res["passes"]).sum()),
                         binning=d.get("init", ""),
                         binning_values=", ".join(fmt(float(z)) for z in d.get("init_values", [])),
                         fixed=bool(d.get("fixed", False)),
                         categories=" | ".join(d["bin_labels"])))
    pd.DataFrame(rows).to_csv(out("marginal_summary.csv"), index=False)

    failed = [v for v, d in defs.items() if not d["passes"]]
    if failed:
        print("Excluded from Phase 2 (failed Phase 1 marginal check):", ", ".join(failed))
        for v in failed:
            del defs[v]
    if not defs:
        raise SystemExit("No variables passed Phase 1.")
    with open(out("bin_defs_phase1.json"), "w", encoding="utf-8") as fh:
        json.dump({v: def_to_json(d) for v, d in defs.items()}, fh, indent=1)

    # ── Phase 2
    engine = Engine(raw)
    if workers > 1:
        pool = ProcessPoolExecutor(workers, initializer=_init_worker, initargs=(raw,))
        pool_map = lambda fn, it: pool.map(fn, it, chunksize=4)
    else:
        _init_worker(raw)
        pool, pool_map = None, map
    try:
        all_vars, best_valid, best_k, log, dtype_label = phase2(raw, defs, pool_map, engine)
    finally:
        if pool:
            pool.shutdown()

    # ── Priority tie-breaking: county+zip > zip > county; more cross vars first
    source = raw["source"]

    def priority(s):
        nc = sum(source[v] == "county" for v in s)
        nz = len(s) - nc
        tier = 1 if nc and nz else 2 if nz else 3
        return (tier, -(nc * nz))

    best_sorted = sorted(best_valid, key=priority)
    top = best_sorted[0]
    print(f"\nLargest valid subset: {best_k} variable(s); type {dtype_label(top)}")
    print("Top subset:", ", ".join(top))

    # ── Deliverables
    with open(out("bin_defs_final.json"), "w", encoding="utf-8") as fh:
        json.dump({v: def_to_json(d) for v, d in defs.items()}, fh, indent=1)

    top_res = engine.test(top, {v: defs[v] for v in top}, detail=True)
    top_res["cells"].to_csv(out("top_subset_cells.csv"), index=False)

    frames = []
    for i, s in enumerate(best_sorted, 1):
        r = engine.test(s, {v: defs[v] for v in s}, detail=True)
        c = r["cells"]
        c.insert(0, "dataset_type", r["dtype"])
        c.insert(0, "subset_vars", ", ".join(s))
        c.insert(0, "subset_rank", i)
        frames.append(c)
    pd.concat(frames, ignore_index=True).to_csv(out("all_top_subsets_cells.csv"), index=False)

    log_df = pd.DataFrame(log)
    log_df.to_csv(out("search_log.csv"), index=False)

    labels = {v: " | ".join(defs[v]["bin_labels"]) for v in all_vars}
    srows = []
    for e in log:
        if not e["passes"]:
            continue
        cv = e["vars"].split(", ")
        row = dict(iteration=e["iteration"], n_vars=e["n_vars"], variables_included=e["vars"],
                   search_type=e["dataset_type"], n_identifiable_combinations=e["n_fail"],
                   coarsened=e["coarsened"], coarsened_var=e["coarsened_var"])
        for v in all_vars:
            row[f"{v}_categories"] = labels[v] if v in cv else None
        srows.append(row)
    summary = pd.DataFrame(srows)
    summary.to_csv(out("summary_table.csv"), index=False)

    # ── De-identified (binned) versions of the input files, using final bins.
    # NOTE: only the combination of variables in the top subset is guaranteed valid.
    for side in ("county", "zip"):
        vs = [v for v in all_vars if source[v] == side]
        if not vs:
            continue
        df = pd.DataFrame({raw[f"{side}_id_col"]: raw[f"{side}_ids"],
                           "state": raw[f"{side}_state_lab"]})
        for v in vs:
            codes = apply_def(raw[f"{side}_raw"][v], defs[v])
            df[f"{v}_bin"] = pd.Categorical.from_codes(codes, defs[v]["bin_labels"], ordered=True)
        df.to_csv(out(f"{side}_binned.csv"), index=False)

    with open(out("run_summary.json"), "w", encoding="utf-8") as fh:
        json.dump(dict(config=cfg, variable_types=raw["types"], excluded_phase1=failed,
                       largest_valid_k=best_k, top_subset=list(top),
                       top_subset_type=dtype_label(top),
                       all_top_subsets=[list(s) for s in best_sorted]),
                  fh, indent=1, default=str)

    print(f"Search log: {len(log_df)} rows; summary table: {len(summary)} rows")
    print(f"Top-subset cells: {len(top_res['cells'])} ({top_res['n_fail']} fail)")
    print(f"Outputs in {out_dir}; total time {time.time() - t_start:.1f}s")


if __name__ == "__main__":
    main()
