import Foundation

/// The loaded cassette as published by the Engine — a Codable mirror of the
/// EngineKit's hardware-read SmartCellInfo (which lives in EngineKit and isn't
/// Codable). Front-ends use this to render cassette match/mismatch.
public struct CassetteStatus: Codable, Equatable {
    public var partNumber: String
    public var labelWidthMils: Int
    public var labelHeightMils: Int
    public var printableWidthMils: Int
    public var printableHeightMils: Int
    public var isDieCut: Bool
    public var supplyRemainingPct: Int
    public var labelsPerRoll: Int?
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The printer's raster-frame rotation for the loaded media (M611 PICL "Area
    /// Rotation", e.g. 270 for M6 die-cut). nil for the M610 (VGL handles its own).
    /// Optional so older status files still decode.
    public var areaRotation: Int?
    /// M611-only live telemetry (nil/absent for the M610). Optional → tolerant decode.
    public var ribbonRemainingPct: Int?
    public var ribbonPartNumber: String?
    public var batteryPct: Int?

    public init(partNumber: String, labelWidthMils: Int, labelHeightMils: Int,
                printableWidthMils: Int, printableHeightMils: Int, isDieCut: Bool,
                supplyRemainingPct: Int, labelsPerRoll: Int?, pixelWidth: Int, pixelHeight: Int,
                areaRotation: Int? = nil, ribbonRemainingPct: Int? = nil,
                ribbonPartNumber: String? = nil, batteryPct: Int? = nil) {
        self.partNumber = partNumber
        self.labelWidthMils = labelWidthMils
        self.labelHeightMils = labelHeightMils
        self.printableWidthMils = printableWidthMils
        self.printableHeightMils = printableHeightMils
        self.isDieCut = isDieCut
        self.supplyRemainingPct = supplyRemainingPct
        self.labelsPerRoll = labelsPerRoll
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.areaRotation = areaRotation
        self.ribbonRemainingPct = ribbonRemainingPct
        self.ribbonPartNumber = ribbonPartNumber
        self.batteryPct = batteryPct
    }
}

/// One connected printer in the Engine's published status.
public struct PrinterStatusEntry: Codable {
    public var id: String
    public var name: String
    public var model: String          // "M610" | "M611" | …
    public var serial: String
    public var status: String         // "ready" | "busy" | "offline"
    public var cassette: CassetteStatus?
    public var activeJobCount: Int
    /// Whether this printer's driver reports live telemetry (battery / labels / ribbon
    /// percentages). The M611 does; the M610 doesn't. Front-ends gate the telemetry
    /// display on this so the readouts only show for printers that can supply them.
    public var supportsTelemetry: Bool

    public init(id: String, name: String, model: String, serial: String,
                status: String, cassette: CassetteStatus?, activeJobCount: Int,
                supportsTelemetry: Bool = false) {
        self.id = id; self.name = name; self.model = model; self.serial = serial
        self.status = status; self.cassette = cassette; self.activeJobCount = activeJobCount
        self.supportsTelemetry = supportsTelemetry
    }

    enum CodingKeys: String, CodingKey {
        case id, name, model, serial, status, cassette, activeJobCount, supportsTelemetry
    }
    // Tolerant decode so a status file written before `supportsTelemetry` existed still
    // decodes (default false) rather than dropping the whole printers array.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        serial = (try? c.decode(String.self, forKey: .serial)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "offline"
        cassette = try? c.decode(CassetteStatus.self, forKey: .cassette)
        activeJobCount = (try? c.decode(Int.self, forKey: .activeJobCount)) ?? 0
        supportsTelemetry = (try? c.decode(Bool.self, forKey: .supportsTelemetry)) ?? false
    }
}

/// One in-flight (printing or queued) job in the Engine's published status, so a
/// front-end can show live progress and offer a Cancel control without owning the
/// USB device. The Engine fills this from its in-flight `PrintJob`(s).
public struct ActiveJobStatus: Codable, Identifiable, Hashable {
    public var id: String          // the PrintJobFile id (== queue filename stem)
    public var title: String       // display name (→ PrintJob.title)
    public var sourceApp: String   // "autoprint" | "customdesigner" | …
    public var labelCount: Int     // total labels in the job
    public var completed: Int      // labels finished so far
    public var state: State        // printing | queued

    public enum State: String, Codable {
        case printing
        case queued
    }

    public init(id: String, title: String, sourceApp: String,
                labelCount: Int, completed: Int, state: State) {
        self.id = id; self.title = title; self.sourceApp = sourceApp
        self.labelCount = labelCount; self.completed = completed; self.state = state
    }
}

/// Snapshot of printer + cassette state the Engine writes to the IPC status file
/// (printers.json) whenever it changes; front-ends watch the file to stay in sync.
public struct PrinterStatusFile: Codable {
    public var schema: Int
    public var updatedAt: String
    public var engineRunning: Bool
    public var printers: [PrinterStatusEntry]
    /// In-flight jobs across all printers (printing or queued), for cross-process
    /// progress + cancel. Defaults to empty so older readers/writers still work.
    public var activeJobs: [ActiveJobStatus]

    public init(updatedAt: String, engineRunning: Bool,
                printers: [PrinterStatusEntry],
                activeJobs: [ActiveJobStatus] = []) {
        self.schema = 1
        self.updatedAt = updatedAt
        self.engineRunning = engineRunning
        self.printers = printers
        self.activeJobs = activeJobs
    }

    enum CodingKeys: String, CodingKey {
        case schema, updatedAt, engineRunning, printers, activeJobs
    }

    // Tolerant decode so a status file written before `activeJobs` existed still
    // decodes (older Engine ↔ newer front-end during a partial update).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema        = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        updatedAt     = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""
        engineRunning = (try? c.decode(Bool.self, forKey: .engineRunning)) ?? false
        printers      = (try? c.decode([PrinterStatusEntry].self, forKey: .printers)) ?? []
        activeJobs    = (try? c.decode([ActiveJobStatus].self, forKey: .activeJobs)) ?? []
    }
}
