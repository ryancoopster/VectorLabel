#!/usr/bin/env bash
# Stamp the build identity, then build. Use this instead of a bare `swift build`
# so the in-app version (menu footer) always reflects the current commit.
#   scripts/build.sh             → debug build
#   scripts/build.sh -c release  → release build
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/stamp-version.sh
swift build "$@"
