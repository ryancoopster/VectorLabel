import AppKit
import WebKit
import SwiftUI
import Combine

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
    private var reprinting: RecentPrint?

    // Observes the active PrintJob so we can drive the web view's progress UI.
    private var jobObservers: Set<AnyCancellable> = []

    // Recent-print record for the job submitted this session, so its status can
    // be updated (printing → complete / cancelled-mid-print). nil until Print is
    // clicked; while nil, a ✕ Cancel records a "cancelled before printing" entry.
    private var currentRecentPrintID: UUID?

    // MARK: – Show / hide

    func showForNewExport(fileURL: URL, records: [WireRecord]) {
        self.records = records
        self.sourceFileURL = fileURL
        self.reprinting = nil
        self.currentRecentPrintID = nil
        openWindowIfNeeded()
        sendInitialState()
    }

    func showForReprint(_ recent: RecentPrint) {
        self.reprinting = recent
        self.currentRecentPrintID = nil
        // Clear any stale export URL so the recorded source filename comes from
        // the reprint record, not a previously-opened export.
        self.sourceFileURL = nil
        openWindowIfNeeded()
        // Recent prints store the CSV path; try to reload it
        if let csv = loadCSVForReprint(recent) {
            self.records = csv
        }
        sendInitialState()
    }

    func close() {
        jobObservers.removeAll()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel")
        window?.close()
        window = nil
        webView = nil
    }

    // MARK: – Window setup

    private func openWindowIfNeeded() {
        if let win = window {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(self, name: "vectorlabel")
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

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
        win.center()
        win.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    // MARK: – JS bridge: push data into the web view

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
              reprint: \(reprintJSON)
            });
          }
        })();
        """
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: – Reprint CSV reload

    private func loadCSVForReprint(_ recent: RecentPrint) -> [WireRecord]? {
        // Try to find the CSV in the exports tree
        let exportsRoot = AppSettings.shared.exportsFolderURL
        guard let enumerator = FileManager.default.enumerator(at: exportsRoot, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == recent.sourceFileName {
                return WireExportParser.parse(fileURL: url)
            }
        }
        return nil
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

        // Render VGL jobs
        let selectedRecords = recordIndices.compactMap { i -> WireRecord? in
            guard i >= 0 && i < records.count else { return nil }
            return records[i]
        }

        var jobs: [[UInt8]] = []
        for record in selectedRecords {
            guard let rendered = LabelRenderer.render(template: template, record: record) else { continue }
            let job = BradyVGL.buildPrintJob(pixels: rendered.pixels, width: rendered.width, height: rendered.height)
            jobs.append(job)
        }

        // Submit to printer and mirror its progress into the web view's modal.
        let job = PrinterManager.shared.submit(
            jobs: jobs,
            title: title,
            templateName: templateName,
            printerID: printerID
        )
        observePrintJob(job)

        // Record in recent prints as in-progress; status is updated on completion
        // or mid-print cancellation by observePrintJob.
        if let recent = makeRecentPrint(from: payload, labelCount: jobs.count, status: .printing) {
            currentRecentPrintID = recent.id
            RecentPrintsStore.shared.add(recent)
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
            rangeTo: payload["rangeTo"] as? Int
        )
    }

    /// Bridge a job's progress into the print window's modal. The HTML defines
    /// `updatePrintProgress(done,total)` and `completePrint()`; without these
    /// calls the modal would sit at 0% forever even though printing succeeds.
    private func observePrintJob(_ job: PrintJob) {
        jobObservers.removeAll()
        let total = job.labelCount

        job.$completedLabels
            .sink { [weak self] done in
                Task { @MainActor in
                    self?.evalJS("if(typeof updatePrintProgress==='function')updatePrintProgress(\(done),\(total));")
                }
            }
            .store(in: &jobObservers)

        job.$isComplete
            .sink { [weak self, weak job] complete in
                guard complete else { return }
                Task { @MainActor in
                    guard let self = self else { return }
                    self.evalJS("if(typeof completePrint==='function')completePrint();")
                    if let id = self.currentRecentPrintID {
                        RecentPrintsStore.shared.updateStatus(
                            id: id,
                            to: (job?.isCancelled ?? false) ? .cancelledMidPrint : .complete
                        )
                    }
                    self.jobObservers.removeAll()
                }
            }
            .store(in: &jobObservers)
    }

    private func evalJS(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: – NSWindowDelegate

extension PrintWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        jobObservers.removeAll()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel")
        webView = nil
        window = nil
    }
}

// MARK: – JSON helper

private extension String {
    /// Returns the string wrapped in JSON double-quotes with proper escaping.
    var jsonQuoted: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
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
