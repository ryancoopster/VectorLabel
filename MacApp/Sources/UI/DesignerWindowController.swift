import AppKit
import WebKit
import Combine
import VectorLabelCore

/// Which flavour of the designer this controller hosts.
///
/// `.template` is the classic Template Designer — opens the template picker on
/// launch, edits/saves `.vlt.json` templates. `.custom` is the Custom Designer
/// shell: the same canvas, but the DB panel + print header arrive in later
/// phases. Both share the identical hosting code below.
public enum DesignerMode {
    case template
    case custom
}

/// Reusable hosting for the VectorLabel HTML designer (VectorLabelDesigner.html in
/// a WKWebView). Core-only — it touches TemplateStore / AppSettings but never
/// EngineKit / libusb — so any front-end app can present it.
///
/// It owns:
///   • the NSWindow + WKWebView that loads VectorLabelDesigner.html,
///   • the "vectorlabel" WKScriptMessageHandler
///     (saveTemplate/listTemplates/deleteTemplate/setColumnConfig/setDesignerPrefs/editReturn
///      + browseTemplate/browseDataSource),
///   • the inject methods (initDesignerTemplates/initDesignerRecords/applyColumnConfig/setTheme/…),
///   • light/dark theme observation, and the shared record-column-config sync.
///
/// Hosts that want to drive the print-window "edit template" round-trip set
/// `onEditReturn` and call `openForPrintEdit(templateIndex:)`.
@MainActor
public final class DesignerWindowController: NSObject {

    public let mode: DesignerMode

    private var window: NSWindow?
    private var webView: WKWebView?
    private var closeObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    /// Template index to load on the next designer load (print-window editing).
    private var pendingEditTemplateIndex: Int?
    /// True while the designer is open to edit a template for the print window.
    private var designerForPrintEdit = false

    /// Invoked when the print-edit round-trip ends — either the user saved and
    /// returned, or closed the designer. `saved` is whether a save happened on
    /// this return; `templateIndex` echoes the index being edited (if known).
    /// Hosts use this to refocus/refresh the print window.
    public var onEditReturn: ((_ saved: Bool, _ templateIndex: Int?) -> Void)?

    public init(mode: DesignerMode) {
        self.mode = mode
        super.init()
    }

    /// True while a designer window is on screen.
    public var isOpen: Bool { window != nil }

    /// The hosted WKWebView, if open (exposed for hosts that need to push extra
    /// state, e.g. theme on an external change).
    public var hostedWebView: WKWebView? { webView }

    // MARK: – Show

    /// Open (or focus) the designer in its normal standalone mode.
    public func open() {
        present(editTemplateIndex: nil)
    }

    /// Open (or focus) the designer to edit the template at `templateIndex` for
    /// the print window; on return/close, `onEditReturn` fires.
    public func openForPrintEdit(templateIndex: Int) {
        present(editTemplateIndex: templateIndex)
    }

    private func present(editTemplateIndex: Int?) {
        pendingEditTemplateIndex = editTemplateIndex
        designerForPrintEdit = (editTemplateIndex != nil)
        if let win = window {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(webView)
            if let idx = editTemplateIndex {
                applyPendingEdit(idx)
            } else {
                webView?.evaluateJavaScript("window._printEdit=false; if(typeof R==='function')R(); if(typeof openTemplate==='function')openTemplate();", completionHandler: nil)
            }
            return
        }

        // The HTML lives in VectorLabelCore's resource bundle. Prefer a live repo
        // copy during development (so git pull is reflected without a rebuild),
        // then fall back to the bundled Core resource.
        guard let htmlURL = devHTMLURL("VectorLabelDesigner")
                            ?? CoreResources.url("VectorLabelDesigner", "html")
        else { return }

        // WKWebView with navigation delegate so we can inject records after load,
        // plus a message handler so the designer can save/list/browse templates
        // through Swift (WKWebView has no File System Access API).
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let contentController = WKUserContentController()
        contentController.add(self, name: "vectorlabel")
        // Set the theme before first paint (avoids a flash of the old theme when
        // the designer reopens after a light/dark switch).
        let theme = AppSettings.shared.isLight ? "light" : ""
        contentController.addUserScript(WKUserScript(
            source: "document.documentElement.dataset.theme='\(theme)';",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = contentController
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self   // so <input type=file> shows an NSOpenPanel (image picker)
        wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        webView = wv

        // Use NSPanel with .nonactivatingPanel so the window appears without
        // stealing activation from a host menu bar status item.
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        win.title = (mode == .custom) ? "VectorLabel — Custom Designer"
                                      : "VectorLabel — Template Designer"
        win.contentView = wv
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        win.applyVLSizing(autosaveName: (mode == .custom) ? "VLCustomDesignerWindow" : "VLDesignerWindow",
                          defaultContentSize: NSSize(width: 1280, height: 860))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        // Make the web view first responder so keyboard shortcuts (arrow-key
        // nudge, delete, undo) reach the designer immediately.
        win.makeFirstResponder(wv)
        window = win

        // Keep the designer's column config in sync with the shared setting.
        AppSettings.shared.$recordColumnOrder.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.injectColumnConfig() }.store(in: &cancellables)
        AppSettings.shared.$recordHiddenColumns.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.injectColumnConfig() }.store(in: &cancellables)
        AppSettings.shared.$recordColumnWidths.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.injectColumnConfig() }.store(in: &cancellables)
        // Push the light/dark theme to the designer webview when it changes.
        AppSettings.shared.$appearance.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.webView?.evaluateJavaScript("if(typeof setTheme==='function')setTheme('\(mode)')", completionHandler: nil)
            }.store(in: &cancellables)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.webView?.navigationDelegate = nil
                self.webView?.configuration.userContentController
                    .removeScriptMessageHandler(forName: "vectorlabel")
                self.webView = nil
                self.window = nil
                self.cancellables.removeAll()
                if let token = self.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.closeObserver = nil
                }
                TemplateStore.shared.reload()
                // If the designer was closed (e.g. via its close button) while
                // editing for the print window, tell the host to return.
                if self.designerForPrintEdit {
                    let idx = self.pendingEditTemplateIndex
                    self.designerForPrintEdit = false
                    self.onEditReturn?(false, idx)
                }
            }
        }
    }

    // MARK: – Inject helpers

    /// Auto-load most recent CSV for the designer.
    ///
    /// Finds the most recent CSV export with ≥10 records across all project
    /// subfolders under Exports/, sorted by embedded datecode in the filename.
    private func findMostRecentCSV(minRecords: Int = 10) -> (url: URL, records: [WireRecord])? {
        let exportsRoot = AppSettings.shared.exportsFolderURL
        guard let enumerator = FileManager.default.enumerator(
            at: exportsRoot,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return nil }

        var candidates: [(datecode: String, url: URL)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "csv",
                  let dc = ExportFilenameParser.datecode(from: fileURL.lastPathComponent)
            else { continue }
            candidates.append((dc, fileURL))
        }

        // Sort newest first (lexicographic on YYYYMMDD_HHMMSS = chronological)
        candidates.sort { $0.datecode > $1.datecode }

        for candidate in candidates {
            if let records = WireExportParser.parse(fileURL: candidate.url),
               records.count >= minRecords {
                return (candidate.url, records)
            }
        }
        return nil
    }

    private func injectDesignerRecords(_ records: [WireRecord], filename: String) {
        guard let wv = webView else { return }
        guard let data = try? JSONEncoder().encode(records),
              let json = String(data: data, encoding: .utf8)
        else { return }
        // JSON-encode the filename string safely (escapes CR/LF/U+2028/U+2029 too).
        let fnJSON = filename.jsonQuoted
        let js = "if(typeof initDesignerRecords==='function')initDesignerRecords(\(json),\(fnJSON));"
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Push the current templates-folder contents into the designer so its Open
    /// dialog lists every saved template.
    private func injectDesignerTemplates() {
        guard let wv = webView,
              let data = try? JSONEncoder().encode(TemplateStore.shared.templates),
              let json = String(data: data, encoding: .utf8)
        else { return }
        wv.evaluateJavaScript(
            "if(typeof initDesignerTemplates==='function')initDesignerTemplates(\(json));",
            completionHandler: nil
        )
    }

    /// Load a specific template (by store index) into the designer for print
    /// editing. Index, not id, because ids can be duplicated across templates.
    private func applyPendingEdit(_ index: Int) {
        pendingEditTemplateIndex = nil
        let templates = TemplateStore.shared.templates
        guard let wv = webView, index >= 0, index < templates.count,
              let data = try? JSONEncoder().encode(templates[index]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        wv.evaluateJavaScript("if(typeof initPrintEdit==='function')initPrintEdit(\(json));",
                              completionHandler: nil)
    }

    /// Confirm (native dialog), then delete a template by id and refresh the
    /// designer's Open list.
    private func confirmAndDeleteTemplate(id: String, name: String) {
        guard let tpl = TemplateStore.shared.templates.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = "This permanently removes the template file from ~/Documents/VectorLabel/Templates/. This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if let win = window {
            alert.beginSheetModal(for: win) { [weak self] resp in
                guard resp == .alertFirstButtonReturn else { return }
                try? TemplateStore.shared.delete(tpl)
                self?.injectDesignerTemplates()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            try? TemplateStore.shared.delete(tpl)
            injectDesignerTemplates()
        }
    }

    /// Push persisted snap/grid preferences into the designer.
    private func injectDesignerPrefs() {
        guard let wv = webView else { return }
        let s = AppSettings.shared
        wv.evaluateJavaScript(
            "if(typeof initDesignerPrefs==='function')initDesignerPrefs({snapGrid:\(s.designerSnapGrid),snapObjects:\(s.designerSnapObjects),gridSize:\(s.designerGridSize),recH:\(s.designerRecordsHeight)});",
            completionHandler: nil
        )
    }

    /// Push the shared record-column config (order/hidden/widths) into the designer.
    private func injectColumnConfig() {
        guard let wv = webView else { return }
        wv.evaluateJavaScript(
            "if(typeof applyColumnConfig==='function')applyColumnConfig(\(AppSettings.shared.columnConfigJSON()));",
            completionHandler: nil
        )
    }

    /// Show a Finder open panel so the user can load a template from any folder,
    /// then inject the chosen template into the designer.
    private func browseForTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = AppSettings.shared.templatesFolderURL
        panel.message = "Choose a VectorLabel template (.json) to open"
        panel.level = .modalPanel  // above the floating designer window
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.injectBrowsedTemplate(from: url) }
        }
    }

    /// Finder panel (at the Exports folder) to pick a CSV data source for the
    /// designer preview; loads it and injects the records.
    private func browseForDataSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = AppSettings.shared.exportsFolderURL
        panel.message = "Choose a CSV export to preview in the designer"
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self = self, let wv = self.webView,
                      let records = WireExportParser.parse(fileURL: url)
                else { return }
                guard let data = try? JSONEncoder().encode(records),
                      let json = String(data: data, encoding: .utf8) else { return }
                let fnJSON = url.lastPathComponent.jsonQuoted
                wv.evaluateJavaScript("if(typeof initDesignerRecords==='function')initDesignerRecords(\(json),\(fnJSON));", completionHandler: nil)
            }
        }
    }

    private func injectBrowsedTemplate(from url: URL) {
        guard let wv = webView,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any], dict["objs"] != nil,
              let reData = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: reData, encoding: .utf8)
        else { return }
        wv.evaluateJavaScript(
            "if(typeof addBrowsedTemplate==='function')addBrowsedTemplate(\(json));",
            completionHandler: nil
        )
    }

    // MARK: – Dev HTML loader

    private func devHTMLURL(_ name: String) -> URL? {
        // During development, load HTML directly from the repo so changes
        // are picked up without a full rebuild. Xcode's .copy resource bundling
        // caches files and may not re-copy after a git pull.
        let home = NSHomeDirectory()
        let searchPaths = [
            "Documents/VectorLabel/MacApp/Sources/Core",
            "Developer/VectorLabel/MacApp/Sources/Core",
            "Desktop/VectorLabel/MacApp/Sources/Core",
        ]
        for rel in searchPaths {
            let candidate = URL(fileURLWithPath: home)
                .appendingPathComponent(rel)
                .appendingPathComponent("\(name).html")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Fallback: look relative to compiled source path
        let src = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core")
        let candidate = src.appendingPathComponent("\(name).html")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

// MARK: – WKUIDelegate (file picker for the designer's <input type=file>)

extension DesignerWindowController: WKUIDelegate {
    public func webView(_ webView: WKWebView,
                        runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "svg"]
        panel.prompt = "Choose Image"
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}

// MARK: – WKNavigationDelegate (for designer auto-load)

extension DesignerWindowController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only handle our designer webview
        guard webView === self.webView else { return }
        // Apply the current light/dark theme.
        webView.evaluateJavaScript("if(typeof setTheme==='function')setTheme('\(AppSettings.shared.appearance)')", completionHandler: nil)
        // Inject the most recent CSV with ≥10 records
        if let result = findMostRecentCSV(minRecords: 10) {
            injectDesignerRecords(result.records, filename: result.url.lastPathComponent)
        }
        // Inject the templates-folder list so the designer's Open dialog can list them.
        TemplateStore.shared.reload()
        injectDesignerTemplates()
        injectColumnConfig()
        injectDesignerPrefs()
        if let idx = pendingEditTemplateIndex {
            // Editing for the print window: load that template, skip the picker.
            applyPendingEdit(idx)
        } else {
            // Standalone mode: ensure the New/Open/Save toolbar (not the
            // print-edit Return buttons) and open the template picker.
            webView.evaluateJavaScript("window._printEdit=false; if(typeof openTemplate==='function')openTemplate();", completionHandler: nil)
        }
    }
}

// MARK: – WKScriptMessageHandler (designer save / list / browse)

extension DesignerWindowController: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController,
                                       didReceive message: WKScriptMessage) {
        guard message.name == "vectorlabel",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }

        switch action {
        case "saveTemplate":
            TemplateStore.shared.save(fromPayload: body["payload"])
            injectDesignerTemplates()   // refresh the Open list with the new file

        case "listTemplates":
            TemplateStore.shared.reload()   // pick up renamed/added/removed files
            injectDesignerTemplates()

        case "browseTemplate":
            browseForTemplate()

        case "browseDataSource":
            browseForDataSource()

        case "deleteTemplate":
            if let p = body["payload"] as? [String: Any], let id = p["id"] as? String {
                confirmAndDeleteTemplate(id: id, name: p["name"] as? String ?? "this template")
            }

        case "setColumnConfig":
            AppSettings.shared.applyColumnConfigPayload(body["payload"])

        case "setDesignerPrefs":
            if let p = body["payload"] as? [String: Any] {
                if let v = p["snapGrid"] as? Bool { AppSettings.shared.designerSnapGrid = v }
                if let v = p["snapObjects"] as? Bool { AppSettings.shared.designerSnapObjects = v }
                if let v = p["gridSize"] as? Double { AppSettings.shared.designerGridSize = v }
                if let v = p["recH"] as? Double { AppSettings.shared.designerRecordsHeight = v }
            }

        case "editReturn":
            // Save first (if requested) so the print window refreshes with the
            // updated template, then close the designer and return. If the save
            // fails, STOP — alert and keep the designer open, so we never silently
            // revert the print window to the old template and print the un-edited
            // layout.
            if let p = body["payload"] as? [String: Any], (p["save"] as? Bool) == true {
                if !TemplateStore.shared.save(fromPayload: p["template"]) {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t save the template"
                    alert.informativeText = "Your changes have not been applied. Check that the disk isn’t full and that VectorLabel can write to ~/Documents/VectorLabel/Templates/."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return   // keep the designer open so the user can retry / copy their work
                }
            }
            let idx = pendingEditTemplateIndex
            designerForPrintEdit = false   // handled here; don't double-return on close
            onEditReturn?(true, idx)
            window?.close()

        default:
            break
        }
    }
}

// String.jsonQuoted is defined in VectorLabelCore (Core/Bridge.swift)
