import Foundation

/// The loaded cassette as published by the Engine — a Codable mirror of the
/// EngineKit's hardware-read SmartCellInfo (which lives in EngineKit and isn't
/// Codable). Front-ends use this to render cassette match/mismatch.
public struct CassetteStatus: Codable {
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

    public init(partNumber: String, labelWidthMils: Int, labelHeightMils: Int,
                printableWidthMils: Int, printableHeightMils: Int, isDieCut: Bool,
                supplyRemainingPct: Int, labelsPerRoll: Int?, pixelWidth: Int, pixelHeight: Int) {
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

    public init(id: String, name: String, model: String, serial: String,
                status: String, cassette: CassetteStatus?, activeJobCount: Int) {
        self.id = id; self.name = name; self.model = model; self.serial = serial
        self.status = status; self.cassette = cassette; self.activeJobCount = activeJobCount
    }
}

/// Snapshot of printer + cassette state the Engine writes to the IPC status file
/// (printers.json) whenever it changes; front-ends watch the file to stay in sync.
public struct PrinterStatusFile: Codable {
    public var schema: Int
    public var updatedAt: String
    public var engineRunning: Bool
    public var printers: [PrinterStatusEntry]

    public init(updatedAt: String, engineRunning: Bool, printers: [PrinterStatusEntry]) {
        self.schema = 1
        self.updatedAt = updatedAt
        self.engineRunning = engineRunning
        self.printers = printers
    }
}
