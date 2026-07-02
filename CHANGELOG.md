# Changelog

All notable changes to VectorLabel are recorded here. **This file is the single source
of truth for what changed between versions** — every fix and feature lands under
`[Unreleased]` as it's made, and moves under a dated version heading when that version
is released. The website's [Downloads page](https://ryancoopster.github.io/VectorLabel/downloads.html)
is built from these entries so users can see the changes between each release.

The format follows [Keep a Changelog](https://keepachangelog.com/); versions are
`MAJOR.MINOR.PATCH` (in [`/VERSION`](VERSION)). Each build also carries a monotonic build
number (git commit count) + short SHA, shown in the menu-bar footer.

## [Unreleased]

### Changed
- **Updates:** the update-available popup (and the Preferences ▸ Updates summary card)
  now lists the changes between your installed version and the new one — every version
  in between, straight from this changelog — instead of a general app summary. The
  GitHub release page for each version likewise shows that version's changelog section
  instead of boilerplate.

### Fixed
- **Print preview shows only the printable area again.** The print window's label
  preview (and expanded grid) no longer draw the physical label with hatched margins —
  on wrap supplies the dead space crowded out the label content. The hatched-margins
  view stays in the designers, where the physical context matters; the preview's
  "Printable area" row still notes when dimensions come from the loaded cassette.
- **Correct M611 USB id in the printer registry.** The default printer-model list
  recorded the Brady M611's USB product id as 0x010C (an early unverified guess);
  the real, hardware-confirmed id is 0x0013. Fresh installs now seed the correct id,
  and existing installs are migrated automatically (a hand-edited entry that already
  has the real id is left alone). M611 USB detection itself was never affected — the
  USB driver already matched the confirmed id — but the registry entry now agrees
  with the hardware, so per-printer settings resolve by id even for a renamed entry.

## [1.4.1] — 2026-07-02

### Changed
- **No more duplicate tabs.** Opening a file that's already open now switches to its
  existing tab instead of opening a second copy — in the Template Designer (.vltmp,
  whether opened from Finder, the Open… dialog, or the built-in template picker), the
  Custom Designer (.vlcus and not-yet-saved .BWT/.lbx imports), and the print window
  (a new export or a Reprint of a file that's already showing lands on its open tab).
  New/untitled documents and reprint-reopened designs are never deduplicated.
- **One shared suite log.** All four apps now write to a single rolling log file
  (~/Library/Logs/VectorLabel/VectorLabel.log, lines tagged per app) instead of one
  log per app, and error reports attach the combined suite timeline instead of a
  per-app log.

## [1.4.0] — 2026-07-02

### Added
- **Built-in error reporting.** When any of the four apps hits an error — a failed
  print, a file that won't open or save, a download/update failure, or a crash on the
  previous launch — the alert now offers **Report…**, which opens a popup where you can
  describe what happened and send the report privately to the developer (filed as a
  GitHub issue in a private repo). A **Report a Problem…** row in the Engine menu sends
  a report any time. The first report asks for your name, email, and (optionally) phone
  so the developer can follow up, then remembers them. Reports include app/version,
  macOS and hardware info, current printer status, and the app's recent log (each app
  now keeps a rolling log file under ~/Library/Logs/VectorLabel/).
- **Printable-area margins on the canvas.** Both designers and the print window's
  preview now show the label's physical edges with the unprintable margins hatched,
  so you can see exactly where the selected printer can print. In the Custom Designer
  and print window the margins come from the selected live printer (and its loaded
  cassette when it reports a printable area); the Template Designer — which has no
  printer attached — gains a **Printer dropdown** next to the Supply button to pick
  the target model, and the choice is saved with the template. A **Margins** toggle
  next to the grid control hides the overlay. P-touch margins come from the tape-width
  head table (e.g. 12 mm tape prints a centered ~9.9 mm band); Brady margins come
  from the supply catalog and live cassette telemetry.

## [1.3.1] — 2026-07-02

### Fixed
- **All four apps:** the blank "… Settings" window (an empty settings scene macOS 26
  presents when an app launches or activates) is now closed the instant it appears —
  on launch, after the installer relaunches the apps, on Dock/reopen, and around the
  update prompts. The 1.3.0 fix only covered the Engine's update prompts, which is why
  the window still opened on launch; Auto Print had the same stray window.

## [1.3.0] — 2026-07-02

### Changed
- **Updates:** the first-launch "How should VectorLabel check for updates?" prompt now
  defaults to **Every 7 days** (was: on every launch). Every option can still be chosen,
  and changed later in Preferences ▸ Updates.

### Fixed
- **Updates:** an empty "VectorLabel Engine Settings" window could appear when the update
  prompts surfaced (the first-launch question, "update available", "you're up to date",
  and update errors). It no longer does.

## [1.2.0] — 2026-07-01

### Added
- **Table object** in both designers: insert a grid of rows × columns, where every cell
  behaves like its own text box — static text, a data **field** (drag a column header
  onto a cell to bind it), or a **formula**, with full per-cell formatting incl.
  auto-scale. Select cells (shift = range, ⌘ = toggle), format or size many at once,
  copy/paste cells within or between tables, drag row/column lines to resize (with
  "Lock table size" on, drags redistribute inside the table), lock rows/columns to equal
  sizes, and right-click a cell to add/delete rows/columns or type an exact row height /
  column width. Double-click any cell to type into it directly. The first value entered
  into a cell (typed or bound) one-time auto-sizes its font to fit ~10 characters in the
  cell — after that the size is never changed automatically. Tables render identically
  in the designers, the print preview, and the printed output.
- **Auto-update from GitHub releases:** the Engine can now check GitHub for a newer
  VectorLabel — on every launch, every N days, or manually (a one-time prompt on first
  launch asks which; changeable any time in Preferences ▸ **Updates**, the new tab).
  When a newer version is found, a popup shows the release notes with **Update Now**
  (downloads the installer to ~/Downloads with progress, opens it, and quits the suite
  so it can be replaced cleanly), **Remind Me Tomorrow**, and **Don't Update** (skips
  that version only). The menu bar gains a "Check for Updates…" row, and Preferences ▸
  Updates shows the last-checked time plus a "Version X.Y.Z available" summary card —
  even for a skipped/snoozed version.
- **Online-only cloud files download before opening.** Files kept "online-only" by
  Dropbox, iCloud Drive, OneDrive or any similar sync service used to fail or stall when
  opened. Now every file the app opens — CSV/Excel data sources, templates, custom
  labels, Brady/Brother imports, images, supply-catalog imports, Finder double-clicks —
  first shows a small "Downloading …" popup with Cancel while the service fetches the
  file, then continues exactly where you left off. Cancel returns you to where you were.
- **Merged cells** in tables: select multiple cells and right-click → **Merge cells**
  (Excel-style bounding rectangle); right-click a merged cell → **Split cell** — the
  text stays in the top-left cell and every cell keeps the merged cell's formatting.
  Merges print identically in the preview and on the printer.
- **Clear commands** in tables: right-click any cell selection (single or multi) →
  **Clear text** (content only; formatting kept) or **Clear text & formatting**.

### Changed
- **Installer:** on macOS older than 14 (Sonoma) the installer now **warns** that the apps
  may not run correctly and lets you continue, instead of hard-blocking. (The apps target
  macOS 14 on Apple Silicon.)
- **Designers:** the stepper (▲/▼) buttons on numeric inputs in the object settings panel
  are bigger and easier to hit, and pressing ↑/↓ with a numeric input focused now steps
  and applies the value just like clicking the buttons.

### Fixed
- **Tables:** double-clicking a cell now reliably starts editing regardless of how the
  table was selected — and works for every cell type: static cells edit inline, formula
  cells open the formula editor, field cells jump to the column picker. (Editing engages
  by clicking the already-selected cell, so one click on an unselected table now selects
  the cell under the pointer and a second click — at any speed — starts editing.)

## [1.1.0] — 2026-07-01

First public release (open alpha).

### Added
- **The four-app suite:** VectorLabel Engine (menu-bar printing hub), Auto Print (the
  print window), Template Designer, and Custom Designer.
- **Design + print** wire / cable / asset / panel / patch labels on a true-to-size
  canvas — text, barcodes, QR, DataMatrix, images, symbols, lines and shapes.
- **Vectorworks ConnectCAD integration:** two export commands drop circuit data into a
  watch folder; the print window opens automatically with your records loaded.
- **Data binding & formulas:** bind a CSV or Excel (`.xlsx`) file (one label per row);
  spreadsheet-style formulas evaluate identically in preview and print.
- **Tabs everywhere:** the print window and both designers open several labels at once,
  with a `+` for new documents and per-tab live state.
- **Barcodes:** 15 linear + 2-D symbologies, rendered at each printer's native DPI.
- **Import:** open Brady `.BWT` and Brother P-touch `.lbx` templates (auto-converted
  into a new tab).
- **Printers:** Brady M610 & M611 (300 DPI) and Brother P-touch (180 DPI) over USB and
  the network, with live status/telemetry and cassette auto-detection on the M611.
- **Editable supply catalog** (sizes, part numbers, quantities, buy links) and
  **per-printer settings** (cut mode, orientation, calibration, feed-to-clear).
- **Signed + notarized installer** published from CI.

### Changed
- **Auto-scale text never truncates** — with auto-scale on, the font shrinks until the
  whole value fits; it no longer clips to a "…".

### Fixed
- The light / dark / auto **appearance choice relays across the whole suite.** Changing it
  from the Engine menu (or Preferences) immediately switches Auto Print and both designers
  too; an app opened later syncs to the current setting on launch.

### Known limitations (open alpha)
- The Brady **M611** is hardware-validated. The Brady **M610 cut** behavior and the
  **Brother P-touch** drivers are built but **not yet hardware-confirmed** — see
  [`docs/PTOUCH-DRIVER-STATUS.md`](docs/PTOUCH-DRIVER-STATUS.md).

[Unreleased]: https://github.com/ryancoopster/VectorLabel/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/ryancoopster/VectorLabel/releases/tag/v1.2.0
[1.1.0]: https://github.com/ryancoopster/VectorLabel/releases/tag/v1.1.0
