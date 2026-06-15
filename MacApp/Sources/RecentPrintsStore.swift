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

    enum PrintRange: String, Codable {
        case all, selected, range
    }

    var rangeFrom: Int?
    var rangeTo: Int?

    /// Human-readable time since print, e.g. "2 min ago", "1 hr ago".
    var timeAgo: String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60    { return "Just now" }
        if secs < 3600  { return "\(secs / 60) min ago" }
        if secs < 86400 { return "\(secs / 3600) hr ago" }
        return "\(secs / 86400) day(s) ago"
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
