#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
SDK_VERSION="$(xcrun --show-sdk-version)"
MIN_VERSION="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
# SwiftPM links with the deployment target as both minos and sdk, which makes
# macOS treat the app as a legacy build. Record the real SDK so the system
# applies the current appearance while the minimum stays at macOS 15.
swift build -c release --product Kindling \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker "$MIN_VERSION" -Xlinker "$SDK_VERSION"
BIN="$(swift build -c release --show-bin-path)"
APP="${KINDLING_APP_PATH:-$PWD/build/Kindling.app}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Kindling" "$APP/Contents/MacOS/Kindling"

# Icon artifacts are generated from Resources/IconSources by
# scripts/build-icons.sh and committed. An ordinary build must not need Xcode's
# actool or a WebKit session, so it only copies them — and fails loudly if they
# are missing, rather than shipping whatever tile the system invents.
for asset in Resources/AppIcon.icns Resources/Assets.car; do
    if [ ! -s "$asset" ]; then
        echo "missing $asset — run ./scripts/build-icons.sh" >&2
        exit 1
    fi
done
if [ "$(head -c 8 Resources/Assets.car)" != "BOMStore" ]; then
    echo "Resources/Assets.car is not an asset catalogue — rerun ./scripts/build-icons.sh" >&2
    exit 1
fi
cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Kindling</string>
<key>CFBundleDisplayName</key><string>Kindling</string>
<key>CFBundleIdentifier</key><string>com.example.kindling</string>
<key>CFBundleExecutable</key><string>Kindling</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.reference</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

SIGN_ID="${CODESIGN_IDENTITY:--}"
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict --deep "$APP"
echo "Built $APP"
