import Foundation
import Combine
import AppKit

/// All user-configurable preferences for VectorLabel.
/// Values are persisted via UserDefaults through @AppStorage-compatible wrappers.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: – Export

    /// Root watch folder. The app watches Exports/ inside this path.
    @Published var watchFolderPath: String {
        didSet { UserDefaults.standard.set(watchFolderPath, forKey: "watchFolderPath") }
    }

    /// Open the print window automatically when a new CSV is detected.
    @Published var autoOpenPrintWindow: Bool {
        didSet { UserDefaults.standard.set(autoOpenPrintWindow, forKey: "autoOpenPrintWindow") }
    }

    /// Maximum number of export CSVs to retain per project subfolder.
    /// Pruning uses the _export_YYYYMMDD_HHMMSS datecode in the filename.
    @Published var maxExportsPerProject: Int {
        didSet {
            UserDefaults.standard.set(maxExportsPerProject, forKey: "maxExportsPerProject")
            ExportSettings.maxExportsPerProject = maxExportsPerProject
        }
    }

    // MARK: – Templates

    /// Folder where .vlt.json template files are stored.
    @Published var templatesFolderPath: String {
        didSet { UserDefaults.standard.set(templatesFolderPath, forKey: "templatesFolderPath") }
    }

    // MARK: – Printing

    /// USB Product ID override for M611 (until confirmed).
    @Published var m611ProductIDOverride: String {
        didSet { UserDefaults.standard.set(m611ProductIDOverride, forKey: "m611ProductIDOverride") }
    }

    /// Milliseconds to wait between sending consecutive label jobs.
    @Published var interLabelDelayMs: Int {
        didSet { UserDefaults.standard.set(interLabelDelayMs, forKey: "interLabelDelayMs") }
    }

    /// Default print range mode: "all", "selected", or "range".
    @Published var defaultPrintRange: String {
        didSet { UserDefaults.standard.set(defaultPrintRange, forKey: "defaultPrintRange") }
    }

    // MARK: – Recent prints

    /// How many recent print jobs to show in the menu bar (user-defined, default 5).
    @Published var recentPrintsCount: Int {
        didSet { UserDefaults.standard.set(recentPrintsCount, forKey: "recentPrintsCount") }
    }

    /// Template id pre-selected when the print window opens. Empty = none.
    /// Persists across print-window open/close and app restarts.
    @Published var defaultTemplateID: String {
        didSet { UserDefaults.standard.set(defaultTemplateID, forKey: "defaultTemplateID") }
    }

    /// User-arranged record-table column order (CSV keys). Shared between the
    /// print window and the template designer, persisted across launches.
    /// Empty = natural order.
    @Published var recordColumnOrder: [String] {
        didSet { UserDefaults.standard.set(recordColumnOrder, forKey: "recordColumnOrder") }
    }

    /// Record-table columns the user has hidden. Shared + persisted.
    @Published var recordHiddenColumns: [String] {
        didSet { UserDefaults.standard.set(recordHiddenColumns, forKey: "recordHiddenColumns") }
    }

    /// Per-column widths in px (CSV key → width). Shared + persisted.
    @Published var recordColumnWidths: [String: Double] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(recordColumnWidths),
                                      forKey: "recordColumnWidths")
        }
    }

    // MARK: – Template designer preferences (persisted)

    @Published var designerSnapGrid: Bool {
        didSet { UserDefaults.standard.set(designerSnapGrid, forKey: "designerSnapGrid") }
    }
    @Published var designerSnapObjects: Bool {
        didSet { UserDefaults.standard.set(designerSnapObjects, forKey: "designerSnapObjects") }
    }
    @Published var designerGridSize: Double {
        didSet { UserDefaults.standard.set(designerGridSize, forKey: "designerGridSize") }
    }

    // MARK: – Printer calibration (per printer, keyed by serial number)

    /// Print-alignment offset in printer pixels, keyed by the printer's serial
    /// number so it persists across disconnect/reconnect and survives relaunch.
    /// Value is [dx, dy]; dx shifts along the tape feed, dy across the tape.
    /// Keyed by serial (not the full USB id) so it follows the physical printer.
    @Published var printerCalibration: [String: [Double]] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(printerCalibration),
                                      forKey: "printerCalibration")
        }
    }

    /// Calibration offset (in printer pixels) for a printer serial. (0,0) if none.
    func calibrationOffset(forSerial serial: String) -> (dx: Double, dy: Double) {
        let a = printerCalibration[serial] ?? []
        return (a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0)
    }

    /// Set the calibration offset (printer pixels) for a printer serial.
    func setCalibrationOffset(forSerial serial: String, dx: Double, dy: Double) {
        printerCalibration[serial] = [dx, dy]
    }

    // MARK: – App behaviour

    /// Whether to also show VectorLabel in the Dock (menu-bar-only by default).
    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            // NSApp.setActivationPolicy must be called on the main actor.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(self.showInDock ? .regular : .accessory)
            }
        }
    }

    /// Apply a column config payload {order, hidden, widths} posted from a web view.
    func applyColumnConfigPayload(_ payload: Any?) {
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
    func columnConfigJSON() -> String {
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

    var watchFolderURL: URL { URL(fileURLWithPath: watchFolderPath) }
    var exportsFolderURL: URL { watchFolderURL.appendingPathComponent("Exports") }
    var templatesFolderURL: URL { URL(fileURLWithPath: templatesFolderPath) }

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
        m611ProductIDOverride = defaults.string(forKey: "m611ProductIDOverride") ?? ""
        interLabelDelayMs = defaults.object(forKey: "interLabelDelayMs") as? Int ?? 50
        defaultPrintRange = defaults.string(forKey: "defaultPrintRange") ?? "all"
        recentPrintsCount = defaults.object(forKey: "recentPrintsCount") as? Int ?? 5
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
        if let d = defaults.data(forKey: "printerCalibration"),
           let m = try? JSONDecoder().decode([String: [Double]].self, from: d) {
            printerCalibration = m
        } else {
            printerCalibration = [:]
        }
        showInDock        = defaults.object(forKey: "showInDock") as? Bool ?? false

        // Sync ExportSettings singleton
        ExportSettings.maxExportsPerProject = maxExportsPerProject
    }

    func resetToDefaults() {
        let home = NSHomeDirectory()
        let base = (home as NSString).appendingPathComponent("Documents/VectorLabel")
        watchFolderPath      = base
        autoOpenPrintWindow  = true
        maxExportsPerProject = 15
        templatesFolderPath  = (base as NSString).appendingPathComponent("Templates")
        m611ProductIDOverride = ""
        interLabelDelayMs    = 50
        defaultPrintRange    = "all"
        recentPrintsCount    = 5
        defaultTemplateID    = ""
        recordColumnOrder    = []
        recordHiddenColumns  = []
        recordColumnWidths   = [:]
        designerSnapGrid     = true
        designerSnapObjects  = true
        designerGridSize     = 0.05
        showInDock           = false
    }
}
