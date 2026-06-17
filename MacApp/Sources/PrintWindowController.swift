import AppKit
import WebKit
import SwiftUI
import Combine
import UserNotifications

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
final class PrintWindowController: NSObject {

    private var window: NSWindow?
    private var webView: WKWebView?

    // Data to pass into the print window
    private var records: [WireRecord] = []
    private var sourceFileURL: URL?
    // The CSV on disk that `records` came from — used to persist inline edits.
    // Tracked separately from sourceFileURL (which is cleared on reprint).
    private var csvWritebackURL: URL?
    private var reprinting: RecentPrint?

    // Observes the active PrintJob so we can drive the web view's progress UI.
    private var jobObservers: Set<AnyCancellable> = []

    // Keeps the print window's printer dropdown in sync with the live USB scan.
    // Without this, a window opened before the scan finishes shows no printers.
    private var printerObserver: AnyCancellable?

    // Pushes detected cassette (SmartCell) info into the web view as it updates.
    private var cassetteObserver: AnyCancellable?

    // Pushes the shared record-column config (order/hidden/widths) into the web
    // view when it changes (e.g. the user reorders columns in the designer).
    private var columnObservers: Set<AnyCancellable> = []

    // Re-injects templates whenever the store changes, so the open print window
    // reflects edits made anywhere (standalone designer or edit-return).
    private var templatesObserver: AnyCancellable?

    // Recent-print record for the job submitted this session, so its status can
    // be updated (printing → complete / cancelled-mid-print). nil until Print is
    // clicked; while nil, a ✕ Cancel records a "cancelled before printing" entry.
    private var currentRecentPrintID: UUID?

    // Long-lived observers that update a Recent Print's status when its job
    // finishes. Kept here (not in jobObservers) so they survive the window
    // closing immediately after the print starts.
    private var printStatusObservers: Set<AnyCancellable> = []

    // The app that was frontmost before the print window appeared, so we can
    // return the user to it after the print starts.
    private var previousApp: NSRunningApplication?

    /// Called after a print is submitted: the window has closed and the caller
    /// should open the menu-bar popover so the user can watch printer status.
    var onPrintStarted: (() -> Void)?

    /// Called when the user taps Edit on a template — the caller opens the
    /// Template Designer for that template (by list index; the print window
    /// stays open). Index, not id, because ids can be duplicated.
    var onEditTemplate: ((Int) -> Void)?

    // MARK: – Show / hide

    func showForNewExport(fileURL: URL, records: [WireRecord]) {
        capturePreviousApp()
        self.records = records
        self.sourceFileURL = fileURL
        self.csvWritebackURL = fileURL
        self.reprinting = nil
        self.currentRecentPrintID = nil
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

    func showForReprint(_ recent: RecentPrint) {
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
        self.currentRecentPrintID = nil
        // Clear any stale export URL so the recorded source filename comes from
        // the reprint record, not a previously-opened export.
        self.sourceFileURL = nil
        self.records = csv
        self.csvWritebackURL = url   // allow inline edits to persist on reprint too
        openWindowIfNeeded()
        sendInitialState()
    }

    func close() {
        flushWriteback()   // persist any debounced inline edit before tearing down
        jobObservers.removeAll()
        printerObserver = nil
        cassetteObserver = nil
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
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        // Push live printer-list changes into the web view. $printers emits its
        // current value immediately and again on every scan change, so a window
        // opened before the USB scan finishes still gets printers when they appear.
        printerObserver = PrinterManager.shared.$printers
            .receive(on: RunLoop.main)
            .sink { [weak self] printers in self?.pushPrinters(printers) }

        // Push detected cassette info as it changes (auto-detect or manual).
        cassetteObserver = PrinterManager.shared.$cassettes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushCassettes() }

        // Report the outcome of a user-initiated "Detect supply" so the page can
        // show success/failure/busy instead of the toast quietly fading.
        PrinterManager.shared.onForcedDetectResult = { [weak self] _, ok, busy in
            self?.evalJS("if(typeof cassetteDetectResult==='function')cassetteDetectResult(\(ok),\(busy));")
        }

        // Refresh templates whenever the store changes (any save anywhere).
        templatesObserver = TemplateStore.shared.$templates.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushTemplates() }

        // Push the light/dark theme live whenever it changes.
        AppSettings.shared.$appearance.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] mode in self?.evalJS("if(typeof setTheme==='function')setTheme('\(mode)')") }
            .store(in: &columnObservers)

        // Keep the column config in sync with the designer / persisted setting.
        AppSettings.shared.$recordColumnOrder.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushColumnConfig() }.store(in: &columnObservers)
        AppSettings.shared.$recordHiddenColumns.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushColumnConfig() }.store(in: &columnObservers)
        AppSettings.shared.$recordColumnWidths.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushColumnConfig() }.store(in: &columnObservers)

        // Prefer live repo file during development so git pull is reflected immediately
        let htmlURL = Self.findHTMLFile("VectorLabelPrint")
            ?? Bundle.module.url(forResource: "VectorLabelPrint", withExtension: "html")
            ?? Bundle.main.url(forResource: "VectorLabelPrint", withExtension: "html")
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
    func returnFromEdit() {
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

    /// Pushes the current printer list to the web view without resetting the
    /// user's record selection. No-ops when the page isn't loaded yet.
    private func pushPrinters(_ printers: [PrinterDevice]) {
        let dicts = printers.map { p -> [String: String] in
            ["id": p.id, "name": p.name, "model": p.model, "serial": p.serial,
             "status": p.status.rawValue]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dicts),
              let json = String(data: data, encoding: .utf8)
        else { return }
        evalJS("if(typeof updatePrinters==='function')updatePrinters(\(json));")
    }

    /// Detected cassette info keyed by printer id, as a JSON object string.
    private func cassettesJSONString() -> String {
        var dict: [String: [String: Any]] = [:]
        for (id, c) in PrinterManager.shared.cassettes {
            var entry: [String: Any] = [
                "partNumber": c.partNumber,
                "labelWidthMils": c.labelWidthMils,
                "labelHeightMils": c.labelHeightMils,
                "isDieCut": c.isDieCut,
                "supplyRemainingPct": c.supplyRemainingPct,
                "pixelWidth": c.pixelWidth,
                "pixelHeight": c.pixelHeight,
            ]
            if let perRoll = BradyCatalog.labelsPerRoll(forPartNumber: c.partNumber) {
                entry["labelsPerRoll"] = perRoll
            }
            dict[id] = entry
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

        let printerJSON: String
        let printerDicts = PrinterManager.shared.printers.map { p -> [String: String] in
            ["id": p.id, "name": p.name, "model": p.model, "serial": p.serial,
             "status": p.status.rawValue]
        }
        if let data = try? JSONSerialization.data(withJSONObject: printerDicts),
           let s = String(data: data, encoding: .utf8) { printerJSON = s }
        else { printerJSON = "[]" }

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
          if (typeof setTheme === 'function') setTheme('\(AppSettings.shared.appearance)');
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sendInitialState()
    }
}

// MARK: – WKScriptMessageHandler (JS → Swift messages)

extension PrintWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
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
                PrinterManager.shared.refreshCassette(for: printerID, force: true)
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
            // The ✕ Cancel button sends the configured job flagged cancelled so
            // it's still saved to Recent Prints (for reprint), even though it was
            // never printed. Skip when there's nothing printable, or when a print
            // was already submitted this session (that record tracks its own
            // status via observePrintJob, so don't add a duplicate).
            if currentRecentPrintID == nil,
               let payload = body["payload"] as? [String: Any],
               payload["cancelled"] as? Bool == true,
               let indices = payload["recordIndices"] as? [Int], !indices.isEmpty,
               let recent = makeRecentPrint(from: payload, labelCount: indices.count,
                                            status: .cancelledBeforePrinting) {
                RecentPrintsStore.shared.add(recent)
            }
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

        // Build the Recent Print record up front (on the main actor — it reads
        // window state). Then render the (potentially large) batch OFF the main
        // thread so the UI doesn't freeze, and submit back on the main actor.
        let recent = makeRecentPrint(from: payload, labelCount: selectedRecords.count, status: .printing)
        DispatchQueue.global(qos: .userInitiated).async {
            var jobs: [[UInt8]] = []
            var labelPx = 0   // longest rendered dimension (px) → print-length estimate
            for record in selectedRecords {
                guard let rendered = LabelRenderer.render(template: template, record: record, offset: offset) else { continue }
                labelPx = max(labelPx, max(rendered.width, rendered.height))
                jobs.append(BradyVGL.buildPrintJob(pixels: rendered.pixels, width: rendered.width, height: rendered.height))
            }
            // Estimate per-label print time from the label's print length. Calibrated
            // to measured hardware: a 1.5" label (~450 px @ 300 dpi) prints in ~0.85 s.
            let estLabelMs = Int(Double(labelPx) / 300.0 * 370.0) + 300

            Task { @MainActor in
                guard !jobs.isEmpty else { return }   // nothing printable — keep window open
                let job = PrinterManager.shared.submit(
                    jobs: jobs, title: title, templateName: templateName,
                    printerID: printerID, estLabelMs: estLabelMs
                )
                if let recent = recent {
                    self.currentRecentPrintID = recent.id
                    RecentPrintsStore.shared.add(recent)
                    self.trackPrintStatus(job: job, recentID: recent.id)
                }
                // The print has started: close the window, return to the prior app,
                // and pop the menu so the user can watch the queue.
                let started = self.onPrintStarted
                let prior = self.previousApp
                self.previousApp = nil
                self.close()
                prior?.activate()
                started?()
            }
        }
    }

    /// Builds a RecentPrint from a print/cancel payload, or nil if required
    /// fields are missing. Shared by the print and the cancel-records paths.
    private func makeRecentPrint(from payload: [String: Any], labelCount: Int,
                                 status: RecentPrint.Status) -> RecentPrint? {
        guard let printerID     = payload["printerID"]     as? String,
              let title         = payload["title"]         as? String,
              let templateName  = payload["templateName"]  as? String,
              let recordIndices = payload["recordIndices"] as? [Int]
        else { return nil }

        let printRange: RecentPrint.PrintRange
        if let rangeStr = payload["printRange"] as? String {
            printRange = RecentPrint.PrintRange(rawValue: rangeStr) ?? .selected
        } else {
            printRange = .selected
        }

        // Capture the active filter/sort (objects) as JSON so reprint restores them.
        func jsonString(_ v: Any?) -> String? {
            guard let v = v, !(v is NSNull),
                  let data = try? JSONSerialization.data(withJSONObject: v),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }

        return RecentPrint(
            date: Date(),
            title: title,
            sourceFileName: sourceFileURL?.lastPathComponent ?? reprinting?.sourceFileName ?? "",
            templateName: templateName,
            printerName: PrinterManager.shared.printers.first { $0.id == printerID }?.name ?? printerID,
            labelCount: labelCount,
            printRange: printRange,
            selectedIndices: recordIndices,
            status: status,
            rangeFrom: payload["rangeFrom"] as? Int,
            rangeTo: payload["rangeTo"] as? Int,
            filterJSON: jsonString(payload["filter"]),
            sortJSON: jsonString(payload["sort"])
        )
    }

    /// Update a Recent Print's status when its job finishes. The observer lives
    /// in `printStatusObservers` so it outlives the print window (which closes
    /// immediately after the print starts).
    private func trackPrintStatus(job: PrintJob, recentID: UUID) {
        var cancellable: AnyCancellable?
        cancellable = job.$isComplete.sink { [weak self] complete in
            guard complete else { return }
            Task { @MainActor in
                let outcome: RecentPrint.Status = job.didFail ? .failed
                    : (job.isCancelled ? .cancelledMidPrint : .complete)
                RecentPrintsStore.shared.updateStatus(id: recentID, to: outcome)
                if outcome == .failed {
                    let printer = PrinterManager.shared.printers.first { $0.id == job.printerID }?.name ?? job.printerID
                    PrintWindowController.notifyPrintFailed(jobTitle: job.title, printer: printer)
                }
                if let c = cancellable { self?.printStatusObservers.remove(c) }
            }
        }
        if let c = cancellable { printStatusObservers.insert(c) }
    }

    private func evalJS(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Post a system notification when a print fails. The print window has already
    /// closed by then, so this is the operator's active signal. Authorization is
    /// requested lazily — only the first time a print actually fails — so an app
    /// that never fails a print never prompts.
    static func notifyPrintFailed(jobTitle: String, printer: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Print failed"
            content.body = "\(jobTitle) — \(printer)"
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

// MARK: – NSWindowDelegate

extension PrintWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        flushWriteback()   // persist any debounced inline edit
        jobObservers.removeAll()
        printerObserver = nil
        cassetteObserver = nil
        columnObservers.removeAll()
        templatesObserver = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel")
        webView = nil
        window = nil
    }
}

// MARK: – JSON helper

extension String {
    /// The string wrapped in double-quotes, escaped so it is safe to splice into
    /// JavaScript source passed to `evaluateJavaScript`. Escapes the backslash,
    /// quote, and CR/LF, plus U+2028/U+2029 — JS line terminators that would
    /// otherwise let a crafted filename break out of the string literal and inject
    /// code into the privileged web view.
    var jsonQuoted: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }
}

// MARK: – WireRecord: Codable (for JS bridge)
// Records are flattened so JS can access r.Cable, r._Side, r.Number directly.

extension WireRecord: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        side   = (try? c.decode(String.self, forKey: DynamicKey("_Side"))) ?? "Source"
        wireID = (try? c.decode(String.self, forKey: DynamicKey("Number"))) ?? ""
        var f: [String: String] = [:]
        for key in c.allKeys { f[key.stringValue] = try? c.decode(String.self, forKey: key) }
        fields = f
    }
    func encode(to encoder: Encoder) throws {
        // Flatten all fields to top level so JS sees r.Cable, r._Side etc.
        var c = encoder.container(keyedBy: DynamicKey.self)
        for (k, v) in fields { try c.encode(v, forKey: DynamicKey(k)) }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
