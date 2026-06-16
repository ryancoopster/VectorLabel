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

`VectorworksPlugin/export_circuits.py` backs **two** menu commands. Install each
as its own command plug-in:

1. Vectorworks → Tools → Plug-ins → Plug-in Manager → New Command
2. Language: Python, paste the contents of `export_circuits.py`
3. At the bottom of the script, leave exactly one entry-point call active:
   - **Export Selected Circuits to VectorLabel** → `export_selected_circuits()`
   - **Export All Circuits to VectorLabel** → `export_all_circuits()`
4. Add both commands to your workspace toolbar/menu.

- *Selected* exports the current selection.
- *All* exports every ConnectCAD circuit on the **active design layer**.

The CSV lands in `~/Documents/VectorLabel/Exports/<VWFileName>/` and VectorLabel
opens the print window automatically. The export runs silently (no confirmation
dialog); only error conditions alert.

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
| `VectorworksPlugin/export_circuits.py` | Vectorworks ConnectCAD → CSV exporter |
