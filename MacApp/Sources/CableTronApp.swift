import SwiftUI
import AppKit

// MARK: – App entry point

@main
struct VectorLabelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar dropdown
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate)
        } label: {
            // Show a filled/animated icon when a print is active
            if PrinterManager.shared.activeJobs.contains(where: { !$0.isComplete }) {
                Image(systemName: "printer.fill")
            } else {
                // Use a simple text label while we don't have a bundled icon asset
                Text("VL")
                    .font(.system(size: 11, weight: .bold))
            }
        }
        .menuBarExtraStyle(.window)  // use .window for custom SwiftUI content

        // Preferences (⌘,)
        Settings {
            PreferencesView()
        }
    }
}

// MARK: – AppDelegate

/// Wires together the watcher, printer manager, template store and print window.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // One print window controller for the lifetime of the app
    private let printWindowController = PrintWindowController()

    // One template designer window
    private var designerWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't show in Dock by default
        let showInDock = AppSettings.shared.showInDock
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

        // Load templates
        TemplateStore.shared.reload()

        // Start USB printer scan
        PrinterManager.shared.startScan()

        // Start watching the exports folder
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
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let htmlURL = Bundle.main.url(forResource: "VectorLabelDesigner", withExtension: "html")
                            ?? devHTMLURL("VectorLabelDesigner")
        else { return }

        let wv = makeWebView()
        wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())

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

        // Clear reference when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in
            self?.designerWindow = nil
            TemplateStore.shared.reload()   // pick up any newly saved templates
        }
    }

    func openExportFolder() {
        let url = AppSettings.shared.exportsFolderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openReprint(_ recent: RecentPrint) {
        printWindowController.showForReprint(recent)
    }

    // MARK: – Private

    private var watcher: ExportWatcher?

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        return WKWebView(frame: .zero, configuration: config)
    }

    /// Development fallback: find the HTML file relative to this source file.
    private func devHTMLURL(_ name: String) -> URL? {
        let src = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = src.appendingPathComponent("\(name).html")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

// MARK: – Import WebKit (needed for WKWebView in AppDelegate)

import WebKit
