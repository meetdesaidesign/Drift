#!/bin/bash
#
# End-to-end check of the app -> status.json -> screensaver path, using the real built
# Drift.app binary rather than a test double.
#
# It seeds a custom status into Drift's own preferences domain, relaunches the app, and
# confirms the app resolves and publishes it; then it seeds an already-expired status and
# confirms the app publishes the fallback instead. Finally it loads the built .saver and
# confirms it reads what the app wrote.
#
set -euo pipefail
cd "$(dirname "$0")/.."

STATUS_FILE="$HOME/Library/Application Support/Drift/status.json"
DOMAIN="co.drift.app"
FAILED=0

check() {
  local label="$1" expected="$2"
  local actual
  actual=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['display']['text'])" "$STATUS_FILE" 2>/dev/null || echo "<unreadable>")
  if [ "$actual" = "$expected" ]; then
    echo "  PASS  $label — published \"$actual\""
  else
    echo "  FAIL  $label — expected \"$expected\", got \"$actual\""
    FAILED=1
  fi
}

seed_status() {
  # $1 = seconds until expiry, or "never"
  local hex
  hex=$(python3 - "$1" <<'PY'
import sys, json, datetime, binascii
offset = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
status = {
    "text": "Out for lunch",
    "emoji": "\U0001F35C",
    "source": "custom",
    "updatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if offset != "never":
    exp = now + datetime.timedelta(seconds=int(offset))
    status["expiresAt"] = exp.strftime("%Y-%m-%dT%H:%M:%SZ")
print(binascii.hexlify(json.dumps(status).encode()).decode())
PY
)
  defaults write "$DOMAIN" "drift.customStatus" -data "$hex"
  defaults write "$DOMAIN" "drift.source" -string "custom"
}

restart_drift() {
  killall Drift 2>/dev/null || true
  rm -f "$STATUS_FILE"
  # cfprefsd caches the domain; the app must not read a stale copy.
  killall cfprefsd 2>/dev/null || true
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
}

echo "==> 1. A live custom status is published"
seed_status 3600
restart_drift
check "live status" "Out for lunch"

echo "==> 2. An already-expired status is never published"
seed_status -60
restart_drift
check "expired status" "Away from desk"

echo "==> 3. A status with no expiry is published"
seed_status never
restart_drift
check "no-expiry status" "Out for lunch"

echo "==> 4. The built .saver reads what the app published"
if [ -d build/Drift.saver ] && [ -x build/saver-loadtest ]; then
  if ./build/saver-loadtest build/Drift.saver build/preview/e2e | grep -q "ALL CHECKS PASSED"; then
    echo "  PASS  .saver loaded and rendered the published status"
  else
    echo "  FAIL  .saver load test failed"; FAILED=1
  fi
else
  echo "  SKIP  build/Drift.saver or build/saver-loadtest missing"
fi

echo
if [ "$FAILED" = 0 ]; then echo "END-TO-END: ALL CHECKS PASSED"; else echo "END-TO-END: FAILURES ABOVE"; exit 1; fi
