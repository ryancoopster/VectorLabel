import SwiftUI
import AppKit
import Combine
import Darwin
@preconcurrency import UserNotifications
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
    /// Last time the cross-process reassert nudge surfaced Preferences/activated the app —
    /// used to debounce a flood on the system-wide notification bus (focus-steal DoS guard).
    private var lastReassertSurface: Date?
    private var preferencesWindow: NSWindow?
    private var preferencesCloseObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    // Print-queue consumer.
    private var queueWatcher: PrintQueueWatcher?
    // Watches ipc/control/ for front-end control requests (cancel).
    private var controlWatcher: FolderWatcher?
    // Watches ipc/cancelled/ for front-end pre-submit cancellations to record.
    private var cancelledWatcher: FolderWatcher?
    // Maps an in-flight PrintJob.id → the queue's processing/ file URL, the IPC job
    // id (queue filename stem, for cancel matching), the Recent-Prints record id (to
    // update its lifecycle status on completion), and the per-job Combine
    // subscriptions (progress + completion), retained until the job finishes.
    private var inFlight: [UUID: InFlightEntry] = [:]

    /// IPC job ids whose cancel arrived during the brief claim→consume window (before an
    /// inFlight entry existed). consumeResolved cancels them the moment they go in-flight.
    private var pendingCancels: Set<String> = []

    private struct InFlightEntry {
        let processingURL: URL
        let ipcJobID: String
        let recentID: UUID
        var subs: Set<AnyCancellable>
    }

    private let recents = RecentPrintsStore.shared

    // Debounces status publishing so a burst of @Published changes coalesces.
    private var statusPublishWork: DispatchWorkItem?

    /// Exclusive single-Engine lock fd, held for the process lifetime. The OS releases
    /// the advisory flock automatically when this process exits (even on crash).
    private var engineLockFD: Int32 = -1
    /// True once this instance has passed the single-instance check and taken on the
    /// Engine role. A losing second instance never sets it, so its termination handler
    /// must not touch the (winner-owned) shared IPC root.
    private var didBecomeEngine = false

    /// Cross-process nudge: a second Engine launch posts this (then exits) so the LIVE
    /// Engine re-shows its menu-bar item — a reliable manual recovery if the icon vanished.
    static let reassertNotification = Notification.Name("com.sai.vectorlabel.engine.reassert")

    /// Take an exclusive lock so only ONE Engine per IPC root owns the USB printer and
    /// the published status file. Two engines would contend the device, clobber each
    /// other's printers.json, and re-claim each other's in-flight processing jobs
    /// (duplicate prints). Returns false if another Engine already holds the lock.
    private func acquireSingleInstanceLock() -> Bool {
        let root = AppEnvironment.ipcRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("engine.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // Couldn't open the lock file (environmental: fd exhaustion, permissions, full
            // disk). Failing OPEN here risks two Engines double-owning the USB device and
            // racing the status file. Log loudly, and refuse ONLY if another instance of
            // this bundle is already running — never block the legitimate first Engine for a
            // benign open() failure.
            NSLog("[Engine] could not open the single-instance lock (errno \(errno)); falling back to a running-process check.")
            let bid = Bundle.main.bundleIdentifier ?? "com.sai.vectorlabel.engine"
            let mine = ProcessInfo.processInfo.processIdentifier
            let another = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .contains { $0.processIdentifier != mine && !$0.isTerminated }
            return !another
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false                              // held by another Engine
        }
        engineLockFD = fd                             // keep open for the process lifetime
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tee NSLog/stderr into ~/Library/Logs/VectorLabel/Engine.log (attached to
        // problem reports) and capture uncaught exceptions to a crash log + a
        // pending-report marker — both installed before anything else can fail.
        VLLog.install(appName: "Engine")
        ErrorReporter.installCrashCapture(appName: "Engine")
        // A write to a printer socket the device closed (mid-print telemetry polling opens many
        // short-lived sockets) would otherwise raise SIGPIPE and kill the Engine. Ignore it so
        // the write surfaces as a normal EPIPE error instead. (Sockets also set SO_NOSIGPIPE.)
        signal(SIGPIPE, SIG_IGN)
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier!.isEmpty {
            UserDefaults.standard.set("com.sai.vectorlabel.engine", forKey: "CFBundleIdentifier")
        }
        // macOS (26+) presents the lone SwiftUI Settings scene as an empty window at
        // launch/activation — close it on sight, for the whole process lifetime.
        StraySettingsWindowGuard.install()
        // Refuse to start a second Engine on the same IPC root (resolved from the
        // bundle id above): it would double-own the USB device and race the status file.
        guard acquireSingleInstanceLock() else {
            // A live Engine already owns the IPC. Don't just vanish silently — that left
            // the user unable to recover a dropped menu-bar icon (relaunching did nothing).
            // Nudge the live Engine to re-show its icon + come forward, then exit.
            NSLog("[Engine] another VectorLabel Engine already owns \(AppEnvironment.ipcRoot.path) — nudging it to re-show, then exiting.")
            DistributedNotificationCenter.default().postNotificationName(
                Self.reassertNotification, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        didBecomeEngine = true
        AppSettings.shared.applyNativeAppearance()
        // The Engine owns the appearance setting; answer front-ends' launch-time requests by
        // re-broadcasting the current value, and broadcast once on launch so a front-end that
        // just started us picks up the right light/dark mode.
        DistributedNotificationCenter.default().addObserver(
            forName: AppSettings.appearanceRequestNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AppSettings.shared.broadcastAppearance() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { AppSettings.shared.broadcastAppearance() }
        if let appIcon = CoreResources.appIcon() {
            NSApp.applicationIconImage = appIcon
        }

        setupStatusItem()
        installStatusItemResilience()
        NSApp.setActivationPolicy(AppSettings.shared.showInDock ? .regular : .accessory)

        TemplateStore.shared.reload()
        PrinterManager.shared.startScan()

        startQueueConsumer()
        startControlWatcher()
        startCancelledWatcher()
        startStatusPublisher()

        // Bound the done/ archive so it can't grow without limit (custom-design jobs now
        // embed the full .vlcus design for reprint). Keeps a comfortable margin above the
        // menu's recent-history cap so every reachable recent keeps its backing done file.
        PrintQueue().pruneDoneJobs(keep: 1000)

        // GitHub auto-update: ask once how updates should be checked (only when
        // updatePolicy is still unset), THEN run the launch-time policy. Last in
        // launch so the modal prompt can't delay the queue consumer, watchers, or
        // status publisher coming up.
        // Deferred one runloop turn: activating the (.accessory) app for the modal
        // WHILE launch is still in flight is what made SwiftUI present the empty
        // Settings-scene window ("VectorLabel Engine Settings").
        DispatchQueue.main.async {
            UpdateChecker.shared.firstRunPromptIfNeeded {
                UpdateChecker.shared.maybeAutoCheck()
            }
            // If the Engine crashed last time, offer to send that report (the
            // first-run prompt above is modal, so this runs after it closes).
            ErrorReporter.offerPendingCrashReportIfAny(appName: "Engine")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A second Engine that LOST the single-instance lock terminates without having
        // started anything; it must not touch the winner's shared IPC root. Publishing
        // an empty/engineRunning=false status here would blank the winner's printers and
        // in-flight jobs for every front-end watching printers.json.
        guard didBecomeEngine else { return }
        queueWatcher?.stop()
        controlWatcher?.stop()
        cancelledWatcher?.stop()
        PrinterManager.shared.stopScan()
        // Best-effort: publish that the engine is no longer running so front-ends
        // can show "engine offline".
        var status = PrinterManager.shared.currentStatusFile()
        status.engineRunning = false
        try? PrintQueue().publishStatus(status)
    }

    // MARK: – Status item / menu

    /// macOS can drop a long-lived NSStatusItem (after sleep/wake or long uptime) while
    /// the process keeps running, leaving no menu-bar icon. Re-create it on wake, and on a
    /// nudge from a duplicate launch (the single-instance guard) so relaunching recovers it.
    private func installStatusItemResilience() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reassertStatusItem() } }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.reassertNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            // Re-showing the icon is harmless — always do it.
            self.reassertStatusItem()
            // The menu-bar icon can be parked off-screen by a CROWDED menu bar (many
            // menu-bar apps + the notch leave no room), so re-creating it isn't enough.
            // Surfacing Preferences guarantees a re-launch lands a usable on-screen window.
            // But DistributedNotificationCenter is a system-wide bus ANY local process can
            // post, so debounce the focus-stealing side effects: a flood can't continuously
            // yank the Engine frontmost, while a genuine relaunch (one post) still surfaces.
            let now = Date()
            if let last = self.lastReassertSurface, now.timeIntervalSince(last) < 2.0 { return }
            self.lastReassertSurface = now
            NSApp.activate(ignoringOtherApps: true)
            self.openPreferences()
        } }
    }

    /// Clicking the Dock icon (Dock mode) — or re-opening with no window — surfaces
    /// Preferences, the reliable on-screen entry point when the menu-bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openPreferences() }
        return true
    }

    /// Tear down + re-create the menu-bar status item — recovery for an icon the system
    /// dropped (the process keeps running, but the icon is gone). Cheap + idempotent.
    private func reassertStatusItem() {
        // Close any popover first — it's anchored to the old status item's button; tearing
        // the item out from under a shown popover would orphan it and wedge the toggle.
        if let p = menuPopover { p.performClose(nil) }
        menuPopover = nil
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        statusItem = nil
        setupStatusItem()
    }

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
        popover.appearance = NSAppearance(named: AppSettings.shared.isLight ? .aqua : .darkAqua)
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        menuPopover = popover
    }

    // MARK: – Menu actions (called by MenuBarView)

    /// Launch the standalone Template Designer app (packaged suite only).
    func openTemplateDesigner() { DesignerAppLauncher.launch(.template) }

    /// Launch the standalone Custom Designer app (packaged suite only).
    func openCustomDesigner() { DesignerAppLauncher.launch(.custom) }

    /// Reprint: RE-OPEN the source window (print window today; Custom Designer in a
    /// later phase) in the job's print-time state so the user can choose what to
    /// reprint — instead of blindly re-submitting. The front-end watches the IPC
    /// `reprint/` channel and reopens; if the source file is gone it offers a
    /// "reprint without editing" that re-submits the rendered labels. Falls back to
    /// a direct re-submit if we can't hand off (no source app / write failure).
    func reprint(_ recent: RecentPrint) {
        let queue = PrintQueue()
        // Route off the key persisted on the record; consult the done file only as
        // a legacy fallback for records written before sourceApp existed.
        let sourceApp = recent.sourceApp.isEmpty
            ? (queue.readDoneJob(id: recent.jobId)?.sourceApp ?? "")
            : recent.sourceApp
        // Route to the front-end that can RE-OPEN this job in its print-time state:
        // Auto Print (the print window) or the Custom Designer (the saved design). Any
        // other source has no reopen path → re-submit the rendered labels directly
        // (which fails cleanly with one notification if the done file is gone).
        let target: DesignerAppLauncher.Target
        switch sourceApp {
        case "autoprint":      target = .autoPrint
        case "customdesigner": target = .custom
        default:               reprintImmediately(recent); return
        }
        // Stamp the resolved sourceApp so the request routes to the matching channel and
        // the target front-end's filter accepts it (handles the legacy empty-sourceApp
        // record whose source we recovered from the done file above).
        var req = recent
        req.sourceApp = sourceApp
        do {
            try queue.writeReprintRequest(req)         // routed by sourceApp; front-end reopens
            DesignerAppLauncher.ensureRunning(target)  // wake the front-end if it's down
        } catch {
            print("[Engine] reprint: couldn't post reprint request: \(error) — re-submitting directly")
            reprintImmediately(recent)
        }
    }

    /// Re-submit a finished job's already-rendered VGL labels as a fresh job (no
    /// window). Used for sources without a reopen path and as the "can't hand off"
    /// fallback. If the done file is gone, notify + no-op.
    private func reprintImmediately(_ recent: RecentPrint) {
        let queue = PrintQueue()
        guard !recent.jobId.isEmpty, queue.resubmitDoneJob(id: recent.jobId) else {
            print("[Engine] reprint: done file for jobId=\(recent.jobId) not found — cannot reprint")
            notify(title: "Can’t reprint",
                   body: "The original print data for “\(recent.title)” is no longer available.")
            return
        }
        // Drain immediately so it prints even if the FSEvent is coalesced/missed.
        queueWatcher?.drainBacklog()
    }

    /// Confirm, then clear the Recent Prints history. Irreversible, so warn first.
    func confirmClearRecents() {
        let alert = NSAlert()
        alert.messageText = "Clear Recent Prints?"
        alert.informativeText = "This permanently removes all recent print history. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            RecentPrintsStore.shared.clear()
        }
    }

    /// Post a local user notification (best-effort; silently ignored if the user
    /// hasn't granted notification permission).
    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    func openExportFolder() {
        let url = AppSettings.shared.exportsFolderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// Menu action: user-initiated update check — always allowed regardless of
    /// policy, and alerts on errors / "up to date" (unlike the silent auto checks).
    func checkForUpdates() {
        UpdateChecker.shared.checkNow(userInitiated: true)
    }

    /// Menu action: manual "Report a Problem…" popup. Activate first — the
    /// Engine is an .accessory app, so the modal would otherwise open behind
    /// whatever app is frontmost.
    func reportProblem() {
        NSApp.activate(ignoringOtherApps: true)
        ErrorReporter.presentManualReport(appName: "Engine")
    }

    func openPreferences(selectTab: Int? = nil) {
        if let win = preferencesWindow {
            // Already open: switch to the requested tab (if any) and bring it forward.
            if let tab = selectTab {
                NotificationCenter.default.post(name: .vlSelectPreferencesTab, object: tab)
            }
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: PreferencesView(initialTab: selectTab ?? 0))
        let win = NSPanel(contentViewController: controller)
        win.title = "VectorLabel Preferences"
        win.styleMask = [.titled, .closable, .nonactivatingPanel]
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // Default tall enough to show the Printers tab without scrolling; capped to the
        // screen and persisted on resize by applyVLSizing. The autosave key is bumped
        // (…Window2) so a stale saved frame from an earlier default doesn't override it.
        win.applyVLSizing(autosaveName: "VLPreferencesWindow2",
                          defaultContentSize: NSSize(width: 700, height: 800))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        preferencesWindow = win
        preferencesCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // Closing Preferences also closes its child editor windows.
                SupplyCatalogEditorWindow.shared.close()
                PrinterModelEditorWindow.shared.close()
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
        // A job with no printable rasters — a corrupt file that decoded to empty, or a
        // legacy `labels`-only file the Engine can't feed — must FAIL loudly, not submit
        // a 0-label job that PrinterManager marks "complete" and records as a printed
        // 0-label Recent Print. (F29/F91)
        guard !job.renderedLabels.isEmpty else {
            NSLog("[Engine] job \(job.id) has no rendered labels — routing to failed/.")
            PrintQueue().complete(processingURL, success: false)
            return
        }
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

        // Honor `copies` (clamped to a sane range): expand each rendered label so a
        // submitter that sets copies>1 instead of pre-expanding prints the right count.
        // The current front-ends pre-expand and pass copies:1, so this is a no-op for
        // them — but the public field is no longer a silent trap. (F90/F57)
        let copies = min(max(job.copies, 1), 999)
        let labels = copies > 1
            ? job.renderedLabels.flatMap { Array(repeating: $0, count: copies) }
            : job.renderedLabels

        let printJob = PrinterManager.shared.submit(
            labels: labels,
            title: job.title,
            templateName: job.templateName,
            printerID: printerID,
            cutMode: job.cutMode,
            estLabelMs: job.estLabelMs,
            ipcJobID: job.id,
            sourceApp: job.sourceApp,
            feedToClear: job.feedToClear
        )

        // RECENTS OWNERSHIP: the Engine is the only process that prints, so it is
        // the single source of truth for Recent Prints. Record a `.printing` entry
        // now (carrying the IPC job id so Reprint can re-read ipc/done/<id>.json),
        // and update its status to the terminal outcome on completion.
        let printerName = PrinterManager.shared.printers.first { $0.id == printerID }?.name ?? printerID
        // Preserve the front-end's print-time state (source/selection/filter/sort)
        // so Reprint can RE-OPEN the source window in that state, not blindly print.
        let rp = job.reprint
        let recent = RecentPrint(
            date: Date(),
            title: job.title,
            sourceFileName: rp?.sourceFileName ?? "",
            templateName: job.templateName,
            printerName: printerName,
            labelCount: labels.count,
            printRange: RecentPrint.PrintRange(rawValue: rp?.printRange ?? "") ?? .all,
            selectedIndices: rp?.selectedIndices ?? [],
            status: .printing,
            rangeFrom: rp?.rangeFrom,
            rangeTo: rp?.rangeTo,
            filterJSON: rp?.filterJSON,
            sortJSON: rp?.sortJSON,
            jobId: job.id,
            sourceApp: job.sourceApp
        )
        recents.add(recent)

        // MENU-POP-ON-PRINT: open the menu-bar popover so the user can watch
        // progress. This is the cross-process replacement for the old front-end
        // onPrintStarted → popover (now dead across separate processes).
        showMenuPopover()

        var subs = Set<AnyCancellable>()

        // Republish status whenever this job's progress advances, so a front-end
        // watching printers.json sees live `completed` counts (debounced publish).
        printJob.$completedLabels
            .dropFirst()
            .sink { [weak self] _ in self?.schedulePublishStatus() }
            .store(in: &subs)
        printJob.$isPrinting
            .dropFirst()
            .sink { [weak self] _ in self?.schedulePublishStatus() }
            .store(in: &subs)

        // Observe completion: when isComplete flips true (success path) OR didFail
        // is set, finalize the queue file exactly once and drop the subscription.
        // didFail is a plain (lock-guarded) property, not @Published, so we drive
        // the check off $isComplete — PrinterManager sets isComplete=true on every
        // terminal outcome (success, cancel, fail), at which point didFail is
        // already settled.
        printJob.$isComplete
            .filter { $0 }
            .first()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.finishInFlight(printJob)
            }
            .store(in: &subs)

        inFlight[printJob.id] = InFlightEntry(
            processingURL: processingURL,
            ipcJobID: job.id,
            recentID: recent.id,
            subs: subs
        )
        // Honor a cancel that arrived while this job was mid-claim (before it was
        // in-flight): now that it's tracked, cancel it immediately.
        if pendingCancels.remove(job.id) != nil { PrinterManager.shared.cancel(printJob) }
    }

    private func finishInFlight(_ job: PrintJob) {
        guard let entry = inFlight.removeValue(forKey: job.id) else { return }
        entry.subs.forEach { $0.cancel() }
        // Update the Recent-Prints record to its terminal lifecycle state. For a
        // cancelled job, distinguish "before printing" (nothing printed) from
        // "mid-print", and correct the label count to the number actually printed
        // so the recent shows the real outcome, not the full intended total.
        let printed = job.completedLabels
        let status: RecentPrint.Status
        if job.didFail            { status = .failed }
        else if job.isCancelled   { status = printed > 0 ? .cancelledMidPrint : .cancelledBeforePrinting }
        else                      { status = .complete }
        recents.finish(id: entry.recentID, status: status,
                       labelCount: job.isCancelled ? printed : nil)
        // A cancelled job's processing/ file still moves to done/ (its rendered
        // labels are retained there so it can still be reprinted); only a true
        // device failure routes to failed/.
        PrintQueue().complete(entry.processingURL, success: !job.didFail)
    }

    // MARK: – Control channel (cancel an in-flight job)

    private func startControlWatcher() {
        let queue = PrintQueue()
        queue.ensureDirs()
        let fw = FolderWatcher(root: queue.controlDir, suffix: ".json", latency: 0.1) { [weak self] url in
            Task { @MainActor in self?.handleControl(url) }
        }
        fw.start()
        controlWatcher = fw
        // Drain any control requests already waiting (written before we started).
        for url in queue.pendingControlURLs() { handleControl(url) }
    }

    private func handleControl(_ url: URL) {
        let queue = PrintQueue()
        guard let req = queue.readControl(url) else {
            queue.deleteControl(url)   // undecodable — drop it
            return
        }
        switch req.action {
        case .cancel:
            // 1) In-flight: cancel the live PrintJob (the $isComplete observer then runs
            //    finishInFlight, completing the queue file).
            if let pair = inFlight.first(where: { $0.value.ipcJobID == req.jobId }),
               let printJob = PrinterManager.shared.activeJobs.first(where: { $0.id == pair.key }) {
                PrinterManager.shared.cancel(printJob)
            // 2) Still QUEUED (not yet claimed — common when the USB scan is slow and the
            //    job was requeued): pull it out of the queue so it never prints, and
            //    record it as cancelled-before-printing.
            } else if let job = queue.cancelQueuedJob(id: req.jobId) {
                recents.add(RecentPrint(date: Date(), title: job.title, sourceFileName: "",
                                        templateName: job.templateName, printerName: "",
                                        labelCount: 0, printRange: .all, selectedIndices: [],
                                        status: .cancelledBeforePrinting,
                                        jobId: job.id, sourceApp: job.sourceApp))
            // 3) Neither yet — it may be in the brief claim→consume window. Remember the
            //    cancel so consumeResolved honors it the instant the job goes in-flight.
            } else {
                pendingCancels.insert(req.jobId)
            }
        case .detectCassette:
            // Force an on-demand cassette re-read; the republished status clears any
            // stale pre-flight error in the front-ends (printhead-open etc.).
            if !req.printerID.isEmpty {
                PrinterManager.shared.refreshCassette(for: req.printerID, force: true)
            }
        }
        queue.deleteControl(url)
    }

    // MARK: – Cancelled-record channel (front-end records a pre-submit cancel)

    private func startCancelledWatcher() {
        let queue = PrintQueue()
        queue.ensureDirs()
        let fw = FolderWatcher(root: queue.cancelledDir, suffix: ".json", latency: 0.1) { [weak self] url in
            Task { @MainActor in self?.handleCancelled(url) }
        }
        fw.start()
        cancelledWatcher = fw
        // Drain any cancellations recorded before we started watching.
        for url in queue.pendingCancelledURLs() { handleCancelled(url) }
    }

    private func handleCancelled(_ url: URL) {
        let queue = PrintQueue()
        // The front-end already built a RecentPrint with status .cancelledBeforePrinting
        // and the print-time state; record it so it shows in the menu and reprints
        // (re-opens the print window) like any other recent.
        if let recent = queue.readCancelledRecent(url) { recents.add(recent) }
        queue.deleteCancelled(url)
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
