#!/bin/bash
# Builds and runs the offscreen UI renderer (see tools/render-ui.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
APP_SOURCES=$(ls Sources/DriftApp/*.swift | grep -v 'DriftAppMain.swift')
swiftc -target arm64-apple-macos15.0 -swift-version 6 -Onone \
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework IOKit \
  -o build/render-ui \
  Sources/DriftCore/*.swift Sources/DriftShared/*.swift $APP_SOURCES tools/render-ui.swift
exec ./build/render-ui "${1:-build/ui}"
