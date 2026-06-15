import Foundation
import Combine

// MARK: – Template model (matches .vlt.json format from HTML designer)

/// One object on the label canvas — text box, line, or rectangle.
struct TemplateObject: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var t: String           // "tx" | "ln" | "rc"

    // Position and size in label-space (0…1 relative to printable area)
    var x: Double = 0
    var y: Double = 0
    var w: Double = 0.5
    var h: Double = 0.2

    // Text properties (t == "tx")
    var f: String?          // formula, e.g. "=IF(Number<>\"\",Number,\"\")"
    var font: String?
    var fs: Double?         // font size in points (relative to SC=185 canvas)
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var al: String?         // "left" | "center" | "right" | "justify"
    var valign: String?     // "top" | "middle" | "bottom"
    var wrapText: Bool?
    var tracking: Double?
    var stretch: Double?    // horizontal scale %, default 100

    // Line / rectangle
    var lw: Double?         // border/line weight in px
}

/// A saved VectorLabel template, matching .vlt.json exactly.
struct VLTemplate: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var version: Int = 1
    var name: String
    var specN: String       // Brady part number e.g. "BM-32-427"
    var objs: [TemplateObject]

    var labelSize: BradyLabelSize? { BradyCatalog.size(forPartNumber: specN) }
}

// MARK: – TemplateStore

/// Loads and saves .vlt.json template files from ~/Documents/VectorLabel/Templates/.
@MainActor
final class TemplateStore: ObservableObject {

    static let shared = TemplateStore()

    @Published private(set) var templates: [VLTemplate] = []

    private var folderURL: URL { AppSettings.shared.templatesFolderURL }

    private init() { reload() }

    // MARK: – Public API

    func reload() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let decoder = JSONDecoder()
        templates = contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> VLTemplate? in
                guard let data = try? Data(contentsOf: url),
                      var tpl = try? decoder.decode(VLTemplate.self, from: data)
                else { return nil }
                // Use filename (without extension) as display name fallback
                if tpl.name.isEmpty {
                    tpl.name = url.deletingPathExtension().lastPathComponent
                }
                return tpl
            }
    }

    func save(_ template: VLTemplate) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let safe = template.name
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " _-")).inverted)
            .joined(separator: "_")
        let filename = safe.isEmpty ? "template" : safe
        let url = folderURL.appendingPathComponent("\(filename).vlt.json")
        let data = try JSONEncoder().encode(template)
        try data.write(to: url, options: .atomic)
        reload()
    }

    func delete(_ template: VLTemplate) throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: url),
               let t = try? JSONDecoder().decode(VLTemplate.self, from: data),
               t.id == template.id {
                try fm.removeItem(at: url)
            }
        }
        reload()
    }
}
