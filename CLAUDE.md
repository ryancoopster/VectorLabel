# VectorLabel — notes for Claude Code

VectorLabel is a macOS app suite for designing and printing wire/cable/asset labels on
thermal printers (Brady M610/M611, Brother P-touch), with a Vectorworks ConnectCAD
integration. It is in **open alpha**. The suite is four apps (Engine, AutoPrint, Template
Designer, Custom Designer) plus the `VectorworksPlugin/` Python commands. See `README.md`.

## ⚠️ Keep the public docs in sync with the software

The repo ships a marketing site **and** a full support section (quick start, user guide,
FAQ) under `website/`, hosted on GitHub Pages and auto-deployed on every push to `website/`.
**These docs describe how the shipping software behaves, so they go stale the moment you
change behavior and forget to update them.**

**Rule:** when a change alters observable behavior, UI labels, file locations, supported
printers/supplies, the formula language, barcode support, the Vectorworks export, or
install/setup, **update the matching doc in `website/` in the same change.**

- The mapping of *software area → source files → which doc to edit* lives in
  **[`website/DOC-SYNC.md`](website/DOC-SYNC.md)** — read it before/after touching behavior.
- The docs' source of truth is the **HTML in `website/`** (`guide.html`, `faq.html`,
  `quickstart.html`, `support.html`, shared `support.css`). Edit it directly — no build step.
- To check what's currently published, read the file in `website/` or fetch the live HTML
  (e.g. `https://ryancoopster.github.io/VectorLabel/guide.html`).
- Keep the docs **honest about alpha status** (e.g. Brother drivers and Brady M610 cut are
  not hardware-verified). Don't upgrade "pending verification" to "works" without evidence.

Quick checklist after a behavior change:
1. Find the area in `website/DOC-SYNC.md`.
2. Update the matching `guide.html` section (and `quickstart.html` / `faq.html` / `index.html`
   if affected).
3. Bump the "Docs synced to commit …" line in the page footers.
4. Push — GitHub Pages redeploys automatically.
