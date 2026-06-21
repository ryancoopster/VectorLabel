import Foundation
import Combine

// MARK: – Printer-model registry
//
// The set of printers the app knows about, each with its USB IDs + per-printer
// settings. Seeded with the Brady M610 / M611. Editable in Engine ▸ Preferences ▸
// Printers ▸ Per-Printer Settings…, and referenced by the supply catalog (a
// SupplyGroup's `printerModels` are names from this list). Persisted as JSON in
// Application Support (beta-aware).

/// A USB vendor/product id pair, stored as 4-hex-digit strings (e.g. "0E2E"/"010C").
public struct PrinterUSBID: Codable, Hashable, Identifiable {
    public var id: UUID
    public var vendorID: String
    public var productID: String
    public init(vendorID: String, productID: String, id: UUID = UUID()) {
        self.id = id; self.vendorID = vendorID.uppercased(); self.productID = productID.uppercased()
    }
    private enum CodingKeys: String, CodingKey { case id, vendorID, productID }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        vendorID = ((try? c.decode(String.self, forKey: .vendorID)) ?? "").uppercased()
        productID = ((try? c.decode(String.self, forKey: .productID)) ?? "").uppercased()
    }
    /// "0x0E2E:0x010C" form for display.
    public var display: String { "0x\(vendorID):0x\(productID)" }
}

public struct PrinterModel: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String          // e.g. "M611"
    public var usbIDs: [PrinterUSBID]
    /// Per-model print settings (built into the driver, not a global setting).
    ///
    /// `interLabelDelayMs`: pause between consecutive labels when sending one label at
    /// a time; ignored in full-job mode (there's no inter-label gap).
    /// `singleLabelPrinting`: send each label as its own print (true) vs. one batched
    /// full job (false). Single-label gives per-label progress + honors the delay; full
    /// job is one send. Together with the driver's progress capability this decides
    /// whether the menu shows live per-label progress or just "Printing".
    public var interLabelDelayMs: Int
    public var singleLabelPrinting: Bool
    /// Communication methods enabled for this printer (USB / Network / Bluetooth), all
    /// enabled by default. The Engine drives the printer only over a transport that is
    /// both enabled here and supported by the driver (see PrinterCapabilities).
    public var enabledTransports: Set<PrinterTransport>
    public init(name: String, usbIDs: [PrinterUSBID],
                interLabelDelayMs: Int = 0, singleLabelPrinting: Bool = false,
                enabledTransports: Set<PrinterTransport> = Set(PrinterTransport.allCases),
                id: UUID = UUID()) {
        self.id = id; self.name = name; self.usbIDs = usbIDs
        self.interLabelDelayMs = interLabelDelayMs
        self.singleLabelPrinting = singleLabelPrinting
        self.enabledTransports = enabledTransports
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, usbIDs, interLabelDelayMs, singleLabelPrinting, enabledTransports
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        usbIDs = (try? c.decode([PrinterUSBID].self, forKey: .usbIDs)) ?? []
        interLabelDelayMs = (try? c.decode(Int.self, forKey: .interLabelDelayMs)) ?? 0
        singleLabelPrinting = (try? c.decode(Bool.self, forKey: .singleLabelPrinting)) ?? false
        enabledTransports = (try? c.decode(Set<PrinterTransport>.self, forKey: .enabledTransports))
            ?? Set(PrinterTransport.allCases)
    }
}

public struct PrinterModelList: Codable, Hashable {
    public var version: Int
    public var models: [PrinterModel]
    public init(version: Int = 1, models: [PrinterModel]) { self.version = version; self.models = models }
    private enum CodingKeys: String, CodingKey { case version, models }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        models = (try? c.decode([PrinterModel].self, forKey: .models)) ?? []
    }

    /// Seed: the Brady wire-label printers and their USB IDs (VID 0x0E2E; M610 PID
    /// 0x010B confirmed, M611 0x010C unverified — see BradyUSB). M610 defaults to
    /// single-label printing (it reports a hardware label counter and historically
    /// printed one label at a time); the M611 defaults to one full job.
    public static func makeDefault() -> PrinterModelList {
        PrinterModelList(version: 2, models: [
            PrinterModel(name: "M611", usbIDs: [PrinterUSBID(vendorID: "0E2E", productID: "010C")],
                         interLabelDelayMs: 0, singleLabelPrinting: false),
            PrinterModel(name: "M610", usbIDs: [PrinterUSBID(vendorID: "0E2E", productID: "010B")],
                         interLabelDelayMs: 0, singleLabelPrinting: true),
        ])
    }

    /// Upgrade a pre-print-settings (v1) list: seed per-model defaults by name so an
    /// existing install keeps M610's one-label-at-a-time behavior while the M611
    /// defaults to a single full job. No-op for v2+.
    public func migrated() -> PrinterModelList {
        guard version < 2 else { return self }
        // Carry over the user's OLD global inter-label delay if they explicitly set it
        // (UserDefaults only holds the key once changed), so an upgrade doesn't silently
        // drop a value tuned to stop dropped/misprinted labels. Default 0 otherwise —
        // which restores the pre-separation M610 behavior (the old global default was
        // never actually applied to the M610 before the module split).
        let carriedDelay = max(0, (UserDefaults.standard.object(forKey: "interLabelDelayMs") as? Int) ?? 0)
        var l = self
        for i in l.models.indices {
            // Identify the M610 by its hardware PID (0x010B) OR name, so a RENAMED M610
            // entry still keeps single-label printing — its SmartCell label counter is
            // what makes per-label progress meaningful.
            let isM610 = l.models[i].name.uppercased() == "M610"
                || l.models[i].usbIDs.contains { $0.productID.uppercased() == "010B" }
            l.models[i].singleLabelPrinting = isM610
            l.models[i].interLabelDelayMs = carriedDelay
        }
        l.version = 2
        return l
    }
}

/// Persistence + access for the printer-model registry. Mirrors SupplyCatalogStore.
public final class PrinterModelStore: ObservableObject {

    public static let shared = PrinterModelStore()

    @Published public var list: PrinterModelList {
        didSet { Self.setSnapshot(list) }
    }

    private static var fileURL: URL {
        let dir = AppEnvironment.supportRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("PrinterModels.json")
    }
    public static var modelsFileURL: URL { fileURL }

    private init() {
        if let decoded = Self.decodeFile() {
            let upgraded = decoded.migrated()
            list = upgraded
            Self.setSnapshot(upgraded)
            if decoded.version < 2 { save() }   // persist the v1→v2 upgrade once
        } else {
            let def = PrinterModelList.makeDefault()
            list = def
            Self.setSnapshot(def)
        }
    }

    /// Raw decode of the on-disk file (no migration), or nil if missing/empty/undecodable.
    private static func decodeFile() -> PrinterModelList? {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PrinterModelList.self, from: data),
              !decoded.models.isEmpty
        else { return nil }
        return decoded
    }

    private static func loadFromDisk() -> PrinterModelList? { decodeFile()?.migrated() }

    public func save() {
        Self.setSnapshot(list)
        NSLog("[PrinterModelStore] save → " + list.models.map {
            "\($0.name):\($0.singleLabelPrinting ? "single" : "full")/\($0.interLabelDelayMs)ms" }.joined(separator: ", "))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(list) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    public func replace(with newList: PrinterModelList) { list = newList; save() }
    public func restoreDefaults() { replace(with: .makeDefault()) }

    @discardableResult
    public static func reloadSnapshotFromDisk() -> Bool {
        guard let loaded = loadFromDisk(), loaded != snapshot else { return false }
        setSnapshot(loaded); return true
    }

    // Thread-safe snapshot (BradyUSB model lookup runs off-main).
    private static let snapLock = NSLock()
    private static var _snapshot: PrinterModelList?
    private static func setSnapshot(_ l: PrinterModelList) { snapLock.lock(); _snapshot = l; snapLock.unlock() }
    public static var snapshot: PrinterModelList {
        snapLock.lock()
        if let s = _snapshot { snapLock.unlock(); return s }
        snapLock.unlock()
        let loaded = loadFromDisk() ?? .makeDefault()
        setSnapshot(loaded); return loaded
    }

    /// Model name for a USB product id (hex string, no 0x), or nil if not registered.
    public static func modelName(forProductID pidHex: String) -> String? {
        let p = pidHex.uppercased()
        for m in snapshot.models where m.usbIDs.contains(where: { $0.productID == p }) { return m.name }
        return nil
    }

    /// All registered model names, in order.
    public static var modelNames: [String] { snapshot.models.map { $0.name } }

    /// Per-model print settings (inter-label delay + single-label mode) resolved by
    /// model NAME. Reads the thread-safe snapshot, so it's safe off the main thread
    /// (the Engine resolves it on the per-printer device queue). Unknown model → no
    /// delay, full-job.
    public struct PrintSettings: Equatable {
        public let interLabelDelayMs: Int
        public let singleLabelPrinting: Bool
        public init(interLabelDelayMs: Int, singleLabelPrinting: Bool) {
            self.interLabelDelayMs = interLabelDelayMs
            self.singleLabelPrinting = singleLabelPrinting
        }
    }
    public static func printSettings(forName name: String) -> PrintSettings {
        if let m = snapshot.models.first(where: { $0.name == name }) {
            return PrintSettings(interLabelDelayMs: max(0, m.interLabelDelayMs),
                                 singleLabelPrinting: m.singleLabelPrinting)
        }
        return PrintSettings(interLabelDelayMs: 0, singleLabelPrinting: false)
    }

    /// Communication methods enabled for a printer, matched by model NAME or by any of
    /// `productIDs` (uppercase hex, no 0x) — mirroring the migration's name-or-PID match,
    /// so a RENAMED printer entry still resolves and its checkboxes still take effect.
    /// All methods if nothing matches. Reads the thread-safe snapshot (safe off-main).
    public static func enabledTransports(forName name: String,
                                         productIDs: Set<String> = []) -> Set<PrinterTransport> {
        let pids = Set(productIDs.map { $0.uppercased() })
        if let m = snapshot.models.first(where: {
            $0.name == name || $0.usbIDs.contains { pids.contains($0.productID.uppercased()) }
        }) { return m.enabledTransports }
        return Set(PrinterTransport.allCases)
    }
}
