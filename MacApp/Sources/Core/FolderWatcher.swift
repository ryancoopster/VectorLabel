import Foundation
import CoreServices

/// A recursive FSEvents folder watcher. Fires `onFile` (on a private background queue)
/// for each created / modified / renamed file under `root` whose path ends with
/// `suffix`. Generalized from ExportWatcher so the export watcher and the
/// Engine's print-queue watcher share one implementation.
///
/// Callbacks run OFF the main thread (so claim + decode of a big job file doesn't
/// block the UI) — consumers that touch UI/@MainActor state must hop themselves. The
/// stream sets `IgnoreSelf`, so a watcher's OWNING process doesn't get re-notified of
/// its own writes (this is what keeps the Engine's requeue from hot-looping the queue
/// watcher); cross-process writes (a front-end submitting a job) still fire normally.
public final class FolderWatcher {

    public let root: URL
    private let suffix: String
    private let latency: TimeInterval
    private let onFile: (URL) -> Void
    private var stream: FSEventStreamRef?
    private let deliveryQueue = DispatchQueue(label: "com.sai.vectorlabel.folderwatcher", qos: .utility)

    public init(root: URL, suffix: String, latency: TimeInterval = 0.2,
                onFile: @escaping (URL) -> Void) {
        self.root = root
        self.suffix = suffix.lowercased()
        self.latency = latency
        self.onFile = onFile
    }

    public func start() {
        // Create the watched root if it doesn't exist yet.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let paths = [root.path] as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // FileEvents: per-file changes · UseCFTypes: CFString paths · NoDefer: prompt
        // delivery · IgnoreSelf: don't re-notify us of our OWN writes (stops the Engine's
        // requeue move from re-firing the queue watcher → claim → requeue hot-loop).
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagIgnoreSelf
        )
        let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info = info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self)
                let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
                for i in 0 ..< numEvents {
                    guard let path = paths[i] as? String else { continue }
                    guard path.lowercased().hasSuffix(watcher.suffix) else { continue }
                    let flag = flags[i]
                    let created  = flag & UInt32(kFSEventStreamEventFlagItemCreated)  != 0
                    let modified = flag & UInt32(kFSEventStreamEventFlagItemModified) != 0
                    let renamed  = flag & UInt32(kFSEventStreamEventFlagItemRenamed)  != 0
                    guard created || modified || renamed else { continue }
                    watcher.onFile(URL(fileURLWithPath: path))
                }
            },
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )
        guard let s = s else { return }
        FSEventStreamSetDispatchQueue(s, deliveryQueue)   // off-main: claim+decode mustn't block the UI
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
