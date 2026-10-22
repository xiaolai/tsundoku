#!/bin/bash
#
# Regenerate the app icon artifacts from Resources/IconSources.
#
#   ./scripts/build-icons.sh
#   ICON_OUTPUT_DIR=/tmp/icons-out ./scripts/build-icons.sh   # staleness check
#   ICON_PREVIEW_DIR=/tmp/icons-preview ./scripts/build-icons.sh
#       also keeps every rendered appearance and the generated .icon bundle
#       for design review; the compiler still verifies them first.
#
# Writes (atomically, only after every check passes):
#   <out>/AppIcon.icns   legacy macOS icon, 16 through 1024, light appearance
#   <out>/Assets.car     compiled macOS 26+ layered icon, light/dark/tinted
#
# Ordinary builds do NOT run this. scripts/build-app.sh consumes the committed
# artifacts; this script is for when the design sources change. It needs
# Xcode 26+ (actool, Icon Composer's ictool), a macOS session (WebKit), and
# nothing else — no third-party dependency.
#
# Composition, measured from the delivered package:
#
#   macOS 15  IconSources/macos15/tsundoku-light-{1024,small}.svg
#             The tile is already inset at 824/1024 with its own drop shadow,
#             which is what a legacy .icns must carry. `small` (thicker stroke,
#             no glint) is used at 16 and 32 only. Dark cannot be carried:
#             an .icns has no appearance slot, and actool silently drops
#             `luminosity: dark` for the macOS idiom (verified on Xcode 27.1 —
#             it compiles with exit 0 and emits "has 10 unassigned children").
#
#   macOS 26+ IconSources/macos26/{lenses,glint}-light.svg, recoloured white
#             The background is a manifest fill (#f2f2f3 / #1c1b19), not a
#             layer. Layers are white-on-alpha PNGs because a layer fill
#             applied to a stroke-only SVG fills the enclosed area under
#             design generation 26 — the rings become solid discs. Rasterising
#             to PNG fixes it and changes the generation-27 render by 0.08/255.
#             The glint group sits above the lenses group (groups[0] is top).
#
#   tray      IconSources/tray/*.svg — delivered but NOT wired: the app has no
#             NSStatusItem, so copying it into the bundle would be dead weight.
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/Resources/IconSources"
OUT_DIR="${ICON_OUTPUT_DIR:-$REPO/Resources}"
PREVIEW_DIR="${ICON_PREVIEW_DIR:-}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tsundoku-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

die() { echo "build-icons: $*" >&2; exit 1; }

[ -d "$SRC" ] || die "missing source directory $SRC"
mkdir -p "$OUT_DIR"
[ -z "$PREVIEW_DIR" ] || mkdir -p "$PREVIEW_DIR"

# --- toolchain --------------------------------------------------------------

ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for alt in \
    "/Applications/Icon Composer.app/Contents/Executables/ictool" \
    "/Applications/Xcode-beta.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"; do
    [ -x "$ICTOOL" ] || ICTOOL="$alt"
done
[ -x "$ICTOOL" ] || die "Icon Composer's ictool not found. Install Xcode 26 or Icon Composer."
# /usr/bin/ictool and `xcrun ictool` are the actool family. Refuse them.
"$ICTOOL" --version 2>/dev/null | grep -q 'short-bundle-version' \
    || die "$ICTOOL is not the Icon Composer CLI (it answered like actool)."

xcrun --find actool >/dev/null 2>&1 || die "actool not found. Install Xcode 26 or newer."
xcrun --find swiftc >/dev/null 2>&1 || die "swiftc not found. Install Xcode."

xcrun swiftc -O "$REPO/scripts/icon-tools/IconTools.swift" -o "$WORK/IconTools"
TOOLS="$WORK/IconTools"

echo "build-icons: tools ok ($("$ICTOOL" --version | tr -d '\n ' | sed 's/.*short-bundle-version"://;s/[^0-9.]//g'))"

# --- macOS 15: legacy .icns -------------------------------------------------
#
# The .iconset names follow the standard slot names so the mapping into
# icns-write stays readable. iconutil is not used: icns-write checks every
# payload's pixel width against the slot it is placed in.

SMALL="$SRC/macos15/tsundoku-light-small.svg"
FULL="$SRC/macos15/tsundoku-light-1024.svg"
[ -f "$SMALL" ] || die "missing $SMALL"
[ -f "$FULL" ] || die "missing $FULL"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# emit <source.svg> <pixels> <member-name> <min-opaque>
emit() {
    local src=$1 px=$2 name=$3 floor=$4
    "$TOOLS" render "$src" "$ICONSET/$name" "$px" >/dev/null
    "$TOOLS" inspect "$ICONSET/$name" --min-opaque "$floor" \
        --min-bbox-frac 0.70 --max-bbox-frac 0.86 >/dev/null \
        || die "size check failed for $name"
    echo "  $name ($px px)"
}

echo "build-icons: rendering legacy ladder"
emit "$SMALL" 16   icon_16x16.png       70
emit "$SMALL" 32   icon_16x16@2x.png    320
emit "$SMALL" 32   icon_32x32.png       320
emit "$FULL"  64   icon_32x32@2x.png    1200
emit "$FULL"  128  icon_128x128.png     5000
emit "$FULL"  256  icon_128x128@2x.png  20000
emit "$FULL"  256  icon_256x256.png     20000
emit "$FULL"  512  icon_256x256@2x.png  80000
emit "$FULL"  512  icon_512x512.png     80000
emit "$FULL"  1024 icon_512x512@2x.png  320000

# Write the container ourselves rather than through iconutil. iconutil
# downconverts the 16 and 32 slots to the legacy RLE types, which carry only a
# one-bit mask: measured against these renders it moved the 16 slot by 17.6/255
# and the 32 slot by 11.4/255, with visibly square tile corners. PNG members
# are valid for every size.
"$TOOLS" icns-write "$WORK/AppIcon.icns" \
    "$ICONSET/icon_16x16.png" \
    "$ICONSET/icon_16x16@2x.png" \
    "$ICONSET/icon_32x32.png" \
    "$ICONSET/icon_32x32@2x.png" \
    "$ICONSET/icon_128x128.png" \
    "$ICONSET/icon_128x128@2x.png" \
    "$ICONSET/icon_256x256.png" \
    "$ICONSET/icon_256x256@2x.png" \
    "$ICONSET/icon_512x512.png" \
    "$ICONSET/icon_512x512@2x.png" \
    || die "icns-write failed"
# Parse the container itself. `iconutil -c iconset` corrupts the legacy small
# members on the way out, so it must never be used to verify pixels.
"$TOOLS" icns-info "$WORK/AppIcon.icns" | sed 's/^/  /' \
    || die "AppIcon.icns failed container checks"
# The payloads must decode back to the artwork we put in. Extract the 16 and 32
# members verbatim: ImageIO's thumbnail path resamples the largest image and
# never selects them, so a pixel check through it would prove nothing.
for pair in "icp4 16" "icp5 32"; do
    set -- $pair
    "$TOOLS" icns-extract "$WORK/AppIcon.icns" "$1" "$WORK/slot-$2.png" >/dev/null \
        || die "cannot extract $1"
    "$TOOLS" compare "$WORK/slot-$2.png" "$ICONSET/icon_${2}x${2}.png" 0.0 0 \
        || die "$1 does not carry the 16/32 source render"
done
# And the container as a whole must decode.
"$TOOLS" icns-render "$WORK/AppIcon.icns" "$WORK/primary.png" 1024 >/dev/null \
    || die "ImageIO cannot decode AppIcon.icns"
"$TOOLS" compare "$WORK/primary.png" "$ICONSET/icon_512x512@2x.png" 0.5 0 \
    || die "the primary image does not match the 1024 render"
echo "build-icons: AppIcon.icns $(stat -f%z "$WORK/AppIcon.icns") bytes"

# --- macOS 26+: layered .icon -> Assets.car ---------------------------------
#
# The manifest tints white-on-alpha layers through fill-specializations. The
# source SVGs carry colour, so recolour every stroke to white before
# rasterising; the colour lives in the manifest, not the pixels.

echo "build-icons: building layered icon"
ICON="$WORK/AppIcon.icon"
mkdir -p "$ICON/Assets"

white_layer() { # white_layer <source.svg> <output.png>
    local src=$1 png=$2 white="$WORK/$(basename "$1")"
    grep -q 'stroke="#' "$src" || die "$src has no stroke colour to neutralise"
    sed -E 's/stroke="#[0-9A-Fa-f]{6}"/stroke="#FFFFFF"/g' "$src" > "$white"
    local leftover
    leftover="$(grep -Eo 'stroke="#[0-9A-Fa-f]{6}"' "$white" | grep -v '#FFFFFF' || true)"
    [ -z "$leftover" ] || die "$src still has non-white strokes: $leftover"
    "$TOOLS" render "$white" "$png" 1024 >/dev/null
    "$TOOLS" inspect "$png" --min-opaque 1000 >/dev/null \
        || die "layer $png is empty"
    echo "  $(basename "$png") $(stat -f%z "$png") bytes"
}

white_layer "$SRC/macos26/lenses-light.svg" "$ICON/Assets/lenses.png"
white_layer "$SRC/macos26/glint-light.svg"  "$ICON/Assets/glint.png"

# Colours come from the package's own SVGs, not from values retyped here, so
# the manifest cannot drift from the artwork it describes.
BG_LIGHT="$("$TOOLS" srgb "$SRC/macos26/background-light.svg" --fill)"
BG_DARK="$("$TOOLS" srgb "$SRC/macos26/background-dark.svg" --fill)"
LENS_LIGHT="$("$TOOLS" srgb "$SRC/macos26/lenses-light.svg" --stroke)"
LENS_DARK="$("$TOOLS" srgb "$SRC/macos26/lenses-dark.svg" --stroke)"
GLINT_LIGHT="$("$TOOLS" srgb "$SRC/macos26/glint-light.svg" --stroke)"
GLINT_DARK="$("$TOOLS" srgb "$SRC/macos26/glint-dark.svg" --stroke)"
for colour in "$BG_LIGHT" "$BG_DARK" "$LENS_LIGHT" "$LENS_DARK" "$GLINT_LIGHT" "$GLINT_DARK"; do
    case "$colour" in srgb:*) ;; *) die "colour extraction failed: $colour" ;; esac
done

cat > "$ICON/icon.json" <<JSON
{
  "supported-platforms": { "squares": "shared" },
  "fill-specializations": [
    { "value": { "solid": "$BG_LIGHT" } },
    { "appearance": "dark", "value": { "solid": "$BG_DARK" } }
  ],
  "groups": [
    {
      "name": "glint",
      "specular": false,
      "shadow": { "kind": "none", "opacity": 0.5 },
      "translucency": { "enabled": false, "value": 0.5 },
      "lighting": "individual",
      "layers": [
        {
          "image-name": "glint.png",
          "name": "glint",
          "glass": false,
          "fill-specializations": [
            { "value": { "solid": "$GLINT_LIGHT" } },
            { "appearance": "dark", "value": { "solid": "$GLINT_DARK" } },
            { "appearance": "tinted", "value": { "solid": "srgb:1.00000,1.00000,1.00000,1.00000" } }
          ]
        }
      ]
    },
    {
      "name": "lenses",
      "specular": false,
      "shadow": { "kind": "none", "opacity": 0.5 },
      "translucency": { "enabled": false, "value": 0.5 },
      "lighting": "individual",
      "layers": [
        {
          "image-name": "lenses.png",
          "name": "lenses",
          "glass": false,
          "fill-specializations": [
            { "value": { "solid": "$LENS_LIGHT" } },
            { "appearance": "dark", "value": { "solid": "$LENS_DARK" } },
            { "appearance": "tinted", "value": { "solid": "srgb:1.00000,1.00000,1.00000,1.00000" } }
          ]
        }
      ]
    }
  ]
}
JSON
echo "build-icons: manifest colours $BG_LIGHT / $BG_DARK, $LENS_LIGHT / $LENS_DARK, $GLINT_LIGHT / $GLINT_DARK"

CAR="$WORK/car"
mkdir -p "$CAR"
# actool fails silently: a bad name, a directory without the .icon suffix, or
# an invalid manifest exits 0 and writes nothing. Never trust its exit code;
# assert the catalogue exists.
xcrun actool "$ICON" \
    --compile "$CAR" \
    --output-partial-info-plist "$CAR/partial.plist" \
    --app-icon AppIcon \
    --enable-on-demand-resources NO \
    --development-region en \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --platform macosx \
    --output-format human-readable-text --notices --warnings --errors \
    || die "actool failed"
[ -s "$CAR/Assets.car" ] || die "actool exited 0 but wrote no Assets.car"
# actool also emits a four-member AppIcon.icns (16 and 128 at 1x/2x). Shipping
# it would replace the full legacy ladder with one Retina would upscale.
rm -f "$CAR/AppIcon.icns"
echo "build-icons: Assets.car $(stat -f%z "$CAR/Assets.car") bytes"

CAR_INFO="$(xcrun assetutil --info "$CAR/Assets.car")"
for needle in '"AssetType" : "IconImageStack"' 'NSAppearanceNameDarkAqua' 'NSAppearanceNameAqua' '"Name" : "AppIcon"'; do
    grep -qF "$needle" <<<"$CAR_INFO" || die "Assets.car is missing $needle"
done

# --- render every appearance and look at the pixels -------------------------
#
# A compiled catalogue proves nothing about what the system draws; the tile
# does not exist until the renderer makes it. Check both generations: 27 is
# what macOS 27 shows, 26 is what a back-deployed macOS 26 shows. Coordinates
# are (x,y) in the 1024 canvas: 176,512 sits on the left lens stroke, 512,512
# on the background.

echo "build-icons: rendering appearances"
render_rendition() { # <rendition> <generation> -> $WORK/<rendition>-gen<gen>.png
    local rendition=$1 generation=$2
    local out="$WORK/${rendition}-gen${generation}.png"
    "$ICTOOL" "$ICON" --export-image --output-file "$out" \
        --platform macOS --rendition "$rendition" \
        --width 1024 --height 1024 --scale 1 \
        --design-generation "$generation" >/dev/null \
        || die "ictool failed for $rendition generation $generation"
    [ -s "$out" ] || die "ictool wrote no image for $rendition generation $generation"
    if [ -n "$PREVIEW_DIR" ]; then
        cp "$out" "$PREVIEW_DIR/${rendition}-gen${generation}.png"
    fi
    printf '%s' "$out"
}

check_light() { # <rendition> <generation>
    local out; out="$(render_rendition "$1" "$2")"
    "$TOOLS" inspect "$out" --darker 176,512,80 --lighter 512,512,180 >/dev/null \
        || die "$1 generation $2: dark mark on a light field not found"
    echo "  $1 gen$2: mark dark, field light — ok"
}
check_dark() { # <rendition> <generation>
    local out; out="$(render_rendition "$1" "$2")"
    "$TOOLS" inspect "$out" --lighter 176,512,180 --darker 512,512,80 >/dev/null \
        || die "$1 generation $2: light mark on a dark field not found"
    echo "  $1 gen$2: mark light, field dark — ok"
}
check_tinted() { # <rendition> <generation>
    local out; out="$(render_rendition "$1" "$2")"
    "$TOOLS" inspect "$out" --differ 176,512,512,512,30 >/dev/null \
        || die "$1 generation $2: mark does not separate from the field"
    echo "  $1 gen$2: mark separable from field — ok"
}

check_light Default 27
check_dark  Dark    27
check_light Default 26
check_dark  Dark    26
check_tinted TintedLight 27
check_tinted TintedDark  27
check_tinted ClearLight  27
check_tinted ClearDark   27

# --- install ----------------------------------------------------------------

if [ -n "$PREVIEW_DIR" ]; then
    rm -rf "$PREVIEW_DIR/AppIcon.icon"
    cp -R "$ICON" "$PREVIEW_DIR/AppIcon.icon"
    echo "build-icons: previews in $PREVIEW_DIR"
fi

cp "$WORK/AppIcon.icns" "$OUT_DIR/AppIcon.icns"
cp "$CAR/Assets.car" "$OUT_DIR/Assets.car"
echo "build-icons: wrote"
echo "  $OUT_DIR/AppIcon.icns  ($(stat -f%z "$OUT_DIR/AppIcon.icns") bytes)"
echo "  $OUT_DIR/Assets.car    ($(stat -f%z "$OUT_DIR/Assets.car") bytes)"
