#!/usr/bin/env bash
# Copy the REAL VectorLabel front-ends into website/embeds/ so the marketing site's
# live previews (embeds/print.html, embeds/designer.html) render the ACTUAL app HTML.
#
# These copies are .gitignored — they are regenerated here for local `preview`/serving,
# and re-copied fresh from source at GitHub Pages deploy time (.github/workflows/pages.yml),
# so the published previews can never drift from the shipping front-ends.
#
# Run this whenever you edit VectorLabelPrint.html / VectorLabelDesigner.html / bwip-js.js
# and want to preview the site locally.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="MacApp/Sources/Core"
DST="website/embeds"
mkdir -p "$DST"

cp "$SRC/VectorLabelPrint.html"    "$DST/print-app.html"
cp "$SRC/VectorLabelDesigner.html" "$DST/designer-app.html"
cp "$SRC/bwip-js.js"               "$DST/bwip-js.js"

echo "Synced app front-ends → $DST/"
ls -la "$DST"/print-app.html "$DST"/designer-app.html "$DST"/bwip-js.js
