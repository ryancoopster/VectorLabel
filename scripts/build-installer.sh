#!/usr/bin/env bash
# Build a guided macOS installer (.pkg) for the VectorLabel suite.
#
# Produces dist/VectorLabel-Installer-<version>.pkg — a standard Installer.app wizard
# (Welcome ▸ License ▸ Install ▸ Done) that installs the four apps into
# /Applications/VectorLabel/ and OPTIONALLY a set of starter label templates into the
# user's ~/Documents/VectorLabel/Templates. The license screen must be accepted to proceed.
#
# Reads the already-built suite from dist/VectorLabel/ (so an outer pipeline can build +
# notarize the apps first); if it isn't there, this builds it via scripts/package-suite.sh.
# The installer .pkg is signed when DEVELOPER_ID_INSTALLER_IDENTITY is set (a "Developer ID
# Installer" cert — distinct from the "Developer ID Application" cert that signs the apps);
# otherwise an unsigned package is produced for local testing. Notarization of the .pkg is
# done by the release workflow (or manually with notarytool) after this runs.
#
# Usage:
#   scripts/build-installer.sh
#   DEVELOPER_ID_INSTALLER_IDENTITY="Developer ID Installer: Name (TEAMID)" scripts/build-installer.sh
#   TEMPLATES_SRC=/path/to/templates scripts/build-installer.sh   # override which templates ship
#   VARIANT=beta scripts/build-installer.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Variant parity with package-suite.sh: beta gets a distinct subfolder / bundle-id infix.
SUFFIX=""; NAMESUFFIX=""; SUBDIR="VectorLabel"
if [ "${VARIANT:-}" = "beta" ]; then SUFFIX=".beta"; NAMESUFFIX="-Beta"; SUBDIR="VectorLabel Beta"; fi

APPSRC="dist/$SUBDIR"
if ! ls "$APPSRC"/*.app >/dev/null 2>&1; then
  echo "→ No built suite in '$APPSRC' — building it (scripts/package-suite.sh)…"
  scripts/package-suite.sh
fi

VERSION=$(tr -d '[:space:]' < VERSION)
PKGID_APPS="com.sai.vectorlabel${SUFFIX}.suite"
PKGID_TPL="com.sai.vectorlabel${SUFFIX}.templates"
INSTALL_DIR="/Applications/$SUBDIR"
TEMPLATES_SRC="${TEMPLATES_SRC:-$HOME/Documents/VectorLabel/Templates}"
INST="scripts/installer"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── Apps component: the four apps → /Applications/VectorLabel, non-relocatable so they
#    always land there (not redirected to a stray older copy Spotlight finds). ditto keeps
#    each already-signed bundle's signature, symlinks and stapled ticket intact.
APPS_ROOT="$WORK/apps"; mkdir -p "$APPS_ROOT$INSTALL_DIR"
for app in "$APPSRC"/*.app; do ditto "$app" "$APPS_ROOT$INSTALL_DIR/$(basename "$app")"; done
APPCOMP="$WORK/apps-component.plist"
pkgbuild --analyze --root "$APPS_ROOT" "$APPCOMP" >/dev/null
i=0; while /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$APPCOMP" 2>/dev/null; do i=$((i+1)); done
echo "  marked $i bundle(s) non-relocatable"
chmod +x "$INST/scripts-apps/postinstall"
pkgbuild --root "$APPS_ROOT" --component-plist "$APPCOMP" --identifier "$PKGID_APPS" \
  --version "$VERSION" --install-location / --scripts "$INST/scripts-apps" \
  "$WORK/VectorLabel-apps.pkg"

# ── Templates component (optional choice): the current templates, copied into the user's
#    Documents by its postinstall. Always built so the choice exists, even if empty.
TPL_ROOT="$WORK/tpl"
TPL_STAGE="$TPL_ROOT/Library/Application Support/VectorLabel/SampleTemplates"; mkdir -p "$TPL_STAGE"
TPL_COUNT=0
if [ -d "$TEMPLATES_SRC" ]; then
  while IFS= read -r -d '' f; do cp -X "$f" "$TPL_STAGE/"; TPL_COUNT=$((TPL_COUNT+1)); done \
    < <(find "$TEMPLATES_SRC" -maxdepth 1 -name '*.vltmp' -print0)
fi
echo "  staged $TPL_COUNT template(s) from $TEMPLATES_SRC"
chmod +x "$INST/scripts-templates/postinstall"
pkgbuild --root "$TPL_ROOT" --identifier "$PKGID_TPL" --version "$VERSION" \
  --install-location / --scripts "$INST/scripts-templates" "$WORK/VectorLabel-templates.pkg"

# ── Vectorworks plug-ins component (optional choice): the .vsm bundles, copied into each
#    installed Vectorworks version's user Plug-ins folder by its postinstall (no-op if VW
#    isn't installed). Always built so the choice exists.
PKGID_VW="com.sai.vectorlabel${SUFFIX}.vwplugins"
VW_ROOT="$WORK/vw"
VW_STAGE="$VW_ROOT/Library/Application Support/VectorLabel/VectorworksPlugins"; mkdir -p "$VW_STAGE"
VW_COUNT=0
while IFS= read -r -d '' f; do cp -X "$f" "$VW_STAGE/"; VW_COUNT=$((VW_COUNT+1)); done \
  < <(find VectorworksPlugin -maxdepth 1 -name '*.vsm' -print0)
echo "  staged $VW_COUNT Vectorworks plug-in(s)"
chmod +x "$INST/scripts-vwplugins/postinstall"
pkgbuild --root "$VW_ROOT" --identifier "$PKGID_VW" --version "$VERSION" \
  --install-location / --scripts "$INST/scripts-vwplugins" "$WORK/VectorLabel-vwplugins.pkg"

# ── Installer resources (welcome / license / conclusion). The license pane is the real
#    LICENSE file, rendered as plain text; accepting it is required to continue.
RES="$WORK/resources"; mkdir -p "$RES"
cp "$INST/welcome.html" "$INST/conclusion.html" "$RES/"
cp LICENSE "$RES/LICENSE.txt"

# ── Distribution: the wizard + the two choices (apps required, templates optional).
DISTXML="$WORK/distribution.xml"
cat > "$DISTXML" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>VectorLabel${NAMESUFFIX}</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <license file="LICENSE.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="allow" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <volume-check>
        <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="apps"/>
        <line choice="templates"/>
        <line choice="vwplugins"/>
    </choices-outline>
    <choice id="apps" title="VectorLabel apps" enabled="false" selected="true"
            description="The four VectorLabel apps, installed to ${INSTALL_DIR}.">
        <pkg-ref id="$PKGID_APPS"/>
    </choice>
    <choice id="templates" title="Sample label templates" selected="true"
            description="Install starter label templates into your Documents/VectorLabel/Templates folder. Templates you already have (same filename) are never overwritten.">
        <pkg-ref id="$PKGID_TPL"/>
    </choice>
    <choice id="vwplugins" title="Vectorworks ConnectCAD plug-ins" selected="true"
            description="Install the two ConnectCAD 'Export … Circuits to VectorLabel' commands into Vectorworks. Skipped automatically if Vectorworks isn't installed. One-time step afterward: add the commands to your workspace via Tools ▸ Workspaces ▸ Edit Current Workspace.">
        <pkg-ref id="$PKGID_VW"/>
    </choice>
    <pkg-ref id="$PKGID_APPS" version="$VERSION">VectorLabel-apps.pkg</pkg-ref>
    <pkg-ref id="$PKGID_TPL" version="$VERSION">VectorLabel-templates.pkg</pkg-ref>
    <pkg-ref id="$PKGID_VW" version="$VERSION">VectorLabel-vwplugins.pkg</pkg-ref>
</installer-gui-script>
XML

UNSIGNED="$WORK/installer-unsigned.pkg"
productbuild --distribution "$DISTXML" --resources "$RES" --package-path "$WORK" "$UNSIGNED"

mkdir -p dist
OUT="dist/VectorLabel-Installer${NAMESUFFIX}-${VERSION}.pkg"
if [ -n "${DEVELOPER_ID_INSTALLER_IDENTITY:-}" ]; then
  productsign --timestamp --sign "$DEVELOPER_ID_INSTALLER_IDENTITY" "$UNSIGNED" "$OUT"
  pkgutil --check-signature "$OUT" | sed 's/^/  /'
else
  cp "$UNSIGNED" "$OUT"
  echo "  (unsigned — set DEVELOPER_ID_INSTALLER_IDENTITY to produce a distributable installer)"
fi

echo "Built $OUT  (v$VERSION, $TPL_COUNT template(s))"
