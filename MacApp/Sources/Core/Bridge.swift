import Foundation

// MARK: – JSON helper

public extension String {
    /// The string wrapped in double-quotes, escaped so it is safe to splice into
    /// JavaScript source passed to `evaluateJavaScript`. Escapes the backslash,
    /// quote, and CR/LF, plus U+2028/U+2029 — JS line terminators that would
    /// otherwise let a crafted filename break out of the string literal and inject
    /// code into the privileged web view.
    var jsonQuoted: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }
}

// MARK: – WireRecord: Codable (for JS bridge)
// Records are flattened so JS can access r.Cable, r._Side, r.Number directly.

extension WireRecord: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        side   = (try? c.decode(String.self, forKey: DynamicKey("_Side"))) ?? "Source"
        wireID = (try? c.decode(String.self, forKey: DynamicKey("Number"))) ?? ""
        var f: [String: String] = [:]
        for key in c.allKeys { f[key.stringValue] = try? c.decode(String.self, forKey: key) }
        fields = f
    }
    public func encode(to encoder: Encoder) throws {
        // Flatten all fields to top level so JS sees r.Cable, r._Side etc.
        var c = encoder.container(keyedBy: DynamicKey.self)
        for (k, v) in fields { try c.encode(v, forKey: DynamicKey(k)) }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
