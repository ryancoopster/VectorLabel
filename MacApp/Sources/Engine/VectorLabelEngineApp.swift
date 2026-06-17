import SwiftUI
import AppKit
import Combine
import VectorLabelCore
import VectorLabelEngineKit
import VectorLabelUI

// MARK: – App entry point
//
// VectorLabelEngine is the headless print engine + menu-bar app. It owns the USB
// printers (the only target that links EngineKit / libusb), consumes the file
// IPC print queue, and publishes printer/cassette status that the front-end apps
// (Auto Print / Custom Designer) read. The window-bearing designers and the
// print window live in their own apps and are launched by bundle id.

@main
@MainActor
struct VectorLabelEngineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // NSStatusItem is managed entirely by AppDelegate; use an empty scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: – AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    private var statusItem: NSStatusItem?
    private var menuPopover: NSPopover?
    private var preferencesWindow: NSWindow?
    private var preferencesCloseObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    // Print-queue consumer.
    private var queueWatcher: PrintQueueWatcher?
    // Maps an in-flight PrintJob.id → the queue's processing/ file URL, so a job's
    // completion can be routed back to PrintQueue.complete(). Also retains the
    // per-job Combine subscription until completion.
    private var inFlight: [UUID: (processingURL: URL, sub: AnyCancellable)] = [:]

    // Debounces status publishing so a burst of @Published changes coalesces.
    private var statusPublishWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel.engine", forKey: "CFBundleIdentifier")
        }
        AppSettings.shared.applyNativeAppearance()
        if let appIcon = CoreResources.image("AppIcon", "icns") {
            NSApp.applicationIconImage = appIcon
        }

        setupStatusItem()
        NSApp.setActivationPolicy(AppSettings.shared.showInDock ? .regular : .accessory)

        TemplateStore.shared.reload()
        PrinterManager.shared.startScan()

        startQueueConsumer()
        startStatusPublisher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        queueWatcher?.stop()
        PrinterManager.shared.stopScan()
        // Best-effort: publish that the engine is no longer running so front-ends
        // can show "engine offline".
        var status = PrinterManager.shared.currentStatusFile()
        status.engineRunning = false
        try? PrintQueue().publishStatus(status)
    }

    // MARK: – Status item / menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let menuIcon = CoreResources.image("MenuBarIcon", "png") {
                menuIcon.isTemplate = true   // auto-tints for light/dark menu bars
                menuIcon.size = NSSize(width: 18, height: 18)
                button.image = menuIcon
                button.imagePosition = .imageOnly
            } else {
                button.title = "VL"
                button.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            }
            button.action = #selector(toggleMenuBarPopover)
            button.target = self
        }
        statusItem = item
    }

    @objc func toggleMenuBarPopover() {
        if let popover = menuPopover, popover.isShown {
            popover.performClose(nil)
            menuPopover = nil
            return
        }
        showMenuPopover()
    }

    func showMenuPopover() {
        guard let button = statusItem?.button else { return }
        if let popover = menuPopover, popover.isShown { return }
        let popover = NSPopover()
        let hosting = NSHostingController(rootView: MenuBarView().environmentObject(self))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        menuPopover = popover
    }

    // MARK: – Menu actions (called by MenuBarView)

    /// Launch the standalone Template Designer app (packaged suite only).
    func openTemplateDesigner() { DesignerAppLauncher.launch(.template) }

    /// Launch the standalone Custom Designer app (packaged suite only).
    func openCustomDesigner() { DesignerAppLauncher.launch(.custom) }

    /// Reprint lives in the Auto Print app (which owns the print window). Launch
    /// it; per-record reprint wiring over IPC arrives in a later phase.
    func openReprint(_ recent: RecentPrint) { DesignerAppLauncher.launch(.autoPrint) }

    func openExportFolder() {
        let url = AppSettings.shared.exportsFolderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
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
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        win.applyVLSizing(autosaveName: "VLPreferencesWindow",
                          defaultContentSize: NSSize(width: 680, height: 560))
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

    // MARK: – Print-queue consumer
    //
    // Watches the IPC queue; for each job, submits its pre-rendered VGL labels to
    // PrinterManager, then observes the returned PrintJob and reports the outcome
    // back to the queue via PrintQueue.complete().

    // Guards the re-drain so a flapping printer list can't hot-loop the backlog.
    private var lastRedrainAt: Date = .distantPast

    private func startQueueConsumer() {
        let watcher = PrintQueueWatcher(queue: PrintQueue()) { [weak self] job, processingURL in
            // PrintQueueWatcher invokes onJob on its FolderWatcher thread; hop to
            // the main actor for PrinterManager submission + Combine wiring.
            Task { @MainActor in self?.consume(job: job, processingURL: processingURL) }
        }
        watcher.start()
        queueWatcher = watcher

        // The startup backlog drain (in watcher.start) can run before the async USB
        // scan has populated `printers`; no-printer jobs are then re-queued rather
        // than failed (see consume()). Re-drain the queue whenever the printer list
        // transitions to non-empty so those re-queued jobs print once a printer
        // appears. A short backoff prevents a flapping list from hot-looping.
        PrinterManager.shared.$printers
            .receive(on: RunLoop.main)
            .sink { [weak self] printers in
                guard let self else { return }
                guard !printers.isEmpty else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastRedrainAt) > 1.0 else { return }
                self.lastRedrainAt = now
                self.queueWatcher?.drainBacklog()
            }
            .store(in: &cancellables)
    }

    private func consume(job: PrintJobFile, processingURL: URL) {
        // A job that names a SPECIFIC printer is resolved to exactly that id; if
        // it's absent we fail it (same as before). A job with no printerID
        // (Custom Designer's "Engine picks the printer" contract) is resolved to
        // the sole ready / any printer.
        if let explicitID = job.printerID, !explicitID.isEmpty {
            consumeResolved(job: job, processingURL: processingURL, printerID: explicitID)
            return
        }

        let auto = PrinterManager.shared.printers.first(where: { $0.status == .ready })?.id
            ?? PrinterManager.shared.printers.first?.id

        guard let printerID = auto, !printerID.isEmpty else {
            // No printer resolvable. If the USB scan hasn't completed yet, the
            // printer list is simply empty *for now* — un-claim the job back to
            // queue/ so it's re-drained once a printer appears (see the $printers
            // observer in startQueueConsumer). Only fail if the scan has run and
            // genuinely found no printer.
            if PrinterManager.shared.hasScannedOnce {
                PrintQueue().complete(processingURL, success: false)
            } else {
                PrintQueue().requeue(processingURL)
            }
            return
        }
        consumeResolved(job: job, processingURL: processingURL, printerID: printerID)
    }

    private func consumeResolved(job: PrintJobFile, processingURL: URL, printerID: String) {

        let printJob = PrinterManager.shared.submit(
            jobs: job.labels.map { [UInt8]($0) },
            title: job.title,
            templateName: job.templateName,
            printerID: printerID,
            cutMode: job.cutMode,
            estLabelMs: job.estLabelMs
        )

        // Observe completion: when isComplete flips true (success path) OR didFail
        // is set, finalize the queue file exactly once and drop the subscription.
        // didFail is a plain (lock-guarded) property, not @Published, so we drive
        // the check off $isComplete — PrinterManager sets isComplete=true on every
        // terminal outcome (success, cancel, fail), at which point didFail is
        // already settled.
        let sub = printJob.$isComplete
            .filter { $0 }
            .first()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.finishInFlight(printJob, success: !printJob.didFail)
            }
        inFlight[printJob.id] = (processingURL, sub)
    }

    private func finishInFlight(_ job: PrintJob, success: Bool) {
        guard let entry = inFlight.removeValue(forKey: job.id) else { return }
        entry.sub.cancel()
        PrintQueue().complete(entry.processingURL, success: success)
    }

    // MARK: – Status publisher
    //
    // Whenever the printer list, detected cassettes, or active-job set changes,
    // republish PrinterStatusFile to the IPC status dir (debounced ~0.2 s). The
    // front-ends watch printers.json and re-render from it.

    private func startStatusPublisher() {
        let schedule: () -> Void = { [weak self] in self?.schedulePublishStatus() }
        PrinterManager.shared.$printers.receive(on: RunLoop.main)
            .sink { _ in schedule() }.store(in: &cancellables)
        PrinterManager.shared.$cassettes.receive(on: RunLoop.main)
            .sink { _ in schedule() }.store(in: &cancellables)
        PrinterManager.shared.$activeJobs.receive(on: RunLoop.main)
            .sink { _ in schedule() }.store(in: &cancellables)
        // Publish once at startup so front-ends see "engine running" immediately.
        publishStatus()
    }

    private func schedulePublishStatus() {
        statusPublishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publishStatus() }
        statusPublishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func publishStatus() {
        try? PrintQueue().publishStatus(PrinterManager.shared.currentStatusFile())
    }
}
