#!/usr/bin/env bash
# Build the VectorLabel app suite and install it for local testing. Installs the
# four apps into /Applications/<SubDir>/ (production → "VectorLabel"; VARIANT=beta
# → "VectorLabel Beta"), leaving any legacy /Applications/VectorLabel.app untouched.
# Relaunches the always-on apps (Engine + Auto Print); the designers launch on
# demand from the Engine menu or by opening a document.
#
#   scripts/install.sh             # pull main, build suite, install, relaunch
#   scripts/install.sh --no-pull   # skip the git pull
#   VARIANT=beta scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

[ "${1:-}" = "--no-pull" ] || { echo "→ Pulling latest main…"; git pull --ff-only; }

echo "→ Building + packaging the suite (unsigned)…"
scripts/package-suite.sh >/dev/null

SUBDIR="VectorLabel"; [ "${VARIANT:-}" = "beta" ] && SUBDIR="VectorLabel Beta"
SRCDIR="dist/$SUBDIR"
APPS=(VectorLabelEngine VectorLabelAutoPrint VectorLabelTemplateDesigner VectorLabelCustomDesigner)

echo "→ Stopping any running suite apps…"
for x in "${APPS[@]}"; do pkill -f "$SUBDIR/$x.app/Contents/MacOS/$x" 2>/dev/null || true; done
sleep 1

DESTROOT="/Applications"; [ -w "$DESTROOT" ] || DESTROOT="$HOME/Applications"
DEST="$DESTROOT/$SUBDIR"
mkdir -p "$DEST"
for x in "${APPS[@]}"; do rm -rf "$DEST/$x.app"; cp -R "$SRCDIR/$x.app" "$DEST/$x.app"; done
touch "$DEST/VectorLabelEngine.app"   # nudge Finder's icon cache

# Register the designers with Launch Services so the .vltmp / .vlcus document
# associations (declared in their Info.plists) take effect immediately — a
# double-click in Finder opens the right designer without a logout/reboot.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  echo "→ Registering document types with Launch Services…"
  "$LSREGISTER" -f "$DEST/VectorLabelTemplateDesigner.app" "$DEST/VectorLabelCustomDesigner.app" || true
fi

echo "→ Launching Engine + Auto Print…"
open "$DEST/VectorLabelEngine.app"
open "$DEST/VectorLabelAutoPrint.app"

PB=/usr/libexec/PlistBuddy
VER=$("$PB" -c "Print :CFBundleShortVersionString" "$DEST/VectorLabelEngine.app/Contents/Info.plist")
BUILD=$("$PB" -c "Print :CFBundleVersion" "$DEST/VectorLabelEngine.app/Contents/Info.plist")
echo "✓ Installed suite → $DEST  (v$VER build $BUILD)"
echo "  Engine + Auto Print are running; open the designers from the Engine menu or:"
echo "    open \"$DEST/VectorLabelTemplateDesigner.app\"   /   \"$DEST/VectorLabelCustomDesigner.app\""
echo "  NB: only one Engine can own the USB printer — quit the legacy VectorLabel.app while testing this suite."
