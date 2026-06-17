#!/usr/bin/env bash
# Sync the locally-installed VectorLabel.app to the latest committed build:
#   pull main → stamp version → build release → bundle libusb → ad-hoc sign →
#   install to /Applications → relaunch.
#
# This is the unsigned local-test path. A *distributable* signed build is produced
# by the GitHub release workflow on a version tag (see docs/SIGNING.md).
#
#   scripts/install.sh            # pull + rebuild + install + relaunch
#   scripts/install.sh --no-pull  # rebuild current checkout (skip git pull)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != "--no-pull" ]; then
  echo "→ Pulling latest main…"
  git pull --ff-only
fi

echo "→ Building + packaging (unsigned)…"
./scripts/package-app.sh >/dev/null

echo "→ Installing…"
pkill -f 'VectorLabel.app/Contents/MacOS/VectorLabel' 2>/dev/null || true
sleep 1
DEST=/Applications/VectorLabel.app
if ! ( rm -rf "$DEST" 2>/dev/null && cp -R dist/VectorLabel.app /Applications/ 2>/dev/null ); then
  mkdir -p "$HOME/Applications"; DEST="$HOME/Applications/VectorLabel.app"
  rm -rf "$DEST"; cp -R dist/VectorLabel.app "$HOME/Applications/"
fi
open "$DEST"

PB=/usr/libexec/PlistBuddy
VER=$("$PB" -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist")
BUILD=$("$PB" -c "Print :CFBundleVersion" "$DEST/Contents/Info.plist")
SHA=$("$PB" -c "Print :VLGitCommit" "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")
echo "✓ Running $DEST  —  v$VER (build $BUILD · $SHA)"
