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
    private var webView: WKWebView?

    // Data to pass into the print window
    private var records: [WireRecord] = []
    private var sourceFileURL: URL?
    // The CSV on disk that `records` came from — used to persist inline edits.
    // Tracked separately from sourceFileURL (which is cleared on reprint).
    private var csvWritebackURL: URL?
    private var reprinting: RecentPrint?
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
        flushWriteback()                   // persist any pending inline edit first
        capturePreviousApp()
        self.records = records
        self.sourceFileURL = fileURL
        self.csvWritebackURL = fileURL
        self.reprinting = nil
        openWindowIfNeeded()
        sendInitialState()
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
        // Debounce duplicate Reprint taps: if we're already showing this record,
        // just refocus instead of rebuilding the window.
        if window != nil, reprinting?.id == recent.id {
            NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil); return
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
                    let e = NSAlert()
                    e.messageText = "Can’t reprint"
                    e.informativeText = "The original print data for “\(recent.title)” is no longer available."
                    e.alertStyle = .warning
                    e.runModal()
                }
            }
            return
        }
        flushWriteback()   // persist any pending inline edit before swapping records
        self.reprinting = recent
        // Clear any stale export URL so the recorded source filename comes from
        // the reprint record, not a previously-opened export.
        self.sourceFileURL = nil
        self.records = csv
        self.csvWritebackURL = url   // allow inline edits to persist on reprint too
        openWindowIfNeeded()
        sendInitialState()
    }

    public func close() {
        flushWriteback()   // persist any debounced inline edit before tearing down
        catalogPollTimer?.invalidate(); catalogPollTimer = nil   // stop the 2s disk poll
        columnObservers.removeAll()
        templatesObserver = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel")
        window?.close()
        window = nil
        webView = nil
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

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(self, name: "vectorlabel")
        // Set the theme before first paint so reopening after a theme change
        // doesn't flash the old colors.
        let theme = AppSettings.shared.isLight ? "light" : ""
        contentController.addUserScript(WKUserScript(
            source: "document.documentElement.dataset.theme='\(theme)';",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Inject the editable supply catalog before the page's BL table is built.
        contentController.addUserScript(WKUserScript(
            source: "window.__VL_BUILD__='\(BuildInfo.build)'; window.__VL_CATALOG__=\(SupplyCatalogStore.webCatalogJSON(forModel: ""));",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        // Live printer-list + cassette changes now arrive via the PrintBackend's
        // onStatusChange (wired in wireBackend()), which translates the Engine's
        // PrinterStatusFile into the same JSON the page already consumes. A window
        // opened before the first status still gets state from the seeded value.

        // Refresh templates whenever the store changes (any save anywhere).
        templatesObserver = TemplateStore.shared.$templates.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushTemplates() }

        // Push the EFFECTIVE light/dark theme live on any appearance change,
        // including the OS flipping while in "system" mode.
        AppSettings.shared.$appearance.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evalJS("if(typeof setTheme==='function')setTheme('\(AppSettings.shared.effectiveTheme)')") }
            .store(in: &columnObservers)
        AppSettings.shared.$systemAppearanceTick.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evalJS("if(typeof setTheme==='function')setTheme('\(AppSettings.shared.effectiveTheme)')") }
            .store(in: &columnObservers)

        // Live-sync the supply catalog. In the Engine process the editor lives
        // in-process, so observing the store catches edits immediately.
        SupplyCatalogStore.shared.$catalog.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reinjectCatalog() }.store(in: &columnObservers)
        // In AutoPrint (a separate process with no editor) the observation above never
        // fires, so poll the on-disk catalog like the designers do. The Engine must
        // NOT poll — its in-process snapshot is authoritative, and a poll could read
        // the file mid-write and revert a fresh edit; it relies on the observation.
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

        // Prefer live repo file during development so git pull is reflected immediately
        let htmlURL = Self.findHTMLFile("VectorLabelPrint")
            ?? CoreResources.url("VectorLabelPrint", "html")
        guard let htmlURL = htmlURL else { return }
        // Grant access to the parent directory so WKWebView can read the file.
        // For repo files, grant access up to MacApp/ so any relative resources work.
        let accessURL = htmlURL.deletingLastPathComponent()
        wv.loadFileURL(htmlURL, allowingReadAccessTo: accessURL)

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        win.title = "VectorLabel — Print"
        win.contentView = wv
        // Auto-launches when an export is detected while the user is in another
        // app (e.g. Vectorworks). Float above normal windows and don't hide on
        // deactivate so it stays in the front layer instead of appearing behind.
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
        evalJS("if(typeof refreshTemplates==='function')refreshTemplates(\(json));")
    }

    // MARK: – Template persistence

    /// Persist a template edited in the print window's designer to
    /// ~/Documents/VectorLabel/Templates/. The JS payload is {id?, name, specN, objs}.
    private func saveTemplate(from payloadAny: Any?) {
        TemplateStore.shared.save(fromPayload: payloadAny)
    }

    // MARK: – JS bridge: push data into the web view

    /// The printers from the latest backend status as [id,name,model,serial,status]
    /// dicts — the same shape the page consumes via updatePrinters / initPrintWindow.
    private func printerDicts() -> [[String: Any]] {
        (lastStatus?.printers ?? []).map { p in
            ["id": p.id, "name": p.name, "model": p.model, "serial": p.serial,
             "status": p.status, "supportsTelemetry": p.supportsTelemetry,
             "hasAutoCutter": p.hasAutoCutter, "ribbonLengthInches": p.ribbonLengthInches]
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
        evalJS("if(typeof updatePrinters==='function')updatePrinters(\(printersJSONString()));")
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
        evalJS("if(typeof updateCassettes==='function')updateCassettes(\(cassettesJSONString()));")
    }

    /// Push the shared column config (order/hidden/widths) into the web view.
    private func pushColumnConfig() {
        evalJS("if(typeof applyColumnConfig==='function')applyColumnConfig(\(AppSettings.shared.columnConfigJSON()));")
    }

    private func sendInitialState() {
        guard let wv = webView else { return }

        let encoder = JSONEncoder()
        guard let recordsData  = try? encoder.encode(records),
              let recordsJSON  = String(data: recordsData, encoding: .utf8),
              let templatesData = try? encoder.encode(TemplateStore.shared.templates),
              let templatesJSON = String(data: templatesData, encoding: .utf8)
        else { return }

        let printerJSON = printersJSONString()

        let sourceFile = sourceFileURL?.lastPathComponent
            ?? reprinting?.sourceFileName
            ?? "export.csv"

        // Build reprint settings if applicable
        var reprintJSON = "null"
        if let r = reprinting,
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
              feedToClear: \(AppSettings.shared.feedToClearBeforePrint),
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

    private var writebackWork: DispatchWorkItem?

    /// Debounced persistence of inline edits to the source CSV — coalesces rapid
    /// edits into one write ~0.6 s after the last change instead of rewriting the
    /// whole file on every keystroke-commit. Call `flushWriteback()` on close.
    private func scheduleWriteback() {
        writebackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeRecordsBackToCSV() }
        writebackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Write any pending edit immediately (e.g. before the window closes).
    private func flushWriteback() {
        guard writebackWork != nil else { return }
        writebackWork?.cancel(); writebackWork = nil
        writeRecordsBackToCSV()
    }

    /// Persist `records` back to the source CSV, preserving its column order. The
    /// records snapshot is taken on the main actor; the header read + serialize +
    /// write run off the main thread so a large export doesn't block the UI.
    private func writeRecordsBackToCSV() {
        guard let url = csvWritebackURL else { return }
        let snapshot = records   // value-type copy, safe to use off the main actor
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
            try? csv.write(to: url, atomically: true, encoding: .utf8)
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
        sendInitialState()
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

        switch action {
        case "print":
            handlePrintAction(body["payload"])

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
            if let p = body["payload"] as? [String: Any],
               let index = p["index"] as? Int,
               let field = p["field"] as? String,
               let value = p["value"] as? String,
               index >= 0, index < records.count {
                var f = records[index].fields
                f[field] = value
                records[index] = WireRecord(side: f["_Side"] ?? records[index].side,
                                            wireID: f["Number"] ?? records[index].wireID,
                                            fields: f)
                scheduleWriteback()
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
            close()

        case "ready":
            sendInitialState()

        case "setFeedToClear":
            // Persist the "feed to clear before printing" tick box so it survives reopen.
            AppSettings.shared.feedToClearBeforePrint =
                ((body["payload"] as? [String: Any])?["value"] as? Bool) ?? false

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

    private func handlePrintAction(_ payloadAny: Any?) {
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
        let loadedPN = backend?.status?.printers.first(where: { $0.id == printerID })?.cassette?.partNumber

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
            var rasters: [(pixels: [UInt8], width: Int, height: Int)] = []
            var labelPx = 0   // longest rendered dimension (px) → print-length estimate
            for record in selectedRecords {
                guard let rendered = LabelRenderer.render(template: template, record: record, offset: offset, loadedPartNumber: loadedPN) else { continue }
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
                                                    height: rendered.height, partNumber: part))
            }
            // Feed-to-clear: the Engine synthesizes + prepends the blank lead label at print
            // time (from live media + the real label geometry), so we only flag the job here.
            // Estimate per-label print time from the label's print length. Calibrated
            // to measured hardware: a 1.5" label (~450 px @ 300 dpi) prints in ~0.85 s.
            let estLabelMs = RenderedLabel.estimatedPrintMs(maxDimensionPx: labelPx)

            Task { @MainActor in
                guard !renderedLabels.isEmpty else { return }   // nothing printable — keep window open
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
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t start the print"
                    alert.informativeText = "The job could not be queued: \(error.localizedDescription)\n\nNothing was sent to the printer. Please try again."
                    alert.addButton(withTitle: "OK")
                    if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
                    return
                }
                // The print has started: close the window, return to the prior app,
                // and pop the menu so the user can watch the queue. Live job outcome
                // (complete / cancelled / failed) is now tracked by the Engine's menu
                // bar, not this window.
                let started = self.onPrintStarted
                let prior = self.previousApp
                self.previousApp = nil
                self.close()
                prior?.activate()
                started?()
            }
        }
    }

    private func evalJS(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Push the latest supply catalog into the print web UI (live editor sync).
    private func reinjectCatalog() {
        let json = SupplyCatalogStore.webCatalogJSON(forModel: "")
        evalJS("window.__VL_CATALOG__=\(json); if(typeof applyCatalog==='function')applyCatalog(window.__VL_CATALOG__);")
    }
}

// MARK: – NSWindowDelegate

extension PrintWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        flushWriteback()   // persist any debounced inline edit
        catalogPollTimer?.invalidate(); catalogPollTimer = nil   // stop the 2s disk poll
        columnObservers.removeAll()
        templatesObserver = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel")
        webView = nil
        window = nil
    }
}
