# VectorLabel

A two-part system for printing Brady M610/M611 wrap-around wire labels directly from Vectorworks ConnectCAD circuits.

## Components

### `VectorworksPlugin/export_circuits.py`
Vectorworks Python plug-in script. Select one or more ConnectCAD circuit objects, run the command, and it exports a CSV to `~/Documents/VectorLabel/`. Each circuit produces two rows — one for the Source label and one for the Destination label.

**Install:** Tools > Plug-ins > Plug-in Manager > New > Command > Python. Paste the script contents. Add to workspace via Tools > Workspaces > Edit Current Workspace.

### `MacApp/`
Swift/SwiftUI macOS menu bar companion app. Watches `~/Documents/VectorLabel/` for new CSV exports, shows a print preview window with template selection, and sends VGL-encoded print jobs directly to a Brady M610 or M611 via USB (libusb).

**Status:** Source files scaffolded. Xcode project and template editor UI in progress.

## Supported Brady Label Sizes
| Part Number | Size | Notes |
|---|---|---|
| BM-31-427 | 1" × 1.5" | Roll |
| BM-32-427 | 1.5" × 1.5" | Roll |
| BM-33-427 | 1.5" × 4" | Roll |

## Setup (Mac App)
```bash
brew install libusb
```
Then open `MacApp/` in Xcode and build. Requires macOS 13+.

## Export CSV Columns
| Column | Description |
|---|---|
| `_Side` | Source or Destination |
| `Number` | Cable number |
| `Cable` | Cable name |
| `Signal` | Signal type (LAN, PWR, DANTE, etc.) |
| `Device_Name` | Near-end device name |
| `Device_Tag` | Near-end device tag |
| `Socket_Name` | Near-end socket name |
| `Connector` | Near-end connector type |
| `Other_Device` | Far-end device name |
| `Other_Socket` | Far-end socket name |
| `Other_Connector` | Far-end connector type |
| `Room` / `Rack` / `RackU` | Physical location (destination side) |
| `Cable Type` | Cable type |
| `CableLength` | Cable length setting |

## Open Items
- Xcode project file
- Template editor UI
- Template persistence (Application Support)
- M611 USB product ID verification
- Settings window
