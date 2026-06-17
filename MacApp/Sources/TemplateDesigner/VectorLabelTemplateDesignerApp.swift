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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel.templatedesigner", forKey: "CFBundleIdentifier")
        }
        AppSettings.shared.applyNativeAppearance()
        if let appIcon = CoreResources.image("AppIcon", "icns") {
            NSApp.applicationIconImage = appIcon
        }
        NSApp.setActivationPolicy(.regular)

        TemplateStore.shared.reload()
        designer = DesignerWindowController(mode: .template)
        designer.open()
    }

    /// Re-open the designer window when the user clicks the Dock icon and no
    /// window is on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { designer.open() }
        return true
    }
}
