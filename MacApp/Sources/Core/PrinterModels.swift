import Foundation
import Combine

// MARK: – Printer-model registry
//
// The set of printer models the app knows about, each with its USB IDs. Seeded with
// the Brady M610 / M611. Editable in Engine ▸ Preferences ▸ Printers ▸ Printer
// Models…, and referenced by the supply catalog (a SupplyGroup's `printerModels` are
// names from this list). Persisted as JSON in Application Support (beta-aware).

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
    public init(name: String, usbIDs: [PrinterUSBID], id: UUID = UUID()) {
        self.id = id; self.name = name; self.usbIDs = usbIDs
    }
    private enum CodingKeys: String, CodingKey { case id, name, usbIDs }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        usbIDs = (try? c.decode([PrinterUSBID].self, forKey: .usbIDs)) ?? []
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
    /// 0x010B confirmed, M611 0x010C unverified — see BradyUSB).
    public static func makeDefault() -> PrinterModelList {
        PrinterModelList(version: 1, models: [
            PrinterModel(name: "M611", usbIDs: [PrinterUSBID(vendorID: "0E2E", productID: "010C")]),
            PrinterModel(name: "M610", usbIDs: [PrinterUSBID(vendorID: "0E2E", productID: "010B")]),
        ])
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
        let loaded = Self.loadFromDisk() ?? PrinterModelList.makeDefault()
        list = loaded
        Self.setSnapshot(loaded)
    }

    private static func loadFromDisk() -> PrinterModelList? {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PrinterModelList.self, from: data),
              !decoded.models.isEmpty
        else { return nil }
        return decoded
    }

    public func save() {
        Self.setSnapshot(list)
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
}
