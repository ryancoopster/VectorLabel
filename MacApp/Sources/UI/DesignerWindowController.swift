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
    private var tabBar: BrowserTabBar?
    private var contentArea: NSView?
    /// One open document per tab, each with its own WKWebView (full live state — canvas,
    /// undo, bound data). The print-edit round-trip uses a single tab with the bar hidden.
    private var tabs: [DesignerTab] = []
    private var activeID: String?
    private var activeTab: DesignerTab? { tabs.first { $0.id == activeID } }
    /// Back-compat accessor → the active tab's web view (most of the controller uses this).
    private var webView: WKWebView? { activeTab?.webView }
    private var closeObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    /// Template index to load on the next designer load (print-window editing).
    private var pendingEditTemplateIndex: Int?
    /// True while the designer is open to edit a template for the print window.
    private var designerForPrintEdit = false

    /// A template/doc to inject into the ACTIVE tab once it loads (a new tab is created
    /// per open; these live on the tab so didFinish applies the right one). Computed →
    /// the active tab.
    private var pendingOpenTemplate: VLTemplate? {
        get { activeTab?.pendingOpenTemplate } set { activeTab?.pendingOpenTemplate = newValue }
    }
    private var pendingOpenCustomDoc: CustomLabelDocument? {
        get { activeTab?.pendingOpenCustomDoc } set { activeTab?.pendingOpenCustomDoc = newValue }
    }
    private var pendingInjectJS: String? {
        get { activeTab?.pendingInjectJS } set { activeTab?.pendingInjectJS = newValue }
    }

    /// Invoked when the print-edit round-trip ends — either the user saved and
    /// returned, or closed the designer. `saved` is whether a save happened on
    /// this return; `templateIndex` echoes the index being edited (if known).
    /// Hosts use this to refocus/refresh the print window.
    public var onEditReturn: ((_ saved: Bool, _ templateIndex: Int?) -> Void)?

    /// Fired when the user chooses "Cancel All" in the print-edit unsaved-changes
    /// prompt: abandon the edit AND cancel the underlying print (the host records it
    /// to Recent Prints as cancelled and closes the print window).
    public var onEditCancelAll: (() -> Void)?

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

    /// The bound data source for the Custom Designer. Either imported (path set) or
    /// created on the fly in the document (path nil — the data lives only in the .vlcus).
    private struct BoundDataSource {
        /// Source file URL, or nil for a from-scratch in-document dataset.
        var path: URL?
        /// Display name (the source file name, or a generic name for from-scratch data).
        var filename: String
        /// Whether the first row of the file supplies column headers. Only
        /// meaningful for .xlsx; CSV always has a header row (WireExportParser).
        var headerRow: Bool
        /// Parsed records, one per data row — the print path renders one label each.
        var records: [WireRecord]
        /// Column names in display order (the union across records, header order).
        var columns: [String]
    }

    /// One open designer document — its own WKWebView + per-document state.
    @MainActor
    private final class DesignerTab {
        let id = UUID().uuidString
        let webView: WKWebView
        var dataSource: BoundDataSource?
        var isDirty = false
        var pendingOpenTemplate: VLTemplate?
        var pendingOpenCustomDoc: CustomLabelDocument?
        /// One-shot JS applied once the page loads — used to open an in-app import (.BWT/.lbx)
        /// into a fresh tab via the page's initImportedDocument().
        var pendingInjectJS: String?
        var webViewReady = false
        /// Set when the tab finished loading while it wasn't the visible tab (its canvas
        /// had 0 width, so it couldn't self-center). `activateTab` centers it when shown.
        var needsCenter = false
        /// The tab loads its page while hidden; when true, `didFinish` switches to it once
        /// it's painted (so a new "+" tab never flashes a blank white web view).
        var activateOnLoad = false
        var title: String
        init(webView: WKWebView, title: String) { self.webView = webView; self.title = title }
    }

    private var dataSource: BoundDataSource? {
        get { activeTab?.dataSource } set { activeTab?.dataSource = newValue }
    }

    // MARK: – Unsaved-changes / close handling
    /// Mirrors the web designer's unsaved-changes state (setDirty messages). Per tab.
    private var isDirty: Bool {
        get { activeTab?.isDirty ?? false } set { activeTab?.isDirty = newValue }
    }
    /// What to do once a save triggered from a close prompt completes. The save always
    /// runs on the ACTIVE tab (close flows activate the target tab first).
    private enum AfterSave { case none, closeTab, closeTabThenSweep, closeTabThenTerminate, terminate }
    private var afterSave: AfterSave = .none

    /// True once the active tab's webview has finished loading (didFinish). A reopen must
    /// not push a doc into an un-loaded page. Per tab.
    private var webViewReady: Bool {
        get { activeTab?.webViewReady ?? false } set { activeTab?.webViewReady = newValue }
    }
    /// Polls the Engine's on-disk supply catalog (this designer is a separate
    /// process) and pushes changes into the web UI live.
    private var catalogPollTimer: Timer?

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
    public func openTemplate(_ template: VLTemplate, displayName: String? = nil) {
        // Each open lands in its own tab (full live state), so there's never a canvas to
        // clobber. A fresh tab applies its pending template on didFinish. The tab title is
        // the file name (preferred) — hosts pass it in; falls back to the template's name.
        newDocTab(title: displayName ?? (template.name.isEmpty ? nil : template.name))?
            .pendingOpenTemplate = template
    }

    /// Open the designer and load `doc`'s canvas + embedded data in a new tab (custom
    /// mode — used by the Custom Designer's Finder ".vlcus" open handler and Reprint).
    /// The tab title is the file name (preferred); falls back to the doc's name.
    public func openCustomDocument(_ doc: CustomLabelDocument, displayName: String? = nil) {
        guard mode == .custom else { return }
        newDocTab(title: displayName ?? (doc.name.isEmpty ? nil : doc.name))?
            .pendingOpenCustomDoc = doc
    }

    /// The tab a new document / in-app open / import loads into: cold → build the window +
    /// first tab; warm → a new tab. The tab loads its page hidden and switches in once painted.
    @discardableResult
    private func newDocTab(title: String?) -> DesignerTab? {
        let tab: DesignerTab?
        if window == nil { present(editTemplateIndex: nil); tab = tabs.last } else { tab = addTab() }
        if let t = tab, let title, !title.isEmpty { t.title = title; refreshTabBar() }
        return tab
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

        buildWindow()
        guard window != nil else { return }
        addTab()   // first tab; a pending open template/doc is applied on its didFinish
    }

    /// Build a fresh WKWebView for a tab — its own message handler + HTML load. Returns
    /// nil if the designer HTML can't be located.
    private func makeWebView() -> WKWebView? {
        guard let htmlURL = devHTMLURL("VectorLabelDesigner")
                            ?? CoreResources.url("VectorLabelDesigner", "html")
        else { return nil }
        let config = WKWebViewConfiguration()
        config.preferences.setValue(ProcessInfo.processInfo.environment["VL_DEV_HTML"] != nil,
                                    forKey: "developerExtrasEnabled")
        let contentController = WKUserContentController()
        contentController.add(self, name: "vectorlabel")
        let theme = AppSettings.shared.isLight ? "light" : ""
        let modeJS = (mode == .custom) ? "window._designerMode='custom';" : ""
        contentController.addUserScript(WKUserScript(
            source: "document.documentElement.dataset.theme='\(theme)';\(modeJS)",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        contentController.addUserScript(WKUserScript(
            source: "window.__VL_BUILD__='\(BuildInfo.build)'; window.__VL_CATALOG__=\(SupplyCatalogStore.webCatalogJSON(forModel: ""));"
                  + " window.__VL_FONTS__=\(Self.systemFontFamiliesJSON());",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = contentController
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self   // so <input type=file> shows an NSOpenPanel (image picker)
        wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        return wv
    }

    /// Open a new tab (blank, or destined to receive a pending open template/doc on load).
    @discardableResult
    private func addTab(title: String? = nil) -> DesignerTab? {
        guard let wv = makeWebView() else {
            // HTML not found. In print-edit mode fire onEditReturn so the host isn't
            // left with no visible window.
            if designerForPrintEdit {
                let idx = pendingEditTemplateIndex
                designerForPrintEdit = false; pendingEditTemplateIndex = nil
                onEditReturn?(false, idx)
            }
            return nil
        }
        let tab = DesignerTab(webView: wv,
                              title: title ?? (mode == .custom ? "Untitled Custom Design" : "Untitled Template"))
        // Load the page while HIDDEN, keeping the current tab on screen, so the new tab
        // never flashes a blank white web view — didFinish switches to it once it's painted.
        wv.isHidden = true
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
        // Only the newest tab auto-switches when it finishes loading (opening several files
        // at once leaves the earlier ones loading quietly in the background).
        for t in tabs { t.activateOnLoad = false }
        tab.activateOnLoad = true
        refreshTabBar()   // show the new chip right away (it becomes active once painted)
        return tab
    }

    private func activateTab(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeID = id
        for t in tabs { t.webView.isHidden = (t.id != id) }
        refreshTabBar()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(activeTab?.webView)
        // A tab that loaded while hidden couldn't center its canvas (0 width). Now that it
        // has real bounds, force a layout pass and ask it to center — once.
        if let t = activeTab, t.needsCenter, t.webViewReady {
            t.needsCenter = false
            let wv = t.webView
            wv.layoutSubtreeIfNeeded()
            DispatchQueue.main.async {
                wv.evaluateJavaScript("if(typeof centerCanvasWhenReady==='function')centerCanvasWhenReady(0);",
                                      completionHandler: nil)
            }
        }
    }

    private func refreshTabBar() {
        tabBar?.setItems(tabs.map { .init(id: $0.id, title: $0.title, dirty: $0.isDirty) }, active: activeID)
    }

    /// User clicked a tab's ✕ — prompt if that tab has unsaved changes, then close it.
    private func requestCloseTab(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activateTab(id)   // the tab being closed becomes active, so save/finishSave hit it
        if tab.isDirty {
            if promptUnsaved(allowCancel: true, then: .closeTab) { closeActiveTab() }  // Don't Save
            // Save → finishSave closes it; Cancel → it stays open.
        } else {
            closeActiveTab()
        }
    }

    /// Close the active tab (no prompt — callers handle unsaved). Closing the last tab
    /// closes the whole window.
    private func closeActiveTab() {
        guard let tab = activeTab, let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.webView.configuration.userContentController.removeScriptMessageHandler(forName: "vectorlabel")
        tab.webView.navigationDelegate = nil
        tab.webView.removeFromSuperview()
        tabs.remove(at: idx)
        if tabs.isEmpty { window?.close(); return }
        activateTab(tabs[min(idx, tabs.count - 1)].id)
    }

    /// Window-✕ path: close every tab, prompting once per tab with unsaved changes, then
    /// close the window. Drives the async saves — a Save resolves via finishSave, which
    /// re-enters this sweep for the next dirty tab. Cancel on any tab aborts the close.
    private func sweepDirtyTabsThenClose() {
        guard let dirty = tabs.first(where: { $0.isDirty }) else {
            window?.close()   // nothing left unsaved → drop the remaining clean tabs + close
            return
        }
        activateTab(dirty.id)   // show the user which document they're being asked about
        if promptUnsaved(allowCancel: true, then: .closeTabThenSweep) {
            closeActiveTab()               // Don't Save → discard this tab…
            sweepDirtyTabsThenClose()      // …and continue with the next
        }
        // Save → finishSave(.closeTabThenSweep) continues the sweep; Cancel → stop here.
    }

    /// Broadcast a script to every tab's web view (printer/theme/catalog updates keep all
    /// open documents current, not just the visible one).
    private func evalAll(_ js: String) { for t in tabs { t.webView.evaluateJavaScript(js, completionHandler: nil) } }

    /// Create the window shell: an NSPanel hosting a tab bar (normal mode) over a content
    /// area that holds the active tab's web view. Print-edit mode omits the tab bar.
    private func buildWindow() {
        guard (devHTMLURL("VectorLabelDesigner") ?? CoreResources.url("VectorLabelDesigner", "html")) != nil else {
            if designerForPrintEdit {
                let idx = pendingEditTemplateIndex
                designerForPrintEdit = false; pendingEditTemplateIndex = nil
                onEditReturn?(false, idx)
            }
            return
        }
        let area = NSView(); area.translatesAutoresizingMaskIntoConstraints = false
        // Themed backing so the first tab's brief pre-paint moment isn't a white flash.
        area.wantsLayer = true
        area.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.contentArea = area
        let container = NSView()
        if designerForPrintEdit {
            // Single-document editor for the print window: no tab bar.
            container.addSubview(area)
            NSLayoutConstraint.activate([
                area.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                area.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                area.topAnchor.constraint(equalTo: container.topAnchor),
                area.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        } else {
            let bar = BrowserTabBar(showsAdd: true)
            bar.onSelect = { [weak self] id in self?.activateTab(id) }
            bar.onClose  = { [weak self] id in self?.requestCloseTab(id) }
            bar.onAdd    = { [weak self] in self?.addTab() }
            self.tabBar = bar
            container.addSubview(bar); container.addSubview(area)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: container.topAnchor),
                bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                area.topAnchor.constraint(equalTo: bar.bottomAnchor),
                area.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                area.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                area.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        }

        // Use NSPanel with .nonactivatingPanel so the window appears without
        // stealing activation from a host menu bar status item.
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        win.title = (mode == .custom) ? "VectorLabel — Custom Designer"
                                      : "VectorLabel — Template Designer"
        win.contentView = container
        win.delegate = self   // unsaved-changes prompt on close (windowShouldClose)
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        win.applyVLSizing(autosaveName: (mode == .custom) ? "VLCustomDesignerWindow" : "VLDesignerWindow",
                          defaultContentSize: NSSize(width: 1280, height: 860))
        // Floor the width so the top-bar buttons never wrap/overflow (the Template Designer
        // header is the widest). Applies to both modes; templates get a bit more headroom.
        win.contentMinSize = (mode == .custom) ? NSSize(width: 1080, height: 520)
                                               : NSSize(width: 1180, height: 520)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win

        // Custom mode only: own a print backend, observe its status, and inject
        // printer/cassette state into the designer once the page loads.
        if mode == .custom { startPrintBackendIfNeeded() }

        // Keep every open tab's column config / presets / theme / catalog current.
        AppSettings.shared.$recordColumnOrder.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.injectColumnConfig() }.store(in: &cancellables)
        AppSettings.shared.$recordHiddenColumns.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.injectColumnConfig() }.store(in: &cancellables)
        AppSettings.shared.$recordColumnWidths.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.injectColumnConfig() }.store(in: &cancellables)
        AppSettings.shared.$filterSortPresetsJSON.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.injectFilterSortPresets() }.store(in: &cancellables)
        AppSettings.shared.$appearance.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.evalAll("if(typeof setTheme==='function')setTheme('\(AppSettings.shared.effectiveTheme)')")
            }.store(in: &cancellables)
        AppSettings.shared.$systemAppearanceTick.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.evalAll("if(typeof setTheme==='function')setTheme('\(AppSettings.shared.effectiveTheme)')")
            }.store(in: &cancellables)
        // Live-sync the supply catalog from the Engine's edits.
        catalogPollTimer?.invalidate()
        catalogPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if SupplyCatalogStore.reloadSnapshotFromDisk() { self.reinjectCatalog() }
            }
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                for t in self.tabs {
                    t.webView.navigationDelegate = nil
                    t.webView.configuration.userContentController
                        .removeScriptMessageHandler(forName: "vectorlabel")
                }
                self.tabs.removeAll(); self.activeID = nil
                self.window = nil; self.tabBar = nil; self.contentArea = nil
                self.catalogPollTimer?.invalidate(); self.catalogPollTimer = nil   // stop the 2s disk poll
                self.cancellables.removeAll()
                // Custom mode: tear down the print backend's status watcher.
                self.printBackend?.stop()
                self.printBackend = nil
                self.lastStatus = nil
                if let token = self.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.closeObserver = nil
                }
                if self.mode == .template { TemplateStore.shared.reload() }
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
        if !records.isEmpty {
            // Keep the data even when there's no source file — a from-scratch dataset
            // lives only in the .vlcus snapshot (path nil).
            dataSource = BoundDataSource(path: doc.dataSourceURL,
                                         filename: doc.dataSourceURL?.lastPathComponent ?? "Custom data",
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
        let supplyIDJSON = (doc.template.supplyID ?? "").jsonQuoted
        let geomJSON = doc.template.supplyGeometry
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let js = """
        if(typeof initCustomDocument==='function')initCustomDocument({\
        name:\(nameJSON),specN:\(specJSON),objs:\(objJSON),copies:\(doc.copies),\
        cutMode:\(doc.cutMode.rawValue.jsonQuoted),\
        supplyID:\(supplyIDJSON),supplyGeometry:\(geomJSON),\
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
            "if(typeof initDesignerPrefs==='function')initDesignerPrefs({snapGrid:\(s.designerSnapGrid),snapObjects:\(s.designerSnapObjects),gridSize:\(s.designerGridSize),recH:\(s.designerRecordsHeight),propW:\(s.designerPropsWidth),dbH:\(s.designerDatabaseHeight),feedToClearByPrinter:\(s.feedToClearByPrinterJSON()),feedToClearDefault:\(s.feedToClearBeforePrint)});",
            completionHandler: nil
        )
    }

    /// Push the shared record-column config (order/hidden/widths) into EVERY tab (this is
    /// shared AppSettings state, and it's driven by live observers — background tabs must
    /// stay current, not just the active one).
    private func injectColumnConfig() {
        evalAll("if(typeof applyColumnConfig==='function')applyColumnConfig(\(AppSettings.shared.columnConfigJSON()));")
    }

    /// Push the shared filter/sort presets into every tab (same store as the Print window),
    /// so presets saved in either window appear in all open tabs.
    private func injectFilterSortPresets() {
        evalAll("if(typeof applyFilterSortPresets==='function')applyFilterSortPresets(\(AppSettings.shared.filterSortPresetsJSON));")
    }

    /// Show a Finder open panel so the user can load a template from any folder,
    /// then inject the chosen template into the designer.
    private func browseForTemplate() {
        let panel = NSOpenPanel()
        // Accept the new ".vltmp" type, the legacy ".json"/".vlt.json" forms, a Brady
        // Workstation template (".BWT") and a Brother P-touch template (".lbx") — the last
        // two are auto-converted on selection.
        var types: [UTType] = [.json]
        if let vltmp = UTType(filenameExtension: TemplateStore.templateExtension) { types.append(vltmp) }
        if let bwt = UTType(filenameExtension: "bwt") { types.append(bwt) }
        if let lbx = UTType(filenameExtension: "lbx") { types.append(lbx) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true   // ".BWT"/".lbx" may have no registered UTI
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = AppSettings.shared.templatesFolderURL
        panel.message = "Open a VectorLabel template (.vltmp), Brady (.BWT) or Brother P-touch (.lbx)"
        panel.level = .modalPanel  // above the floating designer window
        // The designer window is a .nonactivatingPanel, so the app may not be active —
        // activate it first or the modeless open panel can't become key (unclickable).
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // The pick may be an online-only cloud stub (Dropbox/iCloud) — make it
                // local before reading; cancelling the download simply does nothing.
                CloudFile.materialize([url], for: self.window) { [weak self] result in
                    guard case .ready = result, let self else { return }
                    // Route by file type: ".BWT"/".lbx" are converted; anything else opens as a
                    // VectorLabel template — each into its own new tab (like a Finder open), so the
                    // active canvas is never clobbered and there's no stale-active-tab race.
                    let ext = url.pathExtension.lowercased()
                    if ext == "bwt" || ext == "lbx" { self.performImport(from: url) }
                    else if let tpl = TemplateStore.loadTemplate(from: url) {
                        self.openTemplate(tpl, displayName: url.deletingPathExtension().lastPathComponent)
                    } else {
                        self.presentImportError(url, reason: "This file isn’t a valid VectorLabel template.")
                    }
                }
            }
        }
    }

    /// Custom Designer "Open…": pick a VectorLabel label (".vlcus") OR a third-party
    /// template (Brady ".BWT" / Brother P-touch ".lbx"), routing by file type — the
    /// templates are auto-converted, a ".vlcus" opens normally.
    private func browseForCustomOpen() {
        let panel = NSOpenPanel()
        var types: [UTType] = []
        if let vlcus = UTType(filenameExtension: CustomLabelStore.fileExtension) { types.append(vlcus) }
        if let bwt = UTType(filenameExtension: "bwt") { types.append(bwt) }
        if let lbx = UTType(filenameExtension: "lbx") { types.append(lbx) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.allowsOtherFileTypes = true     // ".BWT"/".lbx" may have no registered UTI
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = CustomLabelStore.defaultFolderURL
        panel.message = "Open a VectorLabel label (.vlcus), Brady (.BWT) or Brother P-touch (.lbx)"
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // Online-only stub? Download before reading (cancel → nothing happens).
                CloudFile.materialize([url], for: self.window) { [weak self] result in
                    guard case .ready = result, let self else { return }
                    let ext = url.pathExtension.lowercased()
                    if ext == "bwt" || ext == "lbx" {
                        self.performImport(from: url)
                    } else if let doc = CustomLabelStore.load(from: url) {
                        self.openCustomDocument(doc, displayName: url.deletingPathExtension().lastPathComponent)
                    } else {
                        self.presentImportError(url, reason: "This file couldn't be opened. Choose a .vlcus, .BWT or .lbx file.")
                    }
                }
            }
        }
    }

    /// Import a third-party template — Brady ".BWT" or Brother P-touch ".lbx" — dispatching
    /// by file type, and load it as a new unsaved document.
    private func performImport(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            presentImportError(url, reason: "The file couldn't be read.")
            return
        }
        let ext = url.pathExtension.lowercased()
        let design: ImportedDesign? = (ext == "lbx") ? BrotherLBXImporter.parse(data)
                                                      : BradyBWTImporter.parse(data)
        guard let imp = design else {
            presentImportError(url, reason: ext == "lbx"
                ? "This Brother P-touch label couldn't be read — no supported text, barcode, or line objects were found."
                : "This doesn't look like a supported Brady text template — no readable label fields were found. Barcode-only or image-only templates aren't supported yet.")
            return
        }
        // Open the import in its OWN tab (consistent with Finder-open and Open… of a .vlcus),
        // so nothing on the current canvas is clobbered — no replace prompt needed.
        let sourceName = url.deletingPathExtension().lastPathComponent
        guard let js = importedDocumentJS(imp, sourceName: sourceName) else {
            presentImportError(url, reason: "The imported label couldn’t be prepared.")
            return
        }
        newDocTab(title: sourceName)?.pendingInjectJS = js
    }

    /// Build the JS doc the page's `initImportedDocument` expects (applied into a fresh tab).
    private func importedDocumentJS(_ imp: ImportedDesign, sourceName: String) -> String? {
        guard let objData = try? JSONSerialization.data(withJSONObject: imp.objects),
              let objJSON = String(data: objData, encoding: .utf8) else { return nil }
        // Resolve the catalog supply. Brady die-cut imports carry a real part number that
        // resolves directly. Brother imports have none — match the P-touch tape group by
        // tape width so the correct tape is auto-selected (and switch the picker to it).
        var specN = imp.partNumber, supplyID = "", supplyGroup = ""
        var w = imp.widthInches, h = imp.heightInches
        if imp.supplyGroupHint == "ptouch", let m = matchPTouchSupply(tapeWidthInches: imp.widthInches) {
            supplyGroup = m.group
            supplyID = m.supply.id.uuidString
            specN = m.supply.primaryPartNumber
            w = m.supply.printableWidthInches; h = m.supply.printableHeightInches
        }
        let geom: [String: Any] = [
            "widthInches": w, "heightInches": h,
            "printableWidthInches": w, "printableHeightInches": h,
            "isContinuous": imp.isContinuous,
        ]
        let geomJSON = (try? JSONSerialization.data(withJSONObject: geom))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let warnJSON = (try? JSONSerialization.data(withJSONObject: imp.warnings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let name = sourceName.isEmpty ? imp.name : sourceName
        let js = """
        if(typeof initImportedDocument==='function')initImportedDocument({\
        name:\(name.jsonQuoted),specN:\(specN.jsonQuoted),supplyID:\(supplyID.jsonQuoted),\
        supplyGroup:\(supplyGroup.jsonQuoted),objs:\(objJSON),\
        supplyGeometry:\(geomJSON),canvasRot:\(imp.canvasRotation),\
        labelLengthInches:\(imp.labelLengthInches),autoLength:\(imp.autoLength),warnings:\(warnJSON)});
        """
        return js
    }

    /// Find the Brother P-touch tape whose printable width best matches an imported label,
    /// so a Brother ".lbx" auto-selects the right tape size. Returns the group name + supply.
    private func matchPTouchSupply(tapeWidthInches: Double) -> (group: String, supply: Supply)? {
        let cat = SupplyCatalogStore.snapshot
        guard let group = cat.groups.first(where: { g in
            g.name.lowercased().contains("p-touch")
                || g.printerModels.contains(where: { $0.uppercased().hasPrefix("PT-") })
        }) else { return nil }
        let supplies = group.categories.flatMap { $0.supplies }.filter { $0.kind == .continuous }
        guard let best = supplies.min(by: {
            abs($0.printableWidthInches - tapeWidthInches) < abs($1.printableWidthInches - tapeWidthInches)
        }) else { return nil }
        return (group.name, best)
    }

    private func presentImportError(_ url: URL, reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't import “\(url.lastPathComponent)”"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        if let win = window { alert.beginSheetModal(for: win, completionHandler: nil) }
        else { alert.runModal() }
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
        // Activate first (the designer window is a .nonactivatingPanel) so this modeless
        // open panel can become key — otherwise it appears but can't be clicked.
        NSApp.activate(ignoringOtherApps: true)
        // Bind to the tab that opened the browser, not whatever is active when the modeless
        // panel completes (the user can switch tabs meanwhile). No tab is closed here, so the
        // accessor swap + defer restore is clean.
        let targetTab = activeTab
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // Online-only stub? Download first. The tab swap happens INSIDE the
                // ready callback so the binding still targets the tab that opened the
                // browser (`targetTab` was captured before the panel began).
                CloudFile.materialize([url], for: self.window) { [weak self] result in
                    guard case .ready = result, let self else { return }
                    let prevActive = self.activeID
                    if let t = targetTab, self.tabs.contains(where: { $0.id == t.id }) { self.activeID = t.id }
                    defer { if let p = prevActive, self.tabs.contains(where: { $0.id == p }) { self.activeID = p } }
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
                                     filename: url.lastPathComponent,
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
        // A from-scratch dataset (no source file) has nothing to refresh from.
        guard let srcPath = ds.path else { return }
        if FileManager.default.fileExists(atPath: srcPath.path) {
            // fileExists is true for an online-only stub too — materialize before the
            // re-read (cancel → the previous binding stays as-is).
            CloudFile.materialize([srcPath], for: window) { [weak self] result in
                guard case .ready = result, let self else { return }
                self.loadAndBindDataSource(from: srcPath, headerRow: ds.headerRow)
            }
        } else {
            let panel = NSOpenPanel()
            var types: [UTType] = [.commaSeparatedText]
            if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
            types.append(.spreadsheet)
            panel.allowedContentTypes = types
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.directoryURL = srcPath.deletingLastPathComponent()
            panel.message = "“\(srcPath.lastPathComponent)” was moved or deleted. Choose the file again."
            panel.level = .modalPanel
            NSApp.activate(ignoringOtherApps: true)   // .nonactivatingPanel → make the open panel clickable
            let targetTab = activeTab   // re-bind the tab that asked to refresh, not the active one
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    // Online-only stub? Download first — the tab swap happens inside the
                    // ready callback so the re-bind still targets `targetTab`.
                    CloudFile.materialize([url], for: self.window) { [weak self] result in
                        guard case .ready = result, let self else { return }
                        let prevActive = self.activeID
                        if let t = targetTab, self.tabs.contains(where: { $0.id == t.id }) { self.activeID = t.id }
                        defer { if let p = prevActive, self.tabs.contains(where: { $0.id == p }) { self.activeID = p } }
                        AppSettings.shared.lastDataSourceFolderPath = url.deletingLastPathComponent().path
                        self.loadAndBindDataSource(from: url, headerRow: ds.headerRow)
                    }
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
        let fnJSON = ds.filename.jsonQuoted
        let isXLSX = ds.path?.pathExtension.lowercased() == "xlsx"
        wv.evaluateJavaScript(
            "if(typeof initBoundData==='function')initBoundData(\(recJSON),\(colJSON),\(fnJSON),\(ds.headerRow),\(isXLSX));",
            completionHandler: nil)
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
        let dicts: [[String: Any]] = (lastStatus?.printers ?? []).map { p in
            ["id": p.id, "name": p.name, "model": p.model, "serial": p.serial,
             "status": p.status, "supportsTelemetry": p.supportsTelemetry,
             "hasAutoCutter": p.hasAutoCutter, "ribbonLengthInches": p.ribbonLengthInches,
             "supportsFeedToClear": p.supportsFeedToClear,
             "cutOptions": p.cutOptions.map { ["mode": $0.mode.rawValue, "label": $0.label] }]
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
            dict[p.id] = c.webDict()   // shared mapping — see CassetteStatus+WebDict.swift
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) { return json }
        return "{}"
    }

    /// Push the current printer list into the designer (custom mode). No-ops until
    /// the page defines updateDesignerPrinters.
    private func injectPrinters() {
        // Broadcast to every tab — printer state is global + observer-driven, so a
        // backgrounded tab must not go stale (it never re-injects on activate).
        evalAll("if(typeof updateDesignerPrinters==='function')updateDesignerPrinters(\(printersJSONString()));")
    }

    /// Push the detected cassettes into every designer tab (custom mode).
    private func injectCassettes() {
        evalAll("if(typeof updateDesignerCassettes==='function')updateDesignerCassettes(\(cassettesJSONString()));")
    }

    /// Installed font FAMILIES (display names) as a JSON array, for the designer's font
    /// dropdown. Hidden/system-internal families (names starting with ".") are dropped.
    /// The designer merges these with its curated list; the renderer resolves any of them.
    static func systemFontFamiliesJSON() -> String {
        let families = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (try? String(data: JSONSerialization.data(withJSONObject: families), encoding: .utf8)) ?? "[]"
    }

    /// Push the latest supply catalog (the Engine's edits) into the designer.
    private func reinjectCatalog() {
        let json = SupplyCatalogStore.webCatalogJSON(forModel: "")
        // Broadcast — the 2s poll must keep every tab's catalog current, not just the active.
        evalAll("window.__VL_CATALOG__=\(json); if(typeof applyCatalog==='function')applyCatalog(window.__VL_CATALOG__);")
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
        // Broadcast the full active-job list to every tab; each tab's header matches its
        // own job by id, so a print started in a background tab keeps updating live.
        evalAll("if(typeof updateDesignerJobStatus==='function')updateDesignerJobStatus(\(activeJobsJSONString()));")
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
        // Orientation: canvasRot 90 = portrait override (continuous) or a 90° design
        // rotation (die-cut); absent/0 = the renderer's default. #14.
        if let rot = payload["canvasRot"] as? Int { tplDict["canvasRot"] = rot }
        else if let rotN = payload["canvasRot"] as? NSNumber { tplDict["canvasRot"] = rotN.intValue }
        // Supply identity + geometry snapshot, so a Reprint reopens the exact design
        // (mirrors the Save path; keeps the canvas size if the supply is later removed).
        if let sid = payload["supplyID"] as? String, !sid.isEmpty { tplDict["supplyID"] = sid }
        if let geom = payload["supplyGeometry"] as? [String: Any] { tplDict["supplyGeometry"] = geom }
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
        // defaults it per stock (continuous → eachLabel; die-cut → afterJobLast). Carried
        // into PrintJobFile.cutMode; the Engine's printer module stamps the per-label
        // cut at ENCODE time — this front-end ships printer-agnostic rasters, not VGL.
        let cutMode = CutMode(rawValue: (payload["cutMode"] as? String) ?? "") ?? .afterJobLast
        // "Feed to clear before printing" — prepend a blank lead label (built below).
        let feedToClear = (payload["feedToClear"] as? Bool) ?? false

        // Capture the full design (the ".vlcus" model) so a later Reprint REOPENS it in
        // the Custom Designer (Stage B) instead of blindly re-submitting. Serialized into
        // reprint.customDocJSON on the job and retained in done/. Built here on the main
        // actor (it reads the in-memory bound data source).
        let reprintInfo: ReprintInfo? = {
            let doc = customLabelDocument(from: template, copies: copies, cutMode: cutMode)
            guard let data = try? JSONEncoder().encode(doc),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return ReprintInfo(customDocJSON: json)
        }()

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
        // The part number actually loaded in this printer, so the renderer can use
        // its feed rotation when two parts of one supply rotate differently.
        let loadedPN = printBackend?.status?.printers.first(where: { $0.id == printerID })?.cassette?.partNumber

        // Render off the main thread (matching the print window), then submit back
        // on the main actor.
        DispatchQueue.global(qos: .userInitiated).async {
            // First render each row's raster once (rendering is the expensive part);
            // we then expand by `copies` and stamp the per-label cut command so the
            // chosen cut SETTING applies across the whole expanded label list (e.g.
            // afterJobLast cuts once after the very last copy of the last row).
            var rasters: [(pixels: [UInt8], width: Int, height: Int, landscape: Bool)] = []
            var maxLabelPx = 0
            for record in records {
                guard let rendered = LabelRenderer.render(template: template, record: record, offset: offset, loadedPartNumber: loadedPN) else { continue }
                maxLabelPx = max(maxLabelPx, rendered.width, rendered.height)
                for _ in 0..<copies { rasters.append(rendered) }
            }
            guard !rasters.isEmpty else { return }
            // Printer-agnostic rasters; the Engine encodes per target printer + stamps
            // the per-label cut from `cutMode` at print time.
            let part = loadedPN ?? template.labelSize?.partNumber ?? ""
            let renderedLabels = rasters.map {
                RenderedLabel(pixels: $0.pixels, width: $0.width, height: $0.height, partNumber: part,
                              landscape: $0.landscape)
            }
            // Feed-to-clear: the Engine synthesizes + prepends the blank lead label at print
            // time (from live media + the real label geometry); we only flag the job here.
            // Same pacing estimate the print window uses.
            let estLabelMs = RenderedLabel.estimatedPrintMs(maxDimensionPx: maxLabelPx)

            Task { @MainActor in
                let jobID = UUID().uuidString
                let job = PrintJobFile(
                    id: jobID,
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    sourceApp: "customdesigner",
                    title: templateName.isEmpty ? "Custom Label" : templateName,
                    templateName: templateName,
                    printerID: printerID,
                    copies: 1,            // copies are expanded into `renderedLabels` above
                    cutMode: cutMode,     // user-chosen cut setting (Phase 6)
                    estLabelMs: estLabelMs,
                    renderedLabels: renderedLabels,
                    reprint: reprintInfo,
                    feedToClear: feedToClear
                )
                do { try backend.submit(job) }
                catch {
                    // Submit failed: the job was NOT queued, so do NOT tell the page a
                    // print started. Surface it and bail. (F26)
                    NSLog("[DesignerWindowController] printCustom submit failed: \(error)")
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t start the print"
                    alert.informativeText = "The job could not be queued: \(error.localizedDescription)\n\nNothing was sent to the printer. Please try again."
                    alert.addButton(withTitle: "OK")
                    if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
                    return
                }
                // Hand the page its job id so it can match the Engine's published
                // status, and push an immediate status so the in-header progress +
                // Cancel control appear right away (updated live thereafter).
                self.webView?.evaluateJavaScript(
                    "if(typeof customPrintSubmitted==='function')customPrintSubmitted(\(renderedLabels.count),\(jobID.jsonQuoted));",
                    completionHandler: nil)
                self.injectActiveJobs()
            }
        }
    }

    /// Build the ".vlcus" document model from the current canvas `template` + the
    /// in-memory bound data snapshot (headers / rows / source path). Shared by Save
    /// (writes it to a file) and the Reprint capture (serialized into the job's
    /// `reprint.customDocJSON`) so a reprint reopens the exact printed design.
    /// Export the bound dataset to CSV or .xlsx via an NSSavePanel.
    private func handleExportDataset(_ payloadAny: Any?) {
        guard let ds = dataSource, !ds.records.isEmpty else {
            let a = NSAlert(); a.messageText = "Nothing to export"
            a.informativeText = "Add some rows or bind a data file first."; a.runModal(); return
        }
        let isXLSX = ((payloadAny as? [String: Any])?["format"] as? String) == "xlsx"
        let base = ds.path?.deletingPathExtension().lastPathComponent ?? "VectorLabel Data"
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = base + (isXLSX ? ".xlsx" : ".csv")
        if isXLSX, let t = UTType(filenameExtension: "xlsx") { panel.allowedContentTypes = [t] }
        else { panel.allowedContentTypes = [.commaSeparatedText] }
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let ds = self?.dataSource else { return }
                let data: Data? = isXLSX
                    ? XLSXWriter.data(headers: ds.columns, rows: ds.records.map { $0.fields })
                    : WireExportParser.csvText(records: ds.records, headers: ds.columns).data(using: .utf8)
                if let data = data {
                    do { try data.write(to: url, options: .atomic) }
                    catch {
                        let a = NSAlert(); a.messageText = "Export failed"
                        a.informativeText = error.localizedDescription; a.runModal()
                    }
                }
            }
        }
    }

    private func customLabelDocument(from template: VLTemplate, copies: Int, cutMode: CutMode) -> CustomLabelDocument {
        var rows: [[String: String]] = []
        var headers: [String] = []
        var srcPath = ""
        var headerRow = true
        if let ds = dataSource {
            headers = ds.columns
            rows = ds.records.map { $0.fields }
            srcPath = ds.path?.path ?? ""
            headerRow = ds.headerRow
        }
        return CustomLabelDocument(
            name: template.name,
            template: template,
            headers: headers,
            rows: rows,
            dataSourcePath: srcPath,
            dataSourceHeaderRow: headerRow,
            labelLengthInches: template.labelLengthInches ?? 0,
            cutMode: cutMode,
            copies: copies)
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
        // Orientation: canvasRot 90 = portrait override (continuous) or a 90° design
        // rotation (die-cut); absent/0 = the renderer's default. #14.
        if let rot = payload["canvasRot"] as? Int { tplDict["canvasRot"] = rot }
        else if let rotN = payload["canvasRot"] as? NSNumber { tplDict["canvasRot"] = rotN.intValue }
        // Supply identity + geometry snapshot (keep the canvas size if the supply is
        // later removed from the catalog).
        if let sid = payload["supplyID"] as? String, !sid.isEmpty { tplDict["supplyID"] = sid }
        if let geom = payload["supplyGeometry"] as? [String: Any] { tplDict["supplyGeometry"] = geom }
        guard let data = try? JSONSerialization.data(withJSONObject: tplDict),
              let template = try? JSONDecoder().decode(VLTemplate.self, from: data)
        else { return }
        let copies = max(1, (payload["copies"] as? Int) ?? 1)
        // The effective cut mode chosen in the designer, so the choice round-trips in the
        // .vlcus. Falls back to afterJobLast if absent/unrecognised (matches the system
        // default in PrintJobFile / PrinterManager).
        let cutMode = CutMode(rawValue: (payload["cutMode"] as? String) ?? "") ?? .afterJobLast

        let doc = customLabelDocument(from: template, copies: copies, cutMode: cutMode)

        // The tab that owns this save — captured now, because the modeless save panel below
        // lets the user switch tabs before it completes (don't rename/mark-clean the wrong tab).
        let savedTab = activeTab

        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: CustomLabelStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(name).\(CustomLabelStore.fileExtension)"
        panel.directoryURL = CustomLabelStore.defaultFolderURL
        panel.message = "Save this custom label (.vlcus)"
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)   // .nonactivatingPanel → make the save panel clickable
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard response == .OK, let url = panel.url else { self.cancelPendingSave(); return }
                // Point the active-tab accessors at the tab that owned the save (the user may
                // have switched tabs while the panel was open), then restore the view.
                let prevActive = self.activeID
                if let t = savedTab, self.tabs.contains(where: { $0.id == t.id }) { self.activeID = t.id }
                do {
                    try CustomLabelStore.save(doc, to: url)
                    // The tab now carries the saved file name (the header no longer shows it).
                    if let t = self.activeTab { t.title = CustomLabelStore.stem(url); self.refreshTabBar() }
                    self.webView?.evaluateJavaScript(
                        "if(typeof showToast==='function')showToast('Saved: '+\(CustomLabelStore.stem(url).jsonQuoted));",
                        completionHandler: nil)
                    self.finishSave()   // clears dirty + runs any close-after-save on the saved tab
                } catch {
                    self.cancelPendingSave()
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t save the custom label"
                    alert.informativeText = "\(error.localizedDescription)"
                    alert.runModal()
                }
                // Put the user back on the tab they were viewing.
                if let p = prevActive, self.tabs.contains(where: { $0.id == p }) {
                    if savedTab != nil, self.tabs.contains(where: { $0.id == savedTab!.id }) {
                        self.activeID = p                       // nothing closed → view never moved; just restore the pointer
                    } else if self.activeID != p {
                        self.activateTab(p)                     // a save-then-close moved the visible tab; re-show theirs
                    }
                }
            }
        }
    }

    // MARK: – Unsaved-changes prompt + close

    /// Standard unsaved-changes prompt. Returns true if the caller should proceed to
    /// close/terminate now (Don't Save), false to keep the window open (Cancel, or a
    /// save was started that finishes the action on completion).
    @discardableResult
    private func promptUnsaved(allowCancel: Bool, then action: AfterSave) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let what = mode == .custom ? "this custom label" : "this template"
        alert.messageText = "Do you want to save the changes you made to \(what)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Don't Save")
        if allowCancel { alert.addButton(withTitle: "Cancel") }
        switch alert.runModal() {
        case .alertFirstButtonReturn:  triggerSave(saveAs: false, then: action); return false
        case .alertSecondButtonReturn: triggerSave(saveAs: true,  then: action); return false
        case .alertThirdButtonReturn:  return true    // Don't Save
        default:                        return false   // Cancel
        }
    }

    /// Trigger a save from the close prompt; `afterSave` runs once it succeeds.
    private func triggerSave(saveAs: Bool, then action: AfterSave) {
        afterSave = action
        let js: String
        if mode == .template {
            js = saveAs ? "if(typeof saveAsTemplate==='function')saveAsTemplate()"
                        : "if(typeof saveTemplate==='function')saveTemplate()"
        } else {
            js = "if(typeof saveCustomDocument==='function')saveCustomDocument()"
        }
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Called by the save handlers after a successful save: clears the dirty flag
    /// and performs any pending close/terminate from the close prompt.
    private func finishSave() {
        isDirty = false   // setter → active tab
        webView?.evaluateJavaScript("if(typeof markClean==='function')markClean()", completionHandler: nil)
        refreshTabBar()
        let action = afterSave; afterSave = .none
        switch action {
        case .closeTab:              closeActiveTab()
        case .closeTabThenSweep:     closeActiveTab(); sweepDirtyTabsThenClose()
        case .closeTabThenTerminate: closeActiveTab(); sweepDirtyTabsThenTerminate()
        case .terminate:             NSApp.terminate(nil)
        case .none:                  break
        }
    }

    /// A pending save-on-close was abandoned (e.g. the save panel was dismissed).
    private func cancelPendingSave() { afterSave = .none }

    /// The Engine quit: prompt to save every tab with unsaved changes (no Cancel, since
    /// the suite is shutting down), then terminate.
    public func closeForEngineQuit() {
        guard window != nil, !designerForPrintEdit, tabs.contains(where: { $0.isDirty })
        else { NSApp.terminate(nil); return }
        sweepDirtyTabsThenTerminate()
    }

    /// Like `sweepDirtyTabsThenClose`, but for the Engine-quit shutdown: no Cancel, and it
    /// terminates once every tab is saved or discarded.
    private func sweepDirtyTabsThenTerminate() {
        guard let dirty = tabs.first(where: { $0.isDirty }) else { NSApp.terminate(nil); return }
        activateTab(dirty.id)
        if promptUnsaved(allowCancel: false, then: .closeTabThenTerminate) {
            closeActiveTab()                    // Don't Save → discard…
            sweepDirtyTabsThenTerminate()       // …and continue
        }
        // Save → finishSave(.closeTabThenTerminate) continues the sweep.
    }

    // MARK: – Dev HTML loader

    private func devHTMLURL(_ name: String) -> URL? {
        // Live-reload the HTML from the repo during development ONLY when opted in
        // via the VL_DEV_HTML environment variable. A shipped/installed app must NOT
        // probe ~/Documents / ~/Desktop here — even a fileExists() inside those
        // folders triggers the macOS privacy-access prompt on launch (and unsigned
        // beta builds re-prompt on every rebuild). With the flag unset we return nil
        // and the caller loads the bundled resource.
        guard ProcessInfo.processInfo.environment["VL_DEV_HTML"] != nil else { return nil }
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

// MARK: – NSWindowDelegate (unsaved-changes prompt on close)

extension DesignerWindowController: NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Editing a template for the print window: the title-bar close offers the
        // same Return choices as the toolbar, plus "Cancel All" (abandon the edit
        // AND cancel the underlying print). Never silently discard edits.
        if designerForPrintEdit {
            let alert = NSAlert()
            alert.messageText = "Finish editing this template?"
            alert.informativeText = "Save your changes and return to the print window, return without saving, or cancel the whole print."
            alert.addButton(withTitle: "Save & Return")       // .alertFirstButtonReturn
            alert.addButton(withTitle: "Save As & Return")    // .alertSecondButtonReturn
            alert.addButton(withTitle: "Cancel & Return")     // .alertThirdButtonReturn — discard, back to print window
            alert.addButton(withTitle: "Cancel All")          // abandon + cancel the print
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                webView?.evaluateJavaScript("if(typeof edPrintSave==='function')edPrintSave()", completionHandler: nil)
                return false   // edPrintSave → editReturn{save} → save + close + onEditReturn → returnFromEdit
            case .alertSecondButtonReturn:
                webView?.evaluateJavaScript("if(typeof edPrintSaveAs==='function')edPrintSaveAs()", completionHandler: nil)
                return false   // opens the save-name modal; editReturn fires after saving
            case .alertThirdButtonReturn:
                webView?.evaluateJavaScript("if(typeof edPrintCancel==='function')edPrintCancel()", completionHandler: nil)
                return false   // editReturn{save:false} → onEditReturn → returnFromEdit
            default:           // Cancel All
                designerForPrintEdit = false   // suppress the willClose onEditReturn path
                onEditCancelAll?()
                return true                    // close the designer now
            }
        }
        // Normal mode: closing the window closes every tab. If none have unsaved changes
        // it closes at once; otherwise the sweep prompts per dirty tab and closes the
        // window once they're all resolved (Cancel on any tab aborts the whole close).
        if !tabs.contains(where: { $0.isDirty }) { return true }
        sweepDirtyTabsThenClose()
        return false
    }

    /// True while the designer has an on-screen window. The window is an NSPanel,
    /// which AppKit excludes from its "terminate after last window closed" count,
    /// so the app delegate consults this to avoid quitting when a transient
    /// WKWebView popup (e.g. a `<select>` dropdown) closes while the designer is
    /// still open.
    public var hasVisibleWindow: Bool { window?.isVisible ?? false }

    /// The designer's window (nil before the first open) — lets the app delegates host
    /// sheets (e.g. the cloud-download panel for Finder-opened documents) on it.
    public var hostWindow: NSWindow? { window }
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
        NSApp.activate(ignoringOtherApps: true)   // .nonactivatingPanel → make the image picker clickable
        panel.begin { [weak self] response in
            guard response == .OK else { completionHandler(nil); return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                guard let self = self else { completionHandler(urls); return }
                // Online-only images must download before the page sees them. The page's
                // file input hangs unless the handler fires EXACTLY once on every path:
                // ready → the urls, cancelled/failed → nil (same as dismissing the panel).
                CloudFile.materialize(urls, for: self.window) { result in
                    if case .ready = result { completionHandler(urls) }
                    else { completionHandler(nil) }
                }
            }
        }
    }
}

// MARK: – WKNavigationDelegate (for designer auto-load)

extension DesignerWindowController: WKNavigationDelegate {
    /// Recover from a WebKit content-process crash — otherwise the designer is left a
    /// blank, dead window, which reads as "the app crashed". Reloading restores a
    /// working designer (the document-start scripts re-inject the theme + catalog).
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("[DesignerWindowController] web content process terminated — reloading")
        webView.reload()
    }

    /// A tab's page loads HIDDEN and only becomes visible in didFinish. If the load fails
    /// before didFinish, the tab would be stranded hidden with its pending doc unapplied —
    /// so un-strand it: reveal it (via activateOnLoad) and reload once.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recoverFailedLoad(webView, error)
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recoverFailedLoad(webView, error)
    }
    private func recoverFailedLoad(_ webView: WKWebView, _ error: Error) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        NSLog("[DesignerWindowController] tab load failed (\(error.localizedDescription)) — recovering")
        if tab.activateOnLoad { tab.activateOnLoad = false; activateTab(tab.id) }  // don't leave it hidden
        webView.reload()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Route to the tab whose web view just loaded.
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        tab.webViewReady = true   // page loaded — warm reopens may inject directly now
        // A tab that finished loading while it wasn't the visible tab loaded hidden (0-width
        // canvas → it can't self-center), so center it when it's next shown.
        tab.needsCenter = (tab.id != activeID)
        // Point the active-tab accessors (webView/dataSource/pending*) at THIS tab for the
        // injection below WITHOUT changing which tab is visible — so a background load
        // (e.g. opening several files at once) never steals focus from the active tab.
        // Restored (and possibly switched to) at the end of this method.
        let _prevActive = activeID
        activeID = tab.id
        // Re-assert the installed font families after load, in case the document-start
        // injection raced the page's own script (the font picker reads window.__VL_FONTS__
        // live, so this guarantees the full system list is present).
        webView.evaluateJavaScript("window.__VL_FONTS__=\(Self.systemFontFamiliesJSON());", completionHandler: nil)
        // Apply the current light/dark theme.
        webView.evaluateJavaScript("if(typeof setTheme==='function')setTheme('\(AppSettings.shared.effectiveTheme)')", completionHandler: nil)
        // Inject the most recent CSV with ≥10 records — TEMPLATE MODE ONLY. The
        // Custom Designer opens with NO bound data (empty database pane, single
        // label), so it must never auto-load an Exports CSV.
        if mode == .template, let result = findMostRecentCSV(minRecords: 10) {
            injectDesignerRecords(result.records, filename: result.url.lastPathComponent)
        }
        // Reading the Templates folder (under ~/Documents) triggers the macOS
        // "access your Documents folder" prompt and is pointless for the Custom
        // Designer (no template picker), so ONLY the Template Designer reloads +
        // injects the template list. This keeps the Custom Designer from prompting
        // for Documents access on launch.
        if mode == .template {
            TemplateStore.shared.reload()
            injectDesignerTemplates()
        }
        injectColumnConfig()
        injectFilterSortPresets()
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
        } else if let js = pendingInjectJS, !js.isEmpty {
            // In-app "Open…" import (.BWT/.lbx) landing in this fresh tab.
            pendingInjectJS = nil
            webView.evaluateJavaScript("window._printEdit=false; \(js)", completionHandler: nil)
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
        // Restore the visible tab (the injection above pointed the accessors at this tab).
        activeID = _prevActive
        // A freshly added "+"/opened tab loaded hidden — switch to it now that it's painted
        // (this is what prevents the blank-white flash).
        if tab.activateOnLoad {
            tab.activateOnLoad = false
            activateTab(tab.id)
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

        // Resolve the sending tab. User actions come from the visible (active) tab, so the
        // active-tab accessors are already correct; a background tab only posts during load
        // (e.g. setDirty), which we route explicitly below rather than activating it — so a
        // background load never steals focus.
        let msgTab = tabs.first(where: { $0.webView === message.webView })

        switch action {
        case "saveTemplate":
            if TemplateStore.shared.save(fromPayload: body["payload"]) {
                injectDesignerTemplates()   // refresh the Open list with the new file
                // The tab carries the saved name (the header no longer shows it).
                if let nm = (body["payload"] as? [String: Any])?["name"] as? String, !nm.isEmpty {
                    (msgTab ?? activeTab)?.title = nm; refreshTabBar()
                }
                finishSave()
            }

        case "listTemplates":
            TemplateStore.shared.reload()   // pick up renamed/added/removed files
            injectDesignerTemplates()

        case "browseTemplate":
            browseForTemplate()

        case "browseCustomOpen":
            browseForCustomOpen()

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

        case "syncBoundData":
            // Custom Designer only — the page mutated the dataset STRUCTURALLY (add row /
            // add column / rename column / paste / ripple / drag-fill). Rebuild the in-memory
            // dataSource from the full snapshot so it embeds into the .vlcus and drives
            // print/preview. A from-scratch dataset (no prior import) keeps path nil — it
            // lives only in the document. We never write back to the original file.
            if mode == .custom,
               let p = body["payload"] as? [String: Any],
               let cols = p["columns"] as? [String],
               let rowDicts = p["records"] as? [[String: Any]] {
                let recs: [WireRecord] = rowDicts.map { row in
                    var f: [String: String] = [:]
                    for (k, v) in row { f[k] = v as? String ?? String(describing: v) }
                    return WireRecord(side: f["_Side"] ?? "", wireID: f["Number"] ?? "", fields: f)
                }
                if var ds = dataSource {
                    ds.columns = cols; ds.records = recs
                    dataSource = ds
                } else {
                    dataSource = BoundDataSource(path: nil, filename: "Custom data",
                                                 headerRow: true, records: recs, columns: cols)
                }
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

        case "exportDataset":
            // Custom Designer only — write the current dataset out as CSV or .xlsx via a
            // save panel (the user may overwrite their original import if they choose).
            if mode == .custom { handleExportDataset(body["payload"]) }

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

        case "detectCassette":
            // Custom Designer only — force an on-demand cassette re-read so a stale
            // pre-flight error can clear without a physical reconnect. Best-effort over IPC.
            if mode == .custom {
                let id = (body["payload"] as? [String: Any])?["printerID"] as? String ?? ""
                if !id.isEmpty { printBackend?.requestCassetteRefresh(printerID: id) }
            }

        case "setDirty":
            // The web designer mirrors its unsaved-changes state + document name here. Route
            // to the sending tab (a background tab can post during load) so the right chip
            // updates. The name keeps the tab title in sync with picker/New loads that set
            // S.tplName purely in JS.
            let p = body["payload"] as? [String: Any]
            let tab = msgTab ?? activeTab
            tab?.isDirty = p?["dirty"] as? Bool ?? false
            if let nm = p?["name"] as? String, !nm.isEmpty { tab?.title = nm }
            if tab?.isDirty == true { afterSave = .none }   // a new edit cancels a pending close
            refreshTabBar()                                 // reflect the dot + title on the chip

        case "jsError":
            // Uncaught error inside the WKWebView — log prominently for diagnosis.
            let p = body["payload"] as? [String: Any] ?? [:]
            NSLog("[VL-JS-ERROR] \(p["msg"] ?? "") @ \(p["at"] ?? "") \(p["stack"] ?? "")")

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

        case "setFilterSortPresets":
            // Filter/sort presets are shared with the Print window via the same
            // AppSettings store, so a preset saved here shows up there and back.
            if let arr = body["payload"] as? [Any],
               let data = try? JSONSerialization.data(withJSONObject: arr),
               let json = String(data: data, encoding: .utf8) {
                AppSettings.shared.filterSortPresetsJSON = json
            }

        case "setDesignerPrefs":
            if let p = body["payload"] as? [String: Any] {
                if let v = p["snapGrid"] as? Bool { AppSettings.shared.designerSnapGrid = v }
                if let v = p["snapObjects"] as? Bool { AppSettings.shared.designerSnapObjects = v }
                if let v = p["gridSize"] as? Double { AppSettings.shared.designerGridSize = v }
                if let v = p["recH"] as? Double { AppSettings.shared.designerRecordsHeight = v }
                if let v = p["propW"] as? Double { AppSettings.shared.designerPropsWidth = v }
                if let v = p["dbH"] as? Double { AppSettings.shared.designerDatabaseHeight = v }
            }

        case "setFeedToClear":
            // Persist the feed-to-clear tick box PER PRINTER (key from the payload) so each
            // printer remembers its own choice across reopen.
            let payload = body["payload"] as? [String: Any]
            AppSettings.shared.setFeedToClear(forKey: (payload?["key"] as? String) ?? "",
                                              (payload?["value"] as? Bool) ?? false)

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
