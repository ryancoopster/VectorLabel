import Foundation
import Combine
import AppKit

// MARK: – Models

/// A Brady printer discovered on USB.
struct PrinterDevice: Identifiable, Hashable {
    let id: String          // "<vendorID>:<productID>:<serialNumber>"
    let name: String        // "Brady M610" or "Brady M611"
    let model: String       // "M610" | "M611"
    let serial: String
    var status: Status

    enum Status: String, Hashable {
        case ready, busy, offline
        var displayName: String {
            switch self { case .ready: "Ready"; case .busy: "Busy"; case .offline: "Offline" }
        }
    }
}

/// One print job in the active queue.
final class PrintJob: ObservableObject, Identifiable {
    let id: UUID = UUID()
    let title: String           // e.g. "Kodak Hall — N044–N046"
    let labelCount: Int
    let templateName: String
    let printerID: String

    @Published var completedLabels: Int = 0
    @Published var isComplete: Bool = false
    @Published var isPrinting: Bool = false   // false while queued, true once printing

    // Read from the background print task and written from the main thread, so it
    // needs its own synchronization rather than relying on @Published/main-actor.
    private let cancelLock = NSLock()
    private var _isCancelled = false
    var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _isCancelled
    }

    var progress: Double { labelCount > 0 ? Double(completedLabels) / Double(labelCount) : 0 }

    init(title: String, labelCount: Int, templateName: String, printerID: String) {
        self.title = title; self.labelCount = labelCount
        self.templateName = templateName; self.printerID = printerID
    }

    func requestCancel() {
        cancelLock.lock(); _isCancelled = true; cancelLock.unlock()
    }
}

// MARK: – PrinterManager

/// Manages USB printer discovery, active jobs, and print dispatch.
@MainActor
final class PrinterManager: ObservableObject {

    static let shared = PrinterManager()

    @Published var printers: [PrinterDevice] = []
    @Published var activeJobs: [PrintJob] = []

    private var scanTimer: Timer?

    // MARK: – USB scan

    func startScan() {
        performScan()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performScan() }
        }
    }

    func stopScan() { scanTimer?.invalidate(); scanTimer = nil }

    /// Public entry point for manual refresh (called from Preferences).
    func scanNow() { performScan() }

    private func performScan() {
        // Perform USB enumeration on a background thread so we don't block the main queue.
        Task.detached {
            let found = BradyUSB.enumeratePrinters()
            await MainActor.run {
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
                self.printers = updated

                // Forget cassette info for printers that are gone.
                let presentIDs = Set(updated.map { $0.id })
                self.cassettes = self.cassettes.filter { presentIDs.contains($0.key) }
                self.cassetteFetchedAt = self.cassetteFetchedAt.filter { presentIDs.contains($0.key) }

                // Auto-detect the loaded label on newly-connected printers.
                for dev in updated where dev.status == .ready && !previouslyReady.contains(dev.id) {
                    self.refreshCassette(for: dev.id)
                }
            }
        }
    }

    // MARK: – Print dispatch

    /// Submit a set of VGL jobs to the given printer.
    /// Returns the created `PrintJob` so callers can observe its progress.
    @discardableResult
    func submit(
        jobs: [[UInt8]],
        title: String,
        templateName: String,
        printerID: String,
        estLabelMs: Int = 1000,
        delayMs: Int = AppSettings.shared.interLabelDelayMs
    ) -> PrintJob {
        let job = PrintJob(
            title: title,
            labelCount: jobs.count,
            templateName: templateName,
            printerID: printerID
        )
        activeJobs.append(job)
        setPrinterBusy(printerID, busy: true)

        Task.detached {
            // Per-printer lock: jobs to the SAME printer queue and run one at a
            // time, but different printers print concurrently.
            let lock = BradyUSB.deviceLock(for: printerID)

            func finish() async {
                await MainActor.run {
                    job.isComplete = true
                    // Keep this printer busy if it still has queued/printing jobs.
                    let stillBusy = self.activeJobs.contains {
                        $0.printerID == printerID && !$0.isComplete && $0.id != job.id
                    }
                    self.setPrinterBusy(printerID, busy: stillBusy)
                    self.activeJobs.removeAll { $0.isComplete }
                }
            }

            // Cancelled while still queued — finish without touching the device.
            if job.isCancelled { await finish(); return }
            lock.wait()
            if job.isCancelled { lock.signal(); await finish(); return }
            await MainActor.run { job.isPrinting = true }

            do {
                let handle = try BradyUSB.openPrinterByID(printerID)
                defer { BradyUSB.close(handle) }

                // The printer buffers everything sent to it almost instantly (no USB
                // backpressure) and exposes no usable per-label status — confirmed by
                // probing: status queries return only constant media info, the
                // "labels remaining" counter is unreliable/lumpy, and there's no
                // unsolicited completion message. So we PACE the sends to the real
                // print rate (calibrated from label length): the bar advances honestly
                // one label at a time as each finishes printing, and — because we send
                // one at a time and check between them — Cancel actually stops the
                // remaining labels (anything already sent stays in the printer).
                let perLabelMs = max(150, estLabelMs)
                for (i, vglJob) in jobs.enumerated() {
                    if job.isCancelled { break }
                    try BradyUSB.sendJob(vglJob, handle: handle)
                    // Wait roughly one label's print time, staying responsive to
                    // cancellation, then count this label as printed.
                    var waited = 0
                    while waited < perLabelMs && !job.isCancelled { usleep(40_000); waited += 40 }
                    if job.isCancelled { break }
                    await MainActor.run { job.completedLabels = i + 1 }
                }
            } catch {
                print("[PrinterManager] Print failed: \(error)")
            }
            lock.signal()
            await finish()
        }

        return job
    }

    // MARK: – Calibration

    /// The label-size whose printable area the calibration grid is drawn for:
    /// the loaded cassette's supply if recognised, else a sensible default.
    func calibrationSize(for printerID: String) -> BradyLabelSize {
        func core(_ pn: String) -> String {
            guard let dash = pn.firstIndex(of: "-") else { return pn.uppercased() }
            return String(pn[pn.index(after: dash)...]).uppercased()
        }
        if let c = cassettes[printerID], !c.partNumber.isEmpty,
           let match = BradyCatalog.sizes.first(where: { core($0.partNumber) == core(c.partNumber) }) {
            return match
        }
        return BradyCatalog.size(forPartNumber: "BM-32-427") ?? BradyCatalog.sizes[0]
    }

    /// Print a 1/8" calibration grid on the loaded label, applying the printer's
    /// current calibration offset so the user can iteratively dial it in.
    func printCalibrationGrid(for printerID: String) {
        let serial = printerID.split(separator: ":").dropFirst(2).joined(separator: ":")
        let offset = AppSettings.shared.calibrationOffset(forSerial: serial)
        let size = calibrationSize(for: printerID)
        guard let grid = LabelRenderer.renderCalibrationGrid(size: size, offset: offset) else { return }
        let job = BradyVGL.buildPrintJob(pixels: grid.pixels, width: grid.width, height: grid.height)
        submit(jobs: [job], title: "Calibration grid (\(size.partNumber))",
               templateName: "Calibration", printerID: printerID)
    }

    /// Cancel a specific job.
    func cancel(_ job: PrintJob) { job.requestCancel() }

    /// Cancel every queued/printing job for a printer.
    func cancelAll(for printerID: String) {
        for job in activeJobs where job.printerID == printerID && !job.isComplete {
            job.requestCancel()
        }
    }

    /// Jobs currently queued or printing on a printer, in submit order.
    func jobs(for printerID: String) -> [PrintJob] {
        activeJobs.filter { $0.printerID == printerID && !$0.isComplete }
    }

    private func setPrinterBusy(_ id: String, busy: Bool) {
        printers = printers.map { p in
            var copy = p
            if copy.id == id { copy.status = busy ? .busy : .ready }
            return copy
        }
    }

    // MARK: – SmartCell cassette detection

    /// Most recent SmartCell read per printer ID, for auto-detecting the loaded
    /// supply instead of asking the user.
    @Published var cassettes: [String: BradyUSB.SmartCellInfo] = [:]
    private var cassetteFetchedAt: [String: Date] = [:]
    private let cassetteTTL: TimeInterval = 60

    /// Read the loaded cassette's SmartCell chip for a printer and cache it
    /// (60 s TTL). The query is slow (several seconds when cold — the channel
    /// needs priming) and needs exclusive device access, so it runs on a
    /// background task behind the shared device lock and publishes to `cassettes`.
    /// Skipped while a print is in progress so it never delays a job.
    func refreshCassette(for printerID: String, force: Bool = false) {
        if activeJobs.contains(where: { !$0.isComplete }) { return }  // don't delay a print
        if !force, let at = cassetteFetchedAt[printerID],
           Date().timeIntervalSince(at) < cassetteTTL { return }

        Task.detached {
            let lock = BradyUSB.deviceLock(for: printerID)
            lock.wait()
            var info: BradyUSB.SmartCellInfo?
            do {
                let handle = try BradyUSB.openPrinterByID(printerID)
                defer { BradyUSB.close(handle) }
                info = BradyUSB.querySmartCell(handle: handle)
            } catch {
                // LIBUSB_ERROR_ACCESS or not found — keep any cached value.
            }
            lock.signal()

            if let info {
                await MainActor.run {
                    self.cassettes[printerID] = info
                    self.cassetteFetchedAt[printerID] = Date()
                }
            }
        }
    }
}
