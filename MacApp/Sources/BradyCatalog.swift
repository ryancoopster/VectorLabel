import Foundation

/// A single Brady wrap-around wire label supply.
struct BradyLabelSize: Identifiable, Codable, Hashable {
    var id: String { partNumber }
    let partNumber: String      // e.g. "BM-32-427"
    let widthInches: Double
    let heightInches: Double
    let dpi: Int = 300

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
}
