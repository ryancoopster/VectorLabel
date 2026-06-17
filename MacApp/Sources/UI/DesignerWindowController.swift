import AppKit
import WebKit
import Combine
import UniformTypeIdentifiers
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

    /// A template to inject into the designer once it loads (Finder open of a
    /// ".vltmp" — template mode). Cleared after it's applied.
    private var pendingOpenTemplate: VLTemplate?
    /// A custom-label document to load once the designer loads (Finder open of a
    /// ".vlcus" — custom mode). Cleared after it's applied.
    private var pendingOpenCustomDoc: CustomLabelDocument?

    /// Invoked when the print-edit round-trip ends — either the user saved and
    /// returned, or closed the designer. `saved` is whether a save happened on
    /// this return; `templateIndex` echoes the index being edited (if known).
    /// Hosts use this to refocus/refresh the print window.
    public var onEditReturn: ((_ saved: Bool, _ templateIndex: Int?) -> Void)?

    // MARK: – Custom-mode print path (Phase 2)
    //
    // Only the Custom Designer (`mode == .custom`) prints. It owns a Core-only
    // `IPCPrintBackend` that publishes printer/cassette status from the Engine and
    // submits rendered jobs to the IPC queue — never linking EngineKit/libusb.
    // In `.template` mode all of this stays nil so the Template Designer behaves
    // exactly as before.

    /// The print backend (custom mode only). Reads the Engine's published status
    /// and writes jobs into the print queue.
    private var printBackend: PrintBackend?

    /// The latest printer + cassette status, used to inject the same JSON shapes
    /// the print window consumes (updatePrinters / updateCassettes equivalents).
    private var lastStatus: PrinterStatusFile?

    // MARK: – Custom-mode bound data source (Phase 3)
    //
    // The Custom Designer can bind a CSV/XLSX file as its print data: one label per
    // row. We keep the parsed records + the source path + the "first row is headers"
    // flag in memory here — this is the in-memory doc that Phase 4's `.vlcus` will
    // persist. Template mode never sets any of this.

    /// The bound data source for the Custom Designer, if the user picked one.
    private struct BoundDataSource {
        var path: URL
        /// Whether the first row of the file supplies column headers. Only
        /// meaningful for .xlsx; CSV always has a header row (WireExportParser).
        var headerRow: Bool
        /// Parsed records, one per data row — the print path renders one label each.
        var records: [WireRecord]
        /// Column names in display order (the union across records, header order).
        var columns: [String]
    }
    private var dataSource: BoundDataSource?

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

    /// Open (or focus) the designer and load `template` (template mode — used by the
    /// Template Designer's Finder ".vltmp" open handler). If a window is already on
    /// screen it's reused and the template injected immediately.
    public func openTemplate(_ template: VLTemplate) {
        pendingOpenTemplate = template
        if window != nil {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(webView)
            applyPendingOpenTemplate()
        } else {
            present(editTemplateIndex: nil)
        }
    }

    /// Open (or focus) the designer and load `doc`'s canvas + embedded data (custom
    /// mode — used by the Custom Designer's Finder ".vlcus" open handler).
    public func openCustomDocument(_ doc: CustomLabelDocument) {
        guard mode == .custom else { return }
        pendingOpenCustomDoc = doc
        if window != nil {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(webView)
            applyPendingOpenCustomDoc()
        } else {
            present(editTemplateIndex: nil)
        }
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
            } else if mode == .custom {
                // Re-focusing the Custom Designer: never show the template picker.
                webView?.evaluateJavaScript("window._printEdit=false; if(typeof R==='function')R();", completionHandler: nil)
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
        // the designer reopens after a light/dark switch). Also stamp the designer
        // mode at document start so the HTML can gate the custom-mode print header
        // (window._designerMode==='custom') before its first render.
        let theme = AppSettings.shared.isLight ? "light" : ""
        let modeJS = (mode == .custom) ? "window._designerMode='custom';" : ""
        contentController.addUserScript(WKUserScript(
            source: "document.documentElement.dataset.theme='\(theme)';\(modeJS)",
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
        // Custom mode hosts the web view inside a drop container so a CSV/XLSX
        // dragged from Finder onto the window opens it (#19). The web view's own
        // dragged types are unregistered so OS file drags fall through to the
        // container; template mode keeps the web view as the direct content view.
        if mode == .custom {
            let drop = DesignerDropView(frame: NSRect(x: 0, y: 0, width: 1200, height: 820))
            wv.frame = drop.bounds
            wv.autoresizingMask = [.width, .height]
            drop.addSubview(wv)
            wv.unregisterDraggedTypes()
            drop.registerForDraggedTypes([.fileURL])
            drop.onDragEnter = { [weak self] in self?.setDragOverlay(true) }
            drop.onDragExit  = { [weak self] in self?.setDragOverlay(false) }
            drop.onDropFiles = { [weak self] urls in self?.handleDroppedDataFiles(urls) ?? false }
            win.contentView = drop
        } else {
            win.contentView = wv
        }
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

        // Custom mode only: own a print backend, observe its status, and inject
        // printer/cassette state into the designer once the page loads.
        if mode == .custom { startPrintBackendIfNeeded() }

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
                // Custom mode: tear down the print backend's status watcher.
                self.printBackend?.stop()
                self.printBackend = nil
                self.lastStatus = nil
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

    /// Inject the pending Finder-opened template (".vltmp", template mode) into the
    /// canvas with the normal toolbar (not print-edit). No-op if none pending.
    private func applyPendingOpenTemplate() {
        guard let tpl = pendingOpenTemplate else { return }
        pendingOpenTemplate = nil
        guard let wv = webView,
              let data = try? JSONEncoder().encode(tpl),
              let json = String(data: data, encoding: .utf8)
        else { return }
        wv.evaluateJavaScript("if(typeof initOpenTemplate==='function')initOpenTemplate(\(json));",
                              completionHandler: nil)
    }

    /// Inject the pending Finder-opened custom-label document (".vlcus", custom
    /// mode): restore the in-memory bound data source (so Refresh works) and push
    /// the canvas + embedded rows to the page. No-op if none pending.
    private func applyPendingOpenCustomDoc() {
        guard mode == .custom, let doc = pendingOpenCustomDoc else { return }
        pendingOpenCustomDoc = nil
        // Rebuild the in-memory bound data source from the embedded snapshot so
        // "Refresh from source" can re-read the live file (if it still exists).
        let records = doc.records
        if let url = doc.dataSourceURL, !records.isEmpty {
            dataSource = BoundDataSource(path: url,
                                         headerRow: doc.dataSourceHeaderRow,
                                         records: records,
                                         columns: doc.headers)
        } else {
            dataSource = nil
        }
        guard let wv = webView else { return }
        // Build the JS doc object the page's initCustomDocument expects.
        guard let objData = try? JSONEncoder().encode(doc.template.objs),
              let objJSON = String(data: objData, encoding: .utf8),
              let recData = try? JSONEncoder().encode(records),
              let recJSON = String(data: recData, encoding: .utf8),
              let colData = try? JSONSerialization.data(withJSONObject: doc.headers),
              let colJSON = String(data: colData, encoding: .utf8)
        else { return }
        let isXLSX = doc.dataSourceURL?.pathExtension.lowercased() == "xlsx"
        let filename = (doc.dataSourceURL?.lastPathComponent ?? "").jsonQuoted
        let nameJSON = doc.name.jsonQuoted
        let specJSON = doc.specN.jsonQuoted
        // Continuous supplies carry the saved label length (inches); 0 ⇒ default.
        let lenInches = (doc.template.labelLengthInches ?? 0) > 0
            ? (doc.template.labelLengthInches ?? 0) : doc.labelLengthInches
        let js = """
        if(typeof initCustomDocument==='function')initCustomDocument({\
        name:\(nameJSON),specN:\(specJSON),objs:\(objJSON),copies:\(doc.copies),\
        cutMode:\(doc.cutMode.rawValue.jsonQuoted),\
        labelLengthInches:\(lenInches),canvasRot:\(doc.template.canvasRot ?? 0),\
        records:\(recJSON),columns:\(colJSON),filename:\(filename),\
        headerRow:\(doc.dataSourceHeaderRow),isXLSX:\(isXLSX),\
        hasDataSource:\(doc.dataSourceURL != nil)});
        """
        wv.evaluateJavaScript(js, completionHandler: nil)
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
            "if(typeof initDesignerPrefs==='function')initDesignerPrefs({snapGrid:\(s.designerSnapGrid),snapObjects:\(s.designerSnapObjects),gridSize:\(s.designerGridSize),recH:\(s.designerRecordsHeight),propW:\(s.designerPropsWidth)});",
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
        // Accept the new ".vltmp" type and the legacy ".json"/".vlt.json" forms.
        var types: [UTType] = [.json]
        if let vltmp = UTType(filenameExtension: TemplateStore.templateExtension) { types.append(vltmp) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = AppSettings.shared.templatesFolderURL
        panel.message = "Choose a VectorLabel template (.vltmp) to open"
        panel.level = .modalPanel  // above the floating designer window
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.injectBrowsedTemplate(from: url) }
        }
    }

    /// Finder panel (at the Exports folder) to pick a CSV/XLSX data source.
    ///
    /// Template mode keeps the original lightweight behavior: pick a CSV export and
    /// inject it as the designer preview (no binding, CSV only). Custom mode allows
    /// CSV *or* .xlsx, honors the "first row is headers" flag the page sends, BINDS
    /// the data into the in-memory doc, and prints one label per row.
    ///
    /// `headerRow` is the page's current toggle state (xlsx only — CSV always has a
    /// header row). Defaults to true.
    private func browseForDataSource(headerRow: Bool = true) {
        let panel = NSOpenPanel()
        if mode == .custom {
            // CSV + XLSX. UTType.spreadsheet covers .xlsx; also accept it by
            // extension in case the system doesn't resolve the UTI.
            var types: [UTType] = [.commaSeparatedText]
            if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
            types.append(.spreadsheet)
            panel.allowedContentTypes = types
            panel.message = "Choose a CSV or Excel (.xlsx) file to bind as print data"
        } else {
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.message = "Choose a CSV export to preview in the designer"
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Reopen where the user last picked a data file (custom mode); fall back to
        // the Exports folder the first time, or if that folder no longer exists.
        panel.directoryURL = (mode == .custom ? AppSettings.shared.lastDataSourceFolderURL : nil)
                             ?? AppSettings.shared.exportsFolderURL
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if self.mode == .custom {
                    AppSettings.shared.lastDataSourceFolderPath = url.deletingLastPathComponent().path
                    self.loadAndBindDataSource(from: url, headerRow: headerRow)
                } else {
                    // Template mode: original preview-only CSV path.
                    guard let wv = self.webView,
                          let records = WireExportParser.parse(fileURL: url),
                          let data = try? JSONEncoder().encode(records),
                          let json = String(data: data, encoding: .utf8) else { return }
                    let fnJSON = url.lastPathComponent.jsonQuoted
                    wv.evaluateJavaScript("if(typeof initDesignerRecords==='function')initDesignerRecords(\(json),\(fnJSON));", completionHandler: nil)
                }
            }
        }
    }

    /// Parse `url` (CSV via WireExportParser, .xlsx via ExcelRecordReader), store it
    /// as the bound data source, and inject the columns + rows into the designer.
    /// `headerRow` only applies to .xlsx. Returns true on success.
    @discardableResult
    private func loadAndBindDataSource(from url: URL, headerRow: Bool) -> Bool {
        let isXLSX = url.pathExtension.lowercased() == "xlsx"
        let records: [WireRecord]?
        var fileColumns: [String] = []
        if isXLSX {
            // Read the grid once: it gives both the records and the file column order
            // (WireRecord's fields are unordered, so we can't recover order from them).
            if let grid = ExcelRecordReader.rows(fileURL: url) {
                records = ExcelRecordReader.records(rows: grid, headerRow: headerRow)
                fileColumns = headerColumns(fromGrid: grid, headerRow: headerRow)
            } else {
                records = nil
            }
        } else {
            records = WireExportParser.parse(fileURL: url)
            // CSV header order = the first parsed row's column order.
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                fileColumns = WireExportParser.parseCSV(text).first ?? []
            }
        }
        guard let records, !records.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t read “\(url.lastPathComponent)”"
            alert.informativeText = isXLSX
                ? "The Excel file is empty or unreadable. Make sure it has at least one row of data on the first sheet."
                : "The CSV file is empty or unreadable. Make sure it has a header row and at least one data row."
            alert.runModal()
            return false
        }

        // Prefer the file's header order, then append any extra keys the records
        // carry (e.g. synthesized _Side/Number) that weren't literal headers.
        let columns = columnOrder(for: records, preferred: fileColumns)
        // CSV always has headers; only persist the toggle's effect for xlsx.
        dataSource = BoundDataSource(path: url,
                                     headerRow: isXLSX ? headerRow : true,
                                     records: records,
                                     columns: columns)
        injectBoundData()
        return true
    }

    /// The column names in file order: when `headerRow`, the first grid row trimmed
    /// (blanks → "Column N"); otherwise generic "Column 1…N" across the widest row.
    /// Mirrors ExcelRecordReader's header naming so the chips match the field keys.
    private func headerColumns(fromGrid grid: [[String]], headerRow: Bool) -> [String] {
        let width = grid.map(\.count).max() ?? 0
        guard width > 0 else { return [] }
        if !headerRow { return (1...width).map { "Column \($0)" } }
        let first = grid.first ?? []
        var out: [String] = []
        var seen: [String: Int] = [:]
        for i in 0..<width {
            var name = i < first.count ? first[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if name.isEmpty { name = "Column \(i + 1)" }
            if let n = seen[name] { seen[name] = n + 1; name = "\(name) (\(n + 1))" } else { seen[name] = 1 }
            out.append(name)
        }
        return out
    }

    /// Re-read the STORED data source from disk and re-inject. If the file no longer
    /// exists, show an open panel so the user can repoint it, then re-read.
    private func refreshDataSource() {
        guard mode == .custom, let ds = dataSource else { return }
        if FileManager.default.fileExists(atPath: ds.path.path) {
            loadAndBindDataSource(from: ds.path, headerRow: ds.headerRow)
        } else {
            let panel = NSOpenPanel()
            var types: [UTType] = [.commaSeparatedText]
            if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
            types.append(.spreadsheet)
            panel.allowedContentTypes = types
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.directoryURL = ds.path.deletingLastPathComponent()
            panel.message = "“\(ds.path.lastPathComponent)” was moved or deleted. Choose the file again."
            panel.level = .modalPanel
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated {
                    AppSettings.shared.lastDataSourceFolderPath = url.deletingLastPathComponent().path
                    self?.loadAndBindDataSource(from: url, headerRow: ds.headerRow)
                }
            }
        }
    }

    /// Column list for the DB panel + field source: the file's header order first
    /// (`preferred`), then any remaining record keys (sorted, deterministic) so no
    /// column is ever dropped even if a record carries a key absent from the header.
    private func columnOrder(for records: [WireRecord], preferred: [String]) -> [String] {
        var out: [String] = []
        for c in preferred where !out.contains(c) { out.append(c) }
        for r in records {
            for k in r.fields.keys.sorted() where !out.contains(k) { out.append(k) }
        }
        return out
    }

    /// Inject the bound data source (columns + records + metadata) into the designer
    /// so the DB panel can show columns, the row count, and drive the preview.
    private func injectBoundData() {
        guard let wv = webView, let ds = dataSource,
              let recData = try? JSONEncoder().encode(ds.records),
              let recJSON = String(data: recData, encoding: .utf8),
              let colData = try? JSONSerialization.data(withJSONObject: ds.columns),
              let colJSON = String(data: colData, encoding: .utf8)
        else { return }
        let fnJSON = ds.path.lastPathComponent.jsonQuoted
        let isXLSX = ds.path.pathExtension.lowercased() == "xlsx"
        wv.evaluateJavaScript(
            "if(typeof initBoundData==='function')initBoundData(\(recJSON),\(colJSON),\(fnJSON),\(ds.headerRow),\(isXLSX));",
            completionHandler: nil)
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

    // MARK: – Custom-mode print backend (Phase 2)

    /// Create (once) and start the IPC print backend, wiring its status changes to
    /// re-inject printer/cassette state into the designer. Custom mode only.
    private func startPrintBackendIfNeeded() {
        guard mode == .custom else { return }
        if printBackend == nil {
            let backend = IPCPrintBackend()
            backend.onStatusChange = { [weak self] status in
                guard let self else { return }
                self.lastStatus = status
                self.injectPrinters()
                self.injectCassettes()
                self.injectActiveJobs()
            }
            printBackend = backend
            backend.start()
        }
        // Seed the most recent status (start() emits it synchronously, but the page
        // may not be loaded yet — injectPrinters/Cassettes no-op until it is, and
        // the navigation didFinish re-injects).
        if let s = printBackend?.status { lastStatus = s }
    }

    /// Printers from the latest status as [{id,name,model,serial,status}] — the
    /// same shape the print window consumes via updatePrinters / initPrintWindow.
    private func printersJSONString() -> String {
        let dicts: [[String: String]] = (lastStatus?.printers ?? []).map { p in
            ["id": p.id, "name": p.name, "model": p.model, "serial": p.serial, "status": p.status]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dicts),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Detected cassette info keyed by printer id — the identical object the print
    /// window's updateCassettes consumes (reproduced from each CassetteStatus).
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
            if let perRoll = c.labelsPerRoll ?? BradyCatalog.labelsPerRoll(forPartNumber: c.partNumber) {
                entry["labelsPerRoll"] = perRoll
            }
            dict[p.id] = entry
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) { return json }
        return "{}"
    }

    /// Push the current printer list into the designer (custom mode). No-ops until
    /// the page defines updateDesignerPrinters.
    private func injectPrinters() {
        webView?.evaluateJavaScript(
            "if(typeof updateDesignerPrinters==='function')updateDesignerPrinters(\(printersJSONString()));",
            completionHandler: nil)
    }

    /// Push the detected cassettes into the designer (custom mode).
    private func injectCassettes() {
        webView?.evaluateJavaScript(
            "if(typeof updateDesignerCassettes==='function')updateDesignerCassettes(\(cassettesJSONString()));",
            completionHandler: nil)
    }

    /// The Engine's in-flight (printing/queued) jobs as the array the designer's
    /// print header consumes for live progress + a Cancel control. Custom mode only.
    private func activeJobsJSONString() -> String {
        let jobs = (printBackend as? IPCPrintBackend)?.activeJobs ?? []
        guard let data = try? JSONEncoder().encode(jobs),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Push the active-job list into the designer so the print header can show live
    /// progress + Cancel after the supply selector (no-ops until the page defines it).
    private func injectActiveJobs() {
        webView?.evaluateJavaScript(
            "if(typeof updateDesignerJobStatus==='function')updateDesignerJobStatus(\(activeJobsJSONString()));",
            completionHandler: nil)
    }

    /// Render the designer's current canvas to a Brady VGL job and submit it to the
    /// IPC queue. `payload` is {name, specN, objs, copies, printerID?, record?}.
    ///
    /// Data binding (Phase 3): when a data source is bound, prints ONE label per
    /// bound row — each row's WireRecord is rendered and the labels are concatenated
    /// into a single multi-label job (× copies). With no data bound, prints a single
    /// label rendered against the previewed record (so field/formula text matches
    /// what the user sees), or an empty WireRecord if none was sent.
    private func handlePrintCustom(_ payloadAny: Any?) {
        guard mode == .custom,
              let backend = printBackend,
              let payload = payloadAny as? [String: Any]
        else { return }

        // Decode the canvas into a VLTemplate via the SAME {name, specN, objs}
        // shape the saveTemplate path produces, so rendering matches the designer.
        var tplDict: [String: Any] = [
            "name": (payload["name"] as? String) ?? "Custom Label",
            "specN": (payload["specN"] as? String) ?? "",
            "objs": payload["objs"] ?? [],
            "version": 1,
            "id": UUID().uuidString,
        ]
        // Continuous supplies carry a user-chosen label length (inches) → printable
        // height at render time. Die-cut supplies omit it (catalog fixed height).
        if let len = payload["labelLengthInches"] as? Double, len > 0 {
            tplDict["labelLengthInches"] = len
        } else if let lenN = payload["labelLengthInches"] as? NSNumber, lenN.doubleValue > 0 {
            tplDict["labelLengthInches"] = lenN.doubleValue
        }
        // Landscape canvas rotation (continuous only) → renderer rotates the raster. #14.
        if let rot = payload["canvasRot"] as? Int { tplDict["canvasRot"] = rot }
        else if let rotN = payload["canvasRot"] as? NSNumber { tplDict["canvasRot"] = rotN.intValue }
        // A template with no objects (or an unknown spec) can't render — bail.
        guard let objs = tplDict["objs"] as? [Any], !objs.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: tplDict),
              let template = try? JSONDecoder().decode(VLTemplate.self, from: data),
              template.labelSize != nil
        else { return }

        let copies = max(1, (payload["copies"] as? Int) ?? 1)
        let printerID = (payload["printerID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let templateName = template.name
        // Cut SETTING chosen in the Custom Designer print header (Phase 6). The JS
        // defaults it per stock (continuous → eachLabel; die-cut → never). Carried
        // into PrintJobFile.cutMode AND baked into each label's VGL.
        let cutMode = CutMode(rawValue: (payload["cutMode"] as? String) ?? "") ?? .never

        // One record per label, honoring the print-range subset (Phase 6). When a
        // data source is bound, the page sends `recordIndices` — the rows chosen by
        // the print-range control (All / Selected / Range). We render exactly those
        // rows (× copies). If the page sends nothing (older payloads), fall back to
        // every bound row. With NO data source, a single label against an EMPTY
        // record so static text prints and field/formula text is blank (NOT the
        // leftover sample/CSV preview record — that's only for the on-canvas
        // preview, not the printed output).
        let records: [WireRecord]
        if let ds = dataSource, !ds.records.isEmpty {
            if let idx = payload["recordIndices"] as? [Int] {
                // Map the chosen indices to rows, dropping any out-of-range index.
                records = idx.compactMap { $0 >= 0 && $0 < ds.records.count ? ds.records[$0] : nil }
            } else {
                records = ds.records
            }
            // Nothing selected ⇒ nothing to print.
            guard !records.isEmpty else { return }
        } else {
            records = [WireRecord(side: "", wireID: "", fields: [:])]
        }

        // Per-printer calibration offset (keyed by the printer's serial, as the
        // print window does). printerID is "vid:pid:serial".
        let serial = (printerID ?? "").split(separator: ":").dropFirst(2).joined(separator: ":")
        let offset = AppSettings.shared.calibrationOffset(forSerial: serial)

        // Render off the main thread (matching the print window), then submit back
        // on the main actor.
        DispatchQueue.global(qos: .userInitiated).async {
            // First render each row's raster once (rendering is the expensive part);
            // we then expand by `copies` and stamp the per-label cut command so the
            // chosen cut SETTING applies across the whole expanded label list (e.g.
            // afterJobLast cuts once after the very last copy of the last row).
            var rasters: [(pixels: [UInt8], width: Int, height: Int)] = []
            var maxLabelPx = 0
            for record in records {
                guard let rendered = LabelRenderer.render(template: template, record: record, offset: offset) else { continue }
                maxLabelPx = max(maxLabelPx, rendered.width, rendered.height)
                for _ in 0..<copies { rasters.append(rendered) }
            }
            guard !rasters.isEmpty else { return }
            let total = rasters.count
            var labels: [Data] = []
            labels.reserveCapacity(total)
            for (i, r) in rasters.enumerated() {
                let vglCut = BradyVGL.vglCutMode(forIPCRawValue: cutMode.rawValue, index: i, total: total)
                let vgl = BradyVGL.buildPrintJob(pixels: r.pixels, width: r.width,
                                                 height: r.height, cutMode: vglCut)
                labels.append(Data(vgl))
            }
            // Same pacing estimate the print window uses.
            let estLabelMs = Int(Double(maxLabelPx) / 300.0 * 370.0) + 300

            Task { @MainActor in
                let jobID = UUID().uuidString
                let job = PrintJobFile(
                    id: jobID,
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    sourceApp: "customdesigner",
                    title: templateName.isEmpty ? "Custom Label" : templateName,
                    templateName: templateName,
                    printerID: printerID,
                    copies: 1,            // copies are expanded into `labels` above
                    cutMode: cutMode,     // user-chosen cut setting (Phase 6)
                    estLabelMs: estLabelMs,
                    labels: labels
                )
                do { try backend.submit(job) }
                catch { print("[DesignerWindowController] printCustom submit failed: \(error)") }
                // Hand the page its job id so it can match the Engine's published
                // status, and push an immediate status so the in-header progress +
                // Cancel control appear right away (updated live thereafter).
                self.webView?.evaluateJavaScript(
                    "if(typeof customPrintSubmitted==='function')customPrintSubmitted(\(labels.count),\(jobID.jsonQuoted));",
                    completionHandler: nil)
                self.injectActiveJobs()
            }
        }
    }

    /// Save the current Custom Designer canvas + embedded data as a ".vlcus"
    /// document via an NSSavePanel. `payload` is {name, specN, objs, copies}.
    private func handleSaveCustomDocument(_ payloadAny: Any?) {
        guard mode == .custom, let payload = payloadAny as? [String: Any] else { return }

        // Decode the canvas into a VLTemplate (same {name, specN, objs} shape).
        let name = (payload["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Custom Label"
        var tplDict: [String: Any] = [
            "name": name,
            "specN": (payload["specN"] as? String) ?? "",
            "objs": payload["objs"] ?? [],
            "version": 1,
            "id": UUID().uuidString,
        ]
        if let len = payload["labelLengthInches"] as? Double, len > 0 {
            tplDict["labelLengthInches"] = len
        } else if let lenN = payload["labelLengthInches"] as? NSNumber, lenN.doubleValue > 0 {
            tplDict["labelLengthInches"] = lenN.doubleValue
        }
        // Landscape canvas rotation (continuous only) → renderer rotates the raster. #14.
        if let rot = payload["canvasRot"] as? Int { tplDict["canvasRot"] = rot }
        else if let rotN = payload["canvasRot"] as? NSNumber { tplDict["canvasRot"] = rotN.intValue }
        guard let data = try? JSONSerialization.data(withJSONObject: tplDict),
              let template = try? JSONDecoder().decode(VLTemplate.self, from: data)
        else { return }
        let copies = max(1, (payload["copies"] as? Int) ?? 1)
        // The effective cut mode chosen in the designer, so the choice round-trips
        // in the .vlcus. Falls back to .never if absent/unrecognised.
        let cutMode = CutMode(rawValue: (payload["cutMode"] as? String) ?? "") ?? .never

        // Embedded data snapshot from the in-memory bound source (if any).
        var rows: [[String: String]] = []
        var headers: [String] = []
        var srcPath = ""
        var headerRow = true
        if let ds = dataSource {
            headers = ds.columns
            rows = ds.records.map { $0.fields }
            srcPath = ds.path.path
            headerRow = ds.headerRow
        }

        let doc = CustomLabelDocument(
            name: name,
            template: template,
            headers: headers,
            rows: rows,
            dataSourcePath: srcPath,
            dataSourceHeaderRow: headerRow,
            labelLengthInches: template.labelLengthInches ?? 0,
            cutMode: cutMode,
            copies: copies)

        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: CustomLabelStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(name).\(CustomLabelStore.fileExtension)"
        panel.directoryURL = CustomLabelStore.defaultFolderURL
        panel.message = "Save this custom label (.vlcus)"
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try CustomLabelStore.save(doc, to: url)
                    self?.webView?.evaluateJavaScript(
                        "if(typeof showToast==='function')showToast('Saved: '+\(CustomLabelStore.stem(url).jsonQuoted));",
                        completionHandler: nil)
                } catch {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t save the custom label"
                    alert.informativeText = "\(error.localizedDescription)"
                    alert.runModal()
                }
            }
        }
    }

    // MARK: – Custom-mode file drag-and-drop (#19)

    /// Toggle the in-page "Drop to open file" overlay shown while a CSV/XLSX is
    /// dragged over the Custom Designer window.
    private func setDragOverlay(_ show: Bool) {
        webView?.evaluateJavaScript("if(typeof setDragOverlay==='function')setDragOverlay(\(show));",
                                    completionHandler: nil)
    }

    /// Bind the first dropped CSV/XLSX as the data source. Returns true if accepted.
    @discardableResult
    private func handleDroppedDataFiles(_ urls: [URL]) -> Bool {
        guard mode == .custom else { return false }
        let supported = ["csv", "tsv", "xlsx"]
        guard let url = urls.first(where: { supported.contains($0.pathExtension.lowercased()) })
        else { return false }
        AppSettings.shared.lastDataSourceFolderPath = url.deletingLastPathComponent().path
        return loadAndBindDataSource(from: url, headerRow: true)
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
        // Inject the most recent CSV with ≥10 records — TEMPLATE MODE ONLY. The
        // Custom Designer opens with NO bound data (empty database pane, single
        // label), so it must never auto-load an Exports CSV.
        if mode == .template, let result = findMostRecentCSV(minRecords: 10) {
            injectDesignerRecords(result.records, filename: result.url.lastPathComponent)
        }
        // Inject the templates-folder list so the designer's Open dialog can list
        // them — TEMPLATE MODE ONLY. The Custom Designer has no template picker and
        // must never receive template state (it would be the only thing that could
        // surface a template-open prompt in custom mode).
        TemplateStore.shared.reload()
        if mode == .template { injectDesignerTemplates() }
        injectColumnConfig()
        injectDesignerPrefs()
        // Custom mode: seed the print header with the latest printer/cassette state
        // and re-inject any already-bound data source (so a reload keeps the binding).
        if mode == .custom {
            injectPrinters()
            injectCassettes()
            injectActiveJobs()
            if dataSource != nil { injectBoundData() }
        }
        if let idx = pendingEditTemplateIndex {
            // Editing for the print window: load that template, skip the picker.
            applyPendingEdit(idx)
        } else if pendingOpenCustomDoc != nil {
            // Finder opened a ".vlcus" (custom mode): load canvas + embedded data.
            applyPendingOpenCustomDoc()
        } else if pendingOpenTemplate != nil {
            // Finder opened a ".vltmp" (template mode): load it into the canvas.
            applyPendingOpenTemplate()
        } else if mode == .custom {
            // Custom Designer standalone launch: open a BLANK custom design — never
            // the template Open picker, and with no bound data. The page's
            // newBlankCustomDesign() clears the canvas + title ("Untitled Custom
            // Design") and leaves the database pane empty.
            webView.evaluateJavaScript("window._printEdit=false; if(typeof newBlankCustomDesign==='function')newBlankCustomDesign();", completionHandler: nil)
        } else {
            // Template Designer standalone mode: ensure the New/Open/Save toolbar
            // (not the print-edit Return buttons) and open the template picker.
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
            // Custom mode sends the current "first row is headers" toggle so the
            // xlsx read matches what the user expects. Template mode ignores it.
            let headerRow = (body["payload"] as? [String: Any])?["headerRow"] as? Bool ?? true
            browseForDataSource(headerRow: headerRow)

        case "refreshDataSource":
            // Re-read the stored path (re-pick if it moved) and re-inject.
            refreshDataSource()

        case "clearDataSource":
            // Custom Designer only — unbind the data source. The canvas returns to
            // the single-label (no-data) state and the DB pane shows the empty
            // "choose a file" state. The page clears window._boundData itself.
            if mode == .custom { dataSource = nil }

        case "editRecord":
            // Custom Designer only — live in-place edit of a bound-record field from
            // the database pane. Updates the in-memory BoundDataSource so the edit
            // persists into the .vlcus on save and the printed/preview output
            // reflects it. NOTE: we never write back to the original CSV/Excel file
            // (the .vlcus owns the data snapshot).
            if mode == .custom, var ds = dataSource,
               let p = body["payload"] as? [String: Any],
               let index = p["index"] as? Int,
               let field = p["field"] as? String,
               let value = p["value"] as? String,
               index >= 0, index < ds.records.count {
                var f = ds.records[index].fields
                f[field] = value
                ds.records[index] = WireRecord(side: f["_Side"] ?? ds.records[index].side,
                                               wireID: f["Number"] ?? ds.records[index].wireID,
                                               fields: f)
                dataSource = ds
            }

        case "printCustom":
            // Custom Designer only — render the current canvas as a single label
            // and submit it to the IPC print queue.
            handlePrintCustom(body["payload"])

        case "cancelCustomPrint":
            // Custom Designer only — ask the Engine to cancel the in-flight job by
            // id (falls back to the last submitted job). Best-effort over IPC.
            if mode == .custom {
                let jobId = (body["payload"] as? [String: Any])?["jobId"] as? String
                (printBackend as? IPCPrintBackend)?.cancel(jobId: jobId)
            }

        case "saveCustomDocument":
            // Custom Designer only — write the current canvas + embedded data as a
            // ".vlcus" document (Finder-openable). Shows a Save panel.
            handleSaveCustomDocument(body["payload"])

        case "deleteTemplate":
            if let p = body["payload"] as? [String: Any], let id = p["id"] as? String {
                confirmAndDeleteTemplate(id: id, name: p["name"] as? String ?? "this template")
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

        case "setDesignerPrefs":
            if let p = body["payload"] as? [String: Any] {
                if let v = p["snapGrid"] as? Bool { AppSettings.shared.designerSnapGrid = v }
                if let v = p["snapObjects"] as? Bool { AppSettings.shared.designerSnapObjects = v }
                if let v = p["gridSize"] as? Double { AppSettings.shared.designerGridSize = v }
                if let v = p["recH"] as? Double { AppSettings.shared.designerRecordsHeight = v }
                if let v = p["propW"] as? Double { AppSettings.shared.designerPropsWidth = v }
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

// MARK: – Custom-mode file-drop container (#19)
//
// Hosts the WKWebView and accepts Finder drops of a CSV/XLSX onto the window so the
// Custom Designer can open a data file by drag-and-drop. The web view's own dragged
// types are unregistered in present() so OS file drags fall through to this
// container; intra-page HTML5 drag-and-drop is unaffected (it never crosses into
// AppKit's dragging session).
@MainActor
final class DesignerDropView: NSView {
    var onDragEnter: (@MainActor () -> Void)?
    var onDragExit: (@MainActor () -> Void)?
    var onDropFiles: (@MainActor ([URL]) -> Bool)?

    private static let accepted: Set<String> = ["csv", "tsv", "xlsx"]

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func hasSupported(_ info: NSDraggingInfo) -> Bool {
        fileURLs(info).contains { Self.accepted.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasSupported(sender) else { return [] }
        onDragEnter?()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasSupported(sender) ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hasSupported(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragExit?()
        let good = fileURLs(sender).filter { Self.accepted.contains($0.pathExtension.lowercased()) }
        guard !good.isEmpty else { return false }
        return onDropFiles?(good) ?? false
    }
}

// String.jsonQuoted is defined in VectorLabelCore (Core/Bridge.swift)
