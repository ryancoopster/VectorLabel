import SwiftUI
import AppKit
import VectorLabelCore
import VectorLabelUI

// MARK: – App entry point
//
// VectorLabelAutoPrint is the background front-end that watches the Exports
// folder and pops the print window when a new CSV export is detected. It never
// links EngineKit/libusb — it submits jobs through an IPCPrintBackend (the file
// queue), and the Engine app does the actual printing. Template editing from the
// print window launches the standalone Template Designer app.

@main
@MainActor
struct VectorLabelAutoPrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: – AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    private var printWindowController: PrintWindowController!
    private var backend: IPCPrintBackend!
    private var watcher: ExportWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel.autoprint", forKey: "CFBundleIdentifier")
        }
        AppSettings.shared.applyNativeAppearance()
        if let appIcon = CoreResources.image("AppIcon", "icns") {
            NSApp.applicationIconImage = appIcon
        }
        // Background app: no Dock icon. The print window appears on demand.
        NSApp.setActivationPolicy(.accessory)

        TemplateStore.shared.reload()

        // Print window submits through the IPC queue; the Engine prints. start()
        // begins watching the Engine's published status so the window shows live
        // printer/cassette state.
        let backend = IPCPrintBackend()
        self.backend = backend
        let controller = PrintWindowController()
        controller.backend = backend
        backend.start()
        self.printWindowController = controller

        // Editing a template from the print window launches the Template Designer
        // app (beta-aware bundle id). The designer saves to the shared Templates
        // folder; the print window refreshes from the store on return.
        controller.onEditTemplate = { _ in DesignerAppLauncher.launch(.template) }

        // Watch the Exports folder; open the print window on a new export when the
        // user has auto-open enabled.
        let watcher = ExportWatcher(exportsRootURL: AppSettings.shared.exportsFolderURL)
        watcher.onNewExport = { [weak self] fileURL, records in
            Task { @MainActor in
                guard AppSettings.shared.autoOpenPrintWindow else { return }
                self?.printWindowController.showForNewExport(fileURL: fileURL, records: records)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        backend?.stop()
    }
}
