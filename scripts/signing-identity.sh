#!/bin/bash
# Sourced by build-app.sh. Print only the selected identity on stdout.
tsundoku_signing_identity() {
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$CODESIGN_IDENTITY"
        return
    fi
    local identities count
    identities="$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/{print $2}')" || return
    count="$(printf '%s\n' "$identities" | awk 'NF {n++} END {print n+0}')"
    case "$count" in
        1) printf '%s\n' "$identities" ;;
        0)
            echo 'build-app: no Developer ID Application identity; using ad-hoc signing. Existing permissions may not apply after rebuilding. Set CODESIGN_IDENTITY to preserve a stable identity.' >&2
            printf '%s\n' '-' ;;
        *)
            echo 'build-app: multiple Developer ID Application identities; set CODESIGN_IDENTITY explicitly to preserve the intended permission identity.' >&2
            return 1 ;;
    esac
}
