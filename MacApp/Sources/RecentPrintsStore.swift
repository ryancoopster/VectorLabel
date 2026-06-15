import Foundation

// MARK: – Model

/// A record of a completed print job, persisted for reprint.
struct RecentPrint: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var title: String               // e.g. "Kodak Hall — N044–N046"
    var sourceFileName: String      // original CSV filename
    var templateName: String
    var printerName: String
    var labelCount: Int
    var printRange: PrintRange
    var selectedIndices: [Int]      // which record indices were checked
    var status: Status = .complete  // lifecycle outcome of the job

    enum PrintRange: String, Codable {
        case all, selected, range
    }

    /// Lifecycle outcome shown in the Recent Prints menu.
    enum Status: String, Codable {
        case printing                // submitted, still printing
        case complete                // all labels sent
        case cancelledBeforePrinting // ✕ Cancel before a print started
        case cancelledMidPrint       // job cancelled while printing

        var displayName: String {
            switch self {
            case .printing:                return "Printing…"
            case .complete:                return "Complete"
            case .cancelledBeforePrinting: return "Cancelled before printing"
            case .cancelledMidPrint:       return "Cancelled mid-print"
            }
        }
    }

    var rangeFrom: Int?
    var rangeTo: Int?

    enum CodingKeys: String, CodingKey {
        case id, date, title, sourceFileName, templateName, printerName
        case labelCount, printRange, selectedIndices, status, rangeFrom, rangeTo
    }

    /// Absolute print date and time, e.g. "Jun 15, 2026 at 3:42 PM".
    var dateTimeString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Human-readable time since print, e.g. "2 min ago", "1 hr ago".
    var timeAgo: String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60    { return "Just now" }
        if secs < 3600  { return "\(secs / 60) min ago" }
        if secs < 86400 { return "\(secs / 3600) hr ago" }
        return "\(secs / 86400) day(s) ago"
    }
}

// MARK: – Tolerant decoding

// Decode defensively so adding fields to RecentPrint doesn't make every older
// recent_prints.json fail to decode (which would silently wipe all history).
extension RecentPrint {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = (try? c.decode(UUID.self,   forKey: .id)) ?? UUID()
        date            = (try? c.decode(Date.self,   forKey: .date)) ?? Date()
        title           = (try? c.decode(String.self, forKey: .title)) ?? ""
        sourceFileName  = (try? c.decode(String.self, forKey: .sourceFileName)) ?? ""
        templateName    = (try? c.decode(String.self, forKey: .templateName)) ?? ""
        printerName     = (try? c.decode(String.self, forKey: .printerName)) ?? ""
        labelCount      = (try? c.decode(Int.self,    forKey: .labelCount)) ?? 0
        printRange      = (try? c.decode(PrintRange.self, forKey: .printRange)) ?? .selected
        selectedIndices = (try? c.decode([Int].self,  forKey: .selectedIndices)) ?? []
        // Older records predate the status field; treat them as completed.
        status          = (try? c.decode(Status.self, forKey: .status)) ?? .complete
        rangeFrom       = try? c.decode(Int.self, forKey: .rangeFrom)
        rangeTo         = try? c.decode(Int.self, forKey: .rangeTo)
    }
}

// MARK: – Store

/// Persists recent print jobs to Application Support as JSON.
/// Thread-safe for reads from the main actor; writes happen synchronously.
@MainActor
final class RecentPrintsStore: ObservableObject {

    static let shared = RecentPrintsStore()

    @Published private(set) var prints: [RecentPrint] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("VectorLabel")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recent_prints.json")
    }()

    private init() { load() }

    // MARK: – Public API

    func add(_ print: RecentPrint) {
        prints.insert(print, at: 0)
        let maxCount = AppSettings.shared.recentPrintsCount
        if prints.count > maxCount { prints = Array(prints.prefix(maxCount)) }
        save()
    }

    /// Updates the status of a previously-added record (e.g. printing → complete).
    func updateStatus(id: UUID, to status: RecentPrint.Status) {
        guard let idx = prints.firstIndex(where: { $0.id == id }) else { return }
        prints[idx].status = status
        save()
    }

    func clear() { prints = []; save() }

    // MARK: – Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([RecentPrint].self, from: data)
        else { return }
        prints = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(prints) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
