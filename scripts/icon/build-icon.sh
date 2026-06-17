#!/usr/bin/env bash
# Regenerate the VectorLabel app icon + menu-bar glyph from scripts/icon/glyph.py.
#
# Writes:
#   MacApp/Sources/AppIcon.icns     – Finder/Dock icon (CFBundleIconFile=AppIcon)
#   MacApp/Sources/MenuBarIcon.png  – menu-bar template glyph (isTemplate at runtime)
# Commit those, then run scripts/package-app.sh to bundle them into the .app.
#
# Requires macOS (qlmanage, sips, iconutil — all built in) and Python Pillow
# (pip3 install pillow).
set -euo pipefail
cd "$(dirname "$0")/../.."          # repo root
HERE=scripts/icon
SRC=MacApp/Sources
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

echo "→ App icon"
python3 "$HERE/glyph.py" svg-app "$BUILD/app.svg"
render "$BUILD/app.svg" "$BUILD/app_raw.png" 1024
python3 "$HERE/glyph.py" mask "$BUILD/app_raw.png" "$BUILD/master.png" 1024

ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
for pair in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
            512:icon_512x512 1024:icon_512x512@2x; do
  px="${pair%%:*}"; name="${pair##*:}"
  sips -z "$px" "$px" "$BUILD/master.png" --out "$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$SRC/AppIcon.icns"
echo "  wrote $SRC/AppIcon.icns"

echo "→ Menu-bar glyph"
python3 "$HERE/glyph.py" svg-menu "$BUILD/menu.svg"
render "$BUILD/menu.svg" "$BUILD/menu_raw.png" 1024
python3 "$HERE/glyph.py" menu "$BUILD/menu_raw.png" "$SRC/MenuBarIcon.png"
echo "  wrote $SRC/MenuBarIcon.png"

echo "Done. Run scripts/package-app.sh (or scripts/install.sh) to pick up the new icon."
