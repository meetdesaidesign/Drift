#!/bin/bash
#
# End-to-end check of the app -> status.json -> screensaver path, using the real built
# Drift.app and Drift.saver rather than test doubles.
#
#   1. Launching Drift with no session publishes "Away from desk", so an idle Mac never
#      shows a status left over from last time.
#   2. The built .saver loads the way legacyScreenSaver loads it, and renders what is in
#      status.json.
#   3. A payload left behind by a crash — a session whose return time is long past —
#      renders "Away from desk" instead.
#
# Starting a session end to end needs a click in the popover, so it is not scripted here;
# what the popover writes is covered by the DriftCore tests.
#
set -euo pipefail
cd "$(dirname "$0")/.."

STATUS_FILE="$HOME/Library/Application Support/Drift/status.json"
OUT="build/preview"
FAILED=0

mkdir -p "$OUT"

read_field() {  # read_field <json path expression>
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$STATUS_FILE" 2>/dev/null \
    || echo "<unreadable>"
}

expect() {  # expect <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1 — $3"
  else
    echo "  FAIL  $1 — expected \"$2\", got \"$3\""
    FAILED=1
  fi
}

write_payload() {  # write_payload <seconds until return time>
  python3 - "$1" "$STATUS_FILE" <<'PY'
import sys, json, datetime, os
offset, path = int(sys.argv[1]), sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
back = now + datetime.timedelta(seconds=offset)
stamp = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
payload = {
    "schema": 2,
    "display": {"text": "Out for lunch", "returnTime": stamp(back), "updatedAt": stamp(now)},
    "fallbackText": "Away from desk",
    "sessionReturnTime": stamp(back),
    "writtenAt": stamp(now),
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(payload, f, indent=2)
PY
}

echo "==> 1. Launching Drift with no session publishes the idle status"
killall Drift 2>/dev/null || true
rm -f "$STATUS_FILE"
open build/Drift.app
python3 -c "
import time, os, sys
path = os.path.expanduser('~/Library/Application Support/Drift/status.json')
for _ in range(60):
    time.sleep(0.25)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        time.sleep(0.2); sys.exit(0)
sys.exit(1)
" || { echo "  FAIL  Drift did not publish a status within 15s"; FAILED=1; }
expect "idle status text" "Away from desk" "$(read_field "d['display']['text']")"
expect "idle status has no return time" "True" "$(read_field "d['display'].get('returnTime') is None")"
expect "schema" "2" "$(read_field "d['schema']")"

# Out of the way before the file is written by hand below.
killall Drift 2>/dev/null || true
sleep 1

if [ ! -x build/saver-loadtest ]; then
  echo "==> Building the saver load test"
  swiftc -target arm64-apple-macos15.0 -framework ScreenSaver -framework AppKit \
    -o build/saver-loadtest tools/saver-loadtest.swift
fi

echo "==> 2. The built .saver renders a live session"
write_payload 1800
if ./build/saver-loadtest "build/Back Soon.saver" "$OUT/e2e-live" | grep -q "ALL CHECKS PASSED"; then
  echo "  PASS  .saver loaded and rendered the published status"
else
  echo "  FAIL  .saver load test failed"; FAILED=1
fi

echo "==> 3. A session left behind by a crash is not believed forever"
write_payload -46800   # 13 hours past the return time
if ./build/saver-loadtest "build/Back Soon.saver" "$OUT/e2e-stale" | grep -q "ALL CHECKS PASSED"; then
  echo "  PASS  .saver loaded and rendered the stale payload"
else
  echo "  FAIL  .saver load test failed on the stale payload"; FAILED=1
fi

if cmp -s "$OUT/e2e-live-030.0s.png" "$OUT/e2e-stale-030.0s.png"; then
  echo "  FAIL  the stale payload rendered identically to the live one — the guard did nothing"
  FAILED=1
else
  echo "  PASS  the stale payload rendered differently — it fell back"
fi

# Leave the file as an idle status rather than a hand-written session.
python3 - "$STATUS_FILE" <<'PY'
import json, sys, datetime
path = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({
    "schema": 2,
    "display": {"text": "Away from desk", "updatedAt": stamp},
    "fallbackText": "Away from desk",
    "writtenAt": stamp,
}, open(path, "w"), indent=2)
PY

echo
if [ "$FAILED" = 0 ]; then echo "END-TO-END: ALL CHECKS PASSED"; else echo "END-TO-END: FAILURES ABOVE"; exit 1; fi
