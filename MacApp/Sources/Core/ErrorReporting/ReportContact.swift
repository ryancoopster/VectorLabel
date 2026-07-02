import Foundation

/// Who to follow up with about a problem report. Collected once (the first report from
/// any suite app) and stored suite-wide in Application Support, so every app reuses it.
public struct ReportContact: Codable, Equatable {
    public var name: String
    public var email: String
    public var phone: String
    public init(name: String, email: String, phone: String) {
        self.name = name; self.email = email; self.phone = phone
    }
}

/// JSON persistence for the report contact (the PrinterModelStore pattern, simplified).
public enum ReportContactStore {

    private static var fileURL: URL {
        let dir = AppEnvironment.supportRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ReportContact.json")
    }

    public static func load() -> ReportContact? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ReportContact.self, from: data)
    }

    public static func save(_ c: ReportContact) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(c) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
