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

### Changed
- **Installer:** on macOS older than 14 (Sonoma) the installer now **warns** that the apps
  may not run correctly and lets you continue, instead of hard-blocking. (The apps target
  macOS 14 on Apple Silicon.)

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

[Unreleased]: https://github.com/ryancoopster/VectorLabel/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/ryancoopster/VectorLabel/releases/tag/v1.1.0
