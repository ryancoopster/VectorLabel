import Foundation

/// The result of importing a third-party label template (Brady ".BWT", Brother ".lbx", …)
/// into VectorLabel's designer object model — ready to inject as a new, unsaved document.
/// Shared by every importer + the designer's inject path.
public struct ImportedDesign {
    public var name: String                 // display name (file stem, falls back to part #)
    public var partNumber: String           // source part number, if any (else "")
    public var widthInches: Double           // supply width  (die-cut: part width; continuous: tape width)
    public var heightInches: Double          // supply height (die-cut: part height; continuous: label length)
    public var canvasRotation: Int           // 0 or 90 — stock-aware
    public var labelLengthInches: Double     // continuous only: the along-feed length (0 ⇒ n/a)
    public var isContinuous: Bool
    public var objects: [[String: Any]]      // designer objects (x/y/w/h in inches, in the design frame)
    public var fieldNames: [String]          // bound/source field names, in object order
    public var warnings: [String]            // anything skipped / not yet supported
    /// Hint for picking the real catalog supply when the source has no resolvable part
    /// number — e.g. "ptouch" → match the Brother P-touch tape group by tape width. "" ⇒
    /// resolve by partNumber (or fall back to the imported geometry).
    public var supplyGroupHint: String
    /// The source had auto-length / auto-size enabled (continuous): the length should
    /// auto-fit the content on import rather than use a fixed value.
    public var autoLength: Bool

    public init(name: String, partNumber: String, widthInches: Double, heightInches: Double,
                canvasRotation: Int, labelLengthInches: Double, isContinuous: Bool,
                objects: [[String: Any]], fieldNames: [String], warnings: [String],
                supplyGroupHint: String = "", autoLength: Bool = false) {
        self.name = name; self.partNumber = partNumber
        self.widthInches = widthInches; self.heightInches = heightInches
        self.canvasRotation = canvasRotation; self.labelLengthInches = labelLengthInches
        self.isContinuous = isContinuous
        self.objects = objects; self.fieldNames = fieldNames; self.warnings = warnings
        self.supplyGroupHint = supplyGroupHint; self.autoLength = autoLength
    }
}
