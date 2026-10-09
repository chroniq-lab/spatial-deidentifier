#!/usr/bin/env bash
# Launch the Spatial De-identifier app (macOS / Linux):  bash analysis/sdana05_launch.sh
cd "$(dirname "$0")" || exit 1
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info>=(3,9) else 1)'; then
    PY="$c"; break
  fi
done
if [ -z "$PY" ]; then
  echo "Python 3.9+ not found. Install from https://www.python.org/downloads/ (or: brew install python)"
  exit 1
fi
echo "Using: $(command -v "$PY")"
exec "$PY" sdana05_app_server.py "$@"
