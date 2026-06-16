import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

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
    private var designerWindow: NSWindow?
    private var designerWebView: WKWebView?
    private var preferencesWindow: NSWindow?
    private var designerCloseObserver: NSObjectProtocol?
    private var preferencesCloseObserver: NSObjectProtocol?

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // WKWebView requires a bundle identifier for its sandboxed WebContent process.
        // When running from SPM/Xcode without INFOPLIST_FILE set, inject it directly.
        // SPM cannot inject Info.plist. Set INFOPLIST_FILE in Xcode Build Settings
        // pointing to Info.plist at the repo root to get a proper bundle identifier.
        // As a dev fallback, register the ID in UserDefaults which WKWebView checks.
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel", forKey: "CFBundleIdentifier")
        }
        printWindowController = PrintWindowController()
        // After a print starts, the print window closes itself and asks us to
        // pop open the menu so the user can watch printer/queue status.
        printWindowController.onPrintStarted = { [weak self] in self?.showMenuPopover() }

        // Set up the NSStatusItem — reliable for LSUIElement apps, no activation issues
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "VL"
            button.font = NSFont.systemFont(ofSize: 11, weight: .bold)
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

    func openTemplateDesigner() {
        if let win = designerWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        // SPM places bundled resources in Bundle.module (the generated resource
        // bundle next to the executable), NOT Bundle.main. Try module first so
        // the debug `swift build` binary works; fall back to Bundle.main for a
        // proper .app build, then dev paths.
        guard let htmlURL = Bundle.module.url(forResource: "VectorLabelDesigner", withExtension: "html")
                            ?? Bundle.main.url(forResource: "VectorLabelDesigner", withExtension: "html")
                            ?? devHTMLURL("VectorLabelDesigner")
        else { return }

        // WKWebView with navigation delegate so we can inject records after load,
        // plus a message handler so the designer can save/list/browse templates
        // through Swift (WKWebView has no File System Access API).
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let contentController = WKUserContentController()
        contentController.add(self, name: "vectorlabel")
        config.userContentController = contentController
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
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
        win.center()
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
        win.setContentSize(NSSize(width: 600, height: 480))
        win.center()
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
        // JSON-encode the filename string safely
        let fnJSON = "\"" + filename.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
        // 1. ~/Downloads/VectorLabel/MacApp/Sources/<name>.html  (default clone location)
        // 2. ~/Documents/VectorLabel/MacApp/Sources/<name>.html
        // 3. #file-relative path (source-build fallback)
        let home = NSHomeDirectory()
        let searchPaths = [
            "Documents/VectorLabel/MacApp/Sources",
            "Developer/VectorLabel/MacApp/Sources",
            "Desktop/VectorLabel/MacApp/Sources",
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
        let candidate = src.appendingPathComponent("\(name).html")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

// MARK: – WKNavigationDelegate (for designer auto-load)

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only handle the designer webview
        guard webView === designerWebView else { return }
        // Inject the most recent CSV with ≥10 records
        if let result = findMostRecentCSV(minRecords: 10) {
            injectDesignerRecords(result.records, filename: result.url.lastPathComponent)
        }
        // Inject the templates-folder list so the designer's Open dialog can list them.
        injectDesignerTemplates()
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
            injectDesignerTemplates()

        case "browseTemplate":
            browseForTemplate()

        default:
            break
        }
    }
}

// JSONSerialization.escapeString is defined in PrintWindowController.swift
