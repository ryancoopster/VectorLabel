import Foundation

// MARK: – Printer geometry (printable-area contract)
//
// The CANONICAL per-printer printable-area geometry, shared between the Swift
// drivers and the web front-ends' printable-area overlay. The Brother head table
// here is the single source of truth — `BrotherPT` (the driver) consumes it, and
// `webGeometryJSON()` projects it into `window.__VL_PRINTER_GEOMETRY__` for the
// designer + print HTML (both pages read the same shape; see the printable-area
// spec's Swift↔JS contract).

public enum PrinterGeometry {

    // Brother PT-series head: all current PT drivers (PT-E550W / PT-P750W /
    // PT-E560BT) share the 128-pin, 180-DPI print head.
    public static let headPins = 128
    public static let dpi = 180

    /// Tape width (mm) → unprintable margin pins on EACH side of the head.
    /// Printable pins for a tape = `headPins - 2*marginPins`.
    public static let brotherTapeMarginPins: [(mm: Double, marginPins: Int)] = [
        (3.5, 52), (6, 48), (9, 39), (12, 29), (18, 8), (24, 0),
    ]

    /// Printable pins for a tape width — NEAREST-mm match (mirrors
    /// `BrotherPT.nearestTape`'s nearest-entry semantics, so an off-catalog width
    /// still resolves to the closest real tape instead of failing).
    public static func brotherPrintablePins(forTapeMm mm: Double) -> Int {
        let entry = brotherTapeMarginPins.min { abs($0.mm - mm) < abs($1.mm - mm) }!
        return headPins - entry.marginPins * 2
    }

    /// The `window.__VL_PRINTER_GEOMETRY__` JSON injected into BOTH web front-ends
    /// (designer + print): `{"models":[{model, kind, …ptouch: dpi/headPins/tapes}]}`.
    /// Models come from the user-editable printer registry; `kind` is inferred from
    /// the name ("ptouch" if it starts with "PT-" or contains "P-touch"/"PTouch",
    /// else "brady"). Every ptouch model carries the shared head table above.
    public static func webGeometryJSON() -> String {
        let tapes: [[String: Any]] = brotherTapeMarginPins.map {
            ["mm": $0.mm, "marginPins": $0.marginPins]
        }
        let models: [[String: Any]] = PrinterModelStore.modelNames.map { name in
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if n.hasPrefix("pt-") || n.contains("p-touch") || n.contains("ptouch") {
                return ["model": name, "kind": "ptouch",
                        "dpi": dpi, "headPins": headPins, "tapes": tapes]
            }
            return ["model": name, "kind": "brady"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["models": models]),
              let str = String(data: data, encoding: .utf8) else { return "{\"models\":[]}" }
        return str
    }
}
