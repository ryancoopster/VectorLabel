import AppKit
import WebKit
import SwiftUI
import Combine
import VectorLabelCore

/// Opens the print window (VectorLabelPrint.html in a WKWebView) when a new
/// export is detected, and also when the user taps "Reprint" in the menu bar.
///
/// The HTML print UI communicates back to Swift via WKScriptMessageHandler:
///   window.webkit.messageHandlers.vectorlabel.postMessage({action: ..., payload: ...})
///
/// Actions sent from JS → Swift:
///   "print"   payload: { printerID, title, templateName, vglJobs: [[UInt8]] }
///   "close"   payload: null
///   "ready"   payload: null   (JS has finished loading, send initial state)
/// One open export/reprint in the print window — its own WKWebView + data, so each tab
/// keeps full live state (selection, filter, inline edits) independently of the others.
@MainActor
final class PrintTab {
    let id = UUID().uuidString
    let webView: WKWebView
    var records: [WireRecord]
    var sourceFileURL: URL?
    var csvWritebackURL: URL?
    var reprinting: RecentPrint?
    var writebackWork: DispatchWorkItem?
    var title: String
    init(webView: WKWebView, records: [WireRecord], sourceFileURL: URL?,
         csvWritebackURL: URL?, reprinting: RecentPrint?, title: String) {
        self.webView = webView; self.records = records; self.sourceFileURL = sourceFileURL
        self.csvWritebackURL = csvWritebackURL; self.reprinting = reprinting; self.title = title
    }
}

@MainActor
public final class PrintWindowController: NSObject {

    /// Source of printer/cassette state and job submission. Injected by the host
    /// (the combined app injects a `LocalPrintBackend` wrapping PrinterManager; a
    /// standalone front-end would inject an `IPCPrintBackend`). Setting it (re)wires
    /// the status observer.
    public var backend: PrintBackend? {
        didSet { wireBackend() }
    }

    /// The most recent status pushed by the backend, used to translate printer +
    /// cassette state into the JSON shapes the web UI consumes.
    private var lastStatus: PrinterStatusFile?

    private var window: NSWindow?
    private var tabBar: BrowserTabBar?
    private var contentArea: NSView?

    /// One open export/reprint per tab, each with its own WKWebView (full live state).
    private var tabs: [PrintTab] = []
    private var activeID: String?
    private var activeTab: PrintTab? { tabs.first { $0.id == activeID } }

    // Back-compat accessors so the rest of the controller keeps operating on the ACTIVE
    // tab (the print/preview UI the user sees). Message handlers that can fire from a
    // background tab resolve the tab by message.webView instead.
    private var webView: WKWebView? { activeTab?.webView }
    private var records: [WireRecord] {
        get { activeTab?.records ?? [] }
        set { activeTab?.records = newValue }
    }
    private var sourceFileURL: URL? {
        get { activeTab?.sourceFileURL } set { activeTab?.sourceFileURL = newValue }
    }
    private var csvWritebackURL: URL? {
        get { activeTab?.csvWritebackURL } set { activeTab?.csvWritebackURL = newValue }
    }
    private var reprinting: RecentPrint? {
        get { activeTab?.reprinting } set { activeTab?.reprinting = newValue }
    }
    /// True while a template is being edited in the in-process designer (the print
    /// window is hidden). Guards a mid-edit export/reprint from re-showing it over
    /// the editor; cleared on return.
    private var isEditing = false

    // Pushes the shared record-column config (order/hidden/widths) into the web
    // view when it changes (e.g. the user reorders columns in the designer).
    private var columnObservers: Set<AnyCancellable> = []

    // Re-injects templates whenever the store changes, so the open print window
    // reflects edits made anywhere (standalone designer or edit-return).
    private var templatesObserver: AnyCancellable?

    // AutoPrint hosts this controller in its own process (no in-app catalog editor),
    // so it polls the Engine's on-disk catalog rather than the in-process store.
    private var catalogPollTimer: Timer?

    // The app that was frontmost before the print window appeared, so we can
    // return the user to it after the print starts.
    private var previousApp: NSRunningApplication?

    /// Called after a print is submitted: the window has closed and the caller
    /// should open the menu-bar popover so the user can watch printer status.
    public var onPrintStarted: (() -> Void)?

    /// Called when the user taps Edit on a template — the caller opens the
    /// Template Designer for that template (by list index; the print window
    /// stays open). Index, not id, because ids can be duplicated.
    public var onEditTemplate: ((Int) -> Void)?

    public override init() { super.init() }

    // MARK: – Backend wiring

    /// Subscribe to the backend's status changes and seed the current value. The
    /// backend emits its current status synchronously on `start()` (and again on
    /// every change), so a window opened before the first change still gets state.
    private func wireBackend() {
        guard let backend else { return }
        backend.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.lastStatus = status
            self.pushPrinters()
            self.pushCassettes()
        }
        if let s = backend.status {
            lastStatus = s
            pushPrinters()
            pushCassettes()
        }
    }

    // MARK: – Show / hide

    public func showForNewExport(fileURL: URL, records: [WireRecord]) {
        guard !isEditing else { return }   // don't interrupt an open template edit
        capturePreviousApp()
        openWindowIfNeeded()
        // New exports surface on the newest tab. If this export already has a tab open,
        // refresh it in place; otherwise open a new tab for it.
        if let existing = tabs.first(where: { $0.sourceFileURL == fileURL }) {
            flushWriteback(existing)
            existing.records = records
            existing.reprinting = nil
            existing.title = fileURL.lastPathComponent
            activateTab(existing.id)
            sendInitialState(for: existing)
        } else {
            addTab(records: records, sourceFileURL: fileURL, csvWritebackURL: fileURL,
                   reprinting: nil, title: fileURL.lastPathComponent)
        }
    }

    /// Remember the frontmost app (unless it's us) so we can return to it once
    /// the user starts a print.
    private func capturePreviousApp() {
        if window != nil { return }  // already open; keep the original previousApp
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApp = front
        }
    }

    public func showForReprint(_ recent: RecentPrint) {
        // Don't yank the window out from under an open template edit.
        guard !isEditing else { return }
        // Debounce duplicate Reprint taps: if a tab is already showing this record,
        // just focus it instead of opening another.
        if let existing = tabs.first(where: { $0.reprinting?.id == recent.id }) {
            activateTab(existing.id); return
        }
        capturePreviousApp()
        // Load the source CSV first; exports are pruned (recent prints are not), so
        // the file may be gone. Alert and abort rather than open an empty window.
        guard let (csv, url) = loadCSVForReprint(recent) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            // A cancelled-before-printing record (jobId=="") was never rendered, so
            // there is no done/<id>.json to fall back to — don't offer "Reprint
            // Without Editing", which could only fail.
            if recent.jobId.isEmpty {
                alert.messageText = "Can’t reprint"
                alert.informativeText = "This print was cancelled before any labels were rendered, and its source file “\(recent.sourceFileName)” is no longer available."
                alert.runModal()
                return
            }
            alert.messageText = "Source file not found"
            alert.informativeText = "The export “\(recent.sourceFileName)” is no longer in the Exports folder (it may have been pruned or moved). You can reprint the original labels without editing, or cancel."
            alert.addButton(withTitle: "Reprint Without Editing")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                if !PrintQueue().resubmitDoneJob(id: recent.jobId) {
                    ErrorReporter.showErrorAlert(
                        title: "Can’t reprint",
                        message: "The original print data for “\(recent.title)” is no longer available.",
                        details: nil, in: nil, appName: "Auto Print")
                }
            }
            return
        }
        openWindowIfNeeded()
        // Reprints open in their own tab (source URL nil so the recorded filename comes
        // from the reprint record; csvWritebackURL set so inline edits still persist).
        addTab(records: csv, sourceFileURL: nil, csvWritebackURL: url, reprinting: recent,
               title: recent.sourceFileName.isEmpty ? recent.title : recent.sourceFileName)
    }

    /// Close the ENTIRE print window (every tab) and return focus to the prior app.
    /// AutoPrint is a headless accessory app, so without the restore a ✕/cancel would
    /// dump the user to the Finder instead of back to their app.
    public func close() {
        flushAllWriteback()
        catalogPollTimer?.invalidate(); catalogPollTimer = nil   // stop the 2s disk poll
        columnObservers.removeAll()
        templatesObserver = nil
        for t in tabs { t.webView.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel") }
        tabs.removeAll(); activeID = nil
        window?.close()
        window = nil; tabBar = nil; contentArea = nil
        let prior = previousApp
        previousApp = nil
        prior?.activate()
    }

    // MARK: – Tabs

    /// A fresh WKWebView for a new tab: own message handler + HTML load. Observers that
    /// broadcast to every tab (printers/cassettes/templates/theme) are set up once in
    /// `openWindowIfNeeded`.
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let cc = WKUserContentController()
        cc.add(self, name: "vectorlabel")
        let theme = AppSettings.shared.isLight ? "light" : ""
        cc.addUserScript(WKUserScript(source: "document.documentElement.dataset.theme='\(theme)';",
                                      injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cc.addUserScript(WKUserScript(source: "window.__VL_BUILD__='\(BuildInfo.build)'; window.__VL_CATALOG__=\(SupplyCatalogStore.webCatalogJSON(forModel: ""));"
                                            + " window.__VL_PRINTER_GEOMETRY__=\(PrinterGeometry.webGeometryJSON());",
                                      injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = cc
        config.preferences.setValue(ProcessInfo.processInfo.environment["VL_DEV_HTML"] != nil, forKey: "developerExtrasEnabled")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        if let htmlURL = Self.findHTMLFile("VectorLabelPrint") ?? CoreResources.url("VectorLabelPrint", "html") {
            wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
        return wv
    }

    private func addTab(records: [WireRecord], sourceFileURL: URL?, csvWritebackURL: URL?,
                        reprinting: RecentPrint?, title: String) {
        let wv = makeWebView()
        let tab = PrintTab(webView: wv, records: records, sourceFileURL: sourceFileURL,
                           csvWritebackURL: csvWritebackURL, reprinting: reprinting, title: title)
        tabs.append(tab)
        if let area = contentArea {
            wv.translatesAutoresizingMaskIntoConstraints = false
            area.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                wv.topAnchor.constraint(equalTo: area.topAnchor),
                wv.bottomAnchor.constraint(equalTo: area.bottomAnchor)])
        }
        activateTab(tab.id)   // sendInitialState fires from didFinish once the HTML loads
    }

    private func activateTab(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeID = id
        for t in tabs { t.webView.isHidden = (t.id != id) }
        refreshTabBar()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func refreshTabBar() {
        tabBar?.setItems(tabs.map { .init(id: $0.id, title: $0.title) }, active: activeID)
    }

    /// Remove one tab (flushing its edits). Closing the last tab closes the window.
    private func closeTab(_ id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        flushWriteback(tab)
        tab.webView.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel")
        tab.webView.removeFromSuperview()
        tabs.remove(at: idx)
        if tabs.isEmpty { close(); return }
        activateTab(tabs[min(idx, tabs.count - 1)].id)
    }

    /// After a print or cancel: if several tabs are open, just close this one and leave
    /// the window; otherwise close the whole window exactly as before (return to the
    /// prior app, and after a print open the menu popover).
    private func dismissTabOrWindow(afterPrint: Bool, tabID: String? = nil) {
        // Several tabs open: close the SPECIFIC tab this action belongs to (for an async
        // print that's the tab that printed, not whatever happens to be active now).
        if tabs.count > 1 {
            let target = tabID ?? activeID
            if let id = target, tabs.contains(where: { $0.id == id }) { closeTab(id) }
            return
        }
        if afterPrint {
            let started = onPrintStarted
            let prior = previousApp; previousApp = nil
            close(); prior?.activate(); started?()
        } else {
            close()
        }
    }

    // MARK: – Window setup

    private func openWindowIfNeeded() {
        // Refresh templates from disk on every launch so renamed/added/removed
        // template files show up.
        TemplateStore.shared.reload()
        if let win = window {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        // ── Observers (set up ONCE; each broadcasts to every open tab). ──
        // Refresh templates whenever the store changes (any save anywhere).
        templatesObserver = TemplateStore.shared.$templates.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushTemplates() }
        // Push the EFFECTIVE light/dark theme live on any appearance change.
        AppSettings.shared.$appearance.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evalAll("if(typeof setTheme==='function')setTheme('\(AppSettings.shared.effectiveTheme)')") }
            .store(in: &columnObservers)
        AppSettings.shared.$systemAppearanceTick.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evalAll("if(typeof setTheme==='function')setTheme('\(AppSettings.shared.effectiveTheme)')") }
            .store(in: &columnObservers)
        // Live-sync the supply catalog (Engine: in-process observe; AutoPrint: disk poll).
        SupplyCatalogStore.shared.$catalog.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reinjectCatalog() }.store(in: &columnObservers)
        if Bundle.main.bundleIdentifier?.contains("autoprint") == true {
            catalogPollTimer?.invalidate()
            catalogPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if SupplyCatalogStore.reloadSnapshotFromDisk() { self?.reinjectCatalog() }
                }
            }
        }
        // Keep the column config in sync with the designer / persisted setting.
        AppSettings.shared.$recordColumnOrder.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushColumnConfig() }.store(in: &columnObservers)
        AppSettings.shared.$recordHiddenColumns.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushColumnConfig() }.store(in: &columnObservers)
        AppSettings.shared.$recordColumnWidths.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushColumnConfig() }.store(in: &columnObservers)

        // ── Window chrome: a tab bar over a content area that hosts the active tab's web view. ──
        let bar = BrowserTabBar(showsAdd: false)
        bar.onSelect = { [weak self] id in self?.activateTab(id) }
        bar.onClose  = { [weak self] id in self?.closeTab(id) }
        self.tabBar = bar
        let area = NSView(); area.translatesAutoresizingMaskIntoConstraints = false
        self.contentArea = area
        let container = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar); container.addSubview(area)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            area.topAnchor.constraint(equalTo: bar.bottomAnchor),
            area.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            area.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            area.bottomAnchor.constraint(equalTo: container.bottomAnchor)])

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        win.title = "VectorLabel — Print"
        win.contentView = container
        // Auto-launches when an export is detected while the user is in another app
        // (e.g. Vectorworks). Float above normal windows and don't hide on deactivate.
        win.level = .floating
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        win.applyVLSizing(autosaveName: "VLPrintWindow",
                          defaultContentSize: NSSize(width: 1180, height: 760))
        win.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    /// Called when the designer finishes editing for the print window: refocus
    /// the print window and refresh its template list (selection/task preserved).
    public func returnFromEdit() {
        isEditing = false
        guard window != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        pushTemplates()
    }

    /// "Cancel All" from the editor's unsaved-changes prompt: abandon the edit AND
    /// cancel the underlying print exactly as if the user had pressed ✕ Cancel in
    /// the print window — record it to Recent Prints (cancelled) and close. The
    /// window is hidden during edit but its JS state is intact, so trigger its own
    /// cancel flow.
    public func cancelFromEdit() {
        isEditing = false
        guard window != nil else { return }
        evalJS("if(typeof cancelAndClose==='function')cancelAndClose();")
    }

    /// Re-inject the current template list into the print window.
    private func pushTemplates() {
        guard let data = try? JSONEncoder().encode(TemplateStore.shared.templates),
              let json = String(data: data, encoding: .utf8) else { return }
        evalAll("if(typeof refreshTemplates==='function')refreshTemplates(\(json));")
    }

    // MARK: – Template persistence

    /// Persist a template edited in the print window's designer to
    /// ~/Documents/VectorLabel/Templates/. The JS payload is {id?, name, specN, objs}.
    private func saveTemplate(from payloadAny: Any?) {
        if !TemplateStore.shared.save(fromPayload: payloadAny) {
            ErrorReporter.showErrorAlert(
                title: "Couldn’t save the template",
                message: "Your changes have not been applied. Check that the disk isn’t full and that VectorLabel can write to ~/Documents/VectorLabel/Templates/.",
                details: nil, in: window, appName: "Auto Print")
        }
    }

    // MARK: – JS bridge: push data into the web view

    /// The printers from the latest backend status as [id,name,model,serial,status]
    /// dicts — the same shape the page consumes via updatePrinters / initPrintWindow.
    private func printerDicts() -> [[String: Any]] {
        (lastStatus?.printers ?? []).map { p in
            ["id": p.id, "name": p.name, "model": p.model, "serial": p.serial,
             "status": p.status, "supportsTelemetry": p.supportsTelemetry,
             "hasAutoCutter": p.hasAutoCutter, "ribbonLengthInches": p.ribbonLengthInches,
             "supportsFeedToClear": p.supportsFeedToClear,
             "cutOptions": p.cutOptions.map { ["mode": $0.mode.rawValue, "label": $0.label] }]
        }
    }

    /// The latest printer list as a JSON array string ("[]" when none).
    private func printersJSONString() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: printerDicts()),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Pushes the current printer list to the web view without resetting the
    /// user's record selection. No-ops when the page isn't loaded yet.
    private func pushPrinters() {
        evalAll("if(typeof updatePrinters==='function')updatePrinters(\(printersJSONString()));")
    }

    /// Detected cassette info keyed by printer id, as a JSON object string.
    /// Reproduced from each PrinterStatusEntry's CassetteStatus so the page sees
    /// the identical fields it did when this came straight from PrinterManager.
    private func cassettesJSONString() -> String {
        var dict: [String: [String: Any]] = [:]
        for p in lastStatus?.printers ?? [] {
            guard let c = p.cassette else { continue }
            dict[p.id] = c.webDict()   // shared mapping — see CassetteStatus+WebDict.swift
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) { return json }
        return "{}"
    }

    /// Push the current detected cassettes into the web view.
    private func pushCassettes() {
        evalAll("if(typeof updateCassettes==='function')updateCassettes(\(cassettesJSONString()));")
    }

    /// Push the shared column config (order/hidden/widths) into the web view.
    private func pushColumnConfig() {
        evalAll("if(typeof applyColumnConfig==='function')applyColumnConfig(\(AppSettings.shared.columnConfigJSON()));")
    }

    private func sendInitialState(for tab: PrintTab) {
        let wv = tab.webView

        let encoder = JSONEncoder()
        guard let recordsData  = try? encoder.encode(tab.records),
              let recordsJSON  = String(data: recordsData, encoding: .utf8),
              let templatesData = try? encoder.encode(TemplateStore.shared.templates),
              let templatesJSON = String(data: templatesData, encoding: .utf8)
        else { return }

        let printerJSON = printersJSONString()

        let sourceFile = tab.sourceFileURL?.lastPathComponent
            ?? tab.reprinting?.sourceFileName
            ?? "export.csv"

        // Build reprint settings if applicable
        var reprintJSON = "null"
        if let r = tab.reprinting,
           let data = try? encoder.encode(r),
           let s = String(data: data, encoding: .utf8) { reprintJSON = s }

        let js = """
        (function() {
          if (typeof initPrintWindow === 'function') {
            initPrintWindow({
              records: \(recordsJSON),
              templates: \(templatesJSON),
              printers: \(printerJSON),
              sourceFile: \(sourceFile.jsonQuoted),
              defaultTemplateID: \(AppSettings.shared.defaultTemplateID.jsonQuoted),
              cassettes: \(cassettesJSONString()),
              columnConfig: \(AppSettings.shared.columnConfigJSON()),
              filterSortPresets: \(AppSettings.shared.filterSortPresetsJSON),
              feedToClearByPrinter: \(AppSettings.shared.feedToClearByPrinterJSON()),
              feedToClearDefault: \(AppSettings.shared.feedToClearBeforePrint),
              reprint: \(reprintJSON)
            });
          }
          if (typeof setTheme === 'function') setTheme('\(AppSettings.shared.effectiveTheme)');
        })();
        """
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: – Reprint CSV reload

    private func loadCSVForReprint(_ recent: RecentPrint) -> ([WireRecord], URL)? {
        // Try to find the CSV in the exports tree
        let exportsRoot = AppSettings.shared.exportsFolderURL
        guard let enumerator = FileManager.default.enumerator(at: exportsRoot, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == recent.sourceFileName {
                if let recs = WireExportParser.parse(fileURL: url) { return (recs, url) }
                return nil
            }
        }
        return nil
    }

    /// Debounced persistence of one tab's inline edits to its source CSV — coalesces
    /// rapid edits into one write ~0.6 s after the last change. Per-tab so each export
    /// persists to its own file.
    private func scheduleWriteback(for tab: PrintTab) {
        tab.writebackWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let tab = tab else { return }
            self?.writeRecordsBackToCSV(tab)
        }
        tab.writebackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Write a tab's pending edit immediately (e.g. before it closes).
    private func flushWriteback(_ tab: PrintTab) {
        guard tab.writebackWork != nil else { return }
        tab.writebackWork?.cancel(); tab.writebackWork = nil
        writeRecordsBackToCSV(tab)
    }
    private func flushAllWriteback() { for t in tabs { flushWriteback(t) } }

    /// Persist a tab's `records` back to its source CSV, preserving column order. The
    /// snapshot is taken on the main actor; the header read + serialize + write run off
    /// the main thread so a large export doesn't block the UI.
    private func writeRecordsBackToCSV(_ tab: PrintTab) {
        guard let url = tab.csvWritebackURL else { return }
        let snapshot = tab.records   // value-type copy, safe to use off the main actor
        DispatchQueue.global(qos: .utility).async {
            // The column order MUST come from the existing header — never synthesize
            // one (a sorted-union fallback would reorder/drop columns). Abort if it
            // can't be read rather than write a malformed CSV.
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  let headers = WireExportParser.parseCSV(content).first, !headers.isEmpty else {
                print("[writeRecordsBackToCSV] aborting: could not read the source header from \(url.lastPathComponent)")
                return
            }
            let csv = WireExportParser.csvText(records: snapshot, headers: headers)
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // Surface the failure: the in-memory records (and the printed labels) now
                // differ from the on-disk CSV, so a later reprint would print stale values.
                NSLog("[writeRecordsBackToCSV] could not write inline edits back to \(url.lastPathComponent): \(error) — on-disk CSV now differs from what printed")
            }
        }
    }

    // MARK: – Dev HTML loader

    /// Finds an HTML file in the live repo checkout first, then falls back to the bundle.
    /// This ensures git pull changes are reflected without a full Xcode rebuild.
    static func findHTMLFile(_ name: String) -> URL? { return nil }
}

// MARK: – WKNavigationDelegate

extension PrintWindowController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }) { sendInitialState(for: tab) }
    }
    /// Recover from a WebKit content-process crash instead of leaving a blank window.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("[PrintWindowController] web content process terminated — reloading")
        webView.reload()
    }
}

// MARK: – WKScriptMessageHandler (JS → Swift messages)

extension PrintWindowController: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController,
                                       didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }
        // The tab whose web view sent this — a debounced record sync can fire just after
        // the user switches tabs, so edits route to the sender, not necessarily the active tab.
        let msgTab = tabs.first { $0.webView === message.webView }

        switch action {
        case "print":
            handlePrintAction(body["payload"], tabID: msgTab?.id ?? activeID)

        case "saveTemplate":
            saveTemplate(from: body["payload"])

        case "detectCassette":
            let printerID = (body["payload"] as? [String: Any])?["printerID"] as? String ?? ""
            if !printerID.isEmpty {
                backend?.requestCassetteRefresh(printerID: printerID)
            }

        case "editRecord":
            // Live in-place edit of a record field from the print window. Updates
            // the in-memory record (so the rendered/printed output reflects it) AND
            // persists it back to the source CSV via writeRecordsBackToCSV().
            if let tab = msgTab,
               let p = body["payload"] as? [String: Any],
               let index = p["index"] as? Int,
               let field = p["field"] as? String,
               let value = p["value"] as? String,
               index >= 0, index < tab.records.count {
                var f = tab.records[index].fields
                f[field] = value
                tab.records[index] = WireRecord(side: f["_Side"] ?? tab.records[index].side,
                                                wireID: f["Number"] ?? tab.records[index].wireID,
                                                fields: f)
                scheduleWriteback(for: tab)
            }

        case "syncRecords":
            // Bulk structural change (add row / paste / ripple / drag-fill): replace the
            // in-memory records from the full snapshot and persist to the source CSV. The
            // Print Window never adds columns — the column set is the source export's.
            if let tab = msgTab,
               let p = body["payload"] as? [String: Any],
               let rowDicts = p["records"] as? [[String: Any]] {
                tab.records = rowDicts.map { row in
                    var f: [String: String] = [:]
                    for (k, v) in row { f[k] = v as? String ?? String(describing: v) }
                    return WireRecord(side: f["_Side"] ?? "", wireID: f["Number"] ?? "", fields: f)
                }
                scheduleWriteback(for: tab)
            }

        case "clipboardWrite":
            // Free-edit copy: write the selection (TSV) to the system pasteboard.
            if let t = (body["payload"] as? [String: Any])?["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
        case "clipboardRead":
            // Free-edit paste: hand the page the pasteboard text (JSON-escaped).
            let t = NSPasteboard.general.string(forType: .string) ?? ""
            if let d = try? JSONEncoder().encode(t), let s = String(data: d, encoding: .utf8) {
                webView?.evaluateJavaScript("if(typeof feApplyPaste==='function')feApplyPaste(\(s));", completionHandler: nil)
            }

        case "openURL":
            // "Buy more" — open a bradyid.com supply URL in the system browser.
            // Only http(s) URLs are honored (never file:// or arbitrary schemes).
            if let urlStr = (body["payload"] as? [String: Any])?["url"] as? String,
               let url = URL(string: urlStr),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }

        case "setColumnConfig":
            AppSettings.shared.applyColumnConfigPayload(body["payload"])

        case "setFilterSortPresets":
            if let arr = body["payload"] as? [Any],
               let data = try? JSONSerialization.data(withJSONObject: arr),
               let json = String(data: data, encoding: .utf8) {
                AppSettings.shared.filterSortPresetsJSON = json
            }

        case "editTemplate":
            if let index = (body["payload"] as? [String: Any])?["index"] as? Int {
                // Hide the print window while editing; returnFromEdit() reshows it.
                isEditing = true
                window?.orderOut(nil)
                onEditTemplate?(index)
            }

        case "setDefaultTemplate":
            // payload {id, name} to set, or null to clear. Persists in AppSettings.
            if let payload = body["payload"] as? [String: Any],
               let id = payload["id"] as? String {
                AppSettings.shared.defaultTemplateID = id
            } else {
                AppSettings.shared.defaultTemplateID = ""
            }

        case "close":
            // ✕ Cancel sends cancelled=true plus the configured selection. Record it
            // as a CANCELLED Recent Print via the Engine (the recents owner), so it
            // shows in the menu and can be reopened/reprinted exactly like a print
            // that was sent. Skip when nothing was printable.
            if let payload = body["payload"] as? [String: Any],
               (payload["cancelled"] as? Bool) == true,
               let recordIndices = payload["recordIndices"] as? [Int], !recordIndices.isEmpty {
                recordCancelledPrint(payload: payload, recordIndices: recordIndices)
            }
            dismissTabOrWindow(afterPrint: false)

        case "ready":
            if let msgTab { sendInitialState(for: msgTab) }

        case "setFeedToClear":
            // Persist the feed-to-clear tick box PER PRINTER (key from the payload) so each
            // printer remembers its own choice across reopen.
            let payload = body["payload"] as? [String: Any]
            AppSettings.shared.setFeedToClear(forKey: (payload?["key"] as? String) ?? "",
                                              (payload?["value"] as? Bool) ?? false)

        case "jsError":
            // Uncaught error inside the WKWebView — log prominently and offer a report.
            let p = body["payload"] as? [String: Any] ?? [:]
            NSLog("[VL-JS-ERROR] \(p["msg"] ?? "") @ \(p["at"] ?? "") \(p["stack"] ?? "")")
            ErrorReporter.presentReport(
                title: "Print window script error",
                details: "\(p["msg"] ?? "") @ \(p["at"] ?? "")\n\(p["stack"] ?? "")",
                appName: "Auto Print")

        default:
            break
        }
    }

    /// Record a pre-submit cancellation as a cancelled Recent Print via the IPC
    /// cancelled channel (the Engine owns recents). Carries the same print-time
    /// state as a real print so Reprint re-opens this window in that state.
    private func recordCancelledPrint(payload: [String: Any], recordIndices: [Int]) {
        func jsonStr(_ v: Any?) -> String? {
            guard let v = v, JSONSerialization.isValidJSONObject(v),
                  let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        let source = sourceFileURL?.lastPathComponent ?? reprinting?.sourceFileName ?? ""
        let recent = RecentPrint(
            date: Date(),
            title: (payload["title"] as? String) ?? (source.isEmpty ? "Cancelled print" : source),
            sourceFileName: source,
            templateName: (payload["templateName"] as? String) ?? "",
            printerName: "",
            labelCount: recordIndices.count,
            printRange: RecentPrint.PrintRange(rawValue: (payload["printRange"] as? String) ?? "") ?? .selected,
            selectedIndices: recordIndices,
            status: .cancelledBeforePrinting,
            rangeFrom: payload["rangeFrom"] as? Int,
            rangeTo: payload["rangeTo"] as? Int,
            filterJSON: jsonStr(payload["filter"]),
            sortJSON: jsonStr(payload["sort"]),
            jobId: "",
            sourceApp: "autoprint"
        )
        do {
            try PrintQueue().writeCancelledRecent(recent)
        } catch {
            print("[PrintWindow] couldn't record cancellation: \(error)")
        }
    }

    private func handlePrintAction(_ payloadAny: Any?, tabID: String?) {
        guard let payload = payloadAny as? [String: Any],
              let printerID    = payload["printerID"]    as? String,
              let title        = payload["title"]        as? String,
              let templateName = payload["templateName"] as? String,
              let recordIndices = payload["recordIndices"] as? [Int],
              let templateID   = payload["templateID"]   as? String
        else { return }

        // Find the template
        guard let template = TemplateStore.shared.templates.first(where: { $0.id == templateID })
              ?? TemplateStore.shared.templates.first
        else { return }

        // When "inherit rack" is on, a blank-Rack side of a pair prints its
        // partner's rack in parentheses, e.g. "(RIO RACK)" — matching the preview.
        let inheritRack = (payload["sort"] as? [String: Any])?["inheritRack"] as? Bool ?? false
        func renderRecord(_ i: Int) -> WireRecord {
            let rec = records[i]
            guard inheritRack, (rec.fields["Rack"] ?? "").isEmpty else { return rec }
            var partner: Int? = nil
            if rec.side == "Source", i + 1 < records.count, records[i + 1].side == "Destination" { partner = i + 1 }
            else if rec.side == "Destination", i - 1 >= 0, records[i - 1].side == "Source" { partner = i - 1 }
            guard let p = partner, let prack = records[p].fields["Rack"], !prack.isEmpty else { return rec }
            var f = rec.fields; f["Rack"] = "(" + prack + ")"
            return WireRecord(side: rec.side, wireID: rec.wireID, fields: f)
        }

        // Render VGL jobs
        let selectedRecords = recordIndices.compactMap { i -> WireRecord? in
            guard i >= 0 && i < records.count else { return nil }
            return renderRecord(i)
        }

        // Per-printer calibration offset (keyed by the printer's serial).
        let serial = printerID.split(separator: ":").dropFirst(2).joined(separator: ":")
        let offset = AppSettings.shared.calibrationOffset(forSerial: serial)
        // Loaded part number, so the renderer can pick its feed rotation when two
        // parts of one supply rotate differently on the roll.
        let loadedCassette = backend?.status?.printers.first(where: { $0.id == printerID })?.cassette
        let loadedPN = loadedCassette?.partNumber
        // When the loaded stock is CONTINUOUS but the template is die-cut, hand the
        // renderer the loaded tape's printable width so it re-maps the die-cut design
        // onto the tape (rotate along the feed + scale to fill the width). nil otherwise
        // (die-cut→die-cut and continuous templates render normally).
        let continuousTargetWidthInches: Double? = {
            guard let c = loadedCassette, c.isContinuous == true, c.printableWidthMils > 0 else { return nil }
            return Double(c.printableWidthMils) / 1000.0
        }()

        // Cut SETTING chosen in the print header (Phase 6). Falls back to the
        // sensible default the JS picks per stock (continuous → eachLabel; die-cut
        // → never; else afterJobLast). Carried into PrintJobFile.cutMode; the Engine's
        // printer module stamps the per-label cut at ENCODE time — this front-end ships
        // printer-agnostic rasters, not VGL.
        let cutMode = CutMode(rawValue: (payload["cutMode"] as? String) ?? "") ?? .afterJobLast
        // "Feed to clear before printing" — prepend a blank lead label (built below).
        let feedToClear = (payload["feedToClear"] as? Bool) ?? false

        // Capture the print-time state (main actor) so a later Reprint can re-open
        // this window with the same source, selection, and filter/sort.
        func jsonStr(_ v: Any?) -> String? {
            guard let v = v, JSONSerialization.isValidJSONObject(v),
                  let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        let reprintInfo = ReprintInfo(
            sourceFileName: sourceFileURL?.lastPathComponent ?? reprinting?.sourceFileName ?? "",
            selectedIndices: recordIndices,
            printRange: (payload["printRange"] as? String) ?? "selected",
            rangeFrom: payload["rangeFrom"] as? Int,
            rangeTo: payload["rangeTo"] as? Int,
            filterJSON: jsonStr(payload["filter"]),
            sortJSON: jsonStr(payload["sort"])
        )

        // Recent Prints are recorded by the Engine (the only process that prints),
        // not here — see VectorLabelEngineApp.consumeResolved. Render the
        // (potentially large) batch OFF the main thread so the UI doesn't freeze,
        // and submit back on the main actor.
        DispatchQueue.global(qos: .userInitiated).async {
            // Render first, dropping any record that produces no raster. The cut
            // index MUST be keyed over the labels actually EMITTED — if we keyed it
            // to `selectedRecords.count - 1` and the final record rendered nil, the
            // afterJobLast end-of-job cut would land on a label that never goes out
            // and be lost. (DesignerWindowController computes its cut over `rasters`
            // for the same reason.)
            var rasters: [(pixels: [UInt8], width: Int, height: Int, landscape: Bool)] = []
            var labelPx = 0   // longest rendered dimension (px) → print-length estimate
            for record in selectedRecords {
                guard let rendered = LabelRenderer.render(template: template, record: record, offset: offset,
                                                          loadedPartNumber: loadedPN,
                                                          continuousTargetWidthInches: continuousTargetWidthInches) else { continue }
                labelPx = max(labelPx, max(rendered.width, rendered.height))
                rasters.append(rendered)
            }
            // Wrap each raster as a model-agnostic RenderedLabel; the Engine encodes it
            // for the target printer (VGL for the M610, bitmap/LZ4 for the M611) at print
            // time, stamping the per-label cut from `cutMode`.
            let part = loadedPN ?? template.labelSize?.partNumber ?? ""
            var renderedLabels: [RenderedLabel] = []
            renderedLabels.reserveCapacity(rasters.count)
            for rendered in rasters {
                renderedLabels.append(RenderedLabel(pixels: rendered.pixels, width: rendered.width,
                                                    height: rendered.height, partNumber: part,
                                                    landscape: rendered.landscape))
            }
            // Feed-to-clear: the Engine synthesizes + prepends the blank lead label at print
            // time (from live media + the real label geometry), so we only flag the job here.
            // Estimate per-label print time from the label's print length. Calibrated
            // to measured hardware: a 1.5" label (~450 px @ 300 dpi) prints in ~0.85 s.
            let estLabelMs = RenderedLabel.estimatedPrintMs(maxDimensionPx: labelPx)

            Task { @MainActor in
                guard !renderedLabels.isEmpty else {
                    // Nothing rendered (e.g. every selected record failed to render). Dismiss
                    // the "Printing…" modal so the window isn't stuck on a dead spinner, and
                    // tell the user, instead of returning silently.
                    self.evalJS("if(typeof cancelPrint==='function')cancelPrint()")
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Nothing to print"
                    alert.informativeText = "None of the selected records produced a printable label. Check the template and the selected rows, then try again."
                    alert.addButton(withTitle: "OK")
                    if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
                    return
                }
                // Hand the rendered batch to the print backend as a PrintJobFile. The
                // front-end is printer-agnostic — it submits rasters; the Engine encodes.
                let job = PrintJobFile(
                    id: UUID().uuidString,
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    sourceApp: "autoprint",
                    title: title,
                    templateName: templateName,
                    printerID: printerID,
                    copies: 1,
                    cutMode: cutMode,
                    estLabelMs: estLabelMs,
                    renderedLabels: renderedLabels,
                    reprint: reprintInfo,
                    feedToClear: feedToClear
                )
                do {
                    try self.backend?.submit(job)
                } catch {
                    // Submit failed (disk full / permissions / encode): the job was NOT
                    // queued, so do NOT close the window or signal "print started".
                    // Tell the user and keep the window open to retry. (F26)
                    NSLog("[PrintWindowController] submit failed: \(error)")
                    self.evalJS("if(typeof cancelPrint==='function')cancelPrint()")   // dismiss the stuck Printing… modal
                    ErrorReporter.showErrorAlert(
                        title: "Couldn’t start the print",
                        message: "The job could not be queued: \(error.localizedDescription)\n\nNothing was sent to the printer. Please try again.",
                        details: "\(error)", in: self.window, appName: "Auto Print")
                    return
                }
                // The print has started. With several tabs open, close the tab that PRINTED
                // (resolved when print was pressed — the render is async, so the user may have
                // switched tabs); with a single tab, close the window, return to the prior app,
                // and pop the menu so the user can watch the queue.
                self.dismissTabOrWindow(afterPrint: true, tabID: tabID)
            }
        }
    }

    private func evalJS(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
    /// Run JS in EVERY open tab — for status / theme / catalog broadcasts that all tabs show.
    private func evalAll(_ js: String) {
        for t in tabs { t.webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    /// Push the latest supply catalog into the print web UI (live editor sync).
    private func reinjectCatalog() {
        let json = SupplyCatalogStore.webCatalogJSON(forModel: "")
        evalAll("window.__VL_CATALOG__=\(json); if(typeof applyCatalog==='function')applyCatalog(window.__VL_CATALOG__);")
    }
}

// MARK: – NSWindowDelegate

extension PrintWindowController: NSWindowDelegate {
    /// The window's ✕ closes ALL tabs. Confirm first when more than one is open.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if tabs.count > 1 {
            let alert = NSAlert()
            alert.messageText = "Close all \(tabs.count) tabs?"
            alert.informativeText = "This closes every open export in the print window."
            alert.addButton(withTitle: "Close All")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        return true   // windowWillClose does the teardown
    }

    public func windowWillClose(_ notification: Notification) {
        flushAllWriteback()   // persist any debounced inline edits
        catalogPollTimer?.invalidate(); catalogPollTimer = nil   // stop the 2s disk poll
        columnObservers.removeAll()
        templatesObserver = nil
        for t in tabs { t.webView.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel") }
        tabs.removeAll(); activeID = nil
        window = nil; tabBar = nil; contentArea = nil
        // Return focus to the app that was frontmost when the window appeared — EVERY close
        // path funnels through here, including the title-bar ✕ (AutoPrint is a headless
        // accessory, so otherwise the user is dropped to the Finder). The afterPrint / close()
        // paths nil previousApp before triggering the close, so this is a no-op for them.
        let prior = previousApp; previousApp = nil
        prior?.activate()
    }
}
