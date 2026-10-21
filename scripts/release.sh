#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to a Developer ID Application identity}"
if [ "$CODESIGN_IDENTITY" = "-" ] && [ "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]; then
    echo "Refusing an ad-hoc release. Set ALLOW_ADHOC_RELEASE=1 for a local test build." >&2
    exit 1
fi

OUT="$PWD/build/release"
APP="$OUT/Kindling.app"
rm -rf "$OUT"
mkdir -p "$OUT"

KINDLING_APP_PATH="$APP" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
    ./scripts/build-app.sh

if [ "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]; then
    : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool Keychain profile}"
    ditto -c -k --keepParent "$APP" "$OUT/Kindling.zip"
    xcrun notarytool submit "$OUT/Kindling.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl -a -vvv -t exec "$APP"
fi

STAGING="$(mktemp -d)"
ditto "$APP" "$STAGING/Kindling.app"
ln -s /Applications "$STAGING/Applications"
DMG="$OUT/Kindling-$VERSION.dmg"
hdiutil create -quiet -volname "Kindling $VERSION" -srcfolder "$STAGING" \
    -format UDZO "$DMG"
rm -rf "$STAGING"

if [ "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -vvv -t open --context context:primary-signature "$DMG"
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
sed -e "s|@VERSION@|$VERSION|g" -e "s|@SHA256@|$SHA|g" \
    scripts/distribution/kindling.rb.in > "$OUT/kindling.rb"
echo "DMG: $DMG"
echo "SHA256: $SHA"
echo "Cask: $OUT/kindling.rb"
