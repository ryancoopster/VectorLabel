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
    @Published var isCancelled: Bool = false
    @Published var isComplete: Bool = false

    var progress: Double { labelCount > 0 ? Double(completedLabels) / Double(labelCount) : 0 }

    private var cancelContinuation: CheckedContinuation<Void, Never>?

    init(title: String, labelCount: Int, templateName: String, printerID: String) {
        self.title = title; self.labelCount = labelCount
        self.templateName = templateName; self.printerID = printerID
    }

    func requestCancel() { isCancelled = true }
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
                // Printers we had before that are no longer found → offline
                for existing in self.printers {
                    if !updated.contains(where: { $0.id == existing.id }) {
                        var gone = existing; gone.status = .offline
                        updated.append(gone)
                    }
                }
                self.printers = updated
            }
        }
    }

    // MARK: – Print dispatch

    /// Submit a set of VGL jobs to the given printer.
    func submit(
        jobs: [[UInt8]],
        title: String,
        templateName: String,
        printerID: String,
        delayMs: Int = AppSettings.shared.interLabelDelayMs
    ) {
        let job = PrintJob(
            title: title,
            labelCount: jobs.count,
            templateName: templateName,
            printerID: printerID
        )
        activeJobs.append(job)
        setPrinterBusy(printerID, busy: true)

        Task.detached {
            do {
                let handle = try BradyUSB.openPrinterByID(printerID)
                defer { BradyUSB.close(handle) }

                for (i, vglJob) in jobs.enumerated() {
                    if job.isCancelled { break }
                    try BradyUSB.sendJob(vglJob, handle: handle)
                    await MainActor.run { job.completedLabels = i + 1 }
                    if i < jobs.count - 1 {
                        usleep(useconds_t(delayMs * 1000))
                    }
                }
            } catch {
                print("[PrinterManager] Print failed: \(error)")
            }
            await MainActor.run {
                job.isComplete = true
                self.setPrinterBusy(printerID, busy: false)
                // Clean up completed jobs older than 60s on next scan
                self.activeJobs.removeAll { $0.isComplete }
            }
        }
    }

    private func setPrinterBusy(_ id: String, busy: Bool) {
        printers = printers.map { p in
            var copy = p
            if copy.id == id { copy.status = busy ? .busy : .ready }
            return copy
        }
    }
}
