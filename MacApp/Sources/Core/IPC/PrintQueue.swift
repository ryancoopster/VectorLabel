import Foundation

/// A control message a front-end writes for the Engine (which owns the device):
/// today only `cancel` of an in-flight job. The Engine watches `control/`, acts
/// on each request, and deletes the file.
public struct ControlRequest: Codable {
    public enum Action: String, Codable {
        case cancel
    }
    public var schema: Int
    public var requestId: String   // unique; also the control filename stem
    public var action: Action
    public var jobId: String       // the PrintJobFile id to act on

    public init(requestId: String = UUID().uuidString, action: Action, jobId: String) {
        self.schema = 1
        self.requestId = requestId
        self.action = action
        self.jobId = jobId
    }
}

/// File-based print queue shared between the front-end apps (submitters) and the
/// Engine (consumer). Reuses the FSEvents pattern the export flow already relies
/// on. Layout under `root` (default: ~/Library/Application Support/VectorLabel[ Beta]/ipc):
///
///   queue/       <id>.json      — ready jobs (atomic temp→rename publish)
///   processing/  <id>.json      — claimed by the Engine (atomic move = the lock)
///   done/        <id>.json      — finished
///   failed/      <id>.json      — errored / undecodable
///   control/     <reqid>.json   — front-end → Engine control requests (cancel)
///   status/      printers.json  — Engine-published printer+cassette status
///
/// `root` is injectable so tests can point at a temp directory.
public struct PrintQueue {

    public let root: URL
    public init(root: URL = AppEnvironment.ipcRoot) { self.root = root }

    public var queueDir: URL      { root.appendingPathComponent("queue", isDirectory: true) }
    public var processingDir: URL { root.appendingPathComponent("processing", isDirectory: true) }
    public var doneDir: URL       { root.appendingPathComponent("done", isDirectory: true) }
    public var failedDir: URL     { root.appendingPathComponent("failed", isDirectory: true) }
    public var controlDir: URL    { root.appendingPathComponent("control", isDirectory: true) }
    public var statusDir: URL     { root.appendingPathComponent("status", isDirectory: true) }
    public var statusFile: URL    { statusDir.appendingPathComponent("printers.json") }
    public var reprintDir: URL    { root.appendingPathComponent("reprint", isDirectory: true) }
    public var cancelledDir: URL  { root.appendingPathComponent("cancelled", isDirectory: true) }

    public func ensureDirs() {
        let fm = FileManager.default
        for d in [queueDir, processingDir, doneDir, failedDir, controlDir, statusDir, reprintDir, cancelledDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    // MARK: – Shared file primitives (atomic publish / list / decode)

    /// Encode + publish atomically (temp `.json.tmp` → rename `.json`) so a watcher
    /// filtering on `.json` never sees a partial file.
    @discardableResult
    private func atomicWrite<T: Encodable>(_ value: T, to dir: URL, id: String) throws -> URL {
        ensureDirs()
        let data = try JSONEncoder().encode(value)
        let finalURL = dir.appendingPathComponent("\(id).json")
        let tmpURL = dir.appendingPathComponent("\(id).json.tmp")
        try data.write(to: tmpURL, options: .atomic)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
        return finalURL
    }

    /// All `.json` files in `dir`, name-sorted (stable backlog-drain order).
    private func pendingJSON(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Decode a JSON file, or nil if missing/undecodable.
    private func decodeJSON<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: – Submitter side

    /// Write a job into the queue atomically (temp file → rename), so the watcher
    /// — which only matches `.json` — never sees a partially written file.
    @discardableResult
    public func write(_ job: PrintJobFile) throws -> URL {
        try atomicWrite(job, to: queueDir, id: job.id)
    }

    // MARK: – Engine side

    /// All ready job files currently in the queue (used to drain a backlog at
    /// Engine startup, before the watcher takes over).
    public func pendingJobURLs() -> [URL] { pendingJSON(in: queueDir) }

    /// Atomically claim a queued job by moving it to processing/ (the move IS the
    /// lock — if it fails the job is gone or already claimed) and decode it.
    /// Returns nil if it couldn't be claimed; routes an undecodable file to failed/.
    public func claim(_ url: URL) -> (job: PrintJobFile, processingURL: URL)? {
        ensureDirs()
        let dest = processingDir.appendingPathComponent(url.lastPathComponent)
        do {
            // The move IS the claim/lock: moveItem throws if another event already
            // claimed this job (dest exists) or the source vanished — so a duplicate
            // FSEvents fire never clobbers a job that's already being processed.
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            return nil
        }
        guard let data = try? Data(contentsOf: dest),
              let job = try? JSONDecoder().decode(PrintJobFile.self, from: data) else {
            try? FileManager.default.moveItem(at: dest, to: failedDir.appendingPathComponent(dest.lastPathComponent))
            return nil
        }
        return (job, dest)
    }

    /// Move a claimed (processing) job to done/ or failed/.
    public func complete(_ processingURL: URL, success: Bool) {
        let target = (success ? doneDir : failedDir).appendingPathComponent(processingURL.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: processingURL, to: target)
    }

    /// Un-claim a processing job by moving it back to queue/, so it will be
    /// re-drained later. Used when a job can't be acted on *yet* (e.g. the USB
    /// scan hasn't populated the printer list) but should not be failed.
    /// Returns the new queue URL on success.
    @discardableResult
    public func requeue(_ processingURL: URL) -> URL? {
        let dest = queueDir.appendingPathComponent(processingURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: processingURL, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Sweep processing/ on startup: any leftover `<id>.json` is the residue of a
    /// crash/quit mid-print, and would otherwise be stranded forever. Move each
    /// back to queue/ so the normal drain reprocesses it.
    public func recoverProcessingJobs() {
        ensureDirs()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: processingDir, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.pathExtension == "json" {
            let dest = queueDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: url, to: dest)
        }
    }

    // MARK: – Reprint (read a finished job's rendered labels back)

    /// Read a finished job's `PrintJobFile` from done/ (by its id == filename
    /// stem). Returns nil if the file is missing or undecodable. Used by reprint
    /// to re-submit the same rendered VGL labels as a fresh job.
    public func readDoneJob(id: String) -> PrintJobFile? {
        decodeJSON(doneDir.appendingPathComponent("\(id).json"))
    }

    /// Re-submit a finished job's already-rendered VGL labels as a fresh queue job
    /// (new id/date, same labels/printer/cut). Used by the "Reprint without editing"
    /// fallback when the original source is gone. Returns false if the done file is
    /// missing or the write failed.
    @discardableResult
    public func resubmitDoneJob(id: String) -> Bool {
        guard let original = readDoneJob(id: id) else { return false }
        let fresh = PrintJobFile(
            id: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            sourceApp: original.sourceApp,
            title: original.title,
            templateName: original.templateName,
            printerID: original.printerID,
            copies: original.copies,
            cutMode: original.cutMode,
            estLabelMs: original.estLabelMs,
            renderedLabels: original.renderedLabels,
            labels: original.labels,
            reprint: original.reprint
        )
        return (try? write(fresh)) != nil
    }

    // MARK: – Reprint channel (Engine → front-end: "re-open this job's window")

    /// Engine asks a front-end (Auto Print / Custom Designer) to RE-OPEN the source
    /// window in this job's print-time state. Written atomically; the front-end's
    /// watcher reads, acts, and deletes it.
    @discardableResult
    public func writeReprintRequest(_ recent: RecentPrint) throws -> URL {
        try atomicWrite(recent, to: reprintDir, id: recent.id.uuidString)
    }

    public func pendingReprintURLs() -> [URL] { pendingJSON(in: reprintDir) }

    public func readReprintRequest(_ url: URL) -> RecentPrint? { decodeJSON(url) }

    public func deleteReprint(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: – Cancelled channel (front-end → Engine: "record this as cancelled")

    /// A front-end records a pre-submit cancellation so it lands in the
    /// Engine-owned Recent Prints as cancelled and can be reopened/reprinted just
    /// like a printed job. Written atomically; the Engine reads, adds, deletes.
    @discardableResult
    public func writeCancelledRecent(_ recent: RecentPrint) throws -> URL {
        try atomicWrite(recent, to: cancelledDir, id: recent.id.uuidString)
    }

    public func pendingCancelledURLs() -> [URL] { pendingJSON(in: cancelledDir) }

    public func readCancelledRecent(_ url: URL) -> RecentPrint? { decodeJSON(url) }

    public func deleteCancelled(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: – Control channel (front-ends request, Engine acts)

    /// Write a control request atomically (temp → rename), so the Engine's watcher
    /// — which only matches `.json` — never sees a partial file.
    @discardableResult
    public func writeControl(_ request: ControlRequest) throws -> URL {
        try atomicWrite(request, to: controlDir, id: request.requestId)
    }

    /// All pending control request files (Engine-side backlog drain at startup).
    public func pendingControlURLs() -> [URL] { pendingJSON(in: controlDir) }

    /// Decode a control request file (Engine side). Returns nil if unreadable.
    public func readControl(_ url: URL) -> ControlRequest? { decodeJSON(url) }

    /// Delete a handled control request file (Engine side).
    public func deleteControl(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: – Status (Engine publishes, front-ends read)

    public func publishStatus(_ status: PrinterStatusFile) throws {
        try atomicWrite(status, to: statusDir, id: "printers")   // → status/printers.json
    }

    public func readStatus() -> PrinterStatusFile? { decodeJSON(statusFile) }
}

/// Engine-side watcher: fires `onJob` for each job dropped into the queue
/// (claiming it first), and drains any backlog present at start.
public final class PrintQueueWatcher {

    private let queue: PrintQueue
    private let onJob: (PrintJobFile, URL) -> Void
    private var watcher: FolderWatcher?

    public init(queue: PrintQueue = PrintQueue(), onJob: @escaping (PrintJobFile, URL) -> Void) {
        self.queue = queue
        self.onJob = onJob
    }

    public func start() {
        queue.ensureDirs()
        // Recover orphaned processing/ jobs (crash/quit mid-print) back to queue/
        // BEFORE wiring the watcher, so they're picked up by the backlog drain.
        queue.recoverProcessingJobs()
        let fw = FolderWatcher(root: queue.queueDir, suffix: ".json", latency: 0.2) { [weak self] url in
            guard let self, let claimed = self.queue.claim(url) else { return }
            self.onJob(claimed.job, claimed.processingURL)
        }
        fw.start()
        watcher = fw
        // Drain anything already waiting (e.g. jobs submitted before the Engine launched).
        drainBacklog()
    }

    /// Claim + dispatch every job currently sitting in queue/. Safe to call more
    /// than once (e.g. re-run once the printer list becomes non-empty) — claim()
    /// atomically moves each file, so a job already claimed is skipped.
    public func drainBacklog() {
        for url in queue.pendingJobURLs() {
            if let claimed = queue.claim(url) { onJob(claimed.job, claimed.processingURL) }
        }
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
    }
}
