import SwiftUI
import AppKit
import VectorLabelCore
import VectorLabelUI

// MARK: – App entry point
//
// VectorLabelCustomDesigner is the standalone Custom Designer Dock app — a shell
// for now. It hosts the shared DesignerWindowController in `.custom` mode (same
// canvas as the Template Designer). The DB panel + print header arrive in later
// phases. Core-only — no EngineKit.

@main
@MainActor
struct VectorLabelCustomDesignerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: – AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var designer: DesignerWindowController!

    /// A ".vlcus" file the OS asked us to open before the designer existed.
    private var pendingOpenURLs: [URL] = []

    /// Watches the IPC reprint channel — the Engine posts here when the user taps
    /// "Reprint" on a Custom Designer job in the menu bar; we reopen its saved design.
    private var reprintWatcher: FolderWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel.customdesigner", forKey: "CFBundleIdentifier")
        }
        AppSettings.shared.applyNativeAppearance()
        if let appIcon = CoreResources.appIcon() {
            NSApp.applicationIconImage = appIcon
        }
        NSApp.setActivationPolicy(.regular)

        // Bring up the Engine if it isn't already running (it owns printing + the
        // menu bar), and shut down with it if it later quits.
        DesignerAppLauncher.ensureRunning(.engine)
        observeEngineTermination()

        // Do NOT touch TemplateStore here: the Custom Designer never uses templates,
        // and TemplateStore.shared's init reloads the Templates folder (under
        // ~/Documents) — exactly what triggered the macOS Documents-access prompt on
        // launch. Leaving the singleton untouched means it's never created for the
        // Custom Designer, so ~/Documents is not read on launch.
        designer = DesignerWindowController(mode: .custom)

        // Watch the IPC reprint channel: the Engine posts a request when the user taps
        // "Reprint" on a Custom Designer job, and we reopen the saved design (captured
        // in the job's reprint.customDocJSON) so the user can edit + re-print it.
        let queue = PrintQueue()
        queue.ensureDirs()
        let rw = FolderWatcher(root: queue.reprintCustomDir, suffix: ".json", latency: 0.2) { [weak self] url in
            Task { @MainActor in self?.handleReprintRequest(url) }
        }
        rw.start()
        self.reprintWatcher = rw

        // Decide the first window: a Finder-opened ".vlcus" wins; else honor a reprint
        // request the Engine wrote just before this (possibly cold) launch — DRAIN it,
        // don't discard it; else open the empty Custom Designer.
        let pendingReprints = queue.pendingCustomReprintURLs()
        let anyPending = !pendingOpenURLs.isEmpty || !pendingReprints.isEmpty
        // Each Finder-opened file and each queued reprint gets its own tab.
        for url in pendingOpenURLs { openCustomDocument(at: url) }
        pendingOpenURLs.removeAll()
        for r in pendingReprints { handleReprintRequest(r) }
        if !anyPending { designer.open() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        reprintWatcher?.stop()
    }

    /// Reopen the saved design for a queued Custom Designer reprint, then delete the
    /// request. The design is the ".vlcus" model captured at print time in the job's
    /// reprint.customDocJSON (retained in done/); if it's no longer available, inform
    /// the user and open the empty designer.
    private func handleReprintRequest(_ url: URL) {
        let q = PrintQueue()
        defer { q.deleteReprint(url) }
        guard let recent = q.readReprintRequest(url), recent.sourceApp == "customdesigner" else { return }
        guard let job = q.readDoneJob(id: recent.jobId),
              let json = job.reprint?.customDocJSON,
              let data = json.data(using: .utf8),
              let doc = try? JSONDecoder().decode(CustomLabelDocument.self, from: data)
        else {
            designer.open()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Can’t reopen “\(recent.title)”"
            alert.informativeText = "The original design for this print is no longer available to edit."
            alert.runModal()
            return
        }
        designer.openCustomDocument(doc)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quit fully when the (only) designer window closes — don't linger in the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The designer's window is an NSPanel, which AppKit does NOT count for
        // this check. A transient WKWebView helper window (e.g. the native popup
        // backing the supply-group <select> dropdown) closing therefore trips a
        // spurious "last window closed" and would quit the app while the designer
        // is still open. Only quit when the designer window is genuinely gone.
        if designer?.hasVisibleWindow == true { return false }
        return true
    }

    /// When the Engine quits, close this designer (prompting to save first, no
    /// Cancel) and quit, so the whole suite shuts down together.
    private func observeEngineTermination() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == DesignerAppLauncher.bundleID(for: .engine) else { return }
            MainActor.assumeIsolated { self?.designer?.closeForEngineQuit() }
        }
    }

    /// Finder double-click / `open` of a ".vlcus". May fire before
    /// applicationDidFinishLaunching, so stash the URL until the designer exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Open every selected ".vlcus" as its own tab. If none are valid, keep the last
        // URL so openCustomDocument(at:) surfaces the read error.
        let custom = urls.filter { CustomLabelStore.isCustomLabelFile($0) }
        let toOpen = custom.isEmpty ? Array(urls.suffix(1)) : custom
        guard !toOpen.isEmpty else { return }
        if designer == nil {
            pendingOpenURLs = toOpen
        } else {
            for url in toOpen { openCustomDocument(at: url) }
        }
    }

    /// Load the ".vlcus" at `url` into the Custom Designer (or report a read failure).
    private func openCustomDocument(at url: URL) {
        if let doc = CustomLabelStore.load(from: url) {
            designer.openCustomDocument(doc, displayName: url.deletingPathExtension().lastPathComponent)
        } else {
            designer.open()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t open “\(url.lastPathComponent)”"
            alert.informativeText = "The file isn’t a valid VectorLabel custom label."
            alert.runModal()
        }
    }

    /// Re-open the designer window when the user clicks the Dock icon and no
    /// window is on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { designer.open() }
        return true
    }
}
