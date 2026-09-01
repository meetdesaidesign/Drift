#!/bin/bash
# Builds and runs the calendar-account probe (see tools/list-calendars.swift).
#
# Answers one question: which calendar accounts can EventKit see on this Mac, and is a
# Google account among them? This cannot be checked from a shell directly — TCC blocks
# ~/Library/Calendars and ~/Library/Accounts — so it takes a real EventKit client.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

# A command-line binary has no bundle, so the usage string is linked into the Mach-O
# __TEXT,__info_plist section instead. Without it the Calendars request has no purpose
# string to show.
PLIST="build/list-calendars-Info.plist"
cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>co.drift.tools.list-calendars</string>
	<key>CFBundleName</key>
	<string>Drift calendar probe</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>Lists which calendar accounts are on this Mac, to check whether Drift can see your Google calendar.</string>
	<key>NSCalendarsUsageDescription</key>
	<string>Lists which calendar accounts are on this Mac, to check whether Drift can see your Google calendar.</string>
</dict>
</plist>
PLIST

swiftc -target arm64-apple-macos15.0 -swift-version 6 -Onone \
  -parse-as-library \
  -framework Foundation -framework EventKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" \
  -o build/list-calendars \
  tools/list-calendars.swift

# Ad-hoc sign so TCC has a stable identity to remember the grant against; otherwise every
# rebuild looks like a different binary and re-prompts.
codesign --force --sign - build/list-calendars 2>/dev/null || true

exec ./build/list-calendars
