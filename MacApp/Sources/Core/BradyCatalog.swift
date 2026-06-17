import Foundation

/// A single Brady wrap-around wire label supply.
public struct BradyLabelSize: Identifiable, Codable, Hashable {
    public var id: String { partNumber }
    public let partNumber: String      // e.g. "BM-32-427"
    public let widthInches: Double
    public let heightInches: Double
    // dpi is constant — excluded from Codable to avoid "immutable property will not
    // be decoded" warning (Swift can't decode a let with a default into Codable).
    public var dpi: Int { 300 }

    public init(partNumber: String, widthInches: Double, heightInches: Double) {
        self.partNumber = partNumber
        self.widthInches = widthInches
        self.heightInches = heightInches
    }

    private enum CodingKeys: String, CodingKey {
        case partNumber, widthInches, heightInches
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
                 printableWidthInches: 1.0, printableHeightInches: 0.5, feedRotationDeg: 0, labelsPerRoll: 250),
            Spec(partNumber: "BM-32-427", widthInches: 1.5, heightInches: 1.5,
                 printableWidthInches: 1.5, printableHeightInches: 0.5, feedRotationDeg: 0, labelsPerRoll: 250),
            Spec(partNumber: "BM-33-427", widthInches: 1.5, heightInches: 4.0,
                 printableWidthInches: 1.5, printableHeightInches: 1.5, feedRotationDeg: 90, labelsPerRoll: 100),
        ]
    )

    /// True when the loaded catalog came from the bundled JSON (not the fallback).
    /// Exposed for tests to confirm the resource path actually works.
    public private(set) static var loadedFromResource = false

    fileprivate static let file: CatalogFile = {
        if let url = Bundle.module.url(forResource: "BradyCatalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(CatalogFile.self, from: data) {
            loadedFromResource = true
            return decoded
        }
        return fallback
    }()

    public static let sizes: [BradyLabelSize] = file.sizes.map {
        BradyLabelSize(partNumber: $0.partNumber, widthInches: $0.widthInches, heightInches: $0.heightInches)
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
}
