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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel.customdesigner", forKey: "CFBundleIdentifier")
        }
        AppSettings.shared.applyNativeAppearance()
        if let appIcon = CoreResources.image("AppIcon", "icns") {
            NSApp.applicationIconImage = appIcon
        }
        NSApp.setActivationPolicy(.regular)

        TemplateStore.shared.reload()
        designer = DesignerWindowController(mode: .custom)
        // If Finder handed us a ".vlcus" before launch finished, open it directly;
        // otherwise open the empty Custom Designer.
        if let url = pendingOpenURLs.last {
            pendingOpenURLs.removeAll()
            openCustomDocument(at: url)
        } else {
            designer.open()
        }
    }

    /// Finder double-click / `open` of a ".vlcus". May fire before
    /// applicationDidFinishLaunching, so stash the URL until the designer exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last(where: { CustomLabelStore.isCustomLabelFile($0) }) ?? urls.last
        else { return }
        if designer == nil {
            pendingOpenURLs = [url]
        } else {
            openCustomDocument(at: url)
        }
    }

    /// Load the ".vlcus" at `url` into the Custom Designer (or report a read failure).
    private func openCustomDocument(at url: URL) {
        if let doc = CustomLabelStore.load(from: url) {
            designer.openCustomDocument(doc)
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
