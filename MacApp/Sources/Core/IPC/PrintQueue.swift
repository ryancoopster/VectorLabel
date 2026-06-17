import Foundation

/// File-based print queue shared between the front-end apps (submitters) and the
/// Engine (consumer). Reuses the FSEvents pattern the export flow already relies
/// on. Layout under `root` (default: ~/Library/Application Support/VectorLabel[ Beta]/ipc):
///
///   queue/       <id>.json      — ready jobs (atomic temp→rename publish)
///   processing/  <id>.json      — claimed by the Engine (atomic move = the lock)
///   done/        <id>.json      — finished
///   failed/      <id>.json      — errored / undecodable
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
    public var statusDir: URL     { root.appendingPathComponent("status", isDirectory: true) }
    public var statusFile: URL    { statusDir.appendingPathComponent("printers.json") }

    public func ensureDirs() {
        let fm = FileManager.default
        for d in [queueDir, processingDir, doneDir, failedDir, statusDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    // MARK: – Submitter side

    /// Write a job into the queue atomically (temp file → rename), so the watcher
    /// — which only matches `.json` — never sees a partially written file.
    @discardableResult
    public func write(_ job: PrintJobFile) throws -> URL {
        ensureDirs()
        let data = try JSONEncoder().encode(job)
        let finalURL = queueDir.appendingPathComponent("\(job.id).json")
        let tmpURL = queueDir.appendingPathComponent("\(job.id).json.tmp")
        try data.write(to: tmpURL, options: .atomic)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
        return finalURL
    }

    // MARK: – Engine side

    /// All ready job files currently in the queue (used to drain a backlog at
    /// Engine startup, before the watcher takes over).
    public func pendingJobURLs() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: queueDir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

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

    // MARK: – Status (Engine publishes, front-ends read)

    public func publishStatus(_ status: PrinterStatusFile) throws {
        ensureDirs()
        let data = try JSONEncoder().encode(status)
        let tmp = statusFile.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: statusFile)
        try FileManager.default.moveItem(at: tmp, to: statusFile)
    }

    public func readStatus() -> PrinterStatusFile? {
        guard let data = try? Data(contentsOf: statusFile) else { return nil }
        return try? JSONDecoder().decode(PrinterStatusFile.self, from: data)
    }
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
