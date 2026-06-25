import Foundation
import Combine
import AppKit
import VectorLabelCore
import PrinterM610   // M610 driver module (VGL/USB)
import PrinterM611   // M611 driver module (bitmap/LZ4 over TCP)
import PrinterBrother // Brother P-touch driver modules (classic raster/USB)

// MARK: – Models

// `PrinterDevice` moved to VectorLabelCore (Core/Printing/PrinterDevice.swift) so the
// shared `PrinterModule` protocol + both per-printer modules can refer to it.

/// One print job in the active queue.
public final class PrintJob: ObservableObject, Identifiable {
    public let id: UUID = UUID()
    public let title: String           // e.g. "Kodak Hall — N044–N046"
    public let labelCount: Int
    public let templateName: String
    public let printerID: String

    /// The originating IPC PrintJobFile id (queue filename stem), when this job
    /// came from the cross-process queue. Lets the Engine publish a stable id in
    /// the status's activeJobs so a front-end can cancel by that id. Empty for
    /// in-process jobs (calibration grid).
    public let ipcJobID: String
    /// Originating app ("autoprint" | "customdesigner" | …), for status display.
    public let sourceApp: String
    /// Whether per-label progress is meaningful for this job — the driver reports a
    /// progress signal (M610 counter) OR it's printing one label at a time. When false
    /// the menu shows a coarse "Printing…" → done instead of a per-label bar/count.
    public let reportsProgress: Bool

    @Published public var completedLabels: Int = 0
    @Published public var isComplete: Bool = false
    @Published public var isPrinting: Bool = false   // false while queued, true once printing

    // Read from the background print task and written from the main thread, so it
    // needs its own synchronization rather than relying on @Published/main-actor.
    private let cancelLock = NSLock()
    private var _isCancelled = false
    public var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _isCancelled
    }

    public var progress: Double { labelCount > 0 ? Double(completedLabels) / Double(labelCount) : 0 }

    public init(title: String, labelCount: Int, templateName: String, printerID: String,
                ipcJobID: String = "", sourceApp: String = "", reportsProgress: Bool = true) {
        self.title = title; self.labelCount = labelCount
        self.templateName = templateName; self.printerID = printerID
        self.ipcJobID = ipcJobID; self.sourceApp = sourceApp
        self.reportsProgress = reportsProgress
    }

    public func requestCancel() {
        cancelLock.lock(); _isCancelled = true; cancelLock.unlock()
    }

    // Set from the background print task on a send error, read on the main thread
    // when the job finishes — shares the cancel lock for thread safety.
    private var _didFail = false
    public var didFail: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _didFail
    }
    func markFailed() {
        cancelLock.lock(); _didFail = true; cancelLock.unlock()
    }
}

// MARK: – PrinterManager

/// Manages USB printer discovery, active jobs, and print dispatch.
@MainActor
public final class PrinterManager: ObservableObject {

    public static let shared = PrinterManager()

    public init() {
        // Register the per-printer driver modules. Everything (discovery, encode,
        // transport, status) routes by model through the registry from here on.
        PrinterModuleRegistry.shared.register(M610Module())
        PrinterModuleRegistry.shared.register(M611Module())
        PrinterModuleRegistry.shared.register(PTE550WModule())     // Brother classic (USB + net)
        PrinterModuleRegistry.shared.register(PTP750WModule())     // Brother classic (USB + net)
        PrinterModuleRegistry.shared.register(PTE560BTModule())    // Brother D460BT dialect (USB)
    }

    // One serial queue per printer, serializing all device access (prints + status
    // reads) to that printer while different printers run concurrently.
    private let queuesLock = NSLock()
    private var deviceQueues: [String: DispatchQueue] = [:]
    private func deviceQueue(for id: String) -> DispatchQueue {
        queuesLock.lock(); defer { queuesLock.unlock() }
        if let q = deviceQueues[id] { return q }
        let q = DispatchQueue(label: "vectorlabel.printer.\(id)", qos: .utility)
        deviceQueues[id] = q
        return q
    }

    @Published public var printers: [PrinterDevice] = []
    @Published public var activeJobs: [PrintJob] = []

    /// True once at least one USB enumeration scan has completed. Lets the Engine
    /// distinguish "the scan hasn't run yet" (a no-printer job should be re-queued,
    /// not failed) from "the scan ran and found nothing" (fail a job that needs a
    /// printer). Published so the queue drain can react when scanning finishes.
    @Published public private(set) var hasScannedOnce: Bool = false

    private var scanTimer: Timer?
    private var scanInFlight = false   // prevents overlapping scans piling up if one runs long
    private var settingsSubs = Set<AnyCancellable>()

    // MARK: – USB scan

    public func startScan() {
        performScan()
        // The scan + telemetry poll run on the user's configurable refresh interval
        // (Preferences ▸ Printers ▸ Status Refresh). $refreshIntervalSec emits its
        // current value on subscribe — scheduling the timer — and again on every change.
        AppSettings.shared.$refreshIntervalSec
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleScanTimer() } }
            .store(in: &settingsSubs)
    }

    public func stopScan() { scanTimer?.invalidate(); scanTimer = nil }

    /// (Re)create the periodic timer that BOTH scans for connected printers and re-reads
    /// live status/telemetry, on the configured refresh interval (clamped 1…600s). Each
    /// tick polls telemetry-capable printers, skipping any that are mid-print.
    private func scheduleScanTimer() {
        scanTimer?.invalidate()
        let interval = TimeInterval(min(600, max(1, AppSettings.shared.refreshIntervalSec)))
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performScan()
                self?.pollTelemetry()
            }
        }
    }

    /// Public entry point for manual refresh (called from Preferences).
    public func scanNow() { performScan() }

    // MARK: – Network printers (manual add + subnet discovery)

    /// True while a subnet scan is running, for UI feedback.
    @Published public private(set) var isScanningNetwork = false
    /// Last network scan / add result, shown in the Preferences UI.
    @Published public var networkScanMessage: String?

    /// Add a network printer by IP/hostname, then rescan so it appears.
    public func addNetworkPrinter(name: String, host: String, model: String = "M611") {
        if NetworkPrinterStore.add(name: name, host: host, model: model) {
            networkScanMessage = "Added \(host)."
            performScan()
        }
    }

    /// Registered printer models whose driver can be driven over the network — the
    /// choices for the "Add network printer" model picker. A network entry's model
    /// decides which driver enumerates it, so it must be picked when adding.
    public var networkPrinterModels: [String] {
        PrinterModuleRegistry.shared.all()
            .filter { $0.capabilities.supportedTransports.contains(.network) }
            .map { $0.capabilities.model }
            .sorted()
    }

    /// Remove a network printer and forget its cassette.
    public func removeNetworkPrinter(host: String) {
        NetworkPrinterStore.remove(host: host)
        cassettes["net:\(host)"] = nil
        performScan()
    }

    /// Scan the local subnet for network printers (raw print port 9100), classify each
    /// by PORT SIGNATURE, add any new ones, then rescan. The Brother PT exposes only
    /// 9100; the Brady M611 also exposes the PICL control port 9102 — so an open 9102
    /// distinguishes an M611 from a Brother. (A non-Brother raw-9100 printer would be
    /// guessed as a PT-E550W since that's the only Brother driver; the user can remove a
    /// wrong match. We can't confirm "Brother" over the wire — it gives no status on 9100.)
    public func scanNetwork() {
        guard !isScanningNetwork else { return }
        isScanningNetwork = true
        networkScanMessage = "Scanning the local network…"
        Task.detached {
            // Find raw-print hosts, then classify each off-main (blocking 9102 probe).
            let rawHosts = NetworkDiscovery.scanSubnet(port: 9100)
            var toAdd: [(host: String, model: String)] = []
            for host in rawHosts where !NetworkPrinterStore.contains(host: host) {
                let isM611 = NetworkDiscovery.tcpReachable(host: host, port: 9102, timeoutMs: 600)
                toAdd.append((host, isM611 ? "M611" : "PT-E550W"))
            }
            await MainActor.run {
                for e in toAdd {
                    NetworkPrinterStore.add(name: "\(e.model) (\(e.host))", host: e.host, model: e.model)
                }
                let added = toAdd.count
                self.isScanningNetwork = false
                self.networkScanMessage = added > 0
                    ? "Found \(added) new network printer\(added == 1 ? "" : "s")."
                    : "No new network printers found."
                self.performScan()
            }
        }
    }

    private func performScan() {
        // Skip if a scan is still running, so slow USB enumeration can't pile up
        // overlapping detached tasks all contending for device access.
        if scanInFlight { return }
        // Don't enumerate while a job is in flight. Enumeration opens device handles
        // and reads string descriptors over EP0 (BradyUSB.enumeratePrinters /
        // M611USB.enumerate); doing that concurrently with the in-flight bulk transfers
        // on a printer's serial queue is unsynchronized libusb access to the same device
        // and surfaces as intermittent transfer failures / bogus cassette reads. The
        // post-job finish re-marks status and the next 5s tick resumes scanning.
        if activeJobs.contains(where: { !$0.isComplete }) { return }
        scanInFlight = true
        // Enumerate every registered module (USB + network) on a background thread.
        Task.detached {
            let found = PrinterModuleRegistry.shared.all().flatMap { $0.enumerate() }
            await MainActor.run {
                defer { self.scanInFlight = false; self.hasScannedOnce = true }
                // Merge: update status for existing entries, add new ones, mark missing as offline
                var updated: [PrinterDevice] = []
                for discovered in found {
                    var dev = discovered
                    // If a job is running on this printer, mark it busy
                    if self.activeJobs.contains(where: { $0.printerID == dev.id && !$0.isComplete && !$0.isCancelled }) {
                        dev.status = .busy
                    }
                    updated.append(dev)
                }
                // Printers we had before that are no longer found → mark offline
                // for one scan cycle so the user sees a disconnect, then drop them.
                // (Already-offline entries are not carried forward, so a removed
                // printer disappears on the next scan instead of lingering forever.)
                for existing in self.printers {
                    if !updated.contains(where: { $0.id == existing.id }),
                       existing.status != .offline {
                        var gone = existing; gone.status = .offline
                        updated.append(gone)
                    }
                }

                // Printers that were ready before this scan — used to auto-detect
                // the cassette only on a fresh connect (or offline → ready).
                let previouslyReady = Set(self.printers.filter { $0.status == .ready }.map { $0.id })
                // Only publish when the value actually changed — an identical 5s scan
                // would otherwise emit a no-op change that forces a full DOM rebuild
                // of the print window every cycle (idle CPU/battery drain).
                if updated != self.printers { self.printers = updated }

                // Forget cassette info for printers that are gone.
                let presentIDs = Set(updated.map { $0.id })
                let keptCassettes = self.cassettes.filter { presentIDs.contains($0.key) }
                if keptCassettes != self.cassettes { self.cassettes = keptCassettes }
                self.cassetteFetchedAt = self.cassetteFetchedAt.filter { presentIDs.contains($0.key) }

                // Auto-detect the loaded label on newly-connected printers.
                for dev in updated where dev.status == .ready && !previouslyReady.contains(dev.id) {
                    self.refreshCassette(for: dev.id)
                }
            }
        }
    }

    // MARK: – Print dispatch

    /// Submit a batch of rendered labels to the given printer.
    /// Returns the created `PrintJob` so callers can observe its progress.
    /// `labels` are printer-agnostic `RenderedLabel` rasters (NOT pre-encoded VGL):
    /// the Engine encodes each into the target printer's wire format HERE, via the
    /// model's module, and STAMPS the per-label cut from `cutMode` + `isLastLabel` at
    /// encode time. Defaulting `cutMode` to `.afterJobLast` keeps the single-job paths
    /// (calibration grid, in-process callers) unchanged.
    @discardableResult
    public func submit(
        labels: [RenderedLabel],
        title: String,
        templateName: String,
        printerID: String,
        cutMode: CutMode = .afterJobLast,
        estLabelMs: Int = 1000,
        ipcJobID: String = "",
        sourceApp: String = "",
        feedToClear: Bool = false
    ) -> PrintJob {
        // Resolve the target device, its driver module, and the model's per-model print
        // setting up front (main-actor state). The driver's progress capability + the
        // single-label setting decide whether this job reports per-label progress.
        let device = printers.first { $0.id == printerID }
        let module = device.flatMap { PrinterModuleRegistry.shared.module(forModel: $0.model) }
        let settings = PrinterModelStore.printSettings(forName: device?.model ?? "")
        // The driver owns the send strategy. When it's user-selectable, honor the per-printer
        // "one label at a time" setting; a `.fixed` driver always handles it (and reports good
        // progress regardless). The driver tells us whether it'll report a per-label counter
        // so we set up the right progress UI up front.
        let singleLabel: Bool
        if case .selectable = module?.capabilities.sendMode { singleLabel = settings.singleLabelPrinting }
        else { singleLabel = false }
        let reportsProgress = module?.reportsCounter(singleLabel: singleLabel) ?? false
        NSLog("[PrinterManager] submit '\(title)': \(labels.count) label(s) printer=\(printerID) " +
              "model=\(device?.model ?? "?") sendMode=\(String(describing: module?.capabilities.sendMode)) " +
              "setting.singleLabelPrinting=\(settings.singleLabelPrinting) → " +
              "mode=\(singleLabel ? "SINGLE" : "FULL") progress=\(reportsProgress ? "counter" : "coarse")")

        let job = PrintJob(
            title: title,
            // +1 when a feed-to-clear blank lead label will be prepended (below).
            labelCount: labels.count + (feedToClear && !labels.isEmpty ? 1 : 0),
            templateName: templateName,
            printerID: printerID,
            ipcJobID: ipcJobID,
            sourceApp: sourceApp,
            reportsProgress: reportsProgress
        )
        activeJobs.append(job)
        setPrinterBusy(printerID, busy: true)

        // last-known media status is main-actor state; capture it before hopping to the
        // printer's dedicated serial queue (blocking sends + pacing stay off the pool).
        let status = cassettes[printerID]
        let queue = deviceQueue(for: printerID)
        queue.async {
            func finishOnMain() {
                Task { @MainActor in
                    job.isComplete = true
                    let stillBusy = self.activeJobs.contains {
                        $0.printerID == printerID && !$0.isComplete && $0.id != job.id
                    }
                    self.setPrinterBusy(printerID, busy: stillBusy)
                    self.activeJobs.removeAll { $0.isComplete }
                }
            }

            // Cancelled while still queued — finish without touching the device.
            if job.isCancelled { finishOnMain(); return }
            Task { @MainActor in job.isPrinting = true }

            guard let module, let device else {
                print("[PrinterManager] no driver/device for \(printerID)")
                job.markFailed(); finishOnMain(); return
            }

            // Pre-flight (authoritative, device-owner side). For telemetry-capable
            // drivers (M611) re-read live status so the check — and the encode below —
            // use current media flags, not a possibly-stale cache. A failed read falls
            // back to the cached status so a network blip never blocks a legit print.
            var liveStatus = status
            if module.capabilities.hasLiveTelemetry, let fresh = module.readStatus(device) {
                liveStatus = fresh
                Task { @MainActor in
                    self.cassettes[printerID] = fresh
                    self.cassetteFetchedAt[printerID] = Date()
                }
            }
            if let s = liveStatus,
               s.printheadOpen == true || s.substrateInvalid == true || s.ribbonInvalid == true {
                let why = [s.printheadOpen    == true ? "printhead open"  : nil,
                           s.substrateInvalid == true ? "invalid supply"  : nil,
                           s.ribbonInvalid    == true ? "invalid ribbon"  : nil]
                          .compactMap { $0 }.joined(separator: ", ")
                print("[PrinterManager] Pre-flight blocked '\(title)': \(why)")
                job.markFailed(); finishOnMain(); return
            }

            // Feed-to-clear: synthesize the blank lead label HERE (one source of truth
            // with the cut decision, and after copy-expansion so exactly one is added).
            // Geometry comes from the actual first label: die-cut → one label pitch (its
            // feed height); continuous → a 1" feed (300 dpi). Continuous tape is ALWAYS cut
            // after the feed; die-cut follows the user's cut setting.
            let continuous = (liveStatus?.isContinuous == true) || (liveStatus.map { !$0.isDieCut } ?? false)
            var jobLabels = labels
            let feedClearLead = feedToClear && !labels.isEmpty   // jobLabels[0] is the blank
            if feedClearLead, let first = labels.first {
                // 1" feed at the master render DPI (the surrounding labels' scale) vs
                // one die-cut pitch. The driver downscales this lead like any label.
                let h = continuous ? RenderDPI.master : first.height
                jobLabels.insert(RenderedLabel(pixels: Data(count: first.width * h),
                                               width: first.width, height: h,
                                               partNumber: first.partNumber, dpi: first.dpi), at: 0)
            }
            func cutFor(_ i: Int) -> CutMode {
                (feedClearLead && i == 0 && continuous) ? .eachLabel : cutMode
            }

            do {
                let conn = try module.open(device)
                defer { module.close(conn) }

                // Hand the job to the DRIVER. It owns the send strategy (one label at a time
                // vs one batched job) + pacing, and reports progress as a counter or coarse
                // "printing"; it drains in-flight printing before returning so this close is
                // clean. The Engine just relays progress to the PrintJob.
                let pages = jobLabels.enumerated().map { i, label in
                    DriverPage(label: label, cut: cutFor(i), isLast: i == jobLabels.count - 1)
                }
                try module.run(DriverJob(
                    pages: pages, status: liveStatus, singleLabel: singleLabel,
                    estLabelMs: max(150, estLabelMs),
                    connection: conn, isCancelled: { job.isCancelled },
                    progress: { upd in
                        Task { @MainActor in
                            switch upd {
                            case .counter(let done, _): if done > job.completedLabels { job.completedLabels = done }
                            case .printing: break   // coarse — the menu shows "Printing…"
                            // Fill the bar to 100% only on a clean finish. A cancelled job keeps
                            // the partial count it reached, so Recent Prints records what actually
                            // printed (not the full intended total).
                            case .done:     if !job.isCancelled { job.completedLabels = pages.count }
                            }
                        }
                    },
                    // Manual-cut pause (printers with no auto-cutter, cut-every-label): the
                    // driver calls this between labels; show a modal so the user cuts/tears
                    // the printed label before the next one feeds. Blocks the print thread.
                    awaitCut: {
                        if job.isCancelled { return false }
                        let sem = DispatchSemaphore(value: 0)
                        var keepGoing = true
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.alertStyle = .informational
                            alert.messageText = "Cut the label"
                            alert.informativeText = "Cut or tear off the printed label, then continue printing the next one."
                            alert.addButton(withTitle: "Continue")
                            alert.addButton(withTitle: "Stop Printing")
                            NSApp.activate(ignoringOtherApps: true)
                            keepGoing = (alert.runModal() == .alertFirstButtonReturn)
                            sem.signal()
                        }
                        sem.wait()
                        return keepGoing && !job.isCancelled
                    }))
            } catch {
                print("[PrinterManager] Print failed: \(error)")
                job.markFailed()
            }
            finishOnMain()
        }

        return job
    }

    // MARK: – Calibration

    /// The label-size whose printable area the calibration grid is drawn for:
    /// the loaded cassette's supply if recognised, else a sensible default.
    public func calibrationSize(for printerID: String) -> BradyLabelSize {
        // Use the canonical BradyCatalog.core so the bulk-box↔cartridge equivalence
        // (e.g. BM-109-427 == M6-33-427) is applied here exactly as it is in the
        // renderer and supply matching; a local copy previously omitted it and made
        // a 109-427 cassette fall back to the default 32-427 calibration grid.
        if let c = cassettes[printerID], !c.partNumber.isEmpty,
           let match = BradyCatalog.sizes.first(where: { BradyCatalog.core($0.partNumber) == BradyCatalog.core(c.partNumber) }) {
            return match
        }
        // Non-crashing fallback: the editable catalog can in principle be emptied,
        // so never force-index BradyCatalog.sizes.
        return BradyCatalog.size(forPartNumber: "BM-32-427")
            ?? BradyCatalog.sizes.first
            ?? BradyLabelSize(partNumber: "M6-32-427", widthInches: 1.5, heightInches: 1.5)
    }

    /// Print a 1/8" calibration grid on the loaded label, applying the printer's
    /// current calibration offset so the user can iteratively dial it in.
    public func printCalibrationGrid(for printerID: String) {
        let serial = printerID.split(separator: ":").dropFirst(2).joined(separator: ":")
        let offset = AppSettings.shared.calibrationOffset(forSerial: serial)
        let size = calibrationSize(for: printerID)
        guard let grid = LabelRenderer.renderCalibrationGrid(size: size, offset: offset) else { return }
        let label = RenderedLabel(pixels: grid.pixels, width: grid.width, height: grid.height,
                                  partNumber: size.partNumber)
        submit(labels: [label], title: "Calibration grid (\(size.partNumber))",
               templateName: "Calibration", printerID: printerID)
    }

    /// Cancel a specific job.
    public func cancel(_ job: PrintJob) { job.requestCancel() }

    /// Cancel every queued/printing job for a printer.
    public func cancelAll(for printerID: String) {
        for job in activeJobs where job.printerID == printerID && !job.isComplete {
            job.requestCancel()
        }
    }

    /// Jobs currently queued or printing on a printer, in submit order.
    public func jobs(for printerID: String) -> [PrintJob] {
        activeJobs.filter { $0.printerID == printerID && !$0.isComplete }
    }

    private func setPrinterBusy(_ id: String, busy: Bool) {
        printers = printers.map { p in
            var copy = p
            // Don't promote an offline (unplugged) printer to .ready/.busy — e.g. when a
            // job finishes after the device vanished. The scan owns the offline state.
            if copy.id == id && copy.status != .offline { copy.status = busy ? .busy : .ready }
            return copy
        }
    }

    // MARK: – SmartCell cassette detection

    /// Most recent SmartCell read per printer ID, for auto-detecting the loaded
    /// supply instead of asking the user.
    @Published public var cassettes: [String: CassetteStatus] = [:]
    private var cassetteFetchedAt: [String: Date] = [:]
    private let cassetteTTL: TimeInterval = 60

    /// Reports the outcome of a user-initiated ("force") cassette detect back to
    /// the UI as `(printerID, ok, busy)`, so the page can show success/failure/busy
    /// instead of the "Detecting…" toast silently fading. Set by PrintWindowController.
    public var onForcedDetectResult: ((String, Bool, Bool) -> Void)?

    /// Read the loaded cassette's SmartCell chip for a printer and cache it
    /// (60 s TTL). The query is slow (several seconds when cold — the channel
    /// needs priming) and needs exclusive device access, so it runs on a
    /// background task behind the shared device lock and publishes to `cassettes`.
    /// Skipped while a print is in progress so it never delays a job.
    /// Re-read live telemetry for every connected telemetry-capable printer (M611) so
    /// battery / ribbon / labels / supply / errors stay current — they're otherwise only
    /// read on connect. Per-printer: skips any printer that's mid-print. Driven by the
    /// refresh-interval timer (Preferences ▸ Printers ▸ Status Refresh).
    private func pollTelemetry() {
        for dev in printers where dev.status == .ready {
            guard let caps = PrinterModuleRegistry.shared.module(forModel: dev.model)?.capabilities,
                  caps.hasLiveTelemetry else { continue }
            refreshCassette(for: dev.id, bypassTTL: true)
        }
    }

    public func refreshCassette(for printerID: String, force: Bool = false, bypassTTL: Bool = false) {
        // Never delay a print on THIS printer. A background detect just bails; a
        // user-initiated (force) detect reports "busy" so the operator isn't left
        // without feedback.
        if activeJobs.contains(where: { $0.printerID == printerID && !$0.isComplete }) {
            if force { onForcedDetectResult?(printerID, false, true) }
            return
        }
        // The periodic telemetry poll passes bypassTTL (the timer interval IS the cadence);
        // the connect-time auto-detect respects the TTL to avoid redundant back-to-back reads.
        if !force, !bypassTTL, let at = cassetteFetchedAt[printerID],
           Date().timeIntervalSince(at) < cassetteTTL { return }
        guard let device = printers.first(where: { $0.id == printerID }),
              let module = PrinterModuleRegistry.shared.module(forModel: device.model) else { return }

        // Same per-printer serial queue as printing — serializes against jobs and
        // stays off the cooperative pool. The module reads its own status (M610 =
        // SmartCell over USB, M611 = PICL over TCP) and maps it to CassetteStatus.
        deviceQueue(for: printerID).async {
            let info = module.readStatus(device)
            Task { @MainActor in
                if let info {
                    self.cassettes[printerID] = info
                    self.cassetteFetchedAt[printerID] = Date()
                }
                // Report the result of a user-initiated detect (ok = read succeeded).
                if force { self.onForcedDetectResult?(printerID, info != nil, false) }
            }
        }
    }
}
