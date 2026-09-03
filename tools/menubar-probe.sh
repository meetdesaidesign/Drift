#!/bin/bash
#
# Asks the real Drift.app where its menu-bar item landed and whether its popover opens.
#
# This exists because neither question can be answered from outside the process on this
# Mac: `screencapture` needs Screen Recording permission and `log show` needs Full Disk
# Access, so an invisible status item leaves nothing to read. An unbundled harness is no
# substitute — a status item outside an app bundle never gets a real slot, and reports
# a window at the origin and a popover that will not open.
#
# Drift quits itself after reporting.
#
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d build/Drift.app ] || { echo "error: build/Drift.app not found — run ./build.sh" >&2; exit 1; }

DRIFT_PROBE=1 build/Drift.app/Contents/MacOS/Drift
