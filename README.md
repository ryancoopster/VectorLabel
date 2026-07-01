# VectorLabel

**A macOS suite for designing and printing wire / cable / asset labels on thermal
printers — with a Vectorworks ConnectCAD integration.**

VectorLabel lays out true-to-size labels (text, barcodes, QR, DataMatrix, images and
shapes), binds them to your data (a CSV/Excel file, or a live ConnectCAD export), and
prints them to **Brady** and **Brother** thermal printers over USB or the network.

- 🌐 **Website & docs:** <https://ryancoopster.github.io/VectorLabel/>
  ([User Guide](https://ryancoopster.github.io/VectorLabel/guide.html) ·
  [Quick Start](https://ryancoopster.github.io/VectorLabel/quickstart.html) ·
  [FAQ](https://ryancoopster.github.io/VectorLabel/faq.html) ·
  [Downloads](https://ryancoopster.github.io/VectorLabel/downloads.html))
- 📦 **Download the signed installer:** [GitHub Releases](https://github.com/ryancoopster/VectorLabel/releases)
- 📝 **What changed between versions:** [`CHANGELOG.md`](CHANGELOG.md)

> **Status: open alpha.** The Brady **M611** is hardware-validated. The Brady **M610
> cut** behavior and the **Brother P-touch** drivers are built but **not yet
> hardware-confirmed** — see [`docs/PTOUCH-DRIVER-STATUS.md`](docs/PTOUCH-DRIVER-STATUS.md).
> Licensed under MIT + Commons Clause (use it freely; don't resell it).

---

## What's in the suite

VectorLabel is **four cooperating macOS apps** plus a Vectorworks plug-in. Splitting
them up keeps a single privileged app in charge of the printer, and lets the designers
run as ordinary windowed apps.

| App | What it does |
|---|---|
| **VectorLabel Engine** | The menu-bar hub. Owns the USB/network printers, does all printing, holds the print queue + supply catalog, and hosts Preferences. Everything else talks to it. |
| **Auto Print** | Hosts the **Print window**. Watches your export folder and, when a new Vectorworks export lands, opens the print window with your records loaded so you can print a batch. |
| **Template Designer** | Builds **reusable, data-bound templates** (`.vltmp`). The print window fills them from each row of your data and prints one label per record. |
| **Custom Designer** | Makes **one-off labels** (`.vlcus`) and prints them itself. Can bind its own CSV/Excel data (one label per row) and reprint the exact design later. |
| **Vectorworks plug-in** | Two ConnectCAD commands (`export_selected.py`, `export_all.py`) that export circuit data straight into VectorLabel's watch folder. |

The two designers share one canvas engine, so the editing tools are identical; they
differ in their toolbar, default document name, and the Custom Designer's print header
+ database pane. Both are **tabbed** — open several labels at once.

## Highlights

- **Design or bind data.** Draw a label by hand, or bind a CSV/Excel file (or a live
  ConnectCAD export) and print one label per row.
- **Formulas & fields.** Spreadsheet-style formulas (`=IF(…)`, concatenation, etc.)
  evaluated identically in the on-screen preview and the printed output.
- **Barcodes built in.** 15 linear + 2-D symbologies (Code 128, QR, DataMatrix, PDF417,
  Aztec, …) via a vendored bwip-js, rasterized crisply at the printer's native DPI.
- **Import existing labels.** Open Brady `.BWT` and Brother P-touch `.lbx` templates —
  they're auto-converted into a new VectorLabel design.
- **Printers.** Brady M610 & M611 (300 DPI, self-laminating wire wraps) and Brother
  P-touch (180 DPI TZe tape) over **USB and the network**, with live status/telemetry
  and cassette auto-detection on supported models.
- **Editable supply catalog.** Sizes, part numbers, quantities and buy links — all
  editable in-app: **Engine ▸ Preferences ▸ Printers ▸ Edit Supplies…**

## Where your files live

```
~/Documents/VectorLabel/
  Templates/          ← .vltmp reusable templates (.vlt.json legacy name still read)
  Exports/
    <VWFileName>/     ← one folder per Vectorworks project file
      <VWFileName>_export_YYYYMMDD_HHMMSS.csv   (auto-pruned; default keep-15 per project)
```

Custom labels (`.vlcus`) save wherever you choose — they embed both the design and a
snapshot of the bound data, so a Reprint reopens the exact label.

---

## Building from source

VectorLabel is a Swift Package with four executable products. You need Xcode's Swift
toolchain and **libusb**.

```bash
brew install libusb pkg-config
git clone https://github.com/ryancoopster/VectorLabel.git
cd VectorLabel
swift build          # debug build of all four apps
swift test           # unit tests
```

- **Apple Silicon vs Intel:** `MacApp/Sources/CLibUSB/module.modulemap` defaults to the
  Apple-Silicon Homebrew path (`/opt/homebrew/…`). On Intel, point it at
  `/usr/local/include/libusb-1.0/libusb.h`.
- **Run a local install of the whole suite:** `./scripts/install.sh` builds, ad-hoc
  signs, and installs the four apps into `/Applications/VectorLabel/`, then launches
  the Engine + Auto Print.
- **Signed, notarized release:** push a `vX.Y.Z` tag — the `release.yml` GitHub Action
  builds, Developer-ID-signs, notarizes and publishes the installer to GitHub Releases
  (requires the repo signing/notary secrets to be configured).

## Repository layout

```
MacApp/Sources/
  Engine/            VectorLabel Engine — menu bar, Preferences, printing hub
  AutoPrint/         Auto Print — hosts the Print window, watches exports
  TemplateDesigner/  Template Designer app
  CustomDesigner/    Custom Designer app
  EngineKit/         Printer manager, USB/network scan, job queue (Engine-only)
  Core/              Shared model + rendering + the two WKWebView front-ends:
                       VectorLabelDesigner.html  (both designers)
                       VectorLabelPrint.html     (print window)
                     plus LabelTemplate (CoreText/CoreGraphics renderer), FormulaEngine,
                     BarcodeRenderer, SupplyCatalog, importers, IPC types, AppSettings
  UI/                Window controllers + BrowserTabBar (shared AppKit chrome)
  PrinterM610/ M611/ PrinterBrother/   per-model drivers (registered at launch)
  CLibUSB/           libusb module map
VectorworksPlugin/   export_selected.py / export_all.py (ConnectCAD → CSV)
scripts/             build / install / package / release helpers
website/             marketing site + support docs (auto-deploys to GitHub Pages)
docs/                contributor docs (see below)
```

## Vectorworks plug-in

Two ConnectCAD commands (Vectorworks shows one menu item per plug-in):

- **Export Selected Circuits to VectorLabel** — exports the current selection.
- **Export All Circuits to VectorLabel** — exports every ConnectCAD circuit on the
  **active design layer**.

The macOS installer's optional **"Vectorworks ConnectCAD plug-ins"** choice copies the
ready-made `.vsm` bundles into your Plug-ins folder; then add both commands to your
workspace (Tools ▸ Workspaces ▸ Edit Current Workspace). To register manually, paste
each script (`VectorworksPlugin/export_selected.py` / `export_all.py`) into its own
**New Command** (Python) in the Plug-in Manager. Each script is self-contained — paste
the whole file. Exports run silently; only errors alert.

---

## Contributing

**Got a new printer working, or want to fix something?** You don't need to be a
programmer — you can drive [Claude Code](https://claude.com/claude-code) right inside
the **Claude app** (no terminal required) to make the change and open a pull request.

- **[docs/CONTRIBUTING-VIA-CLAUDE-CODE.md](docs/CONTRIBUTING-VIA-CLAUDE-CODE.md)** —
  no-terminal walkthrough: connect GitHub in the Claude app, describe your change, and
  let it open the PR.
- **[docs/ADDING-PRINTER-TYPES.md](docs/ADDING-PRINTER-TYPES.md)** — the technical
  recipe for wiring a new printer type into the pipeline + supply catalog.
- **[docs/WRITING-A-PRINTER-DRIVER.md](docs/WRITING-A-PRINTER-DRIVER.md)** — the driver
  protocol/module details, for deeper work.
- **All fixes between releases go in [`CHANGELOG.md`](CHANGELOG.md)** — it's the single
  source of truth for "what changed," and the website's Downloads page is built from it.

Supplies don't need code at all — add them in-app under **Preferences ▸ Printers ▸ Edit
Supplies…** (and ask Claude Code to promote them to built-in defaults if you want them
to ship).

## License

MIT + [Commons Clause](https://commonsclause.com/) — free to use, modify and share; you
may not sell the software itself. See [`LICENSE`](LICENSE).
