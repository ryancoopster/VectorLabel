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
        capturePreviousApp()
        // Load the source CSV first; exports are pruned (recent prints are not), so
        // the file may be gone. Alert and abort rather than open an empty window.
        guard let (csv, url) = loadCSVForReprint(recent) else {
            let alert = NSAlert()
            alert.messageText = "Can’t reprint — source file not found"
            alert.informativeText = "The export “\(recent.sourceFileName)” is no longer in the Exports folder (it may have been pruned or moved)."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
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
            source: "window.__VL_CATALOG__=\(SupplyCatalogStore.webCatalogJSON(forModel: ""));",
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
        guard window != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        pushTemplates()
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
    private func printerDicts() -> [[String: String]] {
        (lastStatus?.printers ?? []).map { p in
            ["id": p.id, "name": p.name, "model": p.model, "serial": p.serial,
             "status": p.status]
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
            var entry: [String: Any] = [
                "partNumber": c.partNumber,
                "labelWidthMils": c.labelWidthMils,
                "labelHeightMils": c.labelHeightMils,
                "isDieCut": c.isDieCut,
                "supplyRemainingPct": c.supplyRemainingPct,
                "pixelWidth": c.pixelWidth,
                "pixelHeight": c.pixelHeight,
            ]
            // Prefer the value the Engine already resolved; fall back to the local
            // catalog so the field is present even on an older status file.
            if let perRoll = c.labelsPerRoll ?? BradyCatalog.labelsPerRoll(forPartNumber: c.partNumber) {
                entry["labelsPerRoll"] = perRoll
            }
            dict[p.id] = entry
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
            // Recent Prints are owned and recorded entirely by the Engine (the only
            // process that prints) — see VectorLabelEngineApp.consumeResolved. A
            // ✕ Cancel before submitting therefore records nothing here: the job
            // never reached the Engine, and writing to this process's own
            // RecentPrintsStore would not appear in the menu bar (a separate
            // process's store) and could clobber the Engine's history file.
            close()

        case "ready":
            sendInitialState()

        default:
            break
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
        // → never; else afterJobLast). Carried into PrintJobFile.cutMode AND baked
        // into each label's VGL via BradyVGL.vglCutMode.
        let cutMode = CutMode(rawValue: (payload["cutMode"] as? String) ?? "") ?? .afterJobLast

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
            let total = rasters.count
            var jobs: [[UInt8]] = []
            jobs.reserveCapacity(total)
            for (i, rendered) in rasters.enumerated() {
                let vglCut = BradyVGL.vglCutMode(forIPCRawValue: cutMode.rawValue, index: i, total: total)
                jobs.append(BradyVGL.buildPrintJob(pixels: rendered.pixels, width: rendered.width,
                                                   height: rendered.height, cutMode: vglCut))
            }
            // Estimate per-label print time from the label's print length. Calibrated
            // to measured hardware: a 1.5" label (~450 px @ 300 dpi) prints in ~0.85 s.
            let estLabelMs = Int(Double(labelPx) / 300.0 * 370.0) + 300

            Task { @MainActor in
                guard !jobs.isEmpty else { return }   // nothing printable — keep window open
                // Hand the rendered batch to the print backend as a PrintJobFile.
                // The combined app's LocalPrintBackend forwards it to PrinterManager
                // exactly as before; a standalone front-end would write it to the
                // IPC queue for the Engine to print.
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
                    labels: jobs.map { Data($0) }
                )
                do {
                    try self.backend?.submit(job)
                } catch {
                    print("[PrintWindowController] submit failed: \(error)")
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
        columnObservers.removeAll()
        templatesObserver = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel")
        webView = nil
        window = nil
    }
}
