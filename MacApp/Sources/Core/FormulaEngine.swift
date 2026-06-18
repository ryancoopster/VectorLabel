import Foundation

/// Swift port of the formula engine from VectorLabelDesigner.html.
///
/// Evaluates Excel-style formulas against a WireRecord's field map.
/// Supported: IF, LEFT, RIGHT, MID, LEN, UPPER, LOWER, TRIM,
///            string literals, & concatenation, <> / = comparisons.
///
/// Example:  =IF(Number<>"",Number&" - "&Cable,Cable)
public enum FormulaEngine {

    // MARK: – Public entry point

    /// Evaluate `formula` against `fields`.
    /// - If the formula doesn't start with `=`, returns it as a literal.
    /// - Returns empty string on parse/eval error.
    public static func evaluate(_ formula: String, fields: [String: String]) -> String {
        guard formula.hasPrefix("=") else { return formula }
        let expr = String(formula.dropFirst())
        let tokens = tokenize(expr)
        do {
            var pos = 0
            let result = try parseExpr(tokens: tokens, pos: &pos, fields: fields)
            return jsString(result)
        } catch {
            return ""
        }
    }

    /// Stringify a value the way JavaScript's `String()` does, so numbers match the
    /// preview: an integral Double prints without a decimal ("2", not "2.0"), and a
    /// Bool prints "true"/"false".
    static func jsString(_ v: Any?) -> String {
        switch v {
        case nil:             return ""
        case let b as Bool:   return b ? "true" : "false"
        case let i as Int:    return String(i)
        case let d as Double: return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case let s as String: return s
        default:              return "\(v!)"
        }
    }

    // MARK: – Tokeniser

    private enum Token {
        case string(String)
        case number(Double)
        case ident(String)
        case amp           // &
        case eq            // =
        case ne            // <>
        case comma         // ,
        case lparen        // (
        case rparen        // )
    }

    private static func tokenize(_ expr: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(expr)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c.isWhitespace { i += 1; continue }

            if c == "\"" {
                var s = ""; i += 1
                while i < chars.count && chars[i] != "\"" { s.append(chars[i]); i += 1 }
                i += 1   // closing quote
                tokens.append(.string(s))
                continue
            }

            if c.isNumber || (c == "-" && i + 1 < chars.count && chars[i+1].isNumber) {
                var n = String(c); i += 1
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") { n.append(chars[i]); i += 1 }
                tokens.append(.number(Double(n) ?? 0))
                continue
            }

            if c == "&" { tokens.append(.amp); i += 1; continue }
            if c == "," { tokens.append(.comma); i += 1; continue }
            if c == "(" { tokens.append(.lparen); i += 1; continue }
            if c == ")" { tokens.append(.rparen); i += 1; continue }

            if c == "<" && i + 1 < chars.count && chars[i+1] == ">" {
                tokens.append(.ne); i += 2; continue
            }
            if c == "=" { tokens.append(.eq); i += 1; continue }

            if c.isLetter || c == "_" {
                var name = String(c); i += 1
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == " ") {
                    name.append(chars[i]); i += 1
                }
                tokens.append(.ident(name.trimmingCharacters(in: .whitespaces)))
                continue
            }

            i += 1  // skip unknown characters
        }

        return tokens
    }

    // MARK: – Parser (recursive descent)

    private enum ParseError: Error { case unexpected }

    /// Friendly-name → column-key map. MUST stay identical to the `FD` tables in
    /// VectorLabelDesigner.html / VectorLabelPrint.html so a formula like
    /// `=Cable Name` resolves the same in the preview and on the printed label.
    static let fieldMap: [(friendly: String, column: String)] = [
        ("Number", "Number"), ("Cable Name", "Cable"), ("Signal", "Signal"),
        ("Connector", "Connector"), ("Device Name", "Device_Name"), ("Device Tag", "Device_Tag"),
        ("Socket Name", "Socket_Name"), ("Socket Tag", "Socket_Tag"),
        ("Other Device", "Other_Device"), ("Other Socket", "Other_Socket"),
        ("Other Connector", "Other_Connector"), ("Rack", "Rack"), ("Room", "Room"),
        ("Rack U", "RackU"), ("Side", "_Side"), ("Cable Type", "Cable_Type"), ("Cable Length", "CableLength"),
    ]

    /// Resolve an identifier the way the JS engine's `rv()` does (so preview == print):
    /// exact column match, then the friendly-name table (case-insensitive), then a
    /// case-insensitive column match, and finally — for an UNKNOWN identifier — the
    /// raw name itself (matching the JS fallback; a typo shows the name, not blank).
    private static func resolveField(_ name: String, fields: [String: String]) -> String {
        if let v = fields[name] { return v }
        let lower = name.lowercased()
        if let m = fieldMap.first(where: { $0.friendly.lowercased() == lower || $0.column.lowercased() == lower }) {
            return fields[m.column] ?? ""
        }
        if let v = fields.first(where: { $0.key.lowercased() == lower })?.value { return v }
        return name
    }

    /// Top-level expression = concatenation. Comparison is NOT handled here; it
    /// fires only immediately after a bare field identifier (in parsePrimary),
    /// exactly matching the JS engine's `pe()`/`pp()` so preview == print.
    private static func parseExpr(tokens: [Token], pos: inout Int, fields: [String: String]) throws -> Any? {
        try parseConcat(tokens: tokens, pos: &pos, fields: fields)
    }

    /// Parses: primary (&  primary)*
    private static func parseConcat(tokens: [Token], pos: inout Int, fields: [String: String]) throws -> Any? {
        var left = try parsePrimary(tokens: tokens, pos: &pos, fields: fields)

        while pos < tokens.count {
            guard case .amp = tokens[pos] else { break }
            pos += 1
            let right = try parsePrimary(tokens: tokens, pos: &pos, fields: fields)
            left = jsString(left) + jsString(right)
        }
        return left
    }

    private static func parsePrimary(tokens: [Token], pos: inout Int, fields: [String: String]) throws -> Any? {
        guard pos < tokens.count else { return "" }

        switch tokens[pos] {

        case .string(let s):
            pos += 1; return s

        case .number(let n):
            pos += 1; return n

        case .lparen:
            pos += 1
            let v = try parseExpr(tokens: tokens, pos: &pos, fields: fields)
            if pos < tokens.count, case .rparen = tokens[pos] { pos += 1 }
            return v

        case .ident(let name):
            pos += 1

            // Function call?
            if pos < tokens.count, case .lparen = tokens[pos] {
                pos += 1  // consume (
                var args: [Any?] = []
                while pos < tokens.count {
                    if case .rparen = tokens[pos] { pos += 1; break }
                    args.append(try parseExpr(tokens: tokens, pos: &pos, fields: fields))
                    if pos < tokens.count, case .comma = tokens[pos] { pos += 1 }
                }
                return evalFunction(name.uppercased(), args: args, fields: fields)
            }

            // Comparison fires only directly after a bare identifier, with a single
            // primary right operand and STRING equality — matching the JS engine.
            if pos < tokens.count {
                let isNE: Bool = { if case .ne = tokens[pos] { return true }; return false }()
                let isEQ: Bool = { if case .eq = tokens[pos] { return true }; return false }()
                if isNE || isEQ {
                    pos += 1
                    let right = try parsePrimary(tokens: tokens, pos: &pos, fields: fields)
                    let equal = resolveField(name, fields: fields) == jsString(right)
                    return isNE ? !equal : equal
                }
            }

            // Plain field reference.
            return resolveField(name, fields: fields)

        case .ne, .eq, .amp, .comma, .rparen:
            return ""
        }
    }

    // MARK: – Built-in functions

    private static func evalFunction(_ name: String, args: [Any?], fields: [String: String]) -> Any? {
        func str(_ v: Any?) -> String { jsString(v) }
        func num(_ v: Any?) -> Int {
            // Numeric literals tokenise as Double, so "3.0" would fail Int(_:).
            // Clamp rather than force-convert: a huge literal such as
            // =LEFT("x",9999999999999999999) overflows Int and would trap at
            // print time (the JS preview clamps it silently via String.slice).
            func clampToInt(_ d: Double) -> Int {
                guard d.isFinite else { return 0 }
                if d >= Double(Int.max) { return Int.max }
                if d <= Double(Int.min) { return Int.min }
                return Int(d)
            }
            if let d = v as? Double { return clampToInt(d) }
            if let i = v as? Int    { return i }
            let s = str(v)
            if let i = Int(s) { return i }
            guard let d2 = Double(s), d2.isFinite else { return 0 }
            return clampToInt(d2)
        }
        // JS truthiness (so IF() branches the same in preview and print): a bool is
        // itself; a number is true when non-zero; ANY non-empty string is true —
        // including "0" and "false" (a string field value of "0" is truthy in JS).
        func bool(_ v: Any?) -> Bool {
            if let b = v as? Bool { return b }
            if let d = v as? Double { return d != 0 }
            if let i = v as? Int { return i != 0 }
            return !str(v).isEmpty
        }

        // Helper to safely pull an element from [Any?] without Any?? double-optional
        func arg(_ i: Int) -> Any? { i < args.count ? args[i] : nil }

        switch name {
        case "IF":
            return bool(arg(0)) ? arg(1) ?? "" : arg(2) ?? ""
        case "LEFT":
            // Omitted count defaults to 1 (Excel); an explicit 0 yields "".
            let s = str(arg(0)); let n = arg(1) == nil ? 1 : num(arg(1))
            return String(s.prefix(max(0, n)))
        case "RIGHT":
            let s = str(arg(0)); let n = arg(1) == nil ? 1 : num(arg(1))
            return String(s.suffix(max(0, n)))
        case "MID":
            let s = str(arg(0))
            let start = max(0, num(arg(1)) - 1)
            let length = max(0, num(arg(2)))
            guard start < s.count else { return "" }
            let from = s.index(s.startIndex, offsetBy: start)
            let to   = s.index(from, offsetBy: min(length, s.count - start))
            return String(s[from..<to])
        case "LEN":
            return str(arg(0)).count
        case "UPPER":
            return str(arg(0)).uppercased()
        case "LOWER":
            return str(arg(0)).lowercased()
        case "TRIM":
            return str(arg(0)).trimmingCharacters(in: .whitespaces)
        default:
            return ""
        }
    }
}
