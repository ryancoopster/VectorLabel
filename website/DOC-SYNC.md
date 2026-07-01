# Keeping the support docs in sync with the software

The marketing site **and** the support docs in `website/` describe how the shipping
software behaves. When you change behavior, **update the matching doc in the same PR**
so the docs never drift from reality.

- **Live site:** https://ryancoopster.github.io/VectorLabel/ (auto-deploys from `website/`
  on every push — see [`.github/workflows/pages.yml`](../.github/workflows/pages.yml)).
- **Source of truth for the docs is the HTML in `website/`.** Edit it directly — there is
  no build step or CMS. (`guide.html` and `faq.html` were originally scaffolded from a
  source-grounded research pass, but they are now hand-maintained like any other file.)
- To **see what the published docs currently say**, fetch the live HTML, e.g.
  `https://ryancoopster.github.io/VectorLabel/guide.html`, or read the file in `website/`.

## The rule (for humans and for Claude Code sessions)

> If a change alters **observable behavior, UI labels, file locations, supported
> printers/supplies, the formula language, barcode support, the Vectorworks export, or
> install/setup**, find the affected page below and update it in the same change. If a
> behavior is added or removed, add/remove the matching section or FAQ entry. Then bump
> the "Docs synced to commit" line in the page footers to the new commit.

Small wording fixes: edit the HTML. Larger structural changes: still edit the HTML
directly (keep the existing component classes from `support.css`).

## Map: software area → source of truth → doc to update

| Software area | Key source (non-exhaustive) | Update this doc |
|---|---|---|
| Install, the 4 apps, menu bar, settings, folder layout | `README.md`, `Package.swift`, `MacApp/Sources/Engine/*`, `MacApp/Sources/Core/AppSettings.swift`, `MacApp/Sources/Core/AppEnvironment.swift`, `.github/workflows/release.yml` | `guide.html` → **Getting started** (`#ch-setup`); `quickstart.html` §1; FAQ "Getting started & the app" |
| Vectorworks export plug-ins & auto-detect | `VectorworksPlugin/export_selected.py`, `VectorworksPlugin/export_all.py`, `MacApp/Sources/AutoPrint/*`, `MacApp/Sources/Core/ExportWatcher.swift` | `guide.html` → **Vectorworks integration** (`#ch-vectorworks`); `quickstart.html` §2 (Path A); FAQ "Vectorworks" |
| Designers, canvas, objects, import | `MacApp/Sources/Core/VectorLabelDesigner.html`, `MacApp/Sources/UI/DesignerWindowController.swift`, `MacApp/Sources/Core/LabelTemplate.swift`, `MacApp/Sources/Core/BradyBWTImporter.swift`, `MacApp/Sources/Core/BrotherLBXImporter.swift` | `guide.html` → **Designing labels** (`#ch-designers`); `quickstart.html` §3 (Path B); FAQ "Designing labels" |
| Data binding, formulas, barcodes | `MacApp/Sources/Core/FormulaEngine.swift`, `MacApp/Sources/Core/BarcodeRenderer.swift`, `MacApp/Sources/Core/LabelTemplate.swift` | `guide.html` → **Data, formulas & barcodes** (`#ch-databind`); FAQ "Data & formulas" / "Barcodes" |
| Print window, printers, supplies, calibration | `MacApp/Sources/Core/VectorLabelPrint.html`, `MacApp/Sources/UI/PrintWindowController.swift`, `MacApp/Sources/PrinterM610/*`, `MacApp/Sources/PrinterM611/*`, `MacApp/Sources/PrinterBrother/*`, `MacApp/Sources/Core/SupplyCatalog*.swift`, `MacApp/Sources/Engine/*Editor.swift`, `docs/PTOUCH-DRIVER-STATUS.md` | `guide.html` → **Printing & printers** (`#ch-printing`); FAQ "Printing" / "Printers & connection" / "Supplies"; **also** the marketing **`index.html`** printers/features/specs sections |
| Errors, limitations, alpha status | all of the above + `docs/*` | `guide.html` → **Fixing common problems** (`#ch-troubleshooting`); `faq.html` (esp. "Troubleshooting & alpha") |

## Files in `website/`

| File | What it is | Edit by hand? |
|---|---|---|
| `index.html` | Marketing landing page (self-contained, standalone HTML5) | Yes |
| `support.html` | Support hub (links the three docs) | Yes |
| `quickstart.html` | Quick start guide | Yes |
| `guide.html` | Full user guide (sidebar TOC, 6 chapters) | Yes |
| `faq.html` | Searchable FAQ (75 Q&As, 10 groups) | Yes |
| `support.css` | Shared stylesheet for the four support pages | Yes |
| `serve.js` | Local dev preview server (not published) | — |

> **Embedding:** the support pages link `support.css` relatively, so embed them on
> Squarespace via an **iframe** to the live URL (not by pasting raw HTML into a Code Block).
> See [`README.md`](README.md).

## Known doc gaps / things to confirm against hardware

Re-check before claiming these as fully working — they are not hardware-confirmed yet:
Brady **M610 cut** behavior and **all Brother P-touch** drivers. (The Brady **M611** IS
hardware-validated.) Keep the docs honest about alpha status until verified.
