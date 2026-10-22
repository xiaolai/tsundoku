#!/bin/bash
# Publishes the generated cask to the Homebrew tap.
#
#   ./scripts/publish-cask.sh [--dry-run]
#
# Run ./scripts/release.sh first: it builds, notarizes and writes
# build/release/tsundoku.rb. The GitHub release the cask points at must
# already exist; this script refuses a cask whose asset URL is not HTTP 200
# or whose sha256 does not match the local DMG. The tap checkout comes from
# TSUNDOKU_TAP_DIR or `brew --repository xiaolai/tap`; it must be clean.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

dry=no
case "${1:-}" in
    --dry-run) dry=yes ;;
    "") ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

fail() { echo "publish-cask: $*" >&2; exit 1; }
say() { echo "$*"; }

version=$(tr -d '[:space:]' < "$root/VERSION")
owner=${REPO_OWNER:-xiaolai}
dmg="$root/build/release/Tsundoku-$version.dmg"
cask="$root/build/release/tsundoku.rb"

[ -f "$dmg" ] || fail "no $dmg; run ./scripts/release.sh first"
[ -f "$cask" ] || fail "no generated cask; run ./scripts/release.sh first"
ruby -c "$cask" >/dev/null || fail "the generated cask is not valid Ruby"

sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
grep -q "$sha" "$cask" || fail "the cask does not carry the DMG's sha256"
url="https://github.com/$owner/tsundoku/releases/download/v$version/Tsundoku-$version.dmg"
code=$(curl -fsSIL -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || fail "the release asset is not reachable: $url"
[ "$code" = "200" ] || fail "the release asset returned HTTP $code: $url"

tap=${TSUNDOKU_TAP_DIR:-}
if [ -z "$tap" ]; then
    tap=$(brew --repository xiaolai/tap 2>/dev/null) || true
fi
[ -n "$tap" ] && [ -d "$tap/Casks" ] || fail "no tap checkout; set TSUNDOKU_TAP_DIR"
[ -z "$(git -C "$tap" status --porcelain)" ] || fail "the tap checkout has uncommitted changes: $tap"

say "version: $version"
say "sha256:  $sha"
say "tap:     $tap"

if [ "$dry" = yes ]; then
    say "dry run: nothing was committed"
    exit 0
fi

git -C "$tap" pull --ff-only --quiet
existing=no
[ -f "$tap/Casks/tsundoku.rb" ] && existing=yes
cp "$cask" "$tap/Casks/tsundoku.rb"
if git -C "$tap" diff --quiet -- Casks/tsundoku.rb; then
    say "the tap already carries tsundoku $version"
    exit 0
fi
git -C "$tap" add Casks/tsundoku.rb
if [ "$existing" = yes ]; then
    subject="Update tsundoku to $version"
else
    subject="Add tsundoku $version"
fi
git -C "$tap" commit -m "$subject"
git -C "$tap" push
say "published: $subject"
