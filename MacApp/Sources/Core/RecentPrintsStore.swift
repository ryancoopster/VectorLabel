import Foundation

// MARK: – Model

/// A record of a completed print job, persisted for reprint.
public struct RecentPrint: Codable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var date: Date
    public var title: String               // e.g. "Kodak Hall — N044–N046"
    public var sourceFileName: String      // original CSV filename
    public var templateName: String
    public var printerName: String
    public var labelCount: Int
    public var printRange: PrintRange
    public var selectedIndices: [Int]      // which record indices were checked
    public var status: Status = .complete  // lifecycle outcome of the job

    /// The IPC PrintJobFile id (filename stem) this record was printed from. The
    /// Engine records it so Reprint can re-read the finished job's rendered VGL
    /// labels from ipc/done/<jobId>.json and re-submit them. Empty for records
    /// that predate the Engine-owned recents (no done file to reprint from).
    public var jobId: String = ""

    /// Which front-end submitted the job ("autoprint" | "customdesigner" | …).
    /// Persisted so Reprint routes off the record itself rather than re-deriving
    /// it from the (prunable) done file. Empty for records that predate this field.
    public var sourceApp: String = ""

    public enum PrintRange: String, Codable {
        case all, selected, range
    }

    /// Lifecycle outcome shown in the Recent Prints menu.
    public enum Status: String, Codable {
        case printing                // submitted, still printing
        case complete                // all labels sent
        case cancelledBeforePrinting // ✕ Cancel before a print started
        case cancelledMidPrint       // job cancelled while printing
        case failed                  // a USB/send error aborted the job

        public var displayName: String {
            switch self {
            case .printing:                return "Printing…"
            case .complete:                return "Complete"
            case .cancelledBeforePrinting: return "Cancelled before printing"
            case .cancelledMidPrint:       return "Cancelled mid-print"
            case .failed:                  return "Failed"
            }
        }
    }

    public var rangeFrom: Int?
    public var rangeTo: Int?

    // The filter/sort that were active for this job, stored as JSON so reprint
    // can restore them (nil = none). Opaque here; parsed by the print web UI.
    public var filterJSON: String?
    public var sortJSON: String?

    enum CodingKeys: String, CodingKey {
        case id, date, title, sourceFileName, templateName, printerName
        case labelCount, printRange, selectedIndices, status, rangeFrom, rangeTo
        case filterJSON, sortJSON, jobId, sourceApp
    }

    public init(id: UUID = UUID(), date: Date, title: String, sourceFileName: String,
                templateName: String, printerName: String, labelCount: Int,
                printRange: PrintRange, selectedIndices: [Int], status: Status = .complete,
                rangeFrom: Int? = nil, rangeTo: Int? = nil,
                filterJSON: String? = nil, sortJSON: String? = nil,
                jobId: String = "", sourceApp: String = "") {
        self.id = id
        self.date = date
        self.title = title
        self.sourceFileName = sourceFileName
        self.templateName = templateName
        self.printerName = printerName
        self.labelCount = labelCount
        self.printRange = printRange
        self.selectedIndices = selectedIndices
        self.status = status
        self.rangeFrom = rangeFrom
        self.rangeTo = rangeTo
        self.filterJSON = filterJSON
        self.sortJSON = sortJSON
        self.jobId = jobId
        self.sourceApp = sourceApp
    }

    /// Absolute print date and time, e.g. "Jun 15, 2026 at 3:42 PM".
    public var dateTimeString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Human-readable time since print, e.g. "2 min ago", "1 hr ago".
    public var timeAgo: String {
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
    public init(from decoder: Decoder) throws {
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
        filterJSON      = try? c.decode(String.self, forKey: .filterJSON)
        sortJSON        = try? c.decode(String.self, forKey: .sortJSON)
        jobId           = (try? c.decode(String.self, forKey: .jobId)) ?? ""
        sourceApp       = (try? c.decode(String.self, forKey: .sourceApp)) ?? ""
    }
}

// MARK: – Store

/// Persists recent print jobs to Application Support as JSON.
/// Thread-safe for reads from the main actor; writes happen synchronously.
@MainActor
public final class RecentPrintsStore: ObservableObject {

    public static let shared = RecentPrintsStore()

    @Published public private(set) var prints: [RecentPrint] = []

    // Variant-aware: production → ~/…/VectorLabel, beta → ~/…/VectorLabel Beta.
    // Previously hardcoded "VectorLabel", so the beta Engine wrote/read recents in
    // the production folder — recents never populated and Reprint never found jobs.
    private let fileURL: URL = {
        let dir = AppEnvironment.supportRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recent_prints.json")
    }()

    private init() { load() }

    // MARK: – Public API

    /// Upper bound on retained history — the menu shows the full scrollable list
    /// and offers Clear, so this only guards the persisted file against unbounded
    /// growth over a very long session.
    public static let maxHistory = 500

    public func add(_ print: RecentPrint) {
        prints.insert(print, at: 0)
        if prints.count > Self.maxHistory { prints = Array(prints.prefix(Self.maxHistory)) }
        save()
    }

    /// Updates the status of a previously-added record (e.g. printing → complete).
    public func updateStatus(id: UUID, to status: RecentPrint.Status) {
        guard let idx = prints.firstIndex(where: { $0.id == id }) else { return }
        prints[idx].status = status
        save()
    }

    /// Finalize a record's lifecycle: set its terminal status and, when provided,
    /// correct its label count to what actually printed. (A cancelled job prints
    /// fewer labels than the intended total, so the recent should reflect that.)
    public func finish(id: UUID, status: RecentPrint.Status, labelCount: Int? = nil) {
        guard let idx = prints.firstIndex(where: { $0.id == id }) else { return }
        prints[idx].status = status
        if let c = labelCount { prints[idx].labelCount = c }
        save()
    }

    public func clear() { prints = []; save() }

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
