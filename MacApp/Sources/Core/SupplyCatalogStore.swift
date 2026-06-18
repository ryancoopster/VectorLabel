import Foundation
import Combine

// MARK: – Supply catalog persistence + access
//
// Persists the editable catalog as JSON in Application Support (beta-aware) and
// exposes it two ways:
//   • `shared` — an ObservableObject for the Engine's Preferences editor (main thread).
//   • `snapshot` — a thread-safe immutable value the BradyCatalog façade reads from
//     any thread (the print/render path runs off-main), and the source for the JS
//     `window.__VL_CATALOG__` injection.
//
// Each app process has its own store; it loads the file at launch. The Engine writes
// edits; the designers read the file when they open, so catalog edits take effect on
// the next designer launch.

public final class SupplyCatalogStore: ObservableObject {

    public static let shared = SupplyCatalogStore()

    /// The live catalog (edited by Preferences). Mutate on the main thread.
    @Published public var catalog: SupplyCatalog {
        didSet { Self.setSnapshot(catalog); scheduleAutosave() }
    }

    /// Coalesce rapid edits (typing) into one disk write shortly after.
    private var autosaveWork: DispatchWorkItem?
    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeToDisk() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private static var fileURL: URL {
        let dir = AppEnvironment.supportRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SupplyCatalog.json")
    }

    private init() {
        let loaded = Self.loadFromDisk() ?? SupplyCatalog.makeDefault()
        catalog = loaded
        Self.setSnapshot(loaded)
    }

    // MARK: – Disk

    /// The on-disk catalog file, exposed so the designer/print apps can poll the
    /// Engine's edits (they run in separate processes from the editor).
    public static var catalogFileURL: URL { fileURL }

    /// Re-read the catalog from disk into the thread-safe snapshot. Used by the
    /// modules polling for Engine edits. Returns true when the catalog changed.
    @discardableResult
    public static func reloadSnapshotFromDisk() -> Bool {
        guard let loaded = loadFromDisk(), loaded != snapshot else { return false }
        setSnapshot(loaded)
        return true
    }

    private static func loadFromDisk() -> SupplyCatalog? {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(SupplyCatalog.self, from: data),
              !decoded.groups.isEmpty
        else { return nil }
        return decoded
    }

    /// Persist the current catalog to disk now (and refresh the snapshot).
    public func save() { autosaveWork?.cancel(); writeToDisk() }

    private func writeToDisk() {
        Self.setSnapshot(catalog)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(catalog) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// Replace the catalog and persist.
    public func replace(with newCatalog: SupplyCatalog) {
        catalog = newCatalog
        save()
    }

    /// Reset to the factory default and persist.
    public func restoreDefaults() {
        replace(with: SupplyCatalog.makeDefault())
    }

    // MARK: – Thread-safe snapshot (for BradyCatalog + injection, any thread)

    private static let snapLock = NSLock()
    private static var _snapshot: SupplyCatalog?

    private static func setSnapshot(_ c: SupplyCatalog) {
        snapLock.lock(); _snapshot = c; snapLock.unlock()
    }

    /// The current catalog as an immutable value, safe to read from any thread.
    /// Lazily loads from disk (or the factory default) on first access.
    public static var snapshot: SupplyCatalog {
        snapLock.lock()
        if let s = _snapshot { snapLock.unlock(); return s }
        snapLock.unlock()
        let loaded = loadFromDisk() ?? SupplyCatalog.makeDefault()
        setSnapshot(loaded)
        return loaded
    }

    // MARK: – Web projection (window.__VL_CATALOG__)

    /// JSON string injected into the designer / print web UIs for `model` (the
    /// connected printer's model). Shape:
    ///   { groupName, categories:[name…], bl:[ {n,cat,ty,tw,th,pw,ph,mt,lm,
    ///       parts:[{pn,qty,lenFt,rot,mat,url}] } ] }
    /// `bl` is one entry per supply (n = its primary part number), preserving the
    /// field names the JS already uses (tw/th/pw/ph/n/ty/mt/lm).
    public static func webCatalogJSON(forModel model: String) -> String {
        let cat = snapshot
        guard let group = cat.group(forModel: model) ?? cat.groups.first else { return "null" }
        // JSONSerialization throws (and we'd crash on `!`) on a non-finite Double,
        // which the editor's numeric fields can produce — clamp to a finite value.
        func fin(_ v: Double) -> Double { v.isFinite ? v : 0 }
        var bl: [[String: Any]] = []
        var categories: [String] = []
        for category in group.categories {
            categories.append(category.name)
            for s in category.supplies {
                let parts: [[String: Any]] = s.parts.map { p in
                    var d: [String: Any] = ["pn": p.partNumber, "rot": p.rotate90,
                                            "mat": p.materialLabel, "url": p.overrideURL]
                    if let q = p.quantityPerRoll { d["qty"] = q }
                    if let l = p.rollLengthFeet { d["lenFt"] = fin(l) }
                    return d
                }
                bl.append([
                    "id": s.id.uuidString,
                    "n": s.primaryPartNumber,
                    "name": s.name,
                    "cat": category.name,
                    "ty": s.kind == .continuous ? "continuous" : "dieCut",
                    "tw": fin(s.widthInches), "th": fin(s.heightInches),
                    "pw": fin(s.printableWidthInches), "ph": fin(s.printableHeightInches),
                    "mt": s.materialFamily, "lm": s.selfLaminating,
                    "parts": parts,
                ])
            }
        }
        let obj: [String: Any] = ["groupName": group.name, "categories": categories, "bl": bl]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "null" }
        return str
    }
}
