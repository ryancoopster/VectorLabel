import Foundation
import Combine
import AppKit

/// All user-configurable preferences for VectorLabel.
/// Values are persisted via UserDefaults through @AppStorage-compatible wrappers.
public final class AppSettings: ObservableObject {

    public static let shared = AppSettings()

    // MARK: – Export

    /// Root watch folder. The app watches Exports/ inside this path.
    @Published public var watchFolderPath: String {
        didSet { UserDefaults.standard.set(watchFolderPath, forKey: "watchFolderPath") }
    }

    /// Open the print window automatically when a new CSV is detected.
    @Published public var autoOpenPrintWindow: Bool {
        didSet { UserDefaults.standard.set(autoOpenPrintWindow, forKey: "autoOpenPrintWindow") }
    }

    /// Maximum number of export CSVs to retain per project subfolder.
    /// Pruning uses the _export_YYYYMMDD_HHMMSS datecode in the filename.
    @Published public var maxExportsPerProject: Int {
        didSet {
            UserDefaults.standard.set(maxExportsPerProject, forKey: "maxExportsPerProject")
            ExportSettings.maxExportsPerProject = maxExportsPerProject
        }
    }

    // MARK: – Templates

    /// Folder where .vlt.json template files are stored.
    @Published public var templatesFolderPath: String {
        didSet { UserDefaults.standard.set(templatesFolderPath, forKey: "templatesFolderPath") }
    }

    // MARK: – Printing

    // Inter-label delay moved to per-printer-model settings (PrinterModelStore /
    // PrinterModel.interLabelDelayMs), set under Printers ▸ Printer Models…

    /// Default print range mode: "all", "selected", or "range".
    @Published public var defaultPrintRange: String {
        didSet { UserDefaults.standard.set(defaultPrintRange, forKey: "defaultPrintRange") }
    }


    /// Template id pre-selected when the print window opens. Empty = none.
    /// Persists across print-window open/close and app restarts.
    @Published public var defaultTemplateID: String {
        didSet { UserDefaults.standard.set(defaultTemplateID, forKey: "defaultTemplateID") }
    }

    /// User-arranged record-table column order (CSV keys). Shared between the
    /// print window and the template designer, persisted across launches.
    /// Empty = natural order.
    @Published public var recordColumnOrder: [String] {
        didSet { UserDefaults.standard.set(recordColumnOrder, forKey: "recordColumnOrder") }
    }

    /// Record-table columns the user has hidden. Shared + persisted.
    @Published public var recordHiddenColumns: [String] {
        didSet { UserDefaults.standard.set(recordHiddenColumns, forKey: "recordHiddenColumns") }
    }

    /// Per-column widths in px (CSV key → width). Shared + persisted.
    @Published public var recordColumnWidths: [String: Double] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(recordColumnWidths),
                                      forKey: "recordColumnWidths")
        }
    }

    /// Saved filter/sort presets for the print window, stored as a JSON array
    /// string ([{id,name,filter,sort}]). Persisted; injected into the print UI.
    @Published public var filterSortPresetsJSON: String {
        didSet { UserDefaults.standard.set(filterSortPresetsJSON, forKey: "filterSortPresetsJSON") }
    }

    // MARK: – Template designer preferences (persisted)

    @Published public var designerSnapGrid: Bool {
        didSet { UserDefaults.standard.set(designerSnapGrid, forKey: "designerSnapGrid") }
    }
    @Published public var designerSnapObjects: Bool {
        didSet { UserDefaults.standard.set(designerSnapObjects, forKey: "designerSnapObjects") }
    }
    @Published public var designerGridSize: Double {
        didSet { UserDefaults.standard.set(designerGridSize, forKey: "designerGridSize") }
    }
    /// Height (px) of the designer's records browser panel.
    @Published public var designerRecordsHeight: Double {
        didSet { UserDefaults.standard.set(designerRecordsHeight, forKey: "designerRecordsHeight") }
    }
    /// Height (px) of the Custom Designer's bottom database pane (persisted; the
    /// records browser is hidden in custom mode, so this is its own value).
    @Published public var designerDatabaseHeight: Double {
        didSet { UserDefaults.standard.set(designerDatabaseHeight, forKey: "designerDatabaseHeight") }
    }
    /// Width (px) of the designer's right-hand properties (inspector) panel.
    @Published public var designerPropsWidth: Double {
        didSet { UserDefaults.standard.set(designerPropsWidth, forKey: "designerPropsWidth") }
    }

    /// Folder last used in the Custom Designer's "Choose data file" panel, so it
    /// reopens where the user last picked a CSV/XLSX instead of always at Exports/.
    /// Empty = none yet (fall back to the Exports folder).
    @Published public var lastDataSourceFolderPath: String {
        didSet { UserDefaults.standard.set(lastDataSourceFolderPath, forKey: "lastDataSourceFolderPath") }
    }

    // MARK: – Printer calibration (per printer, keyed by serial number)

    /// Print-alignment offset in printer pixels, keyed by the printer's serial
    /// number so it persists across disconnect/reconnect and survives relaunch.
    /// Value is [dx, dy]; dx shifts along the tape feed, dy across the tape.
    /// Keyed by serial (not the full USB id) so it follows the physical printer.
    @Published public var printerCalibration: [String: [Double]] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(printerCalibration),
                                      forKey: "printerCalibration")
        }
    }

    /// Calibration offset (in printer pixels) for a printer serial. (0,0) if none.
    public func calibrationOffset(forSerial serial: String) -> (dx: Double, dy: Double) {
        let a = printerCalibration[serial] ?? []
        return (a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0)
    }

    /// Set the calibration offset (printer pixels) for a printer serial.
    public func setCalibrationOffset(forSerial serial: String, dx: Double, dy: Double) {
        printerCalibration[serial] = [dx, dy]
    }

    // MARK: – App behaviour

    /// UI appearance: "dark" (default) or "light". Applies to the menu, the
    /// Preferences window, and both web UIs (print + designer) simultaneously.
    @Published public var appearance: String {
        didSet {
            UserDefaults.standard.set(appearance, forKey: "appearance")
            applyNativeAppearance()
        }
    }
    /// Bumped when the OS appearance changes while in "system" mode, so views that
    /// key their identity on it rebuild with the new effective colours.
    @Published public private(set) var systemAppearanceTick: Int = 0

    /// Whether the EFFECTIVE appearance is light. "system" follows the OS.
    public var isLight: Bool {
        switch appearance {
        case "light": return true
        case "dark":  return false
        default:      return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        }
    }
    /// The effective light/dark theme to push to the web views ("light" | "dark").
    public var effectiveTheme: String { isLight ? "light" : "dark" }

    /// Match the native macOS appearance (so SwiftUI controls, text fields,
    /// scrollbars, and the menu/preferences chrome render in the chosen mode).
    /// "system" leaves NSApp.appearance nil so the OS drives it.
    public func applyNativeAppearance() {
        DispatchQueue.main.async {
            switch self.appearance {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
            default:      NSApp.appearance = nil
            }
        }
    }

    /// Whether to also show VectorLabel in the Dock (menu-bar-only by default).
    @Published public var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            // NSApp.setActivationPolicy must be called on the main actor.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(self.showInDock ? .regular : .accessory)
            }
        }
    }

    /// Apply a column config payload {order, hidden, widths} posted from a web view.
    public func applyColumnConfigPayload(_ payload: Any?) {
        guard let dict = payload as? [String: Any] else { return }
        if let order = dict["order"] as? [String] { recordColumnOrder = order }
        if let hidden = dict["hidden"] as? [String] { recordHiddenColumns = hidden }
        if let widths = dict["widths"] as? [String: Any] {
            var m: [String: Double] = [:]
            for (k, v) in widths { if let d = (v as? NSNumber)?.doubleValue { m[k] = d } }
            recordColumnWidths = m
        }
    }

    /// The shared column config as a JSON object string for injection.
    public func columnConfigJSON() -> String {
        let cfg: [String: Any] = [
            "order": recordColumnOrder,
            "hidden": recordHiddenColumns,
            "widths": recordColumnWidths,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: cfg),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }

    // MARK: – Computed helpers

    public var watchFolderURL: URL { URL(fileURLWithPath: watchFolderPath) }
    public var exportsFolderURL: URL { watchFolderURL.appendingPathComponent("Exports") }
    public var templatesFolderURL: URL { URL(fileURLWithPath: templatesFolderPath) }

    /// Last-used Custom Designer data-file folder, or nil if unset / no longer present.
    public var lastDataSourceFolderURL: URL? {
        guard !lastDataSourceFolderPath.isEmpty else { return nil }
        let u = URL(fileURLWithPath: lastDataSourceFolderPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: – Init

    private init() {
        let defaults = UserDefaults.standard
        let home = NSHomeDirectory()
        let base = (home as NSString).appendingPathComponent("Documents/VectorLabel")

        watchFolderPath    = defaults.string(forKey: "watchFolderPath")
                           ?? base
        autoOpenPrintWindow = defaults.object(forKey: "autoOpenPrintWindow") as? Bool ?? true
        maxExportsPerProject = defaults.object(forKey: "maxExportsPerProject") as? Int ?? 15
        templatesFolderPath = defaults.string(forKey: "templatesFolderPath")
                           ?? ((base as NSString).appendingPathComponent("Templates"))
        defaultPrintRange = defaults.string(forKey: "defaultPrintRange") ?? "all"
        defaultTemplateID = defaults.string(forKey: "defaultTemplateID") ?? ""
        recordColumnOrder = (defaults.array(forKey: "recordColumnOrder") as? [String]) ?? []
        recordHiddenColumns = (defaults.array(forKey: "recordHiddenColumns") as? [String]) ?? []
        if let d = defaults.data(forKey: "recordColumnWidths"),
           let m = try? JSONDecoder().decode([String: Double].self, from: d) {
            recordColumnWidths = m
        } else {
            recordColumnWidths = [:]
        }
        designerSnapGrid    = defaults.object(forKey: "designerSnapGrid") as? Bool ?? true
        designerSnapObjects = defaults.object(forKey: "designerSnapObjects") as? Bool ?? true
        designerGridSize    = defaults.object(forKey: "designerGridSize") as? Double ?? 0.05
        designerRecordsHeight = defaults.object(forKey: "designerRecordsHeight") as? Double ?? 160
        designerDatabaseHeight = defaults.object(forKey: "designerDatabaseHeight") as? Double ?? 240
        designerPropsWidth  = defaults.object(forKey: "designerPropsWidth") as? Double ?? 220
        lastDataSourceFolderPath = defaults.string(forKey: "lastDataSourceFolderPath") ?? ""
        if let d = defaults.data(forKey: "printerCalibration"),
           let m = try? JSONDecoder().decode([String: [Double]].self, from: d) {
            printerCalibration = m
        } else {
            printerCalibration = [:]
        }
        filterSortPresetsJSON = defaults.string(forKey: "filterSortPresetsJSON") ?? "[]"
        appearance        = defaults.string(forKey: "appearance") ?? "dark"
        showInDock        = defaults.object(forKey: "showInDock") as? Bool ?? false

        // Sync ExportSettings singleton
        ExportSettings.maxExportsPerProject = maxExportsPerProject

        // Follow the OS light/dark switch while in "system" mode: re-apply the
        // native appearance and nudge views/web UIs to re-theme.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.appearance == "system" else { return }
            self.systemAppearanceTick &+= 1
            self.applyNativeAppearance()
        }
    }

    public func resetToDefaults() {
        let home = NSHomeDirectory()
        let base = (home as NSString).appendingPathComponent("Documents/VectorLabel")
        watchFolderPath      = base
        autoOpenPrintWindow  = true
        maxExportsPerProject = 15
        templatesFolderPath  = (base as NSString).appendingPathComponent("Templates")
        defaultPrintRange    = "all"
        defaultTemplateID    = ""
        recordColumnOrder    = []
        recordHiddenColumns  = []
        recordColumnWidths   = [:]
        designerSnapGrid     = true
        designerSnapObjects  = true
        designerGridSize     = 0.05
        designerRecordsHeight = 160
        designerDatabaseHeight = 240
        designerPropsWidth   = 220
        lastDataSourceFolderPath = ""
        filterSortPresetsJSON = "[]"
        appearance           = "dark"
        showInDock           = false
    }
}
