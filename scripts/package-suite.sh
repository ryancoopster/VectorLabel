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

# register_doc_type  PLIST  UTI  EXT  DESCRIPTION
# Add an exported UTI (conforming to public.json + public.data, with the given
# filename extension) and a matching CFBundleDocumentTypes entry (Editor / Owner,
# app-icon document icon) to the given Info.plist. Idempotent per plist (the plist
# is freshly copied from Info.plist in package_one each run).
register_doc_type() {
  local PLIST="$1" UTI="$2" EXT="$3" DESC="$4"

  # --- UTExportedTypeDeclarations (array of one declaration) ---
  "$PB" -c "Add :UTExportedTypeDeclarations array" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0 dict" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0:UTTypeIdentifier string $UTI" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0:UTTypeDescription string $DESC" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0:UTTypeIconFile string AppIcon" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo array" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo:0 string public.json" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo:1 string public.data" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0:UTTypeTagSpecification dict" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension array" "$PLIST"
  "$PB" -c "Add :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0 string $EXT" "$PLIST"

  # --- CFBundleDocumentTypes (array of one type, owning the UTI) ---
  "$PB" -c "Add :CFBundleDocumentTypes array" "$PLIST"
  "$PB" -c "Add :CFBundleDocumentTypes:0 dict" "$PLIST"
  "$PB" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string $DESC" "$PLIST"
  "$PB" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Editor" "$PLIST"
  "$PB" -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string Owner" "$PLIST"
  "$PB" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeIconFile string AppIcon" "$PLIST"
  "$PB" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$PLIST"
  "$PB" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string $UTI" "$PLIST"
}

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
  # Copy ONLY the resource bundles the apps actually use, by explicit name. A
  # glob over *.bundle would also scoop up a stale VectorLabel_VectorLabel.bundle
  # left from the pre-restructure target, which must NOT ship. Core is required;
  # the dependency resource bundles (CoreXLSX / ZIPFoundation) are copied only if
  # they exist for this build.
  for BUNDLE in \
    VectorLabel_VectorLabelCore.bundle \
    CoreXLSX_CoreXLSX.bundle \
    ZIPFoundation_ZIPFoundation.bundle; do
    [ -d "$BINDIR/$BUNDLE" ] && cp -R "$BINDIR/$BUNDLE" "$APP/Contents/Resources/"
  done

  # App icon (Phase 7 / #10): per-app monograms over the shared chevron mark —
  #   Custom Designer   → "CD" label (AppIconCustom.icns)
  #   Template Designer → "TD" label (AppIconTemplate.icns)
  #   Engine / Auto Print → plain "L" mark (AppIcon.icns)
  # All ship as Contents/Resources/AppIcon.icns so CFBundleIconFile stays "AppIcon".
  # Missing variant icons fall back to the L icon so packaging never breaks
  # (regenerate with scripts/icon/build-icon.sh on macOS: Pillow + qlmanage).
  local ICON_SRC=MacApp/Sources/Core/AppIcon.icns
  if [ "$EXE" = "VectorLabelCustomDesigner" ] && [ -f MacApp/Sources/Core/AppIconCustom.icns ]; then
    ICON_SRC=MacApp/Sources/Core/AppIconCustom.icns
  elif [ "$EXE" = "VectorLabelTemplateDesigner" ] && [ -f MacApp/Sources/Core/AppIconTemplate.icns ]; then
    ICON_SRC=MacApp/Sources/Core/AppIconTemplate.icns
  fi
  [ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

  # Custom file types (Phase 4): the two designers OWN one document type each so
  # Finder shows the files and a double-click opens the right app.
  #   Template Designer → ".vltmp"  (com.sai.vectorlabel${SUFFIX}.vltmp)
  #   Custom Designer   → ".vlcus"  (com.sai.vectorlabel${SUFFIX}.vlcus)
  # Both are JSON (conform to public.json + public.data). The doc icon is the
  # owning app's icon (UTTypeIconFile/CFBundleTypeIconFile = "AppIcon"), so the
  # Custom Designer's .vlcus files inherit its CL mark. Registered as an exported
  # UTI plus a CFBundleDocumentTypes entry (Editor role, Owner rank).
  #
  # The $SUFFIX (".beta" for beta, "" for prod) is threaded into the UTI so beta
  # and production export DISTINCT UTIs (com.sai.vectorlabel.beta.vltmp vs
  # com.sai.vectorlabel.vltmp). Without it both variants exported the same UTI and
  # Launch Services would collide them, opening the wrong app on double-click.
  case "$EXE" in
    VectorLabelTemplateDesigner) register_doc_type "$APP/Contents/Info.plist" \
        "com.sai.vectorlabel${SUFFIX}.vltmp" "vltmp" "VectorLabel Template" ;;
    VectorLabelCustomDesigner)   register_doc_type "$APP/Contents/Info.plist" \
        "com.sai.vectorlabel${SUFFIX}.vlcus" "vlcus" "VectorLabel Custom Label" ;;
  esac

  # Problem-report delivery token (never in git): release.yml provides
  # VL_REPORTS_TOKEN from a repo secret; ErrorReporter reads it back as the
  # bundle resource "VLReportingToken". Builds without it ship with reporting
  # unconfigured (the report popup offers Copy Report instead of Send).
  [ -n "${VL_REPORTS_TOKEN:-}" ] && printf '%s' "$VL_REPORTS_TOKEN" > "$APP/Contents/Resources/VLReportingToken"

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
