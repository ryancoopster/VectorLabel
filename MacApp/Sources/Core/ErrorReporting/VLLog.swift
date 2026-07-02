import Darwin
import Foundation

/// Tee of stderr (where NSLog writes) into ONE shared suite log file, so problem reports
/// can attach the recent output of all four apps as a single timeline. Console/Xcode
/// output stays intact: fd 2 is redirected into a pipe whose drain thread writes every
/// chunk to the saved original stderr immediately (unprefixed), and appends complete
/// lines — each tagged "[<appName>] " — to ~/Library/Logs/VectorLabel/VectorLabel.log.
///
/// The four apps are separate processes that often run simultaneously, so every append
/// is a short-lived open(O_APPEND) → write → close of whole lines only: O_APPEND writes
/// are kernel-serialized per syscall (no torn lines), and reopening per chunk means a
/// rotation by another app is picked up naturally.
public enum VLLog {

    /// The one log file every suite app appends to.
    private static let sharedLogFileURL = logDirectory()
        .appendingPathComponent("VectorLabel.log")
    /// Sidecar flock(2) file that serializes rotation across the four processes.
    private static let lockFileURL = logDirectory().appendingPathComponent(".log.lock")

    /// Rotate when the log exceeds this (checked at each open).
    private static let maxLogSize = 1_572_864   // 1.5 MB
    /// A line still missing its newline after this many bytes is flushed anyway.
    private static let maxPartialLine = 8192

    private static var installed = false

    /// Path of the shared log file (for the report body's caption).
    static var currentLogPath: String { sharedLogFileURL.path }

    /// Install the stderr tee. Never crashes — any setup failure silently skips (the app
    /// just runs without a log file). Call once, first thing at launch.
    public static func install(appName: String) {
        guard !installed else { return }
        installed = true

        let dir = logDirectory()
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return }

        let savedStderr = dup(STDERR_FILENO)
        guard savedStderr >= 0 else { return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { close(savedStderr); return }
        let readFD = fds[0], writeFD = fds[1]
        guard dup2(writeFD, STDERR_FILENO) >= 0 else {
            close(savedStderr); close(readFD); close(writeFD)
            return
        }
        close(writeFD)

        // Drain thread: copy everything arriving on the old fd 2 to the real stderr
        // as-is, and buffer it to LINE boundaries for the shared log (interleaved
        // half-lines from four apps would be unreadable). Lives for the whole process;
        // exits if the pipe ever closes.
        let linePrefix = Array("[\(appName)] ".utf8)
        Thread.detachNewThread {
            let bufSize = 8192
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            var pending = [UInt8]()   // bytes still waiting for their newline
            while true {
                let n = read(readFD, buf, bufSize)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    break
                }
                writeFully(savedStderr, buf, n)
                pending.append(contentsOf: UnsafeBufferPointer(start: buf, count: n))
                // Complete lines go out now; the trailing partial waits for its newline
                // unless it has grown past maxPartialLine (then it's flushed as a line).
                if let lastNewline = pending.lastIndex(of: 0x0A) {
                    appendToSharedLog(prefixLines(pending[...lastNewline], with: linePrefix))
                    pending.removeSubrange(...lastNewline)
                }
                if pending.count > maxPartialLine {
                    var flushed = prefixLines(pending[...], with: linePrefix)
                    flushed.append(0x0A)
                    appendToSharedLog(flushed)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty {   // pipe closed mid-line: don't lose the last words
                var flushed = prefixLines(pending[...], with: linePrefix)
                flushed.append(0x0A)
                appendToSharedLog(flushed)
            }
            close(readFD)
        }

        NSLog("[VLLog] %@ %@ — logging to %@", appName, BuildInfo.display, sharedLogFileURL.path)
    }

    /// Last `maxBytes` of the shared suite log ("" if none).
    public static func recentTail(maxBytes: Int) -> String {
        guard maxBytes > 0,
              let handle = try? FileHandle(forReadingFrom: sharedLogFileURL) else { return "" }
        defer { handle.closeFile() }
        let end = handle.seekToEndOfFile()
        if end > UInt64(maxBytes) { handle.seek(toFileOffset: end - UInt64(maxBytes)) }
        else { handle.seek(toFileOffset: 0) }
        let data = handle.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    static func logDirectory() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs/VectorLabel", isDirectory: true)
    }

    // MARK: Shared-file appends (drain thread)

    /// Tag every line in `bytes` (already ending at line boundaries, except a forced
    /// partial flush) with the "[<appName>] " prefix. NSLog lines carry their own
    /// timestamps, so the tag is all that's added.
    private static func prefixLines(_ bytes: ArraySlice<UInt8>, with prefix: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + prefix.count * 4)
        var atLineStart = true
        for byte in bytes {
            if atLineStart { out.append(contentsOf: prefix); atLineStart = false }
            out.append(byte)
            if byte == 0x0A { atLineStart = true }
        }
        return out
    }

    /// One chunk of complete lines → one open(O_APPEND|O_CREAT) → write → close.
    /// Never crashes — an open/write failure just drops the chunk from the log.
    private static func appendToSharedLog(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        rotateIfNeeded()
        let fd = open(sharedLogFileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        bytes.withUnsafeBufferPointer { p in
            if let base = p.baseAddress { writeFully(fd, base, p.count) }
        }
        close(fd)
    }

    /// One rotation generation: a log over 1.5 MB becomes VectorLabel.log.old before the
    /// next append. Four processes may hit the threshold at once, so the rename is
    /// serialized by flock(2) on a sidecar lock file, with the size re-checked under the
    /// lock — only the first holder rotates, the rest see a small file and skip. Any
    /// failure (lock, stat, rename) silently skips; logging must never take the app down.
    private static func rotateIfNeeded() {
        let path = sharedLogFileURL.path
        guard fileSize(path) > maxLogSize else { return }
        let lockFD = open(lockFileURL.path, O_WRONLY | O_CREAT, 0o644)
        guard lockFD >= 0 else { return }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { return }
        defer { flock(lockFD, LOCK_UN) }
        guard fileSize(path) > maxLogSize else { return }   // someone else just rotated
        let old = path + ".old"
        unlink(old)
        rename(path, old)
    }

    private static func fileSize(_ path: String) -> Int {
        var st = stat()
        guard stat(path, &st) == 0 else { return 0 }
        return Int(st.st_size)
    }

    /// write(2) the whole chunk, resuming after partial writes / EINTR.
    private static func writeFully(_ fd: Int32, _ buf: UnsafePointer<UInt8>, _ count: Int) {
        var offset = 0
        while offset < count {
            let n = write(fd, buf + offset, count - offset)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return
            }
            offset += n
        }
    }
}
