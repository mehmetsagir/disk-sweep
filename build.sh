#!/bin/zsh
# Builds a release binary and wraps it into build/DiskSweep.app.
# Signing: ad-hoc by default. Set SIGN_IDENTITY to a Developer ID Application identity
# (name or SHA-1) to sign with the hardened runtime and a secure timestamp.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/DiskSweep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiskSweep "$APP/Contents/MacOS/DiskSweep"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Support/Localization/*.lproj "$APP/Contents/Resources/"

IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi

echo "Built: $PWD/$APP"
