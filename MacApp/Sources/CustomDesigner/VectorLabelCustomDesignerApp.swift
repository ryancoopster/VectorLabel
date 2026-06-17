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
        designer.open()
    }

    /// Re-open the designer window when the user clicks the Dock icon and no
    /// window is on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { designer.open() }
        return true
    }
}
