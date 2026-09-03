#!/bin/bash
#
# Builds Drift.app and Drift.saver.
#
# This uses swiftc directly rather than xcodebuild, because this Mac has Command Line
# Tools only and no Xcode.app — see README.md ("Building"). Shared sources are compiled
# into both bundles rather than packaged as a framework, which keeps the .saver
# self-contained: it has to load inside a sandboxed host, where hunting for an embedded
# framework is one more thing that can go wrong.
#
#   ./build.sh              release build into ./build
#   ./build.sh debug        unoptimised build
#
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
BUILD_DIR="build"
TARGET_TRIPLE="arm64-apple-macos15.0"

case "$CONFIG" in
  release) OPT_FLAGS=(-O) ;;
  debug)   OPT_FLAGS=(-Onone -g) ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

COMMON_FLAGS=(
  -target "$TARGET_TRIPLE"
  -swift-version 6
  "${OPT_FLAGS[@]}"
)

CORE_SOURCES=(Sources/DriftCore/*.swift)
SHARED_SOURCES=(Sources/DriftShared/*.swift)
APP_SOURCES=(Sources/DriftApp/*.swift)
SAVER_SOURCES=(Sources/DriftSaver/*.swift)

APP_BUNDLE="$BUILD_DIR/Drift.app"
SAVER_BUNDLE="$BUILD_DIR/Back Soon.saver"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }

rm -rf "$APP_BUNDLE" "$SAVER_BUNDLE"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------- Drift.app

say "Compiling Drift.app ($CONFIG)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
swiftc "${COMMON_FLAGS[@]}" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework IOKit \
  -o "$APP_BUNDLE/Contents/MacOS/Drift" \
  "${CORE_SOURCES[@]}" "${SHARED_SOURCES[@]}" "${APP_SOURCES[@]}"

cp Sources/DriftApp/Info.plist "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
plutil -lint "$APP_BUNDLE/Contents/Info.plist" > /dev/null

# ------------------------------------------------------------- Back Soon.saver

# Named "Back Soon" rather than "Drift" so it cannot be confused with the screensaver
# macOS ships under that same name in the same list. See Sources/DriftSaver/Info.plist.
say "Compiling Back Soon.saver ($CONFIG)"
mkdir -p "$SAVER_BUNDLE/Contents/MacOS" "$SAVER_BUNDLE/Contents/Resources"
# -emit-library with -Xlinker -bundle produces a true MH_BUNDLE, which is what
# NSBundle/legacyScreenSaver expects to dlopen.
swiftc "${COMMON_FLAGS[@]}" \
  -emit-library -Xlinker -bundle \
  -framework AppKit -framework SwiftUI -framework ScreenSaver \
  -o "$SAVER_BUNDLE/Contents/MacOS/Drift" \
  "${CORE_SOURCES[@]}" "${SHARED_SOURCES[@]}" "${SAVER_SOURCES[@]}"

cp Sources/DriftSaver/Info.plist "$SAVER_BUNDLE/Contents/Info.plist"
printf 'BNDL????' > "$SAVER_BUNDLE/Contents/PkgInfo"
plutil -lint "$SAVER_BUNDLE/Contents/Info.plist" > /dev/null

# ---------------------------------------------------------------- signing

# Ad-hoc signing. There is no Developer ID on this Mac, and none is needed: the
# legacyScreenSaver host carries com.apple.security.cs.disable-library-validation, so it
# will load a .saver that is not signed by a matching team. See FEASIBILITY.md.
say "Ad-hoc signing"
codesign --force --sign - --timestamp=none "$SAVER_BUNDLE"
codesign --force --sign - --timestamp=none "$APP_BUNDLE"
codesign --verify --strict "$SAVER_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"

say "Built:"
echo "    $APP_BUNDLE     ($(file -b "$APP_BUNDLE/Contents/MacOS/Drift" | cut -d, -f1))"
echo "    $SAVER_BUNDLE   ($(file -b "$SAVER_BUNDLE/Contents/MacOS/Drift" | cut -d, -f1))"
echo
echo "Install the screensaver with:  ./install-saver.sh"
