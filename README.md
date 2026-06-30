# VectorLabel

A macOS menu bar app for printing Brady M610/M611 wrap-around wire labels from Vectorworks ConnectCAD exports.

## Adding support for another printer

Got a different printer working with VectorLabel and want to contribute it back?

- **[docs/CONTRIBUTING-VIA-CLAUDE-CODE.md](docs/CONTRIBUTING-VIA-CLAUDE-CODE.md)** — a
  no-code-experience-required walkthrough: use [Claude Code](https://claude.com/claude-code)
  to make the change and open a pull request on GitHub.
- **[docs/ADDING-PRINTER-TYPES.md](docs/ADDING-PRINTER-TYPES.md)** — the technical
  instruction set Claude Code follows to wire a new printer type into the print
  pipeline and supply catalog.

Label supplies themselves are editable in-app, no code needed:
**Engine ▸ Preferences ▸ Printers ▸ Edit Supplies…** (categories, sizes, part
numbers, quantities / roll lengths, 90° feed rotation, and buy links, grouped per
printer model).

## Folder structure

```
~/Documents/VectorLabel/
  Templates/          ← .vlt.json label templates from the designer
  Exports/
    <VWFileName>/     ← one folder per Vectorworks project file
      <VWFileName>_export_YYYYMMDD_HHMMSS.csv   (max 15 per project)
```

## Prerequisites

Run these in Terminal **before** opening the project in Xcode:

```bash
brew install libusb pkg-config
```

## Open in Xcode

1. Clone the repository
2. Run `brew install libusb pkg-config`
3. Open `Package.swift` in Xcode (File → Open → select Package.swift)
4. Xcode will resolve the package graph — it should succeed now
5. Select the **VectorLabel** scheme, destination **My Mac**
6. **Product → Build** (⌘B)

### Info.plist & Entitlements

`MacApp/Info.plist` and `MacApp/VectorLabel.entitlements` are not bundled via SPM
(SPM doesn't allow Info.plist as a resource). Set them in Xcode:

- Target → Build Settings → `INFOPLIST_FILE` = `MacApp/Info.plist`
- Target → Signing & Capabilities → Add entitlements file → `MacApp/VectorLabel.entitlements`

Or run via `swift run` for development (entitlements are not enforced in debug).

### Apple Silicon vs Intel

`MacApp/Sources/CLibUSB/module.modulemap` defaults to the Apple Silicon Homebrew path:
```
/opt/homebrew/include/libusb-1.0/libusb.h
```
If you're on Intel, change it to:
```
/usr/local/include/libusb-1.0/libusb.h
```

## Vectorworks plugin

There are **two** menu commands, one per script. Each is its own command
plug-in (Vectorworks shows one menu command per registered plug-in).

**Easiest:** the macOS installer's optional **"Vectorworks ConnectCAD plug-ins"**
choice copies the ready-made `.vsm` bundles
(`VectorworksPlugin/*.vsm`) into your Vectorworks Plug-ins folder automatically —
then just do step 4 below (add them to your workspace). To register them manually
instead:

1. Vectorworks → Tools → Plug-ins → Plug-in Manager → **New Command**
2. Name it **Export Selected Circuits to VectorLabel**, Language: Python,
   paste the entire contents of `export_selected.py`.
3. **New Command** again, name it **Export All Circuits to VectorLabel**,
   paste the entire contents of `export_all.py`.
4. Tools → Workspaces → Edit Current Workspace → drag both commands into your
   menu, then save the workspace.

- *Selected* exports the current selection.
- *All* exports every ConnectCAD circuit on the **active design layer**.

Each script is self-contained (no shared import needed) — just paste the whole
file. The CSV lands in `~/Documents/VectorLabel/Exports/<VWFileName>/` and
VectorLabel opens the print window automatically. Exports run silently (no
confirmation dialog); only error conditions alert.

## Brady USB PID

- M610: VID `0x0E2E`, PID `0x010B` ✓ confirmed  
- M611: PID `0x010C` assumed — if your M611 isn't detected, check Preferences → Printers

## Architecture

| File | Role |
|---|---|
| `CableTronApp.swift` | `@main`, `AppDelegate`, wires everything together |
| `AppSettings.swift` | `UserDefaults`-backed preferences singleton |
| `ExportWatcher.swift` | FSEvents recursive folder watcher + CSV parser + pruner |
| `TemplateStore.swift` | Loads/saves `.vlt.json` templates |
| `FormulaEngine.swift` | Swift port of the JS formula evaluator |
| `LabelTemplate.swift` | Core Graphics renderer: `VLTemplate + WireRecord → pixels` |
| `BradyVGL.swift` | Builds VGL print jobs from pixel buffers |
| `BradyUSB.swift` | libusb transport: enumerate, open, send |
| `PrinterManager.swift` | USB scan loop, active job queue, cancel support |
| `PrintWindowController.swift` | WKWebView print window, JS↔Swift bridge |
| `RecentPrintsStore.swift` | Persists last N print jobs for reprint |
| `MenuBarView.swift` | Full SwiftUI menu bar dropdown |
| `PreferencesView.swift` | Preferences window (6 tabs) |
| `VectorLabelPrint.html` | Print UI (record table, template picker, printer selector, live editor) |
| `VectorLabelDesigner.html` | Standalone template designer |
| `VectorworksPlugin/export_selected.py` | Vectorworks command: export selected ConnectCAD circuits → CSV |
| `VectorworksPlugin/export_all.py` | Vectorworks command: export all circuits on the active layer → CSV |
