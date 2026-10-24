#!/bin/bash
# Explicitly publish the independently verified release cask.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/release_pipeline.py cask "$@"
