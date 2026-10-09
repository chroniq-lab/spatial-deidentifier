"""
Local server for the de-identifier app (standard library only).

Serves index.html and a small JSON API so the page can:
  GET  /api/env              -> Python version + required/optional package status
  POST /api/install          -> pip install missing packages (background job)
  POST /api/run   {config}   -> write config.json and run the de-identifier (background job)
  GET  /api/job?id=..&from=n -> job status + log lines from line n
  GET  /api/results?id=..    -> run_summary.json + list of output files for a finished run
  GET  /api/file?id=..&name= -> download one output file of a run

Binds to 127.0.0.1 only. Start via launch.bat (Windows) / launch.sh, or:
    python app/server.py [--port 8765] [--no-browser]
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import threading
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent                                   # relative config paths resolve here
HTML = HERE / "index.html"
SCRIPT = HERE / "deidentify.py"
UPLOADS = ROOT / "uploads"                           # files sent from the browser land here

# import name -> pip name
REQUIRED = {"numpy": "numpy", "pandas": "pandas", "openpyxl": "openpyxl"}
OPTIONAL = {"pyarrow": "pyarrow"}                    # only for .parquet inputs

JOBS: dict[str, dict] = {}
LOCK = threading.Lock()


def pkg_status():
    def info(mod):
        spec = importlib.util.find_spec(mod)
        if spec is None:
            return {"installed": False, "version": None}
        try:
            from importlib.metadata import version
            v = version(mod)
        except Exception:
            v = "?"
        return {"installed": True, "version": v}
    return {
        "python": sys.version.split()[0],
        "executable": sys.executable,
        "python_ok": sys.version_info >= (3, 9),
        "script_found": SCRIPT.exists(),
        "required": {m: info(m) for m in REQUIRED},
        "optional": {m: info(m) for m in OPTIONAL},
    }


def start_job(kind, cmd, extra=None):
    jid = uuid.uuid4().hex[:10]
    job = {"id": jid, "kind": kind, "status": "running", "log": [" ".join(map(str, cmd))],
           "returncode": None, **(extra or {})}
    with LOCK:
        JOBS[jid] = job

    def work():
        try:
            p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, encoding="utf-8", errors="replace", bufsize=1)
            job["pid"] = p.pid
            for line in p.stdout:
                job["log"].append(line.rstrip("\n"))
            p.wait()
            job["returncode"] = p.returncode
            job["status"] = "done" if p.returncode == 0 else "failed"
        except Exception as e:                       # noqa: BLE001
            job["log"].append(f"ERROR: {e}")
            job["status"] = "failed"

    threading.Thread(target=work, daemon=True).start()
    return jid


def browse(path_str):
    """List sub-folders of a directory (for the output-folder picker)."""
    if not path_str:
        p = Path.home()
    else:
        p = Path(path_str).expanduser()
        if not p.is_absolute():
            p = ROOT / p
    while not p.exists() and p != p.parent:          # fall back to nearest existing parent
        p = p.parent
    p = p.resolve()
    dirs = []
    try:
        for d in sorted(p.iterdir(), key=lambda x: x.name.lower()):
            try:
                if d.is_dir() and not d.name.startswith((".", "$")):
                    dirs.append(d.name)
            except OSError:
                pass
    except OSError as e:
        return {"path": str(p), "parent": str(p.parent), "dirs": [], "error": str(e)}
    drives = []
    if os.name == "nt":
        drives = [f"{c}:\\" for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" if Path(f"{c}:\\").exists()]
    shortcuts = {"Home": str(Path.home()), "App folder": str(ROOT)}
    for nm in ("Desktop", "Documents", "Downloads"):
        if (Path.home() / nm).exists():
            shortcuts[nm] = str(Path.home() / nm)
    return {"path": str(p), "parent": str(p.parent) if p.parent != p else None,
            "dirs": dirs, "drives": drives, "shortcuts": shortcuts,
            "writable": os.access(p, os.W_OK)}


def resolve(p):
    """Absolute paths as-is; relative paths: repo root, then data/, then newest upload."""
    p = Path(p)
    if p.is_absolute():
        return p
    for cand in (ROOT / p, ROOT / "data" / p):
        if cand.exists():
            return cand
    if UPLOADS.exists():
        hits = sorted(UPLOADS.glob(f"*/{p.name}"), key=lambda f: f.stat().st_mtime, reverse=True)
        if hits:
            return hits[0]
    return ROOT / p


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):                       # keep console quiet
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path in ("/", "/index.html"):
            return self.send(200, HTML.read_bytes(), "text/html; charset=utf-8")
        if u.path == "/api/env":
            return self.send(200, pkg_status())
        if u.path == "/api/browse":
            return self.send(200, browse(q.get("path", "")))
        if u.path == "/api/job":
            job = JOBS.get(q.get("id", ""))
            if not job:
                return self.send(404, {"error": "unknown job"})
            start = int(q.get("from", 0))
            return self.send(200, {"status": job["status"], "returncode": job["returncode"],
                                   "lines": job["log"][start:], "next": len(job["log"])})
        if u.path == "/api/results":
            job = JOBS.get(q.get("id", ""))
            if not job or job["kind"] != "run":
                return self.send(404, {"error": "unknown run"})
            out_dir, prefix = job["out_dir"], job["prefix"]
            files = sorted(f.name for f in out_dir.glob(f"{prefix}*") if f.is_file())
            summ = out_dir / f"{prefix}run_summary.json"
            summary = json.loads(summ.read_text(encoding="utf-8")) if summ.exists() else None
            top = out_dir / f"{prefix}top_subset_cells.csv"
            preview = top.read_text(encoding="utf-8").splitlines()[:51] if top.exists() else []
            return self.send(200, {"out_dir": str(out_dir), "files": files,
                                   "summary": summary, "top_cells_preview": preview})
        if u.path == "/api/file":
            job = JOBS.get(q.get("id", ""))
            name = Path(q.get("name", "")).name      # no directory traversal
            if not job or job["kind"] != "run" or not name.startswith(job["prefix"]):
                return self.send(404, {"error": "not found"})
            f = job["out_dir"] / name
            if not f.is_file():
                return self.send(404, {"error": "not found"})
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", f'attachment; filename="{name}"')
            self.end_headers()
            self.wfile.write(f.read_bytes())
            return
        self.send(404, {"error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/api/upload":
            # Raw file body; saved under <repo>/uploads/<session>/<name>
            name = Path(q.get("name", "")).name
            session = "".join(ch for ch in q.get("session", "") if ch.isalnum())[:32] or "default"
            if not name:
                return self.send(400, {"error": "missing file name"})
            dest_dir = UPLOADS / session
            dest_dir.mkdir(parents=True, exist_ok=True)
            dest = dest_dir / name
            remaining = int(self.headers.get("Content-Length") or 0)
            with open(dest, "wb") as fh:
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 1 << 20))
                    if not chunk:
                        break
                    fh.write(chunk)
                    remaining -= len(chunk)
            return self.send(200, {"path": str(dest)})
        if u.path == "/api/mkdir":
            req = self.body()
            parent, name = Path(req.get("parent", "")), Path(req.get("name", "")).name
            if not parent.is_absolute() or not name:
                return self.send(400, {"error": "need absolute parent and a folder name"})
            try:
                (parent / name).mkdir(parents=False, exist_ok=True)
            except OSError as e:
                return self.send(400, {"error": str(e)})
            return self.send(200, browse(str(parent / name)))
        if u.path == "/api/install":
            st = pkg_status()
            want = self.body().get("include_optional", False)
            pkgs = [REQUIRED[m] for m, i in st["required"].items() if not i["installed"]]
            if want:
                pkgs += [OPTIONAL[m] for m, i in st["optional"].items() if not i["installed"]]
            if not pkgs:
                return self.send(200, {"job": None, "message": "Nothing to install."})
            jid = start_job("install", [sys.executable, "-m", "pip", "install", *pkgs])
            return self.send(200, {"job": jid})
        if u.path == "/api/run":
            req = self.body()
            cfg = req.get("config") or {}
            missing = [k for k in ("county_file", "zip_file", "crosswalk_file") if not cfg.get(k)]
            if missing:
                return self.send(400, {"error": f"missing: {missing}"})
            bad = [k for k in ("county_file", "zip_file", "crosswalk_file")
                   if not resolve(cfg[k]).exists()]
            if bad:
                return self.send(400, {"error": "File(s) not found on this machine: " +
                                       ", ".join(f"{k}={resolve(cfg[k])}" for k in bad)})
            for k in ("county_file", "zip_file", "crosswalk_file"):
                cfg[k] = str(resolve(cfg[k]))        # script gets the exact files we checked
            st = pkg_status()
            miss_pkg = [m for m, i in st["required"].items() if not i["installed"]]
            if miss_pkg:
                return self.send(400, {"error": f"Missing packages: {miss_pkg}. Install first."})
            out_dir = resolve(cfg.get("out_dir") or "output")
            try:
                out_dir.mkdir(parents=True, exist_ok=True)
            except OSError as e:
                return self.send(400, {"error": f"Cannot create output folder {out_dir}: {e}"})
            cfg["out_dir"] = str(out_dir)
            prefix = cfg.get("prefix") or "deid_"
            cfg_path = out_dir / f"{prefix}config.json"
            cfg_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
            cmd = [sys.executable, "-u", str(SCRIPT), "--config", str(cfg_path)]
            if req.get("workers"):
                cmd += ["--workers", str(int(req["workers"]))]
            jid = start_job("run", cmd, {"out_dir": out_dir, "prefix": prefix})
            return self.send(200, {"job": jid, "config_path": str(cfg_path)})
        self.send(404, {"error": "not found"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true")
    a = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    url = f"http://127.0.0.1:{a.port}/"
    print(f"Spatial de-identifier app running at {url}  (Ctrl+C to stop)")
    print(f"Python: {sys.executable}")
    if not a.no_browser:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
