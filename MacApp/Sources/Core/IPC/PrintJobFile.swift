import Foundation

/// When to actuate the printer's cutter for a job. Carried end-to-end from the
/// front-end's print settings to the Engine; the cut bytes themselves are wired
/// into BradyVGL in a later phase (continuous/M611 cutter work).
public enum CutMode: String, Codable {
    case afterJobLast   // one cut at the end of the whole job
    case eachLabel      // cut after every label (needed for continuous stock)
    case never          // no cut (e.g. die-cut labels are pre-cut)
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
    public var labels: [Data]             // each element is one complete VGL job

    public init(id: String,
                createdAt: String,
                sourceApp: String,
                title: String,
                templateName: String,
                printerID: String? = nil,
                copies: Int = 1,
                cutMode: CutMode = .afterJobLast,
                estLabelMs: Int = 1000,
                labels: [Data]) {
        self.schema = 1
        self.id = id
        self.createdAt = createdAt
        self.sourceApp = sourceApp
        self.title = title
        self.templateName = templateName
        self.printerID = printerID
        self.copies = copies
        self.cutMode = cutMode
        self.estLabelMs = estLabelMs
        self.labels = labels
    }
}
