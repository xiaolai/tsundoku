#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/signing-identity.sh
security() { printf '%s\n' "$IDENTITIES"; }
unset CODESIGN_IDENTITY
IDENTITIES='  1) ABC123 "Developer ID Application: Example (TEAM)"'
[ "$(tsundoku_signing_identity)" = ABC123 ]
IDENTITIES='  1) DEF456 "Apple Development: Example (TEAM)"'
[ "$(tsundoku_signing_identity 2>/dev/null)" = '-' ]
IDENTITIES=$'  1) ABC123 "Developer ID Application: First (TEAM)"\n  2) DEF456 "Developer ID Application: Second (TEAM)"'
if tsundoku_signing_identity >/dev/null 2>&1; then
    echo 'FAIL: ambiguous identity accepted' >&2
    exit 1
fi
CODESIGN_IDENTITY='explicit identity'
[ "$(tsundoku_signing_identity)" = 'explicit identity' ]
CODESIGN_IDENTITY='-'
[ "$(tsundoku_signing_identity)" = '-' ]
CODESIGN_IDENTITY=''
IDENTITIES=''
[ "$(tsundoku_signing_identity 2>/dev/null)" = '-' ]
echo 'PASS: six signing identity selection cases'
