#!/bin/bash
# Renders the app's main screens (light and dark) from invented demo mail, no screen-recording permission needed.
# Usage: scripts/demo_snapshot.sh OUTDIR   (needs a built binary: scripts/bundle.sh, python3, sqlite3)
set -euo pipefail
OUT="${1:?usage: demo_snapshot.sh OUTDIR}"; mkdir -p "$OUT"
BIN="${INKWELL_BUILD_DIR:-$HOME/Library/Caches/inkwell-build}/release/Inkwell"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEMO="$OUT/demo-home"; rm -rf "$DEMO"; mkdir -p "$DEMO"
export INKWELL_HOME="$DEMO" INKWELL_INSECURE_LOCAL=1
python3 "$HERE/fake_imap.py" 14391 300 1 >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 0.8; "$BIN" --synctest 14391 >/dev/null 2>&1
ACCT=$(sqlite3 "$DEMO/mail.sqlite" "select account from messages limit 1")
for mode in light dark; do
  python3 - "$DEMO/settings.json" "$ACCT" "$mode" <<'PY'
import json, sys
json.dump({"accounts": [{"id": sys.argv[2], "label": "Demo", "displayName": "Demo", "email": "me@example.com", "username": "me",
                         "imapHost": "127.0.0.1", "imapPort": 14391, "smtpHost": "127.0.0.1"}], "appearance": sys.argv[3]}, open(sys.argv[1], "w"))
PY
  INKWELL_SNAPSHOT="$OUT/$mode" INKWELL_NO_PREFETCH=1 "$BIN" >/dev/null 2>&1 & APP=$!
  sleep 24; kill $APP 2>/dev/null || true; wait $APP 2>/dev/null || true
done
ls "$OUT"/*.png
