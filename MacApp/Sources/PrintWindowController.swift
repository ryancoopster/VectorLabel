import AppKit
import WebKit
import SwiftUI

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

    // MARK: – Show / hide

    func showForNewExport(fileURL: URL, records: [WireRecord]) {
        self.records = records
        self.sourceFileURL = fileURL
        self.reprinting = nil
        openWindowIfNeeded()
        sendInitialState()
    }

    func showForReprint(_ recent: RecentPrint) {
        self.reprinting = recent
        openWindowIfNeeded()
        // Recent prints store the CSV path; try to reload it
        if let csv = loadCSVForReprint(recent) {
            self.records = csv
        }
        sendInitialState()
    }

    func close() {
        window?.close()
        window = nil
        webView = nil
    }

    // MARK: – Window setup

    private func openWindowIfNeeded() {
        if window != nil { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

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
            ?? Bundle.main.url(forResource: "VectorLabelPrint", withExtension: "html")
        guard let htmlURL = htmlURL else { return }
        // Grant access to the parent directory so WKWebView can read the file.
        // For repo files, grant access up to MacApp/ so any relative resources work.
        let accessURL = htmlURL.deletingLastPathComponent()
        wv.loadFileURL(htmlURL, allowingReadAccessTo: accessURL)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "VectorLabel — Print"
        win.contentView = wv
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
              sourceFile: \(JSONSerialization.escapeString(sourceFile)),
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
    static func findHTMLFile(_ name: String) -> URL? {
        let home = NSHomeDirectory()
        let searchPaths = [
            "Downloads/VectorLabel/MacApp/Sources",
            "Documents/VectorLabel/MacApp/Sources",
            "Developer/VectorLabel/MacApp/Sources",
            "Desktop/VectorLabel/MacApp/Sources",
            "Projects/VectorLabel/MacApp/Sources",
        ]
        for rel in searchPaths {
            let url = URL(fileURLWithPath: home)
                .appendingPathComponent(rel)
                .appendingPathComponent("\(name).html")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
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

        // Determine print range
        let printRange: RecentPrint.PrintRange
        if let rangeStr = payload["printRange"] as? String {
            printRange = RecentPrint.PrintRange(rawValue: rangeStr) ?? .selected
        } else {
            printRange = .selected
        }

        // Submit to printer
        PrinterManager.shared.submit(
            jobs: jobs,
            title: title,
            templateName: templateName,
            printerID: printerID
        )

        // Record in recent prints
        let recent = RecentPrint(
            date: Date(),
            title: title,
            sourceFileName: sourceFileURL?.lastPathComponent ?? reprinting?.sourceFileName ?? "",
            templateName: templateName,
            printerName: PrinterManager.shared.printers.first { $0.id == printerID }?.name ?? printerID,
            labelCount: jobs.count,
            printRange: printRange,
            selectedIndices: recordIndices,
            rangeFrom: payload["rangeFrom"] as? Int,
            rangeTo: payload["rangeTo"] as? Int
        )
        RecentPrintsStore.shared.add(recent)
    }
}

// MARK: – NSWindowDelegate

extension PrintWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel")
        webView = nil
        window = nil
    }
}

// MARK: – JSON helper

private extension JSONSerialization {
    static func escapeString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s),
              let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return str
    }
}

// MARK: – WireRecord: Codable (for JS bridge)

extension WireRecord: Codable {
    enum CodingKeys: String, CodingKey { case side, wireID, fields }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        side   = try c.decode(String.self, forKey: .side)
        wireID = try c.decode(String.self, forKey: .wireID)
        fields = try c.decode([String: String].self, forKey: .fields)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(side,   forKey: .side)
        try c.encode(wireID, forKey: .wireID)
        try c.encode(fields, forKey: .fields)
    }
}
