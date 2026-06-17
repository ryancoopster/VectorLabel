import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import Combine
import ObjectiveC
import VectorLabelCore
import VectorLabelEngineKit
import VectorLabelUI

// MARK: – App entry point

@main
@MainActor
struct VectorLabelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // NSStatusItem is managed entirely by AppDelegate.
    // We use an empty scene here — the menu bar icon is set up in
    // applicationDidFinishLaunching via NSStatusBar.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: – AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // PrintWindowController is @MainActor; initialised in applicationDidFinishLaunching
    private var printWindowController: PrintWindowController!
    // Print backend the window submits through. In the combined app this wraps the
    // in-process PrinterManager; the window itself only sees the PrintBackend API.
    private var printBackend: PrintBackend!
    private var designerWindow: NSWindow?
    private var designerWebView: WKWebView?
    private var preferencesWindow: NSWindow?
    private var designerCloseObserver: NSObjectProtocol?
    private var preferencesCloseObserver: NSObjectProtocol?

    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    /// Loads an image asset from the Core resource bundle (works in both the dev
    /// `swift build` and the packaged .app). Returns nil if missing.
    private static func bundledImage(_ name: String, ext: String) -> NSImage? {
        CoreResources.image(name, ext)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // WKWebView requires a bundle identifier for its sandboxed WebContent process.
        // When running from SPM/Xcode without INFOPLIST_FILE set, inject it directly.
        // SPM cannot inject Info.plist. Set INFOPLIST_FILE in Xcode Build Settings
        // pointing to Info.plist at the repo root to get a proper bundle identifier.
        // As a dev fallback, register the ID in UserDefaults which WKWebView checks.
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel", forKey: "CFBundleIdentifier")
        }
        // Apply the saved light/dark appearance to the whole app at launch.
        AppSettings.shared.applyNativeAppearance()
        // Dock icon (also covers the dev binary, which has no bundle Info.plist).
        if let appIcon = Self.bundledImage("AppIcon", ext: "icns") {
            NSApp.applicationIconImage = appIcon
        }
        printWindowController = PrintWindowController()
        // Wrap the in-process PrinterManager in a LocalPrintBackend and inject it,
        // so the print window prints through the PrintBackend abstraction (and never
        // touches PrinterManager / libusb directly). start() begins publishing the
        // printer+cassette status the window observes.
        let backend = LocalPrintBackend()
        printBackend = backend
        printWindowController.backend = backend
        backend.start()
        // After a print starts, the print window closes itself and asks us to
        // pop open the menu so the user can watch printer/queue status.
        printWindowController.onPrintStarted = { [weak self] in self?.showMenuPopover() }
        // Editing from the print window opens the single Template Designer.
        printWindowController.onEditTemplate = { [weak self] index in
            self?.openTemplateDesigner(editTemplateIndex: index)
        }

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
                self?.designerWebView?.evaluateJavaScript("if(typeof setTheme==='function')setTheme('\(mode)')", completionHandler: nil)
            }.store(in: &cancellables)

        // Set up the NSStatusItem — reliable for LSUIElement apps, no activation issues
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let menuIcon = Self.bundledImage("MenuBarIcon", ext: "png") {
                menuIcon.isTemplate = true   // auto-tints for light/dark menu bars
                menuIcon.size = NSSize(width: 18, height: 18)
                button.image = menuIcon
                button.imagePosition = .imageOnly
            } else {
                button.title = "VL"          // fallback if the asset is missing
                button.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            }
            button.action = #selector(toggleMenuBarPopover)
            button.target = self
        }
        statusItem = item
        NSApp.setActivationPolicy(AppSettings.shared.showInDock ? .regular : .accessory)
        TemplateStore.shared.reload()
        PrinterManager.shared.startScan()

        let watcher = ExportWatcher(exportsRootURL: AppSettings.shared.exportsFolderURL)
        watcher.onNewExport = { [weak self] fileURL, records in
            Task { @MainActor in
                guard AppSettings.shared.autoOpenPrintWindow else { return }
                self?.printWindowController.showForNewExport(fileURL: fileURL, records: records)
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        PrinterManager.shared.stopScan()
    }

    // MARK: – Actions called by MenuBarView

    // Template index to load for print-window editing on the next designer load.
    private var pendingEditTemplateIndex: Int?
    // True while the designer is open to edit a template for the print window.
    private var designerForPrintEdit = false

    func openTemplateDesigner(editTemplateIndex: Int? = nil) {
        pendingEditTemplateIndex = editTemplateIndex
        designerForPrintEdit = (editTemplateIndex != nil)
        if let win = designerWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(designerWebView)
            if let idx = editTemplateIndex {
                applyPendingEdit(idx)
            } else {
                designerWebView?.evaluateJavaScript("window._printEdit=false; if(typeof R==='function')R(); if(typeof openTemplate==='function')openTemplate();", completionHandler: nil)
            }
            return
        }

        // The HTML now lives in VectorLabelCore's resource bundle. Prefer a live
        // repo copy during development (so git pull is reflected without a
        // rebuild), then fall back to the bundled Core resource.
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
        designerWebView = wv

        // Use NSPanel with .nonactivatingPanel so the window appears without
        // stealing activation from the menu bar status item.
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        win.title = "VectorLabel — Template Designer"
        win.contentView = wv
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        win.applyVLSizing(autosaveName: "VLDesignerWindow",
                          defaultContentSize: NSSize(width: 1280, height: 860))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        // Make the web view first responder so keyboard shortcuts (arrow-key
        // nudge, delete, undo) reach the designer immediately.
        win.makeFirstResponder(wv)
        designerWindow = win

        designerCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.designerWebView?.navigationDelegate = nil
                self.designerWebView?.configuration.userContentController
                    .removeScriptMessageHandler(forName: "vectorlabel")
                self.designerWebView = nil
                self.designerWindow = nil
                if let token = self.designerCloseObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.designerCloseObserver = nil
                }
                TemplateStore.shared.reload()
                // If the designer was closed (e.g. via its close button) while
                // editing for the print window, bring the print window back.
                if self.designerForPrintEdit {
                    self.designerForPrintEdit = false
                    self.printWindowController.returnFromEdit()
                }
            }
        }
    }

    private var menuPopover: NSPopover?

    @objc func toggleMenuBarPopover() {
        if let popover = menuPopover, popover.isShown {
            popover.performClose(nil)
            menuPopover = nil
            return
        }
        showMenuPopover()
    }

    /// Open the status-item popover (the "toolbar menu"). No-op if already shown.
    func showMenuPopover() {
        guard let button = statusItem?.button else { return }
        if let popover = menuPopover, popover.isShown { return }
        let popover = NSPopover()
        let hosting = NSHostingController(
            rootView: MenuBarView().environmentObject(self)
        )
        // Let the popover size its height to the SwiftUI content (width is fixed
        // at 320 in MenuBarView), so recent-print rows with wrapped, multi-line
        // filenames are never clipped.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        // Dark popover chrome so the arrow/background matches the themed content.
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        menuPopover = popover
    }

    func openPreferences() {
        if let win = preferencesWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: PreferencesView())
        let win = NSPanel(contentViewController: controller)
        win.title = "VectorLabel Preferences"
        win.styleMask = [.titled, .closable, .nonactivatingPanel]
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        // The print window floats; keep Preferences just above it so it always
        // opens in front of any other VectorLabel window.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        win.applyVLSizing(autosaveName: "VLPreferencesWindow",
                          defaultContentSize: NSSize(width: 680, height: 560))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        preferencesWindow = win
        preferencesCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.preferencesWindow = nil
                if let token = self.preferencesCloseObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.preferencesCloseObserver = nil
                }
            }
        }
    }

    func openExportFolder() {
        let url = AppSettings.shared.exportsFolderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openReprint(_ recent: RecentPrint) {
        Task { @MainActor in self.printWindowController.showForReprint(recent) }
    }

    // MARK: – Auto-load most recent CSV for the designer

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
        guard let wv = designerWebView else { return }
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
        guard let wv = designerWebView,
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
        guard let wv = designerWebView, index >= 0, index < templates.count,
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
        if let win = designerWindow {
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
        guard let wv = designerWebView else { return }
        let s = AppSettings.shared
        wv.evaluateJavaScript(
            "if(typeof initDesignerPrefs==='function')initDesignerPrefs({snapGrid:\(s.designerSnapGrid),snapObjects:\(s.designerSnapObjects),gridSize:\(s.designerGridSize),recH:\(s.designerRecordsHeight)});",
            completionHandler: nil
        )
    }

    /// Push the shared record-column config (order/hidden/widths) into the designer.
    private func injectColumnConfig() {
        guard let wv = designerWebView else { return }
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
                guard let self = self, let wv = self.designerWebView,
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
        guard let wv = designerWebView,
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

    // MARK: – Private

    private var watcher: ExportWatcher?

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        return WKWebView(frame: .zero, configuration: config)
    }

    private func devHTMLURL(_ name: String) -> URL? {
        // During development, load HTML directly from the repo so changes
        // are picked up without a full rebuild. Xcode's .copy resource bundling
        // caches files and may not re-copy after a git pull.
        //
        // Search order:
        // 1. ~/Downloads/VectorLabel/MacApp/Sources/Core/<name>.html  (default clone location)
        // 2. ~/Documents/VectorLabel/MacApp/Sources/Core/<name>.html
        // 3. #file-relative path (source-build fallback)
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

extension AppDelegate: WKUIDelegate {
    func webView(_ webView: WKWebView,
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

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only handle the designer webview
        guard webView === designerWebView else { return }
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

extension AppDelegate: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
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
            designerForPrintEdit = false   // handled here; don't double-return on close
            printWindowController.returnFromEdit()
            designerWindow?.close()

        default:
            break
        }
    }
}

// String.jsonQuoted is defined in VectorLabelCore (Core/Bridge.swift)
