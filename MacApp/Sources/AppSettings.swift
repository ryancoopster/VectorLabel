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

    /// How many recent print jobs to show in the menu bar (3, 5, or 10).
    @Published var recentPrintsCount: Int {
        didSet { UserDefaults.standard.set(recentPrintsCount, forKey: "recentPrintsCount") }
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
        recentPrintsCount = defaults.object(forKey: "recentPrintsCount") as? Int ?? 3
        showInDock        = defaults.object(forKey: "showInDock") as? Bool ?? false
        devRepoPath       = defaults.string(forKey: "devRepoPath") ?? ""

        // Sync ExportSettings singleton
        ExportSettings.maxExportsPerProject = maxExportsPerProject
    }

    /// Path to the VectorLabel repo checkout, used to load HTML files live during development.
    /// Leave empty to use the bundled HTML (production).
    @Published var devRepoPath: String {
        didSet { UserDefaults.standard.set(devRepoPath, forKey: "devRepoPath") }
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
        recentPrintsCount    = 3
        showInDock           = false
        devRepoPath          = ""
    }
}
