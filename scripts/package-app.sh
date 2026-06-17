#!/usr/bin/env bash
# Build a distributable VectorLabel.app from the SPM release build:
#   - assembles the .app bundle (executable + Info.plist + resource bundle)
#   - bundles libusb and rewrites its load path to be self-contained
#   - stamps the version into Info.plist
#   - optionally code-signs with a Developer ID identity (set SIGN_IDENTITY)
#
# Usage:
#   scripts/package-app.sh                         # unsigned .app in dist/
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
APPNAME=VectorLabel
DIST=dist
APP="$DIST/$APPNAME.app"

./scripts/stamp-version.sh
swift build -c "$CONFIG"

BINDIR=".build/$CONFIG"
EXE="$BINDIR/$APPNAME"
RESBUNDLE="$BINDIR/${APPNAME}_${APPNAME}.bundle"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Info.plist with the stamped version/build/commit.
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
cp Info.plist "$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
"$PB" -c "Add :VLGitCommit string $COMMIT" "$APP/Contents/Info.plist" 2>/dev/null \
  || "$PB" -c "Set :VLGitCommit $COMMIT" "$APP/Contents/Info.plist"

# Executable + SPM resource bundle (the two HTML UIs).
cp "$EXE" "$APP/Contents/MacOS/$APPNAME"
[ -d "$RESBUNDLE" ] && cp -R "$RESBUNDLE" "$APP/Contents/Resources/"

# Bundle libusb and make the executable load it from inside the .app.
LIBUSB_SRC=$(otool -L "$EXE" | awk '/libusb-1\.0.*dylib/{print $1; exit}')
LIBUSB_NAME=""
if [ -n "${LIBUSB_SRC:-}" ] && [ -f "$LIBUSB_SRC" ]; then
  LIBUSB_NAME=$(basename "$LIBUSB_SRC")
  cp "$LIBUSB_SRC" "$APP/Contents/Frameworks/$LIBUSB_NAME"
  chmod u+w "$APP/Contents/Frameworks/$LIBUSB_NAME"
  install_name_tool -id "@rpath/$LIBUSB_NAME" "$APP/Contents/Frameworks/$LIBUSB_NAME"
  install_name_tool -change "$LIBUSB_SRC" "@rpath/$LIBUSB_NAME" "$APP/Contents/MacOS/$APPNAME"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APPNAME" 2>/dev/null || true
else
  echo "WARNING: could not locate the linked libusb dylib; the .app may not run on machines without Homebrew libusb." >&2
fi

echo "Built $APP (unsigned) — v$VERSION build $BUILD"

# ── Code signing ────────────────────────────────────────────────────────────────
# install_name_tool above invalidated the binaries' signatures, and Apple Silicon
# refuses to run an invalidly-signed Mach-O — so we MUST re-sign here. Nested
# Mach-O (the dylib) is signed first, then the app. With a Developer ID identity we
# use hardened runtime + secure timestamp + entitlements (required for notarization);
# without one we ad-hoc sign so the local bundle at least runs (not distributable).
DYLIB_PATH=""
[ -n "$LIBUSB_NAME" ] && DYLIB_PATH="$APP/Contents/Frameworks/$LIBUSB_NAME"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  ENT="Resources/VectorLabel.entitlements"
  [ -n "$DYLIB_PATH" ] && codesign --force --options runtime --timestamp \
      --sign "$SIGN_IDENTITY" "$DYLIB_PATH"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENT" --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "Signed with Developer ID: $SIGN_IDENTITY  (ready to notarize — see docs/SIGNING.md)"
else
  [ -n "$DYLIB_PATH" ] && codesign --force --sign - "$DYLIB_PATH"
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (runs locally, NOT distributable). Set SIGN_IDENTITY for a"
  echo "Developer ID build, then notarize — see docs/SIGNING.md."
fi
