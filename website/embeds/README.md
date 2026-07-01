# website/embeds — live app-HTML previews

The homepage, quick start and user guide don't use hand-drawn mockups of the app.
They embed the **real VectorLabel front-ends** in `<iframe>`s, forced to light mode and
bootstrapped with the current shipping templates, so the marketing site shows exactly
what the software looks like.

## Files

**Committed (edit these):**

| File | What it is |
|------|------------|
| `print.html`     | Wrapper that iframes the real Print window. Params: `tpl=1_5x1_5\|1_5x4`, `view=full\|label\|table`, `anim=1`. |
| `designer.html`  | Wrapper that iframes the real Template Designer. Params: `tpl=…`, `view=full\|canvas`. |
| `vl-demo.js`     | The current templates (`1_5x1_5 V1`, `1_5x4 V1`) the previews load. Mirror of `~/Documents/VectorLabel/Templates/*.vltmp`. |

**Generated — NOT committed (`.gitignore`):**

| File | Source |
|------|--------|
| `print-app.html`    | verbatim copy of `MacApp/Sources/Core/VectorLabelPrint.html` |
| `designer-app.html` | verbatim copy of `MacApp/Sources/Core/VectorLabelDesigner.html` |
| `bwip-js.js`        | verbatim copy of `MacApp/Sources/Core/bwip-js.js` |

## How it stays in sync (no drift)

- **Local preview:** run `scripts/sync-web-embeds.sh` to (re)generate the three copied
  files, then serve `website/`.
- **Production:** `.github/workflows/pages.yml` copies those three files **fresh from
  `MacApp/Sources/Core/` at deploy time**, and the deploy also triggers when any of those
  front-ends changes — so the published previews can never drift from the shipping app.

## If the templates change

The previews load the JSON in `vl-demo.js`. If the shipping default templates
(`1_5x1_5 V1` / `1_5x4 V1`) change, update `vl-demo.js` to match.
