#!/bin/zsh
# Builds a release binary and wraps it into build/DiskSweep.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/DiskSweep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiskSweep "$APP/Contents/MacOS/DiskSweep"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built: $PWD/$APP"
