import Foundation

/// Swift port of the formula engine from VectorLabelDesigner.html.
///
/// Evaluates Excel-style formulas against a WireRecord's field map.
/// Supported: IF, LEFT, RIGHT, MID, LEN, UPPER, LOWER, TRIM,
///            string literals, & concatenation, <> / = comparisons.
///
/// Example:  =IF(Number<>"",Number&" - "&Cable,Cable)
enum FormulaEngine {

    // MARK: – Public entry point

    /// Evaluate `formula` against `fields`.
    /// - If the formula doesn't start with `=`, returns it as a literal.
    /// - Returns empty string on parse/eval error.
    static func evaluate(_ formula: String, fields: [String: String]) -> String {
        guard formula.hasPrefix("=") else { return formula }
        let expr = String(formula.dropFirst())
        let tokens = tokenize(expr)
        do {
            var pos = 0
            let result = try parseExpr(tokens: tokens, pos: &pos, fields: fields)
            return "\(result ?? "")"
        } catch {
            return ""
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

    /// Resolve a field name against the record. Try exact match, then case-insensitive.
    private static func resolveField(_ name: String, fields: [String: String]) -> String {
        if let v = fields[name] { return v }
        let lower = name.lowercased()
        return fields.first { $0.key.lowercased() == lower }?.value ?? ""
    }

    /// Parses a comparison: concat ((= | <>) concat)?
    /// Comparison binds looser than concatenation, matching Excel, so
    /// `A&B = C&D` means `(A&B) = (C&D)`. Works on any operand — field,
    /// string literal, number, function result, or parenthesised expression.
    private static func parseExpr(tokens: [Token], pos: inout Int, fields: [String: String]) throws -> Any? {
        let left = try parseConcat(tokens: tokens, pos: &pos, fields: fields)

        guard pos < tokens.count else { return left }
        let isNE: Bool = { if case .ne = tokens[pos] { return true }; return false }()
        let isEQ: Bool = { if case .eq = tokens[pos] { return true }; return false }()
        guard isNE || isEQ else { return left }

        pos += 1
        let right = try parseConcat(tokens: tokens, pos: &pos, fields: fields)
        let equal = looseEqual(left, right)
        return isNE ? !equal : equal
    }

    /// Parses: primary (&  primary)*
    private static func parseConcat(tokens: [Token], pos: inout Int, fields: [String: String]) throws -> Any? {
        var left = try parsePrimary(tokens: tokens, pos: &pos, fields: fields)

        while pos < tokens.count {
            guard case .amp = tokens[pos] else { break }
            pos += 1
            let right = try parsePrimary(tokens: tokens, pos: &pos, fields: fields)
            left = "\(left ?? "")\(right ?? "")"
        }
        return left
    }

    /// Loose equality: compare numerically when both sides look like numbers
    /// (so `LEN(x)=3` works despite `3` tokenising as a Double), else as strings.
    private static func looseEqual(_ a: Any?, _ b: Any?) -> Bool {
        if let da = anyToDouble(a), let db = anyToDouble(b) { return da == db }
        return "\(a ?? "")" == "\(b ?? "")"
    }

    private static func anyToDouble(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int:    return Double(i)
        case let s as String: return s.isEmpty ? nil : Double(s)
        default:              return nil
        }
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

            // Plain field reference (comparisons are handled in parseExpr)
            return resolveField(name, fields: fields)

        case .ne, .eq, .amp, .comma, .rparen:
            return ""
        }
    }

    // MARK: – Built-in functions

    private static func evalFunction(_ name: String, args: [Any?], fields: [String: String]) -> Any? {
        func str(_ v: Any?) -> String { "\(v ?? "")" }
        func num(_ v: Any?) -> Int {
            // Numeric literals tokenise as Double, so "3.0" would fail Int(_:).
            if let d = v as? Double { return Int(d) }
            if let i = v as? Int    { return i }
            let s = str(v)
            return Int(s) ?? Int(Double(s) ?? 0)
        }
        func bool(_ v: Any?) -> Bool {
            if let b = v as? Bool { return b }
            let s = str(v); return !s.isEmpty && s != "false" && s != "0"
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
