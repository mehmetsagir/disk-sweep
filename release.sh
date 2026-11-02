#!/bin/zsh
# Builds a Developer ID signed DiskSweep.app and packages it as dist/DiskSweep-<version>.dmg.
#
#   SIGN_IDENTITY  Developer ID Application identity (default: the first one in the keychain)
#   NOTARY_PROFILE optional `xcrun notarytool store-credentials` profile; when set, the DMG
#                  is notarized and stapled so Gatekeeper opens it without warnings
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' identity found in the keychain." >&2; exit 1; }

SIGN_IDENTITY="$IDENTITY" ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
APP="build/DiskSweep.app"
DMG="dist/DiskSweep-$VERSION.dmg"
STAGE="$(mktemp -d)"

mkdir -p dist
rm -f "$DMG"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Support/AppIcon.icns "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true
hdiutil create -volname "DiskSweep" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --verbose=2 "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
else
    echo "Note: not notarized (set NOTARY_PROFILE). Other Macs will ask for 'Open Anyway' on first launch."
fi

echo "Built: $PWD/$DMG"
