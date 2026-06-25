import Foundation

/// How a supply is cut/sized: pre-cut die-cut labels (fixed height) vs a
/// continuous tape whose label length the user sets at print time.
public enum BradySupplyType: String, Codable, Hashable {
    case dieCut
    case continuous
}

/// A single Brady wrap-around wire label supply, projected from the editable
/// catalog for the print / match / render pipeline (which looks supplies up by
/// part number). One per part number.
public struct BradyLabelSize: Identifiable, Codable, Hashable {
    public var id: String { partNumber }
    public let partNumber: String      // e.g. "M6-32-427"
    public let widthInches: Double
    public let heightInches: Double
    // The MASTER render DPI (RenderDPI.master), not the printer-native DPI. The
    // whole render path is DPI-relative and keys off this; each driver downscales
    // the master raster to its own native resolution (Brady 300, Brother 180) in
    // encode(). Excluded from Codable (a computed property; nothing to decode).
    public var dpi: Int { RenderDPI.master }

    /// Brady material/part family, e.g. "B-427". "" when unknown.
    public var material: String = ""
    /// die-cut (fixed height) vs continuous (user-set length at print time).
    public var type: BradySupplyType = .dieCut
    /// Self-laminating supply (clear over-laminate tail).
    public var laminated: Bool = false
    /// bradyid.com purchase URLs for a single roll/cartridge and a bulk box ("" if unknown).
    public var buyUrlRoll: String = ""
    public var buyUrlBulk: String = ""

    public init(partNumber: String, widthInches: Double, heightInches: Double,
                material: String = "", type: BradySupplyType = .dieCut, laminated: Bool = false,
                buyUrlRoll: String = "", buyUrlBulk: String = "") {
        self.partNumber = partNumber
        self.widthInches = widthInches
        self.heightInches = heightInches
        self.material = material
        self.type = type
        self.laminated = laminated
        self.buyUrlRoll = buyUrlRoll
        self.buyUrlBulk = buyUrlBulk
    }

    /// True for continuous tape supplies (label length set at print time).
    public var isContinuous: Bool { type == .continuous }

    private enum CodingKeys: String, CodingKey {
        case partNumber, widthInches, heightInches
        case material, type, laminated, buyUrlRoll, buyUrlBulk
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partNumber  = try c.decode(String.self, forKey: .partNumber)
        widthInches = try c.decode(Double.self, forKey: .widthInches)
        heightInches = try c.decode(Double.self, forKey: .heightInches)
        material    = (try? c.decode(String.self, forKey: .material)) ?? ""
        type        = (try? c.decode(BradySupplyType.self, forKey: .type)) ?? .dieCut
        laminated   = (try? c.decode(Bool.self, forKey: .laminated)) ?? false
        buyUrlRoll  = (try? c.decode(String.self, forKey: .buyUrlRoll)) ?? ""
        buyUrlBulk  = (try? c.decode(String.self, forKey: .buyUrlBulk)) ?? ""
    }

    public var pixelWidth: Int { vlInchesToPixels(widthInches, dpi: dpi) }
    public var pixelHeight: Int { vlInchesToPixels(heightInches, dpi: dpi) }

    public var displayName: String {
        "\(partNumber) — \(formatInches(widthInches)) x \(formatInches(heightInches))"
    }

    private func formatInches(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))\"" : String(format: "%.2g\"", v)
    }
}

/// Catalog lookups by part number, used across the print / match / render pipeline.
///
/// This is now a thin façade over the user-editable `SupplyCatalogStore` (which
/// loads from Application Support and seeds `SupplyCatalog.makeDefault()`). The API
/// is unchanged so all existing call sites keep working; the data is just sourced
/// from the editable catalog instead of a bundled JSON. Reads are thread-safe
/// (SupplyCatalogStore.snapshot) so the off-main render path is unaffected.
public enum BradyCatalog {

    private static var catalog: SupplyCatalog { SupplyCatalogStore.snapshot }

    /// Every part number across every group, projected to BradyLabelSize so any
    /// part the printer reports resolves.
    public static var sizes: [BradyLabelSize] {
        catalog.allSupplyParts().map { labelSize(supply: $0.supply, part: $0.part) }
    }

    private static func labelSize(supply s: Supply, part p: SupplyPartNumber) -> BradyLabelSize {
        BradyLabelSize(partNumber: p.partNumber, widthInches: s.widthInches, heightInches: s.heightInches,
                       material: s.materialFamily, type: s.kind == .continuous ? .continuous : .dieCut,
                       laminated: s.selfLaminating, buyUrlRoll: p.overrideURL, buyUrlBulk: "")
    }

    /// Find the (supply, part) for a part number — exact match first, then by
    /// part-number core (so a bulk box resolves to its cartridge family).
    private static func find(_ pn: String) -> (supply: Supply, part: SupplyPartNumber)? {
        let parts = catalog.allSupplyParts()
        if let hit = parts.first(where: { $0.part.partNumber.caseInsensitiveCompare(pn) == .orderedSame }) {
            return hit
        }
        let c = core(pn)
        return parts.first(where: { core($0.part.partNumber) == c })
    }

    public static func size(forPartNumber pn: String) -> BradyLabelSize? {
        guard let f = find(pn) else { return nil }
        return labelSize(supply: f.supply, part: f.part)
    }

    /// Part-number "core" — everything after the first dash, upper-cased
    /// (e.g. "BM-32-427" and "M6-32-427" both → "32-427"). Bulk-box ↔ cartridge
    /// equivalences (e.g. BM-109-427 == M6-33-427) come from the catalog's
    /// `coreEquivalences`.
    public static func core(_ pn: String) -> String {
        guard let dash = pn.firstIndex(of: "-") else { return pn.uppercased() }
        let c = String(pn[pn.index(after: dash)...]).uppercased()
        return catalog.coreEquivalences[c] ?? c
    }

    /// Labels on one standard cartridge, by part-number core. nil if unknown.
    /// Matched by core so a bulk box reports its cartridge's count.
    public static func labelsPerRoll(forPartNumber pn: String) -> Int? {
        let c = core(pn)
        let matches = catalog.allSupplyParts().filter { core($0.part.partNumber) == c }
        // Prefer a sibling part that actually carries a count (parts are user-
        // reorderable, so don't assume the first match has the quantity).
        return matches.first(where: { $0.part.quantityPerRoll != nil })?.part.quantityPerRoll
            ?? matches.first?.part.quantityPerRoll
    }

    /// Roll length in feet for a continuous-tape part number, by core. nil if unknown
    /// (die-cut parts carry a label count instead — see labelsPerRoll). Matched by core
    /// so a sibling part with the length still resolves.
    public static func rollLengthFeet(forPartNumber pn: String) -> Double? {
        let c = core(pn)
        let matches = catalog.allSupplyParts().filter { core($0.part.partNumber) == c }
        return matches.first(where: { $0.part.rollLengthFeet != nil })?.part.rollLengthFeet
            ?? matches.first?.part.rollLengthFeet
    }

    /// Printable area in inches for a part number (nil if unknown — callers fall
    /// back to the physical size).
    public static func printableWidthInches(forPartNumber pn: String)  -> Double? { find(pn)?.supply.printableWidthInches }
    public static func printableHeightInches(forPartNumber pn: String) -> Double? { find(pn)?.supply.printableHeightInches }

    /// The supply identity (UUID string) a part number belongs to, "" if unknown.
    public static func supplyID(forPartNumber pn: String) -> String { find(pn)?.supply.id.uuidString ?? "" }

    // (feedRotationDeg / effectiveFeedRotationDeg were removed with the per-supply
    // "Rotate 90°" override — orientation is now automatic in the renderer + encoders.)

    /// Supply type for a part number (die-cut vs continuous). Unknown parts default
    /// to die-cut, preserving the fixed-height behavior of older supplies.
    public static func supplyType(forPartNumber pn: String) -> BradySupplyType {
        guard let f = find(pn) else { return .dieCut }
        return f.supply.kind == .continuous ? .continuous : .dieCut
    }

    /// True for continuous tape supplies whose label length is set at print time.
    public static func isContinuous(forPartNumber pn: String) -> Bool {
        supplyType(forPartNumber: pn) == .continuous
    }

    /// Legacy purchase URLs. The buy buttons now open a Brady part-number search
    /// (or a per-part override URL), so the roll URL is the part's override ("" ⇒
    /// the UI falls back to search) and there is no separate bulk URL.
    public static func buyUrlRoll(forPartNumber pn: String) -> String { find(pn)?.part.overrideURL ?? "" }
    public static func buyUrlBulk(forPartNumber pn: String) -> String { "" }
}
