import Foundation

// ── Folder structure ──────────────────────────────────────────────────────────
//
//  ~/Documents/VectorLabel/
//    Templates/
//    Exports/
//      <VectorworksFileName>/          ← one folder per VW project file
//        <VWFileName>_export_YYYYMMDD_HHMMSS.csv
//        <VWFileName>_export_YYYYMMDD_HHMMSS.csv
//        ...  (max 15, oldest pruned by datecode in filename)
//
// ExportWatcher watches the Exports/ root with FSEvents in recursive mode,
// so any new CSV dropped into any project subfolder is picked up immediately.
// Pruning uses the _export_YYYYMMDD_HHMMSS datecode in the filename —
// NOT file-system metadata — so it is cloud-sync and copy safe.

// ── ExportWatcher ─────────────────────────────────────────────────────────────

final class ExportWatcher {

    /// Root of the exports tree:  ~/Documents/VectorLabel/Exports/
    let exportsRootURL: URL

    /// Called on the main queue whenever a new CSV is found and parsed.
    var onNewExport: ((URL, [WireRecord]) -> Void)?

    private var eventStream: FSEventStreamRef?

    /// Track which files we have already processed so we don't fire twice.
    private var processedPaths = Set<String>()

    init(exportsRootURL: URL) {
        self.exportsRootURL = exportsRootURL
    }

    // MARK: - Start / Stop

    func start() {
        // Create the Exports root if it doesn't exist yet
        try? FileManager.default.createDirectory(
            at: exportsRootURL,
            withIntermediateDirectories: true
        )

        let paths = [exportsRootURL.path] as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        // kFSEventStreamCreateFlagFileEvents  — fire on individual file changes
        // kFSEventStreamCreateFlagUseCFTypes  — use CFString paths
        // kFSEventStreamCreateFlagNoDefer     — deliver events promptly
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info = info else { return }
                let watcher = Unmanaged<ExportWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self)
                let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

                for i in 0 ..< numEvents {
                    guard let path = paths[i] as? String else { continue }

                    // Only care about .csv files being created / modified
                    guard path.lowercased().hasSuffix(".csv") else { continue }

                    let flag = flags[i]
                    let created  = flag & UInt32(kFSEventStreamEventFlagItemCreated)  != 0
                    let modified = flag & UInt32(kFSEventStreamEventFlagItemModified) != 0
                    let renamed  = flag & UInt32(kFSEventStreamEventFlagItemRenamed)  != 0
                    guard created || modified || renamed else { continue }

                    watcher.handleNewFile(at: URL(fileURLWithPath: path))
                }
            },
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,    // latency in seconds — coalesce rapid bursts
            flags
        )

        guard let stream = stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream

        // Note: we intentionally do NOT scan existing files on launch.
        // The print window only opens when Vectorworks exports a new CSV while the app is running.
    }

    func stop() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - File handling

    /// Called when FSEvents reports a new/modified CSV anywhere under Exports/
    private func handleNewFile(at fileURL: URL) {
        let path = fileURL.path

        // Skip if we already processed this file in this session
        guard !processedPaths.contains(path) else { return }

        // Verify the filename matches our export pattern
        guard ExportFilenameParser.isVectorLabelExport(fileURL.lastPathComponent) else { return }

        // Verify the file is inside a project subfolder (depth = Exports/<project>/<file>)
        // Use standardized paths to avoid trailing-slash mismatches
        let parent = fileURL.deletingLastPathComponent().standardized
        let root   = exportsRootURL.standardized
        // File must be exactly one level below root (project subfolder), not at root itself
        guard parent != root else { return }

        // Mark as processed immediately. FSEvents commonly fires created + modified
        // for the same file within the coalescing window; without claiming the path
        // here (rather than 0.5s later in processFile) both events would schedule a
        // processFile and the export would be handled — and the window opened — twice.
        processedPaths.insert(path)

        print("[ExportWatcher] New export detected: \(fileURL.lastPathComponent)")

        // Delay to ensure file is fully written
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.processFile(at: fileURL)
        }
    }

    private func processFile(at fileURL: URL) {
        // If the file isn't readable/parseable yet (e.g. still being written or
        // cloud-syncing), release the claim so a later FSEvents change can retry.
        guard let records = WireExportParser.parse(fileURL: fileURL), !records.isEmpty else {
            processedPaths.remove(fileURL.path)
            return
        }

        processedPaths.insert(fileURL.path)

        // Prune the project folder this file lives in
        let projectFolder = fileURL.deletingLastPathComponent()
        ExportPruner.prune(projectFolder: projectFolder, keep: ExportSettings.maxExportsPerProject)

        DispatchQueue.main.async { [weak self] in
            self?.onNewExport?(fileURL, records)
        }
    }

    /// Scan the Exports/ tree on launch for files created AFTER the last launch.
    /// Uses the datecode embedded in the filename (not filesystem mtime) for comparison.
    /// Files that already existed when the app was last running are ignored.
    private func scanExistingFiles() {
        // Record this launch time so next launch knows what's new
        let lastLaunchKey = "lastLaunchDatecode"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let nowDatecode = formatter.string(from: Date())
        let lastDatecode = UserDefaults.standard.string(forKey: lastLaunchKey) ?? ""
        UserDefaults.standard.set(nowDatecode, forKey: lastLaunchKey)

        // If there's no previous launch recorded, this is a fresh install —
        // don't auto-open anything on first launch.
        guard !lastDatecode.isEmpty else { return }

        guard let enumerator = FileManager.default.enumerator(
            at: exportsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var csvURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "csv" else { continue }
            guard ExportFilenameParser.isVectorLabelExport(fileURL.lastPathComponent) else { continue }
            let parent = fileURL.deletingLastPathComponent()
            guard parent.path != exportsRootURL.path else { continue }
            // Only pick up files newer than the last launch
            if let dc = ExportFilenameParser.datecode(from: fileURL.lastPathComponent), dc > lastDatecode {
                csvURLs.append(fileURL)
            }
        }

        guard !csvURLs.isEmpty else { return }

        // Sort oldest → newest, fire the most recent per project
        let sorted = csvURLs.sorted {
            let a = ExportFilenameParser.datecode(from: $0.lastPathComponent) ?? ""
            let b = ExportFilenameParser.datecode(from: $1.lastPathComponent) ?? ""
            return a < b
        }
        var seenProjects = Set<String>()
        for fileURL in sorted.reversed() {
            let projectName = fileURL.deletingLastPathComponent().lastPathComponent
            guard !seenProjects.contains(projectName) else { continue }
            seenProjects.insert(projectName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.processFile(at: fileURL)
            }
        }
    }
}

// ── Export filename parser ────────────────────────────────────────────────────

/// Helpers for working with VectorLabel export filenames.
///
/// Expected format:  <VWFileName>_export_YYYYMMDD_HHMMSS.csv
/// Example:          ESM_Kodak_Hall_Master_export_20260614_172508.csv
///
/// The datecode is extracted from the filename itself — never from file-system
/// metadata — so pruning is correct across copies, cloud sync, and Time Machine.

enum ExportFilenameParser {

    private static let pattern = try! NSRegularExpression(
        pattern: #"_export_(\d{8}_\d{6})\.csv$"#,
        options: .caseInsensitive
    )

    /// Returns true if the filename matches the VectorLabel export pattern.
    static func isVectorLabelExport(_ filename: String) -> Bool {
        let range = NSRange(filename.startIndex..., in: filename)
        return pattern.firstMatch(in: filename, range: range) != nil
    }

    /// Extracts the YYYYMMDD_HHMMSS datecode from the filename.
    /// Returns nil if the filename doesn't match the expected pattern.
    static func datecode(from filename: String) -> String? {
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = pattern.firstMatch(in: filename, range: range),
              let dcRange = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[dcRange])
    }
}

// ── Export pruner ─────────────────────────────────────────────────────────────

/// Deletes oldest exports from a project folder when the count exceeds `keep`.
///
/// Sorting is by the _export_YYYYMMDD_HHMMSS datecode in the filename.
/// Lexicographic order == chronological order because the format is zero-padded
/// and fixed-width. Files that don't match the pattern are never touched.

enum ExportPruner {

    static func prune(projectFolder: URL, keep: Int) {
        guard keep > 0 else { return }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: projectFolder,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        // Only consider files that match our naming pattern
        let exportFiles: [(datecode: String, url: URL)] = contents.compactMap { url in
            guard url.pathExtension.lowercased() == "csv",
                  let dc = ExportFilenameParser.datecode(from: url.lastPathComponent)
            else { return nil }
            return (dc, url)
        }

        // Sort oldest → newest by datecode string (lexicographic == chronological)
        let sorted = exportFiles.sorted { $0.datecode < $1.datecode }

        // Delete everything before the last `keep` entries
        let toDelete = sorted.dropLast(keep)
        for entry in toDelete {
            try? fm.removeItem(at: entry.url)
        }
    }
}

// ── Settings ──────────────────────────────────────────────────────────────────

enum ExportSettings {
    /// Maximum number of export CSVs to retain per project folder.
    /// Oldest files (by embedded datecode) are deleted when this is exceeded.
    /// Configurable in Preferences → Export → Exports to keep per project.
    static var maxExportsPerProject: Int = 15
}

// ── Wire record ───────────────────────────────────────────────────────────────

struct WireRecord {
    let side: String          // "Source" or "Destination"
    let wireID: String
    let fields: [String: String]

    subscript(key: String) -> String { fields[key] ?? "" }
}

// ── CSV parser ────────────────────────────────────────────────────────────────

enum WireExportParser {

    /// Parse a VectorLabel CSV export into WireRecord pairs.
    /// Returns nil if the file can't be read or is empty.
    static func parse(fileURL: URL) -> [WireRecord]? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        let headers = parseCSVLine(lines.removeFirst())
        var records: [WireRecord] = []

        for line in lines {
            let values = parseCSVLine(line)
            guard values.count == headers.count else { continue }
            var row: [String: String] = [:]
            for (i, header) in headers.enumerated() { row[header] = values[i] }

            let wireID   = row["Number"] ?? UUID().uuidString
            let side     = row["_Side"]  ?? "Source"
            records.append(WireRecord(side: side, wireID: wireID, fields: row))
        }

        return records.isEmpty ? nil : records
    }

    /// RFC-4180 compliant CSV line parser.
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" {
                        current.append("\""); i += 1   // escaped quote
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":  fields.append(current); current = ""
                default:   current.append(c)
                }
            }
            i += 1
        }
        fields.append(current)
        return fields
    }
}
