import SwiftUI
import AppKit
import WebKit

// MARK: – App entry point

@main
@MainActor
struct VectorLabelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate)
        } label: {
            if PrinterManager.shared.activeJobs.contains(where: { !$0.isComplete }) {
                Image(systemName: "printer.fill")
            } else {
                Text("VL").font(.system(size: 11, weight: .bold))
            }
        }
        .menuBarExtraStyle(.window)

    }
}

// MARK: – AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // PrintWindowController is @MainActor; initialised in applicationDidFinishLaunching
    private var printWindowController: PrintWindowController!
    private var designerWindow: NSWindow?
    private var designerWebView: WKWebView?
    private var preferencesWindow: NSWindow?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure bundle identifier is set — required for WKWebView sandbox
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            // Running without a proper bundle (dev/SPM). Set a temporary identifier.
            UserDefaults.standard.set("com.sai.vectorlabel", forKey: "NSBundleIdentifier")
        }
        printWindowController = PrintWindowController()
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

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        PrinterManager.shared.stopScan()
    }

    // MARK: – Actions called by MenuBarView

    func openTemplateDesigner() {
        if let win = designerWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let htmlURL = Bundle.main.url(forResource: "VectorLabelDesigner", withExtension: "html")
                            ?? devHTMLURL("VectorLabelDesigner")
        else { return }

        // WKWebView with navigation delegate so we can inject records after load
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        designerWebView = wv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "VectorLabel — Template Designer"
        win.contentView = wv
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        designerWindow = win

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in
            self?.designerWindow = nil
            self?.designerWebView = nil
            Task { @MainActor in TemplateStore.shared.reload() }
        }
    }

    func openPreferences() {
        if let win = preferencesWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: PreferencesView())
        let win = NSWindow(contentViewController: controller)
        win.title = "VectorLabel Preferences"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 600, height: 480))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow = win
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in self?.preferencesWindow = nil }
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
            "Downloads/VectorLabel/MacApp/Sources",
            "Documents/VectorLabel/MacApp/Sources",
            "Developer/VectorLabel/MacApp/Sources",
            "Desktop/VectorLabel/MacApp/Sources",
            "Projects/VectorLabel/MacApp/Sources",
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
    }
}

// JSONSerialization.escapeString is defined in PrintWindowController.swift
