import Foundation

/// How a supply is cut/sized: pre-cut die-cut labels (fixed height) vs a
/// continuous tape whose label length the user sets at print time.
public enum BradySupplyType: String, Codable, Hashable {
    case dieCut
    case continuous
}

/// A single Brady wrap-around wire label supply.
public struct BradyLabelSize: Identifiable, Codable, Hashable {
    public var id: String { partNumber }
    public let partNumber: String      // e.g. "BM-32-427"
    public let widthInches: Double
    public let heightInches: Double
    // dpi is constant — excluded from Codable to avoid "immutable property will not
    // be decoded" warning (Swift can't decode a let with a default into Codable).
    public var dpi: Int { 300 }

    // Phase 5 additive metadata (safe defaults so older callers/decodes still work).
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

    public var pixelWidth: Int { Int((widthInches * Double(dpi)).rounded()) }
    public var pixelHeight: Int { Int((heightInches * Double(dpi)).rounded()) }

    public var displayName: String {
        "\(partNumber) — \(formatInches(widthInches)) x \(formatInches(heightInches))"
    }

    private func formatInches(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))\"" : String(format: "%.2g\"", v)
    }
}

/// Catalog of supported Brady wrap-around wire/cable label supplies.
///
/// The data lives in a single source — `BradyCatalog.json` (bundled as an SPM
/// resource) — which this loads once at launch. The JS `BL` tables in the two
/// HTML UIs are mirrors of that file's `js` projection and are kept in sync by a
/// unit test. If the resource is missing or corrupt we fall back to an identical
/// built-in table, so a packaging mistake can never change behavior or crash.
public enum BradyCatalog {

    /// One catalog entry as stored in BradyCatalog.json. (The `js` projection is
    /// consumed only by the HTML UIs / the sync test, so it's omitted here —
    /// JSONDecoder ignores the extra key.)
    fileprivate struct Spec: Codable {
        let partNumber: String
        let widthInches: Double
        let heightInches: Double
        let printableWidthInches: Double
        let printableHeightInches: Double
        let feedRotationDeg: Double
        let labelsPerRoll: Int?
        // Phase 5 additive fields — optional so older JSON (and the test's narrower
        // struct view) still decode. Defaulted at use sites.
        let material: String?
        let type: String?
        let laminated: Bool?
        let buyUrlRoll: String?
        let buyUrlBulk: String?
    }
    fileprivate struct CatalogFile: Codable {
        let coreEquivalences: [String: String]
        let sizes: [Spec]
    }

    /// Built-in fallback — byte-for-byte equivalent to BradyCatalog.json, used
    /// only if the bundled resource can't be read/decoded.
    fileprivate static let fallback = CatalogFile(
        coreEquivalences: ["109-427": "33-427"],
        sizes: [
            Spec(partNumber: "BM-31-427", widthInches: 1.0, heightInches: 1.5,
                 printableWidthInches: 1.0, printableHeightInches: 0.5, feedRotationDeg: 0, labelsPerRoll: 250,
                 material: "B-427", type: "dieCut", laminated: true, buyUrlRoll: "", buyUrlBulk: ""),
            Spec(partNumber: "BM-32-427", widthInches: 1.5, heightInches: 1.5,
                 printableWidthInches: 1.5, printableHeightInches: 0.5, feedRotationDeg: 0, labelsPerRoll: 250,
                 material: "B-427", type: "dieCut", laminated: true, buyUrlRoll: "", buyUrlBulk: ""),
            Spec(partNumber: "BM-33-427", widthInches: 1.5, heightInches: 4.0,
                 printableWidthInches: 1.5, printableHeightInches: 1.5, feedRotationDeg: 90, labelsPerRoll: 100,
                 material: "B-427", type: "dieCut", laminated: true, buyUrlRoll: "", buyUrlBulk: ""),
        ]
    )

    /// True when the loaded catalog came from the bundled JSON (not the fallback).
    /// Exposed for tests to confirm the resource path actually works.
    public private(set) static var loadedFromResource = false

    fileprivate static let file: CatalogFile = {
        if let url = CoreResources.url("BradyCatalog", "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(CatalogFile.self, from: data) {
            loadedFromResource = true
            return decoded
        }
        return fallback
    }()

    public static let sizes: [BradyLabelSize] = file.sizes.map {
        BradyLabelSize(partNumber: $0.partNumber, widthInches: $0.widthInches, heightInches: $0.heightInches,
                       material: $0.material ?? "",
                       type: BradySupplyType(rawValue: $0.type ?? "dieCut") ?? .dieCut,
                       laminated: $0.laminated ?? false,
                       buyUrlRoll: $0.buyUrlRoll ?? "", buyUrlBulk: $0.buyUrlBulk ?? "")
    }

    fileprivate static func spec(forPartNumber pn: String) -> Spec? {
        file.sizes.first { $0.partNumber == pn }
    }

    public static func size(forPartNumber pn: String) -> BradyLabelSize? {
        sizes.first { $0.partNumber == pn }
    }

    /// Part-number "core" — everything after the first dash, upper-cased
    /// (e.g. "BM-32-427" and "M6-32-427" both → "32-427"), so a loaded
    /// cassette's M6-prefixed part matches the BM-prefixed catalog entry.
    /// Bulk-box ↔ cartridge equivalences (e.g. BM-109-427 == M6-33-427) come
    /// from the catalog's `coreEquivalences`.
    public static func core(_ pn: String) -> String {
        guard let dash = pn.firstIndex(of: "-") else { return pn.uppercased() }
        let c = String(pn[pn.index(after: dash)...]).uppercased()
        return file.coreEquivalences[c] ?? c
    }

    /// Labels on one standard M6 cartridge, by part-number core. Returns nil if
    /// unknown. (M6-31-427 & M6-32-427 = 250/roll, M6-33-427 = 100/roll.)
    public static func labelsPerRoll(forPartNumber pn: String) -> Int? {
        let c = core(pn)
        return file.sizes.first { core($0.partNumber) == c }?.labelsPerRoll
    }

    /// Printable area in inches for a part number (nil if unknown — callers fall
    /// back to the physical size). For BM-33-427 the printable zone is 1.5×1.5
    /// even though the total label is 1.5×4.0.
    public static func printableWidthInches(forPartNumber pn: String)  -> Double? { spec(forPartNumber: pn)?.printableWidthInches }
    public static func printableHeightInches(forPartNumber pn: String) -> Double? { spec(forPartNumber: pn)?.printableHeightInches }

    /// Degrees the label feeds rotated relative to the designer layout (the
    /// renderer rotates to match). 0 for most; 90 for the 33-427 family. Matched
    /// by core so M6-33-427 / BM-109-427 rotate like BM-33-427 (preserving the
    /// old `core(...)=="33-427"` gate).
    public static func feedRotationDeg(forPartNumber pn: String) -> Double {
        let c = core(pn)
        return file.sizes.first { core($0.partNumber) == c }?.feedRotationDeg ?? 0
    }

    /// Supply type for a part number (die-cut vs continuous). Unknown parts default
    /// to die-cut, preserving the fixed-height behavior of the existing supplies.
    public static func supplyType(forPartNumber pn: String) -> BradySupplyType {
        BradySupplyType(rawValue: spec(forPartNumber: pn)?.type ?? "dieCut") ?? .dieCut
    }

    /// True for continuous tape supplies whose label length is set at print time.
    public static func isContinuous(forPartNumber pn: String) -> Bool {
        supplyType(forPartNumber: pn) == .continuous
    }

    /// bradyid.com purchase URLs (single roll/cartridge and bulk box) for a part
    /// number, or "" when unknown.
    public static func buyUrlRoll(forPartNumber pn: String) -> String { spec(forPartNumber: pn)?.buyUrlRoll ?? "" }
    public static func buyUrlBulk(forPartNumber pn: String) -> String { spec(forPartNumber: pn)?.buyUrlBulk ?? "" }
}
