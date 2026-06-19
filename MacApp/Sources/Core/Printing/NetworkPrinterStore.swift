import Foundation

/// Persistent list of network (TCP) printers — manually added by IP or found by a
/// subnet scan. Backed by `UserDefaults` (entries are "name|host"); lives in Core so
/// both the M611 module (reads it to enumerate) and the Engine UI (adds/removes) can
/// use it without a cross-module dependency.
public enum NetworkPrinterStore {
    public static let defaultsKey = "vlNetworkPrinters"

    public struct Entry: Equatable {
        public let name: String
        public let host: String
        public let model: String
        public init(name: String, host: String, model: String = "M611") {
            self.name = name; self.host = host; self.model = model
        }
    }

    private static func raw() -> [String] { UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }
    private static func setRaw(_ v: [String]) { UserDefaults.standard.set(v, forKey: defaultsKey) }

    /// Parsed entries. Format per item: "name|host" (host required; name optional).
    public static func list() -> [Entry] {
        raw().compactMap { item in
            let parts = item.split(separator: "|", maxSplits: 1).map(String.init)
            guard let host = parts.last, !host.isEmpty else { return nil }
            let name = parts.count > 1 && !parts[0].isEmpty ? parts[0] : "Brady M611 (\(host))"
            return Entry(name: name, host: host)
        }
    }

    /// Add (or update the name of) a printer, deduped by host. Returns false if `host`
    /// is empty.
    @discardableResult
    public static func add(name: String, host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return false }
        let nm = name.trimmingCharacters(in: .whitespaces)
        var items = raw().filter { hostOf($0) != h }
        items.append("\(nm)|\(h)")
        setRaw(items)
        return true
    }

    public static func remove(host: String) {
        setRaw(raw().filter { hostOf($0) != host })
    }

    public static func contains(host: String) -> Bool {
        raw().contains { hostOf($0) == host }
    }

    private static func hostOf(_ item: String) -> String {
        String(item.split(separator: "|", maxSplits: 1).last ?? "")
    }
}
