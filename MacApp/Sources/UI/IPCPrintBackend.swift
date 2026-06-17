import Foundation
import VectorLabelCore

/// Core-only `PrintBackend` that talks to a separate Engine process through the
/// file-based IPC queue:
///   • reads printer/cassette status from the Engine's published `printers.json`
///   • watches the status directory and re-reads when `printers.json` changes
///   • submits jobs by writing them into the print queue
///
/// This implementation links NO libusb / EngineKit — it is the transport used
/// when the UI runs as its own front-end process.
@MainActor
public final class IPCPrintBackend: PrintBackend {

    private let queue: PrintQueue
    private var watcher: FolderWatcher?

    public private(set) var status: PrinterStatusFile?
    public var onStatusChange: ((PrinterStatusFile) -> Void)?

    /// The id of the most recently submitted job, so a UI that doesn't capture the
    /// id `submit` returns can still address it (e.g. for a Cancel button).
    public private(set) var lastSubmittedJobID: String?

    /// The in-flight jobs from the Engine's latest published status (printing or
    /// queued), so a front-end can render progress + a Cancel control without
    /// owning the USB device. Empty when no status / no active jobs.
    public var activeJobs: [ActiveJobStatus] { status?.activeJobs ?? [] }

    public init(queue: PrintQueue = PrintQueue()) {
        self.queue = queue
    }

    public func start() {
        // Seed the current status synchronously so a window opened before the
        // first FSEvent still shows whatever the Engine last published.
        if let s = queue.readStatus() {
            status = s
            onStatusChange?(s)
        }
        // Watch the status directory; printers.json is published atomically
        // (temp → rename), so we only ever read a complete file.
        queue.ensureDirs()
        let fw = FolderWatcher(root: queue.statusDir, suffix: ".json", latency: 0.2) { [weak self] url in
            guard url.lastPathComponent == "printers.json" else { return }
            Task { @MainActor in self?.reloadStatus() }
        }
        fw.start()
        watcher = fw
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
    }

    private func reloadStatus() {
        guard let s = queue.readStatus() else { return }
        status = s
        onStatusChange?(s)
    }

    public func submit(_ job: PrintJobFile) throws {
        try queue.write(job)
        lastSubmittedJobID = job.id
    }

    /// Request the Engine cancel an in-flight job (by its PrintJobFile id) via the
    /// IPC control channel. Best-effort: the Engine acts on the request when it
    /// reads the control file. Defaults to the last submitted job's id.
    public func cancel(jobId: String? = nil) {
        guard let id = jobId ?? lastSubmittedJobID, !id.isEmpty else { return }
        try? queue.writeControl(ControlRequest(action: .cancel, jobId: id))
    }

    public func requestCassetteRefresh(printerID: String?) {
        // No-op for now: the Engine owns the device and re-reads cassettes on its
        // own schedule. A control message to ask for an on-demand re-read will be
        // added when the Engine grows a control channel.
        // TODO: control-message to Engine to force a cassette re-detect.
    }
}
