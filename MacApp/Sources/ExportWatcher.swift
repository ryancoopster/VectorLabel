import Foundation

/// Watches the export folder (written to by the Vectorworks plugin) for new
/// CSV exports and parses them into WireRecord pairs (source + destination).
final class ExportWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    let folderURL: URL
    var onNewExport: (([WireRecord]) -> Void)?

    init(folderURL: URL) {
        self.folderURL = folderURL
    }

    func start() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        fileDescriptor = open(folderURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let queue = DispatchQueue(label: "com.sai.cabletron.exportwatcher")
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: queue)
        src.setEventHandler { [weak self] in
            self?.scanForNewFiles()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 { close(fd) }
        }
        src.resume()
        source = src

        // Catch anything already sitting in the folder on launch
        scanForNewFiles()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func scanForNewFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return }
        let csvFiles = files.filter { $0.pathExtension.lowercased() == "csv" }

        for file in csvFiles {
            if let records = WireExportParser.parse(fileURL: file) {
                onNewExport?(records)
            }
            // Move processed file aside so it isn't picked up again
            let processedURL = file.deletingPathExtension().appendingPathExtension("processed.csv")
            try? FileManager.default.removeItem(at: processedURL)
            try? FileManager.default.moveItem(at: file, to: processedURL)
        }
    }
}

/// Parses a Vectorworks ConnectCAD wire export into per-side WireRecords.
///
/// Expected CSV format: one row per wire, with a "WireID" column plus
/// arbitrary ConnectCAD field columns prefixed "Src_" and "Dst_" for fields
/// that differ per side, and unprefixed columns for fields shared by both
/// (e.g. CableName, CableType, Length, CombinedField).
enum WireExportParser {
    static func parse(fileURL: URL) -> [WireRecord]? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let headers = parseCSVLine(lines.removeFirst())
        var records: [WireRecord] = []

        for line in lines {
            let values = parseCSVLine(line)
            guard values.count == headers.count else { continue }
            var row: [String: String] = [:]
            for (i, header) in headers.enumerated() { row[header] = values[i] }

            let wireID = row["WireID"] ?? UUID().uuidString

            for side in ["Source", "Destination"] {
                let prefix = side == "Source" ? "Src_" : "Dst_"
                var fields: [String: String] = [:]
                for (key, value) in row {
                    if key.hasPrefix(prefix) {
                        fields[String(key.dropFirst(prefix.count))] = value
                    } else if !key.hasPrefix("Src_") && !key.hasPrefix("Dst_") {
                        fields[key] = value // shared field
                    }
                }
                fields["Side"] = side
                fields["WireID"] = wireID
                records.append(WireRecord(side: side, wireID: wireID, fields: fields))
            }
        }

        return records
    }

    /// Minimal CSV line parser handling quoted fields with commas/quotes.
    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" {
                        current.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == "," { fields.append(current); current = "" }
                else { current.append(c) }
            }
            i += 1
        }
        fields.append(current)
        return fields
    }
}
