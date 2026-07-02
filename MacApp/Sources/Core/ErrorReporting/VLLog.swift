import Darwin
import Foundation

/// Tee of stderr (where NSLog writes) into a per-app log file, so problem reports can
/// attach the app's recent output. Console/Xcode output stays intact: fd 2 is redirected
/// into a pipe whose drain thread writes every chunk BOTH to the saved original stderr
/// and to ~/Library/Logs/VectorLabel/<appName>.log.
public enum VLLog {

    /// Set once by install(); read by recentTail() and the report builder.
    private static var logFileURL: URL?
    private static var installed = false

    /// Path of the current log file (nil when install() wasn't called or failed).
    static var currentLogPath: String? { logFileURL?.path }

    /// Install the stderr tee. Never crashes — any setup failure silently skips (the app
    /// just runs without a log file). Call once, first thing at launch.
    public static func install(appName: String) {
        guard !installed else { return }
        installed = true

        let dir = logDirectory()
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return }
        let url = dir.appendingPathComponent("\(appName).log")
        rotateIfNeeded(url)

        let logFD = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard logFD >= 0 else { return }
        let savedStderr = dup(STDERR_FILENO)
        guard savedStderr >= 0 else { close(logFD); return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { close(logFD); close(savedStderr); return }
        let readFD = fds[0], writeFD = fds[1]
        guard dup2(writeFD, STDERR_FILENO) >= 0 else {
            close(logFD); close(savedStderr); close(readFD); close(writeFD)
            return
        }
        close(writeFD)
        logFileURL = url

        // Drain thread: copy everything arriving on the old fd 2 to the real stderr
        // AND the log file. Lives for the whole process; exits if the pipe ever closes.
        Thread.detachNewThread {
            let bufSize = 8192
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while true {
                let n = read(readFD, buf, bufSize)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    break
                }
                writeFully(savedStderr, buf, n)
                writeFully(logFD, buf, n)
            }
            close(readFD)
        }

        NSLog("[VLLog] %@ %@ — logging to %@", appName, BuildInfo.display, url.path)
    }

    /// Last `maxBytes` of the current log file ("" if none).
    public static func recentTail(maxBytes: Int) -> String {
        guard maxBytes > 0, let url = logFileURL,
              let handle = try? FileHandle(forReadingFrom: url) else { return "" }
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

    /// One rotation generation: a log over 512 KB at install becomes <appName>.log.old.
    private static func rotateIfNeeded(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 512 * 1024 else { return }
        let old = URL(fileURLWithPath: url.path + ".old")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    /// write(2) the whole chunk, resuming after partial writes / EINTR.
    private static func writeFully(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ count: Int) {
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
