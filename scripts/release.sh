#!/bin/bash
# Releases Tsundoku for macOS: provisions the notarization keychain profile
# from the workspace .env, then builds, signs, notarizes and staples.
#
#   ./scripts/release.sh [--profile NAME] [--profile-only] [--adhoc]
#
#   --profile NAME   the keychain profile's name (default tsundoku-notary).
#   --profile-only   make the profile and stop, without releasing.
#   --adhoc          skip notarization; build a local ad-hoc DMG and stop.
#
# Why a script: the profile lives in the login keychain and does not survive
# it; the credentials exist only in the workspace .env, which agents never
# read. This runs the same way every time and prints names, never values.
#
# What it reads, in the order each is tried:
#   the Apple ID    APPLE_ID
#   the password    APP_SPECIFIC_PASSWORD, then APPLE_PASSWORD
#   the team        TEAM_ID or APPLE_TEAM_ID if .env carries one, else the
#                   team of this Mac's Developer ID Application certificate
#   the owner       REPO_OWNER or GITHUB_OWNER, for the Homebrew cask URL
#   the identity    CODESIGN_IDENTITY if set, else the first Developer ID
#                   Application certificate on this Mac
# It stores nothing unless all three notary values are known, and it asks
# Apple once (`history`): a profile that cannot be used fails here, not two
# minutes into a release. TSUNDOKU_ENV_FILE names another env file.
#
# The release itself is scripts/release-build.sh: the signed build, the
# notarization and stapling of the app and the disk image, Gatekeeper on
# both, and the Homebrew cask. It publishes nothing: the disk image and its
# sha256 are printed at the end.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

profile=tsundoku-notary
release=yes
adhoc=no
while [ $# -gt 0 ]; do
    case $1 in
        --profile) [ $# -ge 2 ] || { echo "release: --profile needs a name" >&2; exit 2; }
                   profile=$2; shift 2 ;;
        --profile-only) release=no; shift ;;
        --adhoc) adhoc=yes; shift ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) echo "release: usage: $0 [--profile NAME] [--profile-only] [--adhoc]" >&2; exit 2 ;;
    esac
done

fail() { echo "release: $*" >&2; exit 1; }
say() { echo "$*"; }

if [ "$adhoc" = yes ]; then
    say "release: ad-hoc local build (no notarization)"
    cd "$root"
    ALLOW_ADHOC_RELEASE=1 CODESIGN_IDENTITY=- exec ./scripts/release-build.sh
fi

env_file=${TSUNDOKU_ENV_FILE:-$root/../.env}
[ -f "$env_file" ] || fail "no env file at $env_file"

# Sourced with `set +u`, so a line that reads another unset variable does not
# stop the script; the file is the owner's.
set +u
set -a
# shellcheck disable=SC1090 # the path is chosen above, on purpose
. "$env_file"
set +a
set -u

# Names only, never values: what to look at when one is missing below.
names=$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{printf "%s ", $1}' "$env_file")
pick() {
    local key
    for key in "$@"; do
        if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; return 0; fi
    done
    return 1
}

apple_id=$(pick APPLE_ID) || fail "no APPLE_ID in $env_file (its keys: $names)"
password=$(pick APP_SPECIFIC_PASSWORD APPLE_PASSWORD) \
    || fail "no APP_SPECIFIC_PASSWORD (or APPLE_PASSWORD) in $env_file (its keys: $names)"

team=$(pick TEAM_ID APPLE_TEAM_ID) || team=""
if [ -z "$team" ]; then
    # The certificate's subject carries the team in parentheses:
    # "Developer ID Application: Name (TEAMID)".
    team=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*Developer ID Application: .* (\([A-Z0-9]*\)).*/\1/p' | head -1) || true
fi
[ -n "$team" ] || fail "no team id: TEAM_ID is not in $env_file and this Mac has no Developer ID Application certificate"

identity=${CODESIGN_IDENTITY:-}
if [ -z "$identity" ]; then
    identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^ *[0-9]*) [A-F0-9]* "\(Developer ID Application: .*\)"/\1/p' | head -1) || true
fi
[ -n "$identity" ] || fail "no Developer ID Application identity on this Mac; set CODESIGN_IDENTITY"

owner=$(pick REPO_OWNER GITHUB_OWNER) || owner=""

say "profile:  $profile"
say "apple id: ${apple_id%%@*}@… (hidden)"
say "team:     $team"
say "identity: $identity"
say "owner:    ${owner:-(none — the DMG is built without a cask)}"

if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    say "release: $profile already works on this Mac; storing it again with the values in $env_file"
fi

xcrun notarytool store-credentials "$profile" \
    --apple-id "$apple_id" --team-id "$team" --password "$password" >/dev/null

unset apple_id password

xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || fail "stored, but notarytool cannot use '$profile' — Apple refused or the keychain could not keep it"
say "release: $profile ready"

if [ "$release" = no ]; then
    say "release: --profile-only, nothing was released"
    exit 0
fi

say "release: running scripts/release-build.sh"
cd "$root"
CODESIGN_IDENTITY="$identity" NOTARY_PROFILE="$profile" REPO_OWNER="$owner" \
    exec ./scripts/release-build.sh
