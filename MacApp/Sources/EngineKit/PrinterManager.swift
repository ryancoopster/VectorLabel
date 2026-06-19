import Foundation
import Combine
import AppKit
import VectorLabelCore
import PrinterM610   // M610 driver module (VGL/USB)
import PrinterM611   // M611 driver module (bitmap/LZ4 over TCP)

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
                ipcJobID: String = "", sourceApp: String = "") {
        self.title = title; self.labelCount = labelCount
        self.templateName = templateName; self.printerID = printerID
        self.ipcJobID = ipcJobID; self.sourceApp = sourceApp
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

    // MARK: – USB scan

    public func startScan() {
        performScan()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performScan() }
        }
    }

    public func stopScan() { scanTimer?.invalidate(); scanTimer = nil }

    /// Public entry point for manual refresh (called from Preferences).
    public func scanNow() { performScan() }

    // MARK: – Network printers (manual add + subnet discovery)

    /// True while a subnet scan is running, for UI feedback.
    @Published public private(set) var isScanningNetwork = false
    /// Last network scan / add result, shown in the Preferences UI.
    @Published public var networkScanMessage: String?

    /// Add a network printer by IP/hostname, then rescan so it appears.
    public func addNetworkPrinter(name: String, host: String) {
        if NetworkPrinterStore.add(name: name, host: host) {
            networkScanMessage = "Added \(host)."
            performScan()
        }
    }

    /// Remove a network printer and forget its cassette.
    public func removeNetworkPrinter(host: String) {
        NetworkPrinterStore.remove(host: host)
        cassettes["net:\(host)"] = nil
        performScan()
    }

    /// Scan the local subnet for Brady network printers (port 9102), add any new ones,
    /// then rescan.
    public func scanNetwork() {
        guard !isScanningNetwork else { return }
        isScanningNetwork = true
        networkScanMessage = "Scanning the local network…"
        Task.detached {
            let hosts = NetworkDiscovery.scanSubnet()
            await MainActor.run {
                var added = 0
                for host in hosts where !NetworkPrinterStore.contains(host: host) {
                    // TODO: PICL-verify the model; all supported network models are M611.
                    NetworkPrinterStore.add(name: "Brady M611 (\(host))", host: host)
                    added += 1
                }
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
        delayMs: Int = AppSettings.shared.interLabelDelayMs
    ) -> PrintJob {
        print("[PrinterManager] submit \(labels.count) label(s) cutMode=\(cutMode.rawValue) → \(title)")
        let job = PrintJob(
            title: title,
            labelCount: labels.count,
            templateName: templateName,
            printerID: printerID,
            ipcJobID: ipcJobID,
            sourceApp: sourceApp
        )
        activeJobs.append(job)
        setPrinterBusy(printerID, busy: true)

        // Resolve the target device, its driver module, and last-known media status
        // on the main actor (printers + cassette cache are main-actor state); then do
        // all device I/O on the printer's dedicated serial queue (blocking sends +
        // pacing sleeps stay off the Swift cooperative pool).
        let device = printers.first { $0.id == printerID }
        let module = device.flatMap { PrinterModuleRegistry.shared.module(forModel: $0.model) }
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

            do {
                let conn = try module.open(device)
                defer { module.close(conn) }

                // Encode each label into the printer's wire format HERE (in the Engine,
                // via the model's module) and send one at a time, so progress advances
                // per-label and Cancel stops the rest. The M610 paces off its SmartCell
                // labels-remaining counter; a transport without one (M611) falls back to
                // the time estimate (capabilities.pacesByLabelsRemaining).
                let count = labels.count
                let perLabelMs = max(150, estLabelMs)
                let usePacing = module.capabilities.pacesByLabelsRemaining
                let initialRem = usePacing ? module.labelsRemaining(on: conn) : -1
                for (i, label) in labels.enumerated() {
                    if job.isCancelled { break }
                    let bytes = module.encode(label: label, status: status,
                                              cut: cutMode, isLastLabel: i == count - 1)
                    try module.send(bytes, on: conn)
                    var waited = 0
                    while waited < perLabelMs && !job.isCancelled {
                        if initialRem >= 0, waited % 120 == 0 {
                            let rem = module.labelsRemaining(on: conn)
                            if rem >= 0 && (initialRem - rem) >= (i + 1) { break }   // this label printed
                        }
                        usleep(40_000); waited += 40
                    }
                    if job.isCancelled { break }
                    Task { @MainActor in job.completedLabels = i + 1 }
                    // Honor the user's inter-label delay (Preferences ▸ interLabelDelayMs).
                    // Applied between labels (not after the last) and interruptible by Cancel.
                    if delayMs > 0 && i < count - 1 {
                        var slept = 0
                        while slept < delayMs && !job.isCancelled { usleep(20_000); slept += 20 }
                    }
                }
                // Settle: keep the job "printing" until the counter drops by the job's
                // label count (bounded so a non-reporting supply can't hang it).
                if !job.isCancelled && initialRem >= 0 {
                    let startNs = DispatchTime.now().uptimeNanoseconds
                    let capMs = count * perLabelMs * 2 + 8000
                    while !job.isCancelled {
                        let rem = module.labelsRemaining(on: conn)
                        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
                        if rem >= 0 && (initialRem - rem) >= count { break }   // truly finished
                        if elapsedMs >= capMs { break }                        // safety cap
                        usleep(200_000)
                    }
                }
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
    public func refreshCassette(for printerID: String, force: Bool = false) {
        // Never delay a print. A background detect just bails; a user-initiated
        // (force) detect reports "busy" so the operator isn't left without feedback.
        if activeJobs.contains(where: { !$0.isComplete }) {
            if force { onForcedDetectResult?(printerID, false, true) }
            return
        }
        if !force, let at = cassetteFetchedAt[printerID],
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
