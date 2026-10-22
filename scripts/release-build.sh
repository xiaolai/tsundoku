#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
: "${REPO_OWNER:=xiaolai}"
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to a Developer ID Application identity}"
if [ "${ALLOW_ADHOC_RELEASE:-0}" != "1" ] && [ -n "${REPO_OWNER:-}" ]; then
    case "$REPO_OWNER" in
        *[!A-Za-z0-9-]*)
            echo "REPO_OWNER must contain only letters, digits and hyphens: $REPO_OWNER" >&2
            exit 1
            ;;
    esac
fi
if [ "$CODESIGN_IDENTITY" = "-" ] && [ "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]; then
    echo "Refusing an ad-hoc release. Set ALLOW_ADHOC_RELEASE=1 for a local test build." >&2
    exit 1
fi

OUT="$PWD/build/release"
APP="$OUT/Tsundoku.app"
rm -rf "$OUT"
mkdir -p "$OUT"

TSUNDOKU_APP_PATH="$APP" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
    ./scripts/build-app.sh

if [ "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]; then
    : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool Keychain profile}"
    ditto -c -k --keepParent "$APP" "$OUT/Tsundoku.zip"
    xcrun notarytool submit "$OUT/Tsundoku.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl -a -vvv -t exec "$APP"
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Tsundoku.app"
ln -s /Applications "$STAGING/Applications"
DMG="$OUT/Tsundoku-$VERSION.dmg"
hdiutil create -quiet -volname "Tsundoku $VERSION" -srcfolder "$STAGING" \
    -format UDZO "$DMG"

if [ "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -vvv -t open --context context:primary-signature "$DMG"
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
if [ "${ALLOW_ADHOC_RELEASE:-0}" = "1" ]; then
    # An ad-hoc build has no release page to point a cask at; an unfilled
    # placeholder must never be written.
    echo "Ad-hoc build: no Homebrew cask generated."
    echo "DMG: $DMG"
    echo "SHA256: $SHA"
    exit 0
fi
sed -e "s|@VERSION@|$VERSION|g" -e "s|@SHA256@|$SHA|g" \
    -e "s|@OWNER@|$REPO_OWNER|g" \
    scripts/distribution/tsundoku.rb.in > "$OUT/tsundoku.rb"
echo "DMG: $DMG"
echo "SHA256: $SHA"
echo "Cask: $OUT/tsundoku.rb"
