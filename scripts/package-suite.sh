#!/usr/bin/env bash
# Build the VectorLabel app suite from the SPM release build:
#   Engine (menu-bar, owns the printer) + Auto Print + Template Designer +
#   Custom Designer. Each becomes a self-contained .app with a per-app Info.plist
#   (bundle id, name, LSUIElement, icon). libusb is bundled into the Engine ONLY.
#   Ad-hoc signed, or Developer ID if SIGN_IDENTITY is set.
#
# Usage:
#   scripts/package-suite.sh                 # production suite -> dist/VectorLabel/
#   VARIANT=beta scripts/package-suite.sh    # beta suite -> "dist/VectorLabel Beta/"
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package-suite.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
PB=/usr/libexec/PlistBuddy
ENT="Resources/VectorLabel.entitlements"
BASE_PLIST="Info.plist"

./scripts/stamp-version.sh
swift build -c "$CONFIG"
BINDIR=".build/$CONFIG"

VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)

# Variant: production vs beta — distinct bundle ids (.beta.*), name suffix, and
# install subfolder, so a beta suite coexists with production (and the legacy
# single app) without collision. The ".beta." infix matches AppEnvironment.isBeta.
SUFFIX=""; NAMESUFFIX=""; SUBDIR="VectorLabel"
if [ "${VARIANT:-}" = "beta" ]; then SUFFIX=".beta"; NAMESUFFIX=" (Beta)"; SUBDIR="VectorLabel Beta"; fi
DISTDIR="dist/$SUBDIR"
rm -rf "$DISTDIR"; mkdir -p "$DISTDIR"

# package_one  EXE_NAME  BUNDLE_ID  DISPLAY_NAME  LSUIELEMENT(true|false)  LINK_LIBUSB(0|1)
package_one() {
  local EXE="$1" ID="$2" NAME="$3" LSUI="$4" LIBUSB="$5"
  local APP="$DISTDIR/$EXE.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

  cp "$BASE_PLIST" "$APP/Contents/Info.plist"
  "$PB" -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
  "$PB" -c "Set :CFBundleName $EXE" "$APP/Contents/Info.plist"
  "$PB" -c "Add :CFBundleDisplayName string $NAME" "$APP/Contents/Info.plist" 2>/dev/null \
    || "$PB" -c "Set :CFBundleDisplayName $NAME" "$APP/Contents/Info.plist"
  "$PB" -c "Set :CFBundleExecutable $EXE" "$APP/Contents/Info.plist"
  "$PB" -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  "$PB" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
  "$PB" -c "Add :VLGitCommit string $COMMIT" "$APP/Contents/Info.plist" 2>/dev/null \
    || "$PB" -c "Set :VLGitCommit $COMMIT" "$APP/Contents/Info.plist"
  if [ "$LSUI" = "true" ]; then
    "$PB" -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" 2>/dev/null \
      || "$PB" -c "Set :LSUIElement true" "$APP/Contents/Info.plist"
  else
    "$PB" -c "Delete :LSUIElement" "$APP/Contents/Info.plist" 2>/dev/null || true
  fi

  cp "$BINDIR/$EXE" "$APP/Contents/MacOS/$EXE"
  for b in "$BINDIR"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
  [ -f MacApp/Sources/Core/AppIcon.icns ] && cp MacApp/Sources/Core/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

  local DYLIB_PATH=""
  if [ "$LIBUSB" = "1" ]; then
    local SRC LNAME
    SRC=$(otool -L "$BINDIR/$EXE" | awk '/libusb-1\.0.*dylib/{print $1; exit}')
    if [ -n "${SRC:-}" ] && [ -f "$SRC" ]; then
      LNAME=$(basename "$SRC")
      cp "$SRC" "$APP/Contents/Frameworks/$LNAME"; chmod u+w "$APP/Contents/Frameworks/$LNAME"
      install_name_tool -id "@rpath/$LNAME" "$APP/Contents/Frameworks/$LNAME"
      install_name_tool -change "$SRC" "@rpath/$LNAME" "$APP/Contents/MacOS/$EXE"
      install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$EXE" 2>/dev/null || true
      DYLIB_PATH="$APP/Contents/Frameworks/$LNAME"
    else
      echo "WARNING: libusb not found for $EXE — the Engine may not run without Homebrew libusb." >&2
    fi
  fi

  # Re-sign (install_name_tool invalidated the signature; Apple Silicon requires it).
  if [ -n "${SIGN_IDENTITY:-}" ]; then
    [ -n "$DYLIB_PATH" ] && codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DYLIB_PATH"
    codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict "$APP"
  else
    [ -n "$DYLIB_PATH" ] && codesign --force --sign - "$DYLIB_PATH"
    codesign --force --sign - "$APP"
  fi
  echo "  built $APP  ($ID)"
}

echo "Packaging VectorLabel suite -> $DISTDIR  (v$VERSION build $BUILD ${COMMIT})"
package_one VectorLabelEngine           "com.sai.vectorlabel${SUFFIX}.engine"           "VectorLabel Engine${NAMESUFFIX}"            true  1
package_one VectorLabelAutoPrint        "com.sai.vectorlabel${SUFFIX}.autoprint"        "VectorLabel Auto Print${NAMESUFFIX}"        true  0
package_one VectorLabelTemplateDesigner "com.sai.vectorlabel${SUFFIX}.templatedesigner" "VectorLabel Template Designer${NAMESUFFIX}" false 0
package_one VectorLabelCustomDesigner   "com.sai.vectorlabel${SUFFIX}.customdesigner"   "VectorLabel Custom Designer${NAMESUFFIX}"   false 0
echo "Done — $DISTDIR ($([ -n "${SIGN_IDENTITY:-}" ] && echo 'Developer ID' || echo 'ad-hoc') signed)."
