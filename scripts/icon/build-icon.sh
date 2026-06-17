#!/usr/bin/env bash
# Regenerate the VectorLabel app icons + menu-bar glyph from scripts/icon/glyph.py.
#
# Writes:
#   MacApp/Sources/Core/AppIcon.icns        – L monogram, the Finder/Dock icon for
#                                             Engine / Auto Print / Template Designer
#   MacApp/Sources/Core/AppIconCustom.icns  – CL monogram, the Custom Designer icon
#   MacApp/Sources/Core/MenuBarIcon.png     – menu-bar template glyph (isTemplate at runtime)
# Both .icns use CFBundleIconFile=AppIcon; package-suite.sh copies the right one
# into each app as Contents/Resources/AppIcon.icns.
# Commit those, then run scripts/package-suite.sh to bundle them into the .apps.
#
# Requires macOS (qlmanage, sips, iconutil — all built in) and Python Pillow
# (pip3 install pillow).
set -euo pipefail
cd "$(dirname "$0")/../.."          # repo root
HERE=scripts/icon
SRC=MacApp/Sources/Core          # icons live in the VectorLabelCore resource bundle
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

command -v qlmanage >/dev/null || { echo "qlmanage not found — this script is macOS-only." >&2; exit 1; }
command -v iconutil  >/dev/null || { echo "iconutil not found — this script is macOS-only." >&2; exit 1; }
python3 -c "import PIL" 2>/dev/null || { echo "Pillow missing — run: pip3 install pillow" >&2; exit 1; }

# SVG -> PNG at <size> via QuickLook (full-bleed art, so no QL drop-shadow).
render() {
  local svg="$1" out="$2" size="$3"
  qlmanage -t -s "$size" -o "$BUILD" "$svg" >/dev/null 2>&1
  mv "$BUILD/$(basename "$svg").png" "$out"
}

# build_app_icon  VARIANT(L|CL)  OUT.icns  TAG
# Emit the squircle app icon for the given monogram variant into an .icns.
build_app_icon() {
  local variant="$1" out="$2" tag="$3"
  echo "→ App icon ($tag, $variant monogram)"
  python3 "$HERE/glyph.py" svg-app "$BUILD/$tag.svg" "$variant"
  render "$BUILD/$tag.svg" "$BUILD/${tag}_raw.png" 1024
  python3 "$HERE/glyph.py" mask "$BUILD/${tag}_raw.png" "$BUILD/${tag}_master.png" 1024

  local iconset="$BUILD/$tag.iconset"; rm -rf "$iconset"; mkdir -p "$iconset"
  for pair in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
              128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
              512:icon_512x512 1024:icon_512x512@2x; do
    local px="${pair%%:*}" name="${pair##*:}"
    sips -z "$px" "$px" "$BUILD/${tag}_master.png" --out "$iconset/$name.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$out"
  echo "  wrote $out"
}

build_app_icon L  "$SRC/AppIcon.icns"       app
build_app_icon CL "$SRC/AppIconCustom.icns" appcustom

echo "→ Menu-bar glyph"
python3 "$HERE/glyph.py" svg-menu "$BUILD/menu.svg"
render "$BUILD/menu.svg" "$BUILD/menu_raw.png" 1024
python3 "$HERE/glyph.py" menu "$BUILD/menu_raw.png" "$SRC/MenuBarIcon.png"
echo "  wrote $SRC/MenuBarIcon.png"

echo "Done. Run scripts/package-suite.sh (or scripts/install.sh) to pick up the new icons."
