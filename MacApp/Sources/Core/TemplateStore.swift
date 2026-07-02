import Foundation
import Combine

// MARK: – Template model (matches .vlt.json format from HTML designer)

/// One object on the label canvas — text box, line, or rectangle.
public struct TemplateObject: Codable, Identifiable, Hashable {
    public var id: String = UUID().uuidString
    var t: String           // "tx" | "ln" | "rc"

    // Position and size in label-space (0…1 relative to printable area)
    var x: Double = 0
    var y: Double = 0
    var w: Double = 0.5
    var h: Double = 0.2

    // Text properties (t == "tx")
    var mode: String?       // "static" | "field" | "formula" (nil → inferred)
    var text: String?       // static-mode literal text
    var field: String?      // field-mode column key, e.g. "Connector"
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
    var autoScale: Bool?    // shrink text to fit the box width; `fs` is the max size

    // Line / rectangle / shapes
    var lw: Double?         // border/line weight in px

    // Arrow (t == "ar")
    var arrowStart: Bool?   // arrowhead at the start (x)
    var arrowEnd: Bool?     // arrowhead at the end (x + w)
    var arrowSize: Double?  // arrowhead length in designer px

    // Image (t == "im") / Symbol (t == "sy") — embedded as a data URL
    // (monochrome PNG with alpha), so the template is self-contained and never
    // references an external file. `sym` is the symbol-library key (sy only).
    var src: String?
    var sym: String?
    var lockAspect: Bool?   // image: keep width/height ratio when resizing

    // Barcode (t == "bc"). The encoded data uses the SAME mode/text/field/f as a text
    // object (static literal, bound field, or formula), so binding + drag-drop are shared.
    var bcType: String?     // bwip-js symbology id, e.g. "qrcode" | "datamatrix" | "code128"
    var eclevel: String?    // error-correction level (QR: L/M/Q/H; PDF417/Aztec: numeric)

    // Rotation in degrees, clockwise, about the object's center. nil/0 = none.
    var rot: Double?

    // Designer-only editing aid: which point (tl/tc/tr/ml/mc/mr/bl/bc/br) the
    // X/Y refer to and which stays fixed when resizing. Ignored by the renderer.
    var anchor: String?

    // Table (t == "tb"). Column widths / row heights in inches (w == sum(cols),
    // h == sum(rows)); `cells` is row-major, rows.length × cols.length. All
    // optional so every existing .vltmp/.vlcus keeps decoding unchanged.
    var cols: [Double]?
    var rows: [Double]?
    var lockCols: Bool?     // all columns forced equal (w / cols.count)
    var lockRows: Bool?     // all rows forced equal (h / rows.count)
    var lockSize: Bool?     // overall w/h locked: inner line drags redistribute
    var cells: [[TableCell]]?
}

/// One cell of a table object — exactly the tx-object text fields (no geometry:
/// the cell's box comes from the table's cols/rows grid). All optional so older
/// files and sparse cells decode; defaults mirror a new tx object at render time.
public struct TableCell: Codable, Hashable {
    var mode: String?       // "static" | "field" | "formula" (nil → inferred)
    var text: String?       // static-mode literal text
    var field: String?      // field-mode column key, e.g. "Connector"
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
    var autoScale: Bool?    // shrink text to fit the cell width; `fs` is the max size
    var sized: Bool?        // one-time first-value auto-size already applied (designer
                            // bookkeeping; must round-trip so re-saving a template
                            // never re-triggers the sizing)
    var rs: Int?            // merged-region row span — anchor (top-left) cell only;
                            // nil/1 = unmerged. Covered cells keep their objects but
                            // render nothing (coverage is derived, never stored).
    var cs: Int?            // merged-region column span; same rules as `rs`
}

/// A saved VectorLabel template, matching .vlt.json exactly.
public struct VLTemplate: Codable, Identifiable, Hashable {
    public var id: String = UUID().uuidString  // String so HTML-saved IDs like "st1" decode correctly
    public var version: Int = 1
    public var name: String
    public var specN: String       // Brady part number e.g. "BM-32-427"
    public var objs: [TemplateObject]
    /// For CONTINUOUS supplies only: the user-chosen printed label length in
    /// inches (along the feed). nil/0 for die-cut supplies, which use the catalog's
    /// fixed printable height. Optional so older die-cut templates decode unchanged.
    public var labelLengthInches: Double? = nil
    /// For CONTINUOUS supplies only: 90 if the user rotated the design canvas to
    /// landscape (the renderer rotates the printed raster to match), else 0/nil.
    /// Optional so older templates decode unchanged. #14.
    public var canvasRot: Int? = nil

    /// The catalog Supply.id (UUID string) this design was created against. The
    /// supply catalog is user-editable, so we save the stable id (not just the part
    /// number) to re-resolve the supply on load. Optional — older files have none.
    public var supplyID: String? = nil
    /// A snapshot of the supply's geometry at save time. If the supply is later
    /// removed from the catalog, the canvas keeps THIS size until a new supply is
    /// picked (the catalog can no longer provide the geometry). Optional.
    public var supplyGeometry: SupplyGeometry? = nil

    /// Resolve the label size from the catalog by part number; if the supply was
    /// removed, fall back to the saved geometry snapshot so the canvas size is kept.
    public var labelSize: BradyLabelSize? {
        if let s = BradyCatalog.size(forPartNumber: specN) { return s }
        if let g = supplyGeometry {
            return BradyLabelSize(partNumber: specN, widthInches: g.widthInches, heightInches: g.heightInches,
                                  type: g.isContinuous ? .continuous : .dieCut)
        }
        return nil
    }

    /// The printable height (inches) used for rendering: the catalog's fixed value
    /// for die-cut supplies, or the user-set `labelLengthInches` for continuous
    /// supplies (falling back to the catalog default when none was set).
    public var effectivePrintableHeightInches: Double? {
        guard let size = labelSize else { return nil }
        if BradyCatalog.isContinuous(forPartNumber: specN),
           let len = labelLengthInches, len > 0 {
            return len
        }
        // Ghost supply (removed from the catalog): use the saved printable height.
        if BradyCatalog.size(forPartNumber: specN) == nil, let g = supplyGeometry {
            if g.isContinuous, let len = labelLengthInches, len > 0 { return len }
            return g.printableHeightInches
        }
        return size.printableHeightInches
    }
}

/// A snapshot of a supply's geometry, saved into a template/custom document so the
/// canvas size survives the (now editable) supply being removed from the catalog.
public struct SupplyGeometry: Codable, Hashable {
    public var widthInches: Double
    public var heightInches: Double
    public var printableWidthInches: Double
    public var printableHeightInches: Double
    public var isContinuous: Bool
    public init(widthInches: Double, heightInches: Double, printableWidthInches: Double,
                printableHeightInches: Double, isContinuous: Bool) {
        self.widthInches = widthInches; self.heightInches = heightInches
        self.printableWidthInches = printableWidthInches; self.printableHeightInches = printableHeightInches
        self.isContinuous = isContinuous
    }
}

// MARK: – TemplateStore

/// Loads and saves VectorLabel template files from ~/Documents/VectorLabel/Templates/.
///
/// As of Phase 4 templates are written as ".vltmp" (the registered VectorLabel
/// template document type — still JSON, the same VLTemplate encoding). Legacy
/// ".vlt.json" / ".json" files are still READ, and migrated to a ".vltmp" copy on
/// load so double-clicking and Finder integration work for older saves too.
@MainActor
public final class TemplateStore: ObservableObject {

    public static let shared = TemplateStore()

    /// The file extension written for new/saved templates (no leading dot).
    public nonisolated static let templateExtension = "vltmp"
    /// Extensions read as templates, in priority order (newest format first).
    nonisolated static let readableTemplateSuffixes = [".vltmp", ".vlt.json", ".json"]

    @Published public private(set) var templates: [VLTemplate] = []

    private var folderURL: URL { AppSettings.shared.templatesFolderURL }

    private init() { reload() }

    // MARK: – Public API

    public func reload() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var seenIDs = Set<String>()
        var result: [VLTemplate] = []

        let templateFiles = contents.filter { Self.isTemplateFile($0) }
        // The template id (NOT the filename stem) is the dedup key: a legacy
        // ".vlt.json"/".json" file is a migration SOURCE only when a ".vltmp"
        // already holds the SAME id. Keying by stem (the pre-fix behaviour) lost a
        // template whenever two legacy files shared a stem but had different ids —
        // the second collapsed into the first's migrated ".vltmp". Map every
        // already-present ".vltmp" id so we can recognise an already-migrated
        // legacy file, and track ".vltmp" stems so migration picks a free filename.
        var vltmpIDs = Set<String>()
        var usedVLTMPStems = Set<String>()
        for url in templateFiles where Self.isVLTMP(url) {
            usedVLTMPStems.insert(Self.stem(url))
            if let data = try? Data(contentsOf: url),
               let t = try? decoder.decode(VLTemplate.self, from: data) {
                vltmpIDs.insert(t.id)
            }
        }

        for url in templateFiles
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fnameStem = Self.stem(url)
            guard let data = try? Data(contentsOf: url),
                  var tpl = try? decoder.decode(VLTemplate.self, from: data)
            else { continue }
            // Skip a legacy file whose id already lives in a ".vltmp" — it's that
            // template's migration source (the legacy file stays on disk untouched).
            if !Self.isVLTMP(url), vltmpIDs.contains(tpl.id) { continue }
            // The filename is the display name (so renaming a file on disk
            // updates the name everywhere). Strip the known template suffixes.
            let fname = fnameStem
            if !fname.isEmpty { tpl.name = fname }
            else if tpl.name.isEmpty { tpl.name = url.deletingPathExtension().lastPathComponent }
            // De-duplicate ids: legacy "Save As" copies could share an id, which
            // breaks identifying templates. Give any collision a fresh id and
            // rewrite the file so the data is permanently clean.
            if seenIDs.contains(tpl.id) {
                tpl.id = UUID().uuidString
                if let newData = try? encoder.encode(tpl) {
                    try? newData.write(to: url, options: .atomic)
                }
            }
            seenIDs.insert(tpl.id)
            // Migrate legacy ".vlt.json"/".json" to a ".vltmp" copy so Finder
            // integration applies to old saves too. Disambiguate the filename on a
            // stem collision with a DIFFERENT id (same pattern as save()) so two
            // legacy files sharing a stem don't clobber each other into one ".vltmp".
            if !Self.isVLTMP(url) {
                let base = fname.isEmpty ? "template" : fname
                var targetStem = base
                var n = 2
                while usedVLTMPStems.contains(targetStem) {
                    targetStem = "\(base)-\(n)"; n += 1
                }
                let target = folderURL.appendingPathComponent("\(targetStem).\(Self.templateExtension)")
                if !fm.fileExists(atPath: target.path),
                   let migrated = try? encoder.encode(tpl) {
                    try? migrated.write(to: target, options: .atomic)
                    usedVLTMPStems.insert(targetStem)
                    vltmpIDs.insert(tpl.id)
                }
            }
            result.append(tpl)
        }
        templates = result
    }

    /// True if `url` is a readable template file (`.vltmp`, legacy `.vlt.json`, or
    /// a bare `.json`).
    public nonisolated static func isTemplateFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return readableTemplateSuffixes.contains { name.hasSuffix($0) }
    }

    /// True if `url` already uses the new ".vltmp" extension.
    nonisolated static func isVLTMP(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == templateExtension
    }

    /// The display stem of a template file: the last path component with the known
    /// template suffix (`.vltmp` / `.vlt.json` / `.json`) stripped.
    nonisolated static func stem(_ url: URL) -> String {
        var fname = url.lastPathComponent
        for ext in readableTemplateSuffixes where fname.lowercased().hasSuffix(ext) {
            fname = String(fname.dropLast(ext.count)); break
        }
        return fname
    }

    /// Decode a `VLTemplate` from a file at `url` (e.g. a `.vltmp` double-clicked in
    /// Finder). The file's stem becomes the template name, matching `reload()`.
    /// Returns nil if the file can't be read or isn't a valid template.
    public nonisolated static func loadTemplate(from url: URL) -> VLTemplate? {
        guard let data = try? Data(contentsOf: url),
              var tpl = try? JSONDecoder().decode(VLTemplate.self, from: data)
        else { return nil }
        let s = stem(url)
        if !s.isEmpty { tpl.name = s }
        else if tpl.name.isEmpty { tpl.name = url.deletingPathExtension().lastPathComponent }
        return tpl
    }

    /// Decode a template from a JS editor payload ({id?, name, specN, objs}) and
    /// persist it. VLTemplate's synthesized Codable ignores property defaults, so
    /// id/version are filled in when the payload omits them.
    @discardableResult
    public func save(fromPayload payloadAny: Any?) -> Bool {
        guard var dict = payloadAny as? [String: Any] else { return false }
        if dict["id"] == nil { dict["id"] = UUID().uuidString }
        if dict["version"] == nil { dict["version"] = 1 }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var tpl = try? JSONDecoder().decode(VLTemplate.self, from: data)
        else {
            print("[TemplateStore] save(fromPayload:) could not decode payload")
            return false
        }
        if tpl.name.isEmpty { tpl.name = "Untitled Template" }
        do { try save(tpl); return true }
        catch { print("[TemplateStore] save failed: \(error)"); return false }
    }

    public func save(_ template: VLTemplate) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let safe = template.name
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " _-")).inverted)
            .joined(separator: "_")
        let base = safe.isEmpty ? "template" : safe
        // Different names can sanitize to the same filename (e.g. "A/B" and "A:B"
        // both → "A_B"). Don't silently overwrite a DIFFERENT template — pick a free
        // name. Re-saving the same template (same id) still overwrites its own file.
        // New saves write ".vltmp" (Phase 4); a legacy ".vlt.json" with the same
        // stem is its migration source and is left in place.
        var filename = base
        var url = folderURL.appendingPathComponent("\(filename).\(Self.templateExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let existing = try? JSONDecoder().decode(VLTemplate.self, from: data),
              existing.id != template.id {
            filename = "\(base)-\(n)"; n += 1
            url = folderURL.appendingPathComponent("\(filename).\(Self.templateExtension)")
        }
        let data = try JSONEncoder().encode(template)
        try data.write(to: url, options: .atomic)
        reload()
    }

    public func delete(_ template: VLTemplate) throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return }
        // Remove every backing file for this template id — the ".vltmp" and any
        // legacy ".vlt.json"/".json" copy that shares the id — so a deleted
        // template doesn't reappear from a stale legacy file on the next reload.
        for url in contents where Self.isTemplateFile(url) {
            if let data = try? Data(contentsOf: url),
               let t = try? JSONDecoder().decode(VLTemplate.self, from: data),
               t.id == template.id {
                try fm.removeItem(at: url)
            }
        }
        reload()
    }
}
