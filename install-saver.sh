#!/bin/bash
#
# Installs Drift's screensaver into ~/Library/Screen Savers (per-user, no admin rights
# needed). After this, pick "Back Soon" in System Settings > Screen Saver — it appears
# under "Other".
#
# It is called "Back Soon" and not "Drift" because macOS ships its own screensaver called
# Drift, listed in that same section. Two entries called "Drift" cannot be told apart.
#
set -euo pipefail
cd "$(dirname "$0")"

SRC="build/Back Soon.saver"
DEST_DIR="$HOME/Library/Screen Savers"
DEST="$DEST_DIR/Back Soon.saver"

if [ ! -d "$SRC" ]; then
  echo "error: $SRC not found — run ./build.sh first" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

# System Settings caches loaded .saver bundles in the wallpaper agent, so a running
# instance must be cleared out before a rebuilt bundle is picked up.
if pgrep -q legacyScreenSaver; then
  echo "==> Stopping the running screensaver host"
  killall legacyScreenSaver 2>/dev/null || true
fi

# Any earlier install called Drift.saver has to go, or the picker keeps showing a stale
# duplicate next to Apple's Drift.
rm -rf "$DEST" "$DEST_DIR/Drift.saver"
cp -R "$SRC" "$DEST"
echo "==> Installed $DEST"

# The wallpaper agent builds the screensaver list once and holds it, so it needs a nudge
# to notice a newly installed or replaced bundle.
killall WallpaperAgent 2>/dev/null && echo "==> Restarted WallpaperAgent" || true

echo
echo "Now open System Settings > Screen Saver and choose \"Back Soon\" (under \"Other\")."
