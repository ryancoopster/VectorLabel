import Foundation

/// Persistent list of network (TCP) printers — manually added by IP or found by a
/// subnet scan. Backed by `UserDefaults` (entries are "name|model|host", legacy
/// "name|host" still read); lives in Core so
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

    /// Parsed entries. Format per item: "name|model|host" (current) or legacy
    /// "name|host". Host is always the LAST field, so both forms parse; model defaults
    /// to M611. (host required; name/model optional.)
    public static func list() -> [Entry] {
        raw().compactMap { item in
            let parts = item.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard let host = parts.last, !host.isEmpty else { return nil }
            let name = (parts.count > 1 && !parts[0].isEmpty) ? parts[0] : "Brady M611 (\(host))"
            let model = (parts.count >= 3 && !parts[1].isEmpty) ? parts[1] : "M611"
            return Entry(name: name, host: host, model: model)
        }
    }

    /// Add (or update the name/model of) a printer, deduped by host. Returns false if
    /// `host` is empty. Persists the model so a non-M611 network printer round-trips
    /// (previously the model was dropped and every loaded entry became M611).
    @discardableResult
    public static func add(name: String, host: String, model: String = "M611") -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return false }
        // "|" is the field delimiter, so strip it from name/model or it would corrupt
        // parsing (shift the host field) for a user-entered name containing a pipe.
        let nm = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: " ")
        let m = model.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "")
        var items = raw().filter { hostOf($0) != h }
        items.append("\(nm)|\(m.isEmpty ? "M611" : m)|\(h)")
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
        // Host is the last field in both "name|model|host" and legacy "name|host".
        String(item.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).last ?? "")
    }
}
