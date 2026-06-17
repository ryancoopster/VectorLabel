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
    }

    public func requestCassetteRefresh(printerID: String?) {
        // No-op for now: the Engine owns the device and re-reads cassettes on its
        // own schedule. A control message to ask for an on-demand re-read will be
        // added when the Engine grows a control channel.
        // TODO: control-message to Engine to force a cassette re-detect.
    }
}
