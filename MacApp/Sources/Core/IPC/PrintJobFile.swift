import Foundation

/// When to actuate the printer's cutter for a job. Carried end-to-end from the
/// front-end's print settings to the Engine; the cut bytes themselves are wired
/// into BradyVGL in a later phase (continuous/M611 cutter work).
public enum CutMode: String, Codable {
    case afterJobLast     // one full cut at the end of the whole job
    case eachLabel        // full cut after every label (needed for continuous stock)
    case never            // no cut (e.g. die-cut labels are pre-cut)
    case halfEachFullEnd  // half-cut (score) between labels, full cut at job end (Brother)
}

/// State a front-end captures at print time so a later "Reprint" can RE-OPEN the
/// source window in the same state (instead of blindly re-submitting). Carried on
/// the job to the Engine, which copies it into the Recent-Prints record. All
/// fields optional so older job files still decode.
public struct ReprintInfo: Codable {
    public var sourceFileName: String       // export CSV filename ("" for custom)
    public var selectedIndices: [Int]       // which records were checked
    public var printRange: String           // RecentPrint.PrintRange raw value
    public var rangeFrom: Int?
    public var rangeTo: Int?
    public var filterJSON: String?
    public var sortJSON: String?
    public var customDocJSON: String?       // RESERVED for Stage B (Custom Designer reopen); not written or read by any code today.

    public init(sourceFileName: String = "", selectedIndices: [Int] = [],
                printRange: String = "all", rangeFrom: Int? = nil, rangeTo: Int? = nil,
                filterJSON: String? = nil, sortJSON: String? = nil, customDocJSON: String? = nil) {
        self.sourceFileName = sourceFileName
        self.selectedIndices = selectedIndices
        self.printRange = printRange
        self.rangeFrom = rangeFrom
        self.rangeTo = rangeTo
        self.filterJSON = filterJSON
        self.sortJSON = sortJSON
        self.customDocJSON = customDocJSON
    }
}

/// A print job handed from a front-end app (Auto Print / Custom Designer) to the
/// Engine via the IPC queue. Labels are pre-rendered Brady VGL byte buffers —
/// `Codable` encodes `Data` as base64 in JSON — so the Engine is a pure
/// transport that never needs the template/record/calibration context.
public struct PrintJobFile: Codable {
    public var schema: Int
    public var id: String                 // == filename stem; also the PrintJob identity
    public var createdAt: String          // ISO-8601, stamped by the submitter
    public var sourceApp: String          // "autoprint" | "customdesigner" | …
    public var title: String              // display name (→ PrintJob.title)
    public var templateName: String       // for history
    public var printerID: String?         // nil ⇒ Engine picks the sole ready printer
    public var copies: Int                // per-label copies (default 1)
    public var cutMode: CutMode
    public var estLabelMs: Int            // pacing estimate (→ PrinterManager.submit estLabelMs:)
    /// Pre-rendered, printer-agnostic label rasters. The Engine encodes each into the
    /// target printer's wire format (VGL for M610, bitmap/LZ4 for M611) at print time
    /// — "encode in the Engine", so front-ends stay printer-agnostic.
    public var renderedLabels: [RenderedLabel]
    /// LEGACY: pre-encoded VGL byte jobs. Empty for jobs that carry `renderedLabels`.
    /// Kept so an in-flight pre-upgrade job file still decodes.
    public var labels: [Data]
    public var reprint: ReprintInfo?      // print-time state for "reopen on reprint"
    /// "Feed to clear before printing": when set, the Engine synthesizes + prepends a blank
    /// lead label at print time — die-cut: one label pitch; continuous: a 1" feed — built
    /// from live media + the real label geometry, and force-cut for continuous tape (always)
    /// or cut per `cutMode` for die-cut. The front-end only sets this flag. Default false.
    public var feedToClear: Bool

    public init(id: String,
                createdAt: String,
                sourceApp: String,
                title: String,
                templateName: String,
                printerID: String? = nil,
                copies: Int = 1,
                cutMode: CutMode = .afterJobLast,
                estLabelMs: Int = 1000,
                renderedLabels: [RenderedLabel] = [],
                labels: [Data] = [],
                reprint: ReprintInfo? = nil,
                feedToClear: Bool = false) {
        self.schema = 2
        self.id = id
        self.createdAt = createdAt
        self.sourceApp = sourceApp
        self.title = title
        self.templateName = templateName
        self.printerID = printerID
        self.copies = copies
        self.cutMode = cutMode
        self.estLabelMs = estLabelMs
        self.renderedLabels = renderedLabels
        self.labels = labels
        self.reprint = reprint
        self.feedToClear = feedToClear
    }

    // Tolerant decode: a job file written before `renderedLabels` (or `labels`)
    // existed still decodes (defaults to empty), so a partial upgrade can't wedge
    // the queue on an undecodable file.
    enum CodingKeys: String, CodingKey {
        case schema, id, createdAt, sourceApp, title, templateName, printerID
        case copies, cutMode, estLabelMs, renderedLabels, labels, reprint, feedToClear
    }
    /// The highest `schema` this build understands. A file declaring a newer schema
    /// is rejected (routed to failed/) rather than silently mis-decoded by an older
    /// Engine against a newer front-end's field semantics.
    static let maxSchema = 2

    /// `id` doubles as a filesystem path component (`queue/<id>.json`,
    /// `done/<id>.json`) and is used verbatim in `appendingPathComponent`, so it must
    /// be an opaque, traversal-safe token — never a relative path.
    static func isSafeID(_ s: String) -> Bool {
        guard (1...128).contains(s.count), !s.contains("..") else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        guard schema <= Self.maxSchema else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: c,
                debugDescription: "PrintJobFile schema \(schema) is newer than this build supports (\(Self.maxSchema))")
        }
        // `id` is REQUIRED and must be a safe token. The whole IPC pipeline keys file
        // moves and reprint lookups on it; fabricating a random UUID on a missing key
        // would desync it from the filename, and an unsanitised id is a path-traversal
        // sink in readDoneJob/atomicWrite.
        let rawID = try c.decode(String.self, forKey: .id)
        guard Self.isSafeID(rawID) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c,
                debugDescription: "PrintJobFile id is not a safe token: \(rawID)")
        }
        id = rawID
        createdAt    = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        sourceApp    = (try? c.decode(String.self, forKey: .sourceApp)) ?? ""
        title        = (try? c.decode(String.self, forKey: .title)) ?? ""
        templateName = (try? c.decode(String.self, forKey: .templateName)) ?? ""
        printerID    = try? c.decode(String.self, forKey: .printerID)
        copies       = (try? c.decode(Int.self, forKey: .copies)) ?? 1
        // Distinguish ABSENT (legacy file → default) from MALFORMED (a corrupt/unknown
        // value must propagate so claim() routes the file to failed/, not be silently
        // coerced into a cutting mode). Mirrors the renderedLabels handling below.
        if c.contains(.cutMode) {
            cutMode = try c.decode(CutMode.self, forKey: .cutMode)
        } else {
            cutMode = .afterJobLast
        }
        estLabelMs   = (try? c.decode(Int.self, forKey: .estLabelMs)) ?? 1000
        // When the key is PRESENT, a malformed/oversized raster (see RenderedLabel's
        // validating decoder) must PROPAGATE so claim() routes the file to failed/ —
        // not be swallowed into an empty job that "prints" zero labels and is recorded
        // as a successful 0-label print. An absent key is still tolerated (a
        // pre-`renderedLabels` file decodes with []).
        if c.contains(.renderedLabels) {
            renderedLabels = try c.decode([RenderedLabel].self, forKey: .renderedLabels)
        } else {
            renderedLabels = []
        }
        labels  = (try? c.decode([Data].self, forKey: .labels)) ?? []
        reprint = try? c.decode(ReprintInfo.self, forKey: .reprint)
        feedToClear = (try? c.decode(Bool.self, forKey: .feedToClear)) ?? false
    }
}
