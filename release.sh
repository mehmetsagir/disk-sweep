#!/bin/zsh
# Builds a Developer ID signed DiskSweep.app and packages it as dist/DiskSweep-<version>.dmg.
# When notarization credentials are available, the app and the DMG are notarized by Apple
# and stapled, so Gatekeeper opens them without any warning.
#
# Signing
#   SIGN_IDENTITY   Developer ID Application identity (default: first one in the keychain)
#
# Notarization (optional, first match wins)
#   NOTARY_PROFILE  a profile saved with `xcrun notarytool store-credentials`
#   NOTARY_ENV_FILE path to an env file defining APPLE_API_KEY (.p8 path), APPLE_API_KEY_ID and
#                   optionally APPLE_API_ISSUER; or APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD +
#                   APPLE_TEAM_ID. The file is parsed, never executed, and only APPLE_* keys are read.
#   (or export those APPLE_* variables directly)
set -euo pipefail
cd "$(dirname "$0")"

# ---- credentials -------------------------------------------------------------------------
if [[ -n "${NOTARY_ENV_FILE:-}" ]]; then
    [[ -r "$NOTARY_ENV_FILE" ]] || { echo "Cannot read NOTARY_ENV_FILE: $NOTARY_ENV_FILE" >&2; exit 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#export }"
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; value="${line#*=}"
        value="${value#[\"\']}"; value="${value%[\"\']}"
        case "$key" in
            APPLE_API_KEY|APPLE_API_KEY_ID|APPLE_API_ISSUER|APPLE_ID|APPLE_APP_SPECIFIC_PASSWORD|APPLE_TEAM_ID)
                export "$key=${value/#\~/$HOME}" ;;
        esac
    done < "$NOTARY_ENV_FILE"
fi

typeset -a NOTARY_AUTH
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_ID:-}" ]]; then
    NOTARY_AUTH=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID")
    [[ -n "${APPLE_API_ISSUER:-}" ]] && NOTARY_AUTH+=(--issuer "$APPLE_API_ISSUER")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "@env:APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi

notarize() {   # notarize <file>   (fails unless Apple reports "Accepted")
    local output
    output="$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait 2>&1)" || true
    echo "$output" | rg "id:|status:" | head -4
    echo "$output" | rg -q "status: Accepted" || { echo "$output" | tail -15 >&2; echo "Notarization failed for $1" >&2; exit 1; }
}

# ---- signed build -------------------------------------------------------------------------
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' identity found in the keychain." >&2; exit 1; }

SIGN_IDENTITY="$IDENTITY" ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
APP="build/DiskSweep.app"
DMG="dist/DiskSweep-$VERSION.dmg"
WORK="$(mktemp -d)"

# ---- notarize + staple the app first, so it also passes Gatekeeper offline ------------------
if (( ${#NOTARY_AUTH} )); then
    echo "Notarizing the app..."
    ditto -c -k --keepParent "$APP" "$WORK/DiskSweep.zip"
    notarize "$WORK/DiskSweep.zip"
    xcrun stapler staple "$APP" >/dev/null
fi

# ---- DMG ----------------------------------------------------------------------------------
mkdir -p dist
rm -f "$DMG"
STAGE="$WORK/stage"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Support/AppIcon.icns "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true
hdiutil create -volname "DiskSweep" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --verbose=2 "$DMG"

if (( ${#NOTARY_AUTH} )); then
    echo "Notarizing the DMG..."
    notarize "$DMG"
    xcrun stapler staple "$DMG" >/dev/null
    xcrun stapler validate "$DMG"
    spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | head -2
else
    echo "Note: not notarized (no credentials). Other Macs will ask for 'Open Anyway' on first launch."
fi

rm -rf "$WORK"
echo "Built: $PWD/$DMG"
