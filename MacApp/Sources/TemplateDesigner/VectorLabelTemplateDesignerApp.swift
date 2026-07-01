import SwiftUI
import AppKit
import VectorLabelCore
import VectorLabelUI

// MARK: – App entry point
//
// VectorLabelTemplateDesigner is the standalone Template Designer Dock app. It
// hosts the shared DesignerWindowController in `.template` mode (Core-only — no
// EngineKit). Launched by the Engine's menu and by the print window's "Edit"
// action.

@main
@MainActor
struct VectorLabelTemplateDesignerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: – AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var designer: DesignerWindowController!

    /// A ".vltmp"/".vlt.json" file the OS asked us to open before the designer
    /// existed (application(_:open:) can fire before applicationDidFinishLaunching).
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel.templatedesigner", forKey: "CFBundleIdentifier")
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

        TemplateStore.shared.reload()
        designer = DesignerWindowController(mode: .template)
        // If Finder handed us a document before launch finished, open it directly;
        // otherwise show the normal picker.
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs; pendingOpenURLs.removeAll()
            for url in urls { openTemplate(at: url) }   // one tab per file
        } else {
            designer.open()
        }
    }

    /// Quit fully when the (only) designer window closes — don't linger in the Dock.
    /// The designer window is an NSPanel, which AppKit excludes from this check, so
    /// a transient WKWebView popup (e.g. the supply-group <select> dropdown) closing
    /// can trip a spurious "last window closed" and quit the app while the designer
    /// is still open. Only quit when the designer window is genuinely gone.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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

    /// Finder double-click / `open` of a ".vltmp" (or legacy ".vlt.json"). May fire
    /// before applicationDidFinishLaunching, so stash the URL until the designer
    /// exists, then load it into the canvas.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Open every selected ".vltmp" as its own tab. If none are valid, keep the last
        // URL so openTemplate(at:) surfaces the read error.
        let templates = urls.filter { TemplateStore.isTemplateFile($0) }
        let toOpen = templates.isEmpty ? Array(urls.suffix(1)) : templates
        guard !toOpen.isEmpty else { return }
        if designer == nil {
            pendingOpenURLs = toOpen   // applicationDidFinishLaunching will consume them
        } else {
            for url in toOpen { openTemplate(at: url) }
        }
    }

    /// Load the template at `url` into the designer (or report a read failure).
    private func openTemplate(at url: URL) {
        if let tpl = TemplateStore.loadTemplate(from: url) {
            designer.openTemplate(tpl, displayName: url.deletingPathExtension().lastPathComponent)
        } else {
            designer.open()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t open “\(url.lastPathComponent)”"
            alert.informativeText = "The file isn’t a valid VectorLabel template."
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
