import Foundation

/// A single Brady wrap-around wire label supply.
struct BradyLabelSize: Identifiable, Codable, Hashable {
    var id: String { partNumber }
    let partNumber: String      // e.g. "BM-32-427"
    let widthInches: Double
    let heightInches: Double
    // dpi is constant — excluded from Codable to avoid "immutable property will not
    // be decoded" warning (Swift can't decode a let with a default into Codable).
    var dpi: Int { 300 }

    private enum CodingKeys: String, CodingKey {
        case partNumber, widthInches, heightInches
    }

    var pixelWidth: Int { Int((widthInches * Double(dpi)).rounded()) }
    var pixelHeight: Int { Int((heightInches * Double(dpi)).rounded()) }

    var displayName: String {
        "\(partNumber) — \(formatInches(widthInches)) x \(formatInches(heightInches))"
    }

    private func formatInches(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))\"" : String(format: "%.2g\"", v)
    }
}

/// Static catalog of supported Brady wrap-around wire/cable label supplies.
/// Add new entries here as additional part numbers are confirmed.
enum BradyCatalog {
    static let sizes: [BradyLabelSize] = [
        BradyLabelSize(partNumber: "BM-31-427", widthInches: 1.0, heightInches: 1.5),
        BradyLabelSize(partNumber: "BM-32-427", widthInches: 1.5, heightInches: 1.5),
        BradyLabelSize(partNumber: "BM-33-427", widthInches: 1.5, heightInches: 4.0),
    ]

    static func size(forPartNumber pn: String) -> BradyLabelSize? {
        sizes.first { $0.partNumber == pn }
    }

    /// Part-number "core" — everything after the first dash, upper-cased
    /// (e.g. "BM-32-427" and "M6-32-427" both → "32-427"), so a loaded
    /// cassette's M6-prefixed part matches the BM-prefixed catalog entry.
    static func core(_ pn: String) -> String {
        guard let dash = pn.firstIndex(of: "-") else { return pn.uppercased() }
        return String(pn[pn.index(after: dash)...]).uppercased()
    }

    /// Labels on one standard M6 cartridge, by part-number core. Researched from
    /// Brady / distributor listings (M6-31-427 & M6-32-427 = 250/roll,
    /// M6-33-427 = 100/roll). The bulk "BM-" rolls hold far more; these are the
    /// common cartridges the SmartCell reports. Returns nil if unknown.
    static func labelsPerRoll(forPartNumber pn: String) -> Int? {
        switch core(pn) {
        case "31-427": return 250
        case "32-427": return 250
        case "33-427": return 100
        default:       return nil
        }
    }
}
