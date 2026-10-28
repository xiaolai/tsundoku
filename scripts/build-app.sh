#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
SDK_VERSION="$(xcrun --show-sdk-version)"
MIN_VERSION="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
BUILD_NUMBER="${TSUNDOKU_BUILD_NUMBER:-1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid VERSION' >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build number' >&2; exit 1; }
source scripts/signing-identity.sh
SIGN_ID="$(tsundoku_signing_identity)"
APP="${TSUNDOKU_APP_PATH:-$PWD/build/Tsundoku.app}"

# TSUNDOKU_APP_PATH becomes a recursive delete target below. Refuse anything
# that is not an .app bundle inside this repository or /tmp, and never follow
# a path with a parent traversal.
case "$APP" in
    *.app) ;;
    *)
        echo "build-app: refusing a path that is not an .app bundle: $APP" >&2
        exit 1
        ;;
esac
case "/$APP/" in
    *"/../"*)
        echo "build-app: refusing a path with a parent traversal: $APP" >&2
        exit 1
        ;;
esac
case "$APP" in
    /*) ;;
    *) APP="$PWD/$APP" ;;
esac
# Lexical containment first, so creating the parent cannot escape the roots.
case "$APP" in
    "$PWD"/*|/tmp/*) ;;
    *)
        echo "build-app: refusing an app path outside the repository or /tmp: $APP" >&2
        exit 1
        ;;
esac
# Resolve the destination's parent (creating it if needed) so a symlinked
# ancestor cannot carry the delete outside the permitted roots.
APP_PARENT="$(dirname "$APP")"
mkdir -p "$APP_PARENT"
APP_PARENT="$(cd "$APP_PARENT" && pwd -P)"
APP="$APP_PARENT/$(basename "$APP")"
# macOS resolves /tmp to /private/tmp; compare the canonical roots.
REPO_ROOT="$(cd "$PWD" && pwd -P)"
TMP_ROOT="$(cd /tmp && pwd -P)"
case "$APP" in
    "$REPO_ROOT"/*|"$TMP_ROOT"/*) ;;
    *)
        echo "build-app: refusing an app path outside the repository or /tmp: $APP" >&2
        exit 1
        ;;
esac

# SwiftPM links with the deployment target as both minos and sdk, which makes
# macOS treat the app as a legacy build. Record the real SDK so the system
# applies the current appearance while the minimum stays at macOS 15.
#
# Build products stay outside $PWD and $HOME: the prefix maps also rewrite
# module-cache paths, so a scratch directory under either tree makes the
# compiler warn that every mapped PCM is missing.
SCRATCH="${TMPDIR:-/tmp}/tsundoku-release-build"
swift build -c release --product Tsundoku --scratch-path "$SCRATCH" \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker "$MIN_VERSION" -Xlinker "$SDK_VERSION" \
    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/src/tsundoku" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=/src/tsundoku" \
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/build/user" \
    -Xswiftc -file-prefix-map -Xswiftc "$HOME=/build/user"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

# Assemble into a staging bundle, then replace the destination atomically.
# A failed build leaves the previous app intact.
STAGE="${APP}.stage.$$"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN/Tsundoku" "$STAGE/Contents/MacOS/Tsundoku"
# Keep debug receipts local: linker debug symbols carry absolute object-file paths.
strip -S "$STAGE/Contents/MacOS/Tsundoku"

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
cp Resources/AppIcon.icns Resources/Assets.car "$STAGE/Contents/Resources/"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Tsundoku</string>
<key>CFBundleDisplayName</key><string>Tsundoku</string>
<key>CFBundleIdentifier</key><string>com.lixiaolai.tsundoku</string>
<key>CFBundleExecutable</key><string>Tsundoku</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>${MIN_VERSION}</string>
<key>LSApplicationCategoryType</key><string>public.app-category.reference</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Only the release controller supplies provenance; ordinary builds remain unlabelled.
python3 - "$STAGE/Contents/Info.plist" <<'PYBUILD'
import os, plistlib, re, sys
path = sys.argv[1]
keys = {'TSUNDOKU_SOURCE_COMMIT': 'TsundokuSourceCommit',
        'TSUNDOKU_SOURCE_TREE': 'TsundokuSourceTree',
        'TSUNDOKU_DRIVER_COMMIT': 'TsundokuDriverCommit'}
values = {k: os.environ.get(k, '') for k in keys}
if any(values.values()):
    if not all(re.fullmatch('[a-f0-9]{40}', v) for v in values.values()):
        raise SystemExit('Release provenance must contain three complete Git object IDs.')
    with open(path, 'rb') as stream: info = plistlib.load(stream)
    info.update({keys[k]: v for k, v in values.items()})
    with open(path, 'wb') as stream: plistlib.dump(info, stream)
PYBUILD

# SwiftPM can record the deployment target as the SDK (15.0 / 15.0), which makes
# macOS apply the compatibility appearance. The linker flag above prevents it;
# this assertion makes a regression fail the build instead of a screenshot review.
BUILD_INFO="$(vtool -show-build "$STAGE/Contents/MacOS/Tsundoku")"
BIN_MINOS="$(awk '/minos/{print $2; exit}' <<<"$BUILD_INFO")"
BIN_SDK="$(awk '/sdk/{print $2; exit}' <<<"$BUILD_INFO")"
if [ "$BIN_MINOS" != "$MIN_VERSION" ] || [ "$BIN_SDK" != "$SDK_VERSION" ]; then
    echo "build-app: Tsundoku records minos=$BIN_MINOS sdk=$BIN_SDK;" \
        "expected minos=$MIN_VERSION sdk=$SDK_VERSION" >&2
    echo "build-app: refusing a legacy-appearance build" >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :UIDesignRequiresCompatibility' \
    "$STAGE/Contents/Info.plist" >/dev/null 2>&1
then
    echo "build-app: UIDesignRequiresCompatibility is set; refusing" >&2
    exit 1
fi

if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$STAGE"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$STAGE"
fi
codesign --verify --strict --deep "$STAGE"

# The destination is replaced only after the staged bundle is signed and
# verified. The old bundle is moved aside and restored if the install fails.
BACKUP="${APP}.old.$$"
if [ -e "$APP" ]; then
    mv "$APP" "$BACKUP"
fi
if ! mv "$STAGE" "$APP"; then
    if [ -e "$BACKUP" ]; then
        mv "$BACKUP" "$APP"
    fi
    echo "build-app: could not install $APP; previous bundle restored" >&2
    exit 1
fi
rm -rf "$BACKUP"
trap - EXIT
codesign --verify --strict --deep "$APP"
echo "Built $APP"
