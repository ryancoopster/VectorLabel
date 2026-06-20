import Foundation
import VectorLabelCore

extension CassetteStatus {
    /// The cassette fields the web front-ends read, as a JSON-serializable dict. Shared
    /// by the print + custom-designer windows so the two never drift. Optional telemetry
    /// fields are included only when present (nil for the M610); unknown keys are ignored
    /// by the JS, so listing extra fields here is forward-compatible.
    public func webDict() -> [String: Any] {
        var e: [String: Any] = [
            "partNumber": partNumber,
            "labelWidthMils": labelWidthMils,
            "labelHeightMils": labelHeightMils,
            "isDieCut": isDieCut,
            "supplyRemainingPct": supplyRemainingPct,
            "pixelWidth": pixelWidth,
            "pixelHeight": pixelHeight,
        ]
        if let b = batteryPct           { e["batteryPct"] = b }
        if let r = ribbonRemainingPct   { e["ribbonRemainingPct"] = r }
        if let ps = printerSerial       { e["printerSerial"] = ps }
        if let rp = ribbonPartNumber    { e["ribbonPartNumber"] = rp }
        if let fw = firmwareVersion     { e["firmwareVersion"] = fw }
        if let yn = substrateYNumber    { e["substrateYNumber"] = yn }
        if let ar = areaRotation        { e["areaRotation"] = ar }
        if let cont = isContinuous      { e["isContinuous"] = cont }
        if let ac = acConnected         { e["acConnected"] = ac }
        if printheadOpen == true        { e["printheadOpen"] = true }
        if substrateInvalid == true     { e["substrateInvalid"] = true }
        if ribbonInvalid == true        { e["ribbonInvalid"] = true }
        // Prefer the value the Engine already resolved; fall back to the local catalog so
        // the field is present even on an older status file.
        if let perRoll = labelsPerRoll ?? BradyCatalog.labelsPerRoll(forPartNumber: partNumber) {
            e["labelsPerRoll"] = perRoll
        }
        // Continuous roll length (feet) for the loaded part, so the supply forecast can
        // turn the remaining-supply % into a remaining length. nil for die-cut.
        if let rollFt = BradyCatalog.rollLengthFeet(forPartNumber: partNumber) {
            e["rollLengthFeet"] = rollFt
        }
        return e
    }
}
