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

    // There is no inter-label delay setting — printing always runs at full speed. The only
    // per-printer print setting is single-label vs full-job mode (PrinterModelStore).

    /// How often (seconds) the Engine scans for connected printers and re-reads their
    /// live status/telemetry (battery / ribbon / labels / supply / errors). Default 5s;
    /// reads pause while a job is printing. Clamped to 1…600 by consumers.
    @Published public var refreshIntervalSec: Int {
        didSet { UserDefaults.standard.set(refreshIntervalSec, forKey: "refreshIntervalSec") }
    }

    /// "Feed to clear before printing": prepend a blank lead label to each job (die-cut:
    /// one label pitch; continuous: a 1" feed, always cut) to advance/clear the supply
    /// before the real labels. Persisted; surfaced as a tick box by the print + designer.
    @Published public var feedToClearBeforePrint: Bool {
        didSet { UserDefaults.standard.set(feedToClearBeforePrint, forKey: "feedToClearBeforePrint") }
    }

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
            // Drop any non-finite width (NaN/Inf from a stray drag callback): JSONEncoder
            // throws on it, and the old `set(try? …)` then wrote nil, REMOVING the key
            // and wiping ALL widths. Sanitize + only write on a successful encode.
            let clean = recordColumnWidths.filter { $0.value.isFinite }
            if let data = try? JSONEncoder().encode(clean) {
                UserDefaults.standard.set(data, forKey: "recordColumnWidths")
            }
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
    /// Value is [dx, dy]; matching the renderer (LabelTemplate.render): dx shifts ACROSS
    /// the print head, dy shifts ALONG the tape feed (applied before any orientation
    /// rotation). Keyed by serial (not the full USB id) so it follows the physical printer.
    @Published public var printerCalibration: [String: [Double]] {
        didSet {
            // Drop any entry with a non-finite component (a single NaN/Inf would make the
            // encode throw → the old `set(try? …)` wrote nil and wiped ALL calibrations).
            // Sanitize + only write on a successful encode.
            let clean = printerCalibration.filter { $0.value.allSatisfy { $0.isFinite } }
            if let data = try? JSONEncoder().encode(clean) {
                UserDefaults.standard.set(data, forKey: "printerCalibration")
            }
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

    // MARK: – Feed to clear (per printer)

    /// "Feed to clear" enabled per printer, keyed by the front-end's stable printer key
    /// (serial, falling back to model) so it follows the physical printer like
    /// `printerCalibration`. Only printers whose driver reports `supportsFeedToClear`
    /// (Brady M610/M611) ever surface the tick box. A printer with no stored value falls
    /// back to the legacy global `feedToClearBeforePrint`, so an existing user's single
    /// preference carries over the first time they print on a given printer.
    @Published public var feedToClearByPrinter: [String: Bool] {
        didSet {
            if let data = try? JSONEncoder().encode(feedToClearByPrinter) {
                UserDefaults.standard.set(data, forKey: "feedToClearByPrinter")
            }
        }
    }

    /// Whether feed-to-clear is on for a printer key. Falls back to the legacy global
    /// default when this printer has no stored value yet.
    public func feedToClear(forKey key: String) -> Bool {
        feedToClearByPrinter[key] ?? feedToClearBeforePrint
    }
    /// Persist the feed-to-clear choice for a printer key (empty key ⇒ the legacy global).
    public func setFeedToClear(forKey key: String, _ on: Bool) {
        if key.isEmpty { feedToClearBeforePrint = on } else { feedToClearByPrinter[key] = on }
    }
    /// The per-printer feed-to-clear map as a JSON object string ("{}" on failure), for
    /// injecting into the WKWebView front-ends.
    public func feedToClearByPrinterJSON() -> String {
        guard let d = try? JSONEncoder().encode(feedToClearByPrinter),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: – App behaviour

    /// The suite is four separate processes, each with its OWN `UserDefaults.standard`, so
    /// the appearance choice must be relayed process-to-process. These carry the new value
    /// ("dark"/"light"/"system") in the notification's `object`; `…Request` asks the source
    /// of truth (the Engine) to re-broadcast the current value (for apps opened later).
    public static let appearanceChangedNotification = Notification.Name("com.sai.vectorlabel.appearanceChanged")
    public static let appearanceRequestNotification = Notification.Name("com.sai.vectorlabel.appearanceRequest")
    /// True while applying an appearance received from another app, so we don't re-broadcast.
    private var applyingRemoteAppearance = false

    /// UI appearance: "dark" (default) or "light". Applies to the menu, the
    /// Preferences window, and both web UIs (print + designer) simultaneously.
    @Published public var appearance: String {
        didSet {
            UserDefaults.standard.set(appearance, forKey: "appearance")
            applyNativeAppearance()
            // Relay the choice to the other three apps so the whole suite switches together.
            if !applyingRemoteAppearance && appearance != oldValue {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.appearanceChangedNotification, object: appearance,
                    userInfo: nil, deliverImmediately: true)
            }
        }
    }

    /// Re-broadcast the current appearance to the rest of the suite (Engine → front-ends).
    public func broadcastAppearance() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.appearanceChangedNotification, object: appearance, userInfo: nil, deliverImmediately: true)
    }

    /// Ask the source of truth (the Engine) to re-broadcast the current appearance — called
    /// on launch by a front-end so an app opened AFTER an appearance change still syncs.
    public func requestAppearanceSync() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.appearanceRequestNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Apply an appearance value received from another app (does not re-broadcast).
    private func applyRemoteAppearance(_ value: String) {
        guard value != appearance else { return }
        applyingRemoteAppearance = true
        appearance = value                 // didSet persists + applies native appearance
        applyingRemoteAppearance = false
        systemAppearanceTick &+= 1         // nudge web views / identity-keyed views to re-theme
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
        let apply = {
            switch self.appearance {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
            default:      NSApp.appearance = nil   // "system": follow the OS
            }
        }
        // Apply SYNCHRONOUSLY on the main thread so NSApp.effectiveAppearance is up to date
        // BEFORE the $appearance / $systemAppearanceTick observers read effectiveTheme. If this
        // ran async, switching to "system" pushed the STALE theme to the web views — the native
        // chrome flipped to the OS mode but the WKWebView canvas stayed on the old theme.
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
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

    // MARK: – Software updates (Engine checks GitHub releases; see Engine/UpdateChecker)

    /// How the Engine checks GitHub for new releases: "launch" (on every launch),
    /// "interval" (every `updateIntervalDays` days), or "manual" (only via the
    /// Check-for-Updates button/menu row). "" = not chosen yet → the one-time
    /// first-launch policy prompt runs (and returns after a factory reset).
    @Published public var updatePolicy: String {
        didSet { UserDefaults.standard.set(updatePolicy, forKey: "updatePolicy") }
    }

    /// Days between automatic checks when updatePolicy == "interval". Default 7;
    /// clamped to >= 1 by consumers (UpdateChecker + the Preferences stepper).
    @Published public var updateIntervalDays: Int {
        didSet { UserDefaults.standard.set(updateIntervalDays, forKey: "updateIntervalDays") }
    }

    /// Unix timestamp of the last COMPLETED check (0 = never). Drives the
    /// "interval" policy and the "Last checked:" caption in Preferences. Failed
    /// checks don't update it, so an interval user retries on the next launch.
    @Published public var updateLastCheckTimestamp: Double {
        didSet { UserDefaults.standard.set(updateLastCheckTimestamp, forKey: "updateLastCheckTimestamp") }
    }

    /// The version the user chose "Don't Update" for ("" = none). That exact
    /// version never re-prompts automatically; a NEWER release prompts normally.
    @Published public var updateSkippedVersion: String {
        didSet { UserDefaults.standard.set(updateSkippedVersion, forKey: "updateSkippedVersion") }
    }

    /// Unix timestamp before which automatic checks don't re-prompt (0 = none).
    /// "Remind Me Tomorrow" sets now+24h; user-initiated checks ignore it.
    @Published public var updateRemindAfterTimestamp: Double {
        didSet { UserDefaults.standard.set(updateRemindAfterTimestamp, forKey: "updateRemindAfterTimestamp") }
    }

    /// The newest update found by the last check, cached as AvailableUpdate JSON
    /// ("" = nothing newer). Lets Preferences show the "Version X.Y.Z available"
    /// summary — including for a skipped/snoozed version — without re-checking.
    @Published public var updateAvailableJSON: String {
        didSet { UserDefaults.standard.set(updateAvailableJSON, forKey: "updateAvailableJSON") }
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
        refreshIntervalSec = defaults.object(forKey: "refreshIntervalSec") as? Int ?? 5
        feedToClearBeforePrint = defaults.object(forKey: "feedToClearBeforePrint") as? Bool ?? false
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
        if let d = defaults.data(forKey: "feedToClearByPrinter"),
           let m = try? JSONDecoder().decode([String: Bool].self, from: d) {
            feedToClearByPrinter = m
        } else {
            feedToClearByPrinter = [:]
        }
        filterSortPresetsJSON = defaults.string(forKey: "filterSortPresetsJSON") ?? "[]"
        appearance        = defaults.string(forKey: "appearance") ?? "dark"
        showInDock        = defaults.object(forKey: "showInDock") as? Bool ?? false
        updatePolicy      = defaults.string(forKey: "updatePolicy") ?? ""
        updateIntervalDays = max(1, defaults.object(forKey: "updateIntervalDays") as? Int ?? 7)
        updateLastCheckTimestamp = defaults.object(forKey: "updateLastCheckTimestamp") as? Double ?? 0
        updateSkippedVersion = defaults.string(forKey: "updateSkippedVersion") ?? ""
        updateRemindAfterTimestamp = defaults.object(forKey: "updateRemindAfterTimestamp") as? Double ?? 0
        updateAvailableJSON = defaults.string(forKey: "updateAvailableJSON") ?? ""

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

        // Another app changed the appearance — apply it here too (the value is in `object`).
        DistributedNotificationCenter.default().addObserver(
            forName: Self.appearanceChangedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self, let v = note.object as? String else { return }
            self.applyRemoteAppearance(v)
        }
    }

    public func resetToDefaults() {
        let home = NSHomeDirectory()
        let base = (home as NSString).appendingPathComponent("Documents/VectorLabel")
        watchFolderPath      = base
        autoOpenPrintWindow  = true
        maxExportsPerProject = 15
        templatesFolderPath  = (base as NSString).appendingPathComponent("Templates")
        refreshIntervalSec   = 5
        feedToClearBeforePrint = false
        feedToClearByPrinter = [:]    // factory reset clears per-printer feed-to-clear too
        defaultPrintRange    = "all"
        defaultTemplateID    = ""
        recordColumnOrder    = []
        recordHiddenColumns  = []
        recordColumnWidths   = [:]
        printerCalibration   = [:]   // a factory reset clears per-printer alignment offsets too
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
        updatePolicy         = ""    // factory reset re-arms the first-launch update prompt
        updateIntervalDays   = 7
        updateLastCheckTimestamp = 0
        updateSkippedVersion = ""
        updateRemindAfterTimestamp = 0
        updateAvailableJSON  = ""
    }
}
