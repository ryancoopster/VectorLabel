import Foundation

// MARK: – Custom label document (".vlcus")
//
// Phase 4 defines the ".vlcus" document — the saved state of a VectorLabel Custom
// Designer session. Unlike a template (".vltmp", which is just the canvas), a
// custom-label document is self-contained for one-off label runs: it embeds the
// canvas, a snapshot of the bound data (rows + column headers), the data-source
// path it was bound from, and the size/length/cut print settings.
//
// It is JSON, like ".vltmp", so it's human-inspectable and conforms to public.json.
// Double-clicking one in Finder opens the Custom Designer (see the .app open
// handler + the UTI registration in package-suite.sh).

/// One saved Custom Designer session, persisted as a ".vlcus" JSON file.
public struct CustomLabelDocument: Codable {

    /// Document schema version, so older readers can detect newer files.
    public var schema: Int

    /// File-format version of the embedded canvas (mirrors VLTemplate.version).
    public var version: Int

    /// Display name of the custom label (the file stem on disk).
    public var name: String

    /// Brady part number / label spec the canvas is laid out for (e.g. "BM-32-427").
    /// Mirrors VLTemplate.specN; the canvas below repeats it so the template is
    /// directly renderable on its own.
    public var specN: String

    /// The canvas: the same VLTemplate the Template Designer edits (objects + spec).
    public var template: VLTemplate

    // MARK: – Embedded data snapshot (Phase 3 bound data)

    /// Column names in display order, as bound in the designer.
    public var headers: [String]

    /// One row per label — the embedded snapshot of the bound data at save time,
    /// so the document prints exactly what the user saw even if the source file
    /// later changes or is missing. Each row maps column name → cell value.
    public var rows: [[String: String]]

    /// The data-source file the rows were read from (absolute path), if any, so the
    /// designer can offer to refresh from the live file. Empty ⇒ no bound source.
    public var dataSourcePath: String

    /// Whether the source file's first row supplied the column headers (xlsx; CSV
    /// always has a header row). Preserved so a refresh re-reads identically.
    public var dataSourceHeaderRow: Bool

    // MARK: – Print settings

    /// Label size / part number override for printing. Empty ⇒ use `specN`.
    public var labelSize: String

    /// Continuous-stock label length in inches (0 ⇒ use the die-cut/spec length).
    public var labelLengthInches: Double

    /// When to actuate the cutter for this document's job.
    public var cutMode: CutMode

    /// Number of copies per label row (default 1).
    public var copies: Int

    public init(name: String,
                template: VLTemplate,
                headers: [String] = [],
                rows: [[String: String]] = [],
                dataSourcePath: String = "",
                dataSourceHeaderRow: Bool = true,
                labelSize: String = "",
                labelLengthInches: Double = 0,
                cutMode: CutMode = .never,
                copies: Int = 1) {
        self.schema = 1
        self.version = template.version
        self.name = name
        self.specN = template.specN
        self.template = template
        self.headers = headers
        self.rows = rows
        self.dataSourcePath = dataSourcePath
        self.dataSourceHeaderRow = dataSourceHeaderRow
        self.labelSize = labelSize
        self.labelLengthInches = labelLengthInches
        self.cutMode = cutMode
        self.copies = copies
    }

    // MARK: – Convenience

    /// The embedded rows as `WireRecord`s (one per label) for the print path. The
    /// renderer accesses fields by column name; `_Side`/`Number` are mapped to the
    /// record's side/wireID the same way the live data-binding path does.
    public var records: [WireRecord] {
        rows.map { fields in
            WireRecord(side: fields["_Side"] ?? "",
                       wireID: fields["Number"] ?? "",
                       fields: fields)
        }
    }

    /// The data-source URL, if a non-empty path is stored.
    public var dataSourceURL: URL? {
        dataSourcePath.isEmpty ? nil : URL(fileURLWithPath: dataSourcePath)
    }
}

// MARK: – CustomLabelStore (load / save .vlcus)

/// File I/O for ".vlcus" documents. Save targets the Documents/VectorLabel/Custom/
/// folder by default; load reads any URL (e.g. a Finder double-click). Pure Core —
/// no UI, no EngineKit.
public enum CustomLabelStore {

    /// The ".vlcus" extension written for custom-label documents (no leading dot).
    public static let fileExtension = "vlcus"

    /// Default folder for saved custom labels: ~/Documents/VectorLabel/Custom/.
    public static var defaultFolderURL: URL {
        AppSettings.shared.watchFolderURL.appendingPathComponent("Custom")
    }

    /// Decode a `.vlcus` document from `url`. The file stem overrides the stored
    /// name (so renaming the file renames the label). Returns nil on failure.
    /// The highest document `schema` this build understands. A `.vlcus` declaring a
    /// newer schema is rejected (not silently mis-decoded against unknown field semantics).
    public static let currentSchema = 1

    public static func load(from url: URL) -> CustomLabelDocument? {
        guard let data = try? Data(contentsOf: url),
              var doc = try? JSONDecoder().decode(CustomLabelDocument.self, from: data),
              doc.schema <= currentSchema
        else { return nil }
        let stem = stem(url)
        if !stem.isEmpty {
            doc.name = stem
            doc.template.name = stem
        }
        return doc
    }

    /// Write `doc` to `url` as pretty-printed JSON (atomic).
    public static func save(_ doc: CustomLabelDocument, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: url, options: .atomic)
    }

    /// Write `doc` into the default Custom/ folder, deriving a safe filename from its
    /// name (collision-suffixed). Returns the URL written.
    @discardableResult
    public static func save(_ doc: CustomLabelDocument) throws -> URL {
        let folder = defaultFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = doc.name
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " _-")).inverted)
            .joined(separator: "_")
        let base = safe.isEmpty ? "custom-label" : safe
        var filename = base
        var url = folder.appendingPathComponent("\(filename).\(fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            filename = "\(base)-\(n)"; n += 1
            url = folder.appendingPathComponent("\(filename).\(fileExtension)")
        }
        try save(doc, to: url)
        return url
    }

    /// True if `url` is a `.vlcus` file.
    public static func isCustomLabelFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// The display stem of a `.vlcus` file (extension stripped).
    public static func stem(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".\(fileExtension)") {
            return String(name.dropLast(fileExtension.count + 1))
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
