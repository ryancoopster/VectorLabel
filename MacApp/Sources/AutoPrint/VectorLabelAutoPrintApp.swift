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
// print window opens an in-process Template Designer in print-edit mode and
// re-shows the print window on return.

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
    /// Watches the IPC reprint channel — the Engine posts here when the user taps
    /// "Reprint" in the menu bar, and we re-open the print window in that state.
    private var reprintWatcher: FolderWatcher?
    /// In-process Template Designer used for "Edit" from the print window, so the
    /// edit→return handoff (load template, Save/Cancel & Return, re-show the print
    /// window) stays within one process.
    private var editDesigner: DesignerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel.autoprint", forKey: "CFBundleIdentifier")
        }
        AppSettings.shared.applyNativeAppearance()
        if let appIcon = CoreResources.appIcon() {
            NSApp.applicationIconImage = appIcon
        }
        // Background app: no Dock icon. The print window appears on demand.
        NSApp.setActivationPolicy(.accessory)

        // The Engine owns printing + the IPC queue; bring it up if it isn't running so a
        // print submitted from this front-end is never left queued with no consumer.
        DesignerAppLauncher.ensureRunning(.engine)

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

        // Editing a template from the print window opens the Template Designer
        // IN-PROCESS in print-edit mode: it loads the chosen template and shows the
        // Save / Save As / Cancel & Return buttons. On return (or cancel) we
        // re-show the print window and refresh its list from the shared store.
        // (The bidirectional edit↔return handoff must live in one process — a
        // standalone-app launch dropped the template index and the return path,
        // which is what broke this feature in the suite restructure.)
        let editDesigner = DesignerWindowController(mode: .template)
        editDesigner.onEditReturn = { [weak controller] _, _ in
            controller?.returnFromEdit()
        }
        // "Cancel All" from the editor's unsaved-changes prompt: abandon the edit
        // AND cancel the underlying print (record it to Recent Prints as cancelled,
        // then close the print window) — as if the user had pressed ✕ Cancel there.
        editDesigner.onEditCancelAll = { [weak controller] in
            controller?.cancelFromEdit()
        }
        controller.onEditTemplate = { [weak editDesigner] index in
            editDesigner?.openForPrintEdit(templateIndex: index)
        }
        self.editDesigner = editDesigner

        // Watch the IPC reprint channel. The Engine posts a request here when the
        // user taps "Reprint" in the menu bar; re-open the print window in that
        // job's saved state (source CSV + checked records + filter/sort) so the
        // user can choose what to reprint instead of it re-printing blindly.
        let queue = PrintQueue()
        queue.ensureDirs()
        let reprintWatcher = FolderWatcher(root: queue.reprintDir, suffix: ".json", latency: 0.2) { [weak self] url in
            Task { @MainActor in self?.handleReprintRequest(url) }
        }
        reprintWatcher.start()
        self.reprintWatcher = reprintWatcher
        // Honor any request the Engine wrote moments before this (possibly cold,
        // ensureRunning-triggered) launch — DRAIN it, don't discard it. Mirrors how
        // the Engine drains pending cancelled requests on startup.
        for url in queue.pendingReprintURLs() { handleReprintRequest(url) }

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
        reprintWatcher?.stop()
        backend?.stop()
    }

    /// Re-open the print window for a queued reprint request, then delete the file.
    private func handleReprintRequest(_ url: URL) {
        let q = PrintQueue()
        defer { q.deleteReprint(url) }
        guard let recent = q.readReprintRequest(url) else { return }
        printWindowController.showForReprint(recent)
        NSApp.activate(ignoringOtherApps: true)
    }
}
