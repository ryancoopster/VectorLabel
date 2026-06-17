import Foundation
import Combine
import VectorLabelCore
import VectorLabelEngineKit
import VectorLabelUI

/// In-process `PrintBackend` that wraps the shared `PrinterManager`, so the single
/// combined VectorLabel app prints exactly as it always has — just through the
/// PrintBackend abstraction. This is the only place left in the UI flow that
/// touches PrinterManager / libusb.
///
/// A standalone front-end process would instead use `IPCPrintBackend` (Core-only)
/// to talk to a separate Engine via the file queue.
@MainActor
final class LocalPrintBackend: PrintBackend {

    private let manager: PrinterManager
    private var observers: Set<AnyCancellable> = []

    private(set) var status: PrinterStatusFile?
    var onStatusChange: ((PrinterStatusFile) -> Void)?

    init(manager: PrinterManager = .shared) {
        self.manager = manager
    }

    func start() {
        // Recompute and publish status whenever the printer list, the detected
        // cassettes, or the active-job set changes — mirroring the Combine
        // observers PrintWindowController used to keep itself directly. $printers
        // emits its current value immediately, so a consumer that subscribes after
        // a scan has already happened still gets seeded.
        manager.$printers
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &observers)
        manager.$cassettes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &observers)
        manager.$activeJobs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &observers)
    }

    func stop() {
        observers.removeAll()
    }

    private func publish() {
        let file = manager.currentStatusFile()
        status = file
        onStatusChange?(file)
    }

    func submit(_ job: PrintJobFile) throws {
        // nil printerID ⇒ pick the sole ready printer, matching the IPC contract.
        let printerID = job.printerID
            ?? manager.printers.first(where: { $0.status == .ready })?.id
            ?? manager.printers.first?.id
            ?? ""
        manager.submit(
            jobs: job.labels.map { [UInt8]($0) },
            title: job.title,
            templateName: job.templateName,
            printerID: printerID,
            estLabelMs: job.estLabelMs
        )
    }

    func requestCassetteRefresh(printerID: String?) {
        guard let printerID, !printerID.isEmpty else { return }
        manager.refreshCassette(for: printerID, force: true)
    }
}
