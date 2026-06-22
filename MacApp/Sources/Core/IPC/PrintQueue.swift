import Foundation

/// A control message a front-end writes for the Engine (which owns the device):
/// `cancel` an in-flight job, or `detectCassette` to force an on-demand cassette
/// re-read. The Engine watches `control/`, acts on each request, and deletes the file.
public struct ControlRequest: Codable {
    public enum Action: String, Codable {
        case cancel
        case detectCassette
    }
    public var schema: Int
    public var requestId: String   // unique; also the control filename stem
    public var action: Action
    public var jobId: String       // for .cancel — the PrintJobFile id to act on
    public var printerID: String   // for .detectCassette — the printer to re-read

    public init(requestId: String = UUID().uuidString, action: Action,
                jobId: String = "", printerID: String = "") {
        self.schema = 1
        self.requestId = requestId
        self.action = action
        self.jobId = jobId
        self.printerID = printerID
    }

    enum CodingKeys: String, CodingKey { case schema, requestId, action, jobId, printerID }
    // Tolerant decode so a control file written before `printerID` existed still decodes.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schema    = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        requestId = (try? c.decode(String.self, forKey: .requestId)) ?? UUID().uuidString
        action    = try c.decode(Action.self, forKey: .action)
        jobId     = (try? c.decode(String.self, forKey: .jobId)) ?? ""
        printerID = (try? c.decode(String.self, forKey: .printerID)) ?? ""
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
    /// Reprint requests targeted at the Custom Designer. Kept separate from `reprintDir`
    /// (which Auto Print watches) so the two front-ends don't race over one channel and
    /// mis-handle each other's requests.
    public var reprintCustomDir: URL { root.appendingPathComponent("reprint-custom", isDirectory: true) }
    public var cancelledDir: URL  { root.appendingPathComponent("cancelled", isDirectory: true) }

    public func ensureDirs() {
        let fm = FileManager.default
        for d in [queueDir, processingDir, doneDir, failedDir, controlDir, statusDir, reprintDir, reprintCustomDir, cancelledDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    // MARK: – Shared file primitives (atomic publish / list / decode)

    /// Encode + publish atomically. `Data.write(options:.atomic)` writes to a hidden
    /// temp file in the same directory and then renames it onto `<id>.json` in one
    /// atomic step — so a watcher (filtering on `.json`) never sees a partial file and
    /// a reader never sees the destination momentarily missing. (Replaces an earlier
    /// write-tmp → remove-final → move-tmp sequence whose remove+move opened a window
    /// where `<id>.json` did not exist, intermittently feeding readers ENOENT.)
    @discardableResult
    private func atomicWrite<T: Encodable>(_ value: T, to dir: URL, id: String) throws -> URL {
        ensureDirs()
        let data = try JSONEncoder().encode(value)
        let finalURL = dir.appendingPathComponent("\(id).json")
        try data.write(to: finalURL, options: .atomic)
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
            // Undecodable: route to failed/. Remove any pre-existing failed/<id>.json
            // first (moveItem won't overwrite), and if the move still fails, delete the
            // processing file outright — otherwise recoverProcessingJobs() would move it
            // back to queue/ on every launch and re-fail it forever (a wedge loop).
            let failedTarget = failedDir.appendingPathComponent(dest.lastPathComponent)
            try? FileManager.default.removeItem(at: failedTarget)
            do { try FileManager.default.moveItem(at: dest, to: failedTarget) }
            catch { try? FileManager.default.removeItem(at: dest) }
            return nil
        }
        return (job, dest)
    }

    /// Atomically move `src` onto `dst` in a single step via `rename(2)`, which
    /// overwrites the destination — eliminating the remove-then-move window where `dst`
    /// briefly doesn't exist (a crash there could strand the job, and on a collision the
    /// pre-remove destroys an existing target). Same-volume only, always true here (both
    /// live under the IPC root). Returns true on success.
    @discardableResult
    private func atomicMove(_ src: URL, onto dst: URL) -> Bool {
        rename(src.path, dst.path) == 0
    }

    /// Move a claimed (processing) job to done/ or failed/.
    public func complete(_ processingURL: URL, success: Bool) {
        let target = (success ? doneDir : failedDir).appendingPathComponent(processingURL.lastPathComponent)
        if atomicMove(processingURL, onto: target) { return }
        // Atomic replace failed (rare transient FS error). Don't leave a finalized job
        // sitting in processing/ — the next launch's recoverProcessingJobs() would
        // re-drain and REPRINT it. Log + remove so it reaches a terminal state.
        NSLog("[PrintQueue] complete(): atomic move of \(processingURL.lastPathComponent) → \(success ? "done/" : "failed/") failed (errno \(errno)). Removing to avoid a duplicate reprint.")
        try? FileManager.default.removeItem(at: processingURL)
    }

    /// Un-claim a processing job by moving it back to queue/, so it will be
    /// re-drained later. Used when a job can't be acted on *yet* (e.g. the USB
    /// scan hasn't populated the printer list) but should not be failed.
    /// Returns the new queue URL on success.
    @discardableResult
    public func requeue(_ processingURL: URL) -> URL? {
        let dest = queueDir.appendingPathComponent(processingURL.lastPathComponent)
        return atomicMove(processingURL, onto: dest) ? dest : nil
    }

    /// Cancel a still-QUEUED (unclaimed) job by IPC id: atomically move `queue/<id>.json`
    /// out to done/ so the watcher/drain can never claim + print it, and return the job
    /// (so the caller can record the cancellation). Returns nil if there's no such
    /// queued file — i.e. it was already claimed (handle the in-flight path instead) or
    /// the id is unknown/unsafe. The atomic move is the race gate: if the watcher claims
    /// it first, the move fails and we report "not queued".
    @discardableResult
    public func cancelQueuedJob(id: String) -> PrintJobFile? {
        guard PrintJobFile.isSafeID(id) else { return nil }
        let src = queueDir.appendingPathComponent("\(id).json")
        let dest = doneDir.appendingPathComponent("\(id).json")
        guard atomicMove(src, onto: dest) else { return nil }
        return decodeJSON(dest)
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
            _ = atomicMove(url, onto: dest)
            // A job interrupted AFTER some labels physically printed is re-drained in
            // full (no per-label progress is persisted), so recovery can reprint
            // already-printed labels. Logged so the duplicate isn't silent; resuming
            // from a persisted offset is a follow-up (needs hardware to validate pacing).
            NSLog("[PrintQueue] recovered orphaned job \(url.lastPathComponent) → re-queued (may reprint already-printed labels)")
        }
    }

    // MARK: – Reprint (read a finished job's rendered labels back)

    /// Bound the done/ archive: keep the most-recent `keep` finished job files (by
    /// modification time) and delete older ones. Done files are retained so a job can be
    /// reopened/re-submitted, but only the newest `RecentPrintsStore.maxHistory` are ever
    /// reachable from the menu — so keeping a comfortable margin above that reclaims
    /// orphaned files (including the larger custom-design jobs, which now embed the full
    /// .vlcus design) while never dropping the backing file of a reachable recent. Safe
    /// to call on Engine startup. No-op when at/under `keep`.
    public func pruneDoneJobs(keep: Int) {
        guard keep >= 0 else { return }
        let fm = FileManager.default
        let key: URLResourceKey = .contentModificationDateKey
        let items = (try? fm.contentsOfDirectory(at: doneDir, includingPropertiesForKeys: [key])) ?? []
        let jsons = items.filter { $0.pathExtension == "json" }
        guard jsons.count > keep else { return }
        let mtime: (URL) -> Date = {
            (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
        }
        let sorted = jsons.sorted { mtime($0) > mtime($1) }   // newest first
        for url in sorted.dropFirst(keep) { try? fm.removeItem(at: url) }
    }

    /// Read a finished job's `PrintJobFile` from done/ (by its id == filename
    /// stem). Returns nil if the file is missing or undecodable. Used by reprint
    /// to re-submit the same rendered VGL labels as a fresh job.
    public func readDoneJob(id: String) -> PrintJobFile? {
        // Defensive: `id` flows from a stored RecentPrint and is used as a path
        // component, so never let it escape done/. (Decode-time validation already
        // rejects unsafe ids, but a reprint may read an id persisted before that guard.)
        guard PrintJobFile.isSafeID(id) else { return nil }
        return decodeJSON(doneDir.appendingPathComponent("\(id).json"))
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
    /// watcher reads, acts, and deletes it. Routed by `sourceApp` to the matching
    /// channel so each front-end only sees its own requests.
    @discardableResult
    public func writeReprintRequest(_ recent: RecentPrint) throws -> URL {
        let dir = recent.sourceApp == "customdesigner" ? reprintCustomDir : reprintDir
        return try atomicWrite(recent, to: dir, id: recent.id.uuidString)
    }

    public func pendingReprintURLs() -> [URL] { pendingJSON(in: reprintDir) }

    /// Pending reprint requests targeted at the Custom Designer.
    public func pendingCustomReprintURLs() -> [URL] { pendingJSON(in: reprintCustomDir) }

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
