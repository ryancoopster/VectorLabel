import Foundation
import VectorLabelCore

// Maps EngineKit's live (non-Codable) hardware types onto the Core IPC status
// types so any backend can publish a `PrinterStatusFile`. Used today by the
// combined app's LocalPrintBackend, and reused by the Engine's status publisher
// in a later step.

// `BradyUSB.SmartCellInfo.asCassetteStatus()` now lives in the PrinterM610 module
// (PrinterM610/M610Module.swift) so each printer module owns its status mapping.

public extension PrinterDevice {
    /// A `PrinterStatusEntry` for this printer, given its detected cassette (if
    /// any) and the number of jobs currently active on it.
    func asStatusEntry(cassette: CassetteStatus?, activeJobCount: Int) -> PrinterStatusEntry {
        PrinterStatusEntry(
            id: id,
            name: name,
            model: model,
            serial: serial,
            status: status.rawValue,
            cassette: cassette,
            activeJobCount: activeJobCount
        )
    }
}

public extension PrinterManager {
    /// Build a `PrinterStatusFile` snapshot from the manager's current state —
    /// the printers list, the detected cassettes, and per-printer active job
    /// counts. `engineRunning` reflects that this in-process manager is live.
    func currentStatusFile() -> PrinterStatusFile {
        let entries = printers.map { dev in
            dev.asStatusEntry(
                cassette: cassettes[dev.id],
                activeJobCount: activeJobs.filter { $0.printerID == dev.id && !$0.isComplete }.count
            )
        }
        // Publish each in-flight (cross-process) job so a front-end can show live
        // progress and offer Cancel. Only jobs that carry an IPC id are published
        // (in-process jobs like the calibration grid have none). The id is the
        // PrintJobFile id, which the front-end uses to cancel via the control channel.
        let jobs: [ActiveJobStatus] = activeJobs.compactMap { j in
            guard !j.isComplete, !j.ipcJobID.isEmpty else { return nil }
            return ActiveJobStatus(
                id: j.ipcJobID,
                title: j.title,
                sourceApp: j.sourceApp,
                labelCount: j.labelCount,
                completed: j.completedLabels,
                state: j.isPrinting ? .printing : .queued
            )
        }
        return PrinterStatusFile(
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            engineRunning: true,
            printers: entries,
            activeJobs: jobs
        )
    }
}
