# VectorLabel

A macOS menu bar app for printing Brady M610/M611 wrap-around wire labels from Vectorworks ConnectCAD exports.

## Folder structure

```
~/Documents/VectorLabel/
  Templates/          ← .vlt.json label templates from the designer
  Exports/
    <VWFileName>/     ← one folder per Vectorworks project file
      <VWFileName>_export_YYYYMMDD_HHMMSS.csv   (max 15 per project)
```

## Prerequisites

```bash
brew install libusb
```

## Build (Xcode)

1. Clone the repo
2. `brew install libusb`
3. Open `Package.swift` in Xcode (File → Open → select Package.swift)
4. Select the **VectorLabel** scheme, target **My Mac**
5. **Product → Build** (⌘B)

The first build will ask for permission to access Documents — allow it.

## Build (command line)

```bash
swift build -c release
.build/release/VectorLabel
```

## Vectorworks plugin

Install `VectorworksPlugin/export_circuits.py` as a Vectorworks command plug-in:

1. Vectorworks → Tools → Plug-ins → Plug-in Manager → New Command
2. Language: Python, paste the contents of `export_circuits.py`
3. Add to your workspace toolbar

Select circuits in ConnectCAD, run the command. The CSV lands in  
`~/Documents/VectorLabel/Exports/<VWFileName>/` and VectorLabel opens the print window automatically.

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
| `VectorLabelPrint.html` | Print UI (record table, template picker, printer selector) |
| `VectorLabelDesigner.html` | Template designer (canvas, formula bar, snap grid) |
| `VectorworksPlugin/export_circuits.py` | Vectorworks ConnectCAD → CSV exporter |
