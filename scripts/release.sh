#!/bin/bash
# Explicit phases; --help and plan never build, publish or read credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/release_pipeline.py "$@"
