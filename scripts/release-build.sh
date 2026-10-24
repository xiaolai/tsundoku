#!/bin/bash
# Compatibility entrypoint for the build phase. Nothing is published.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/release_pipeline.py build "$@"
