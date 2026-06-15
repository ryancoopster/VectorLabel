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
        var chars = Array(expr)
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

    /// Parses: primary (&  primary)*
    private static func parseExpr(tokens: [Token], pos: inout Int, fields: [String: String]) throws -> Any? {
        var left = try parsePrimary(tokens: tokens, pos: &pos, fields: fields)

        while pos < tokens.count {
            guard case .amp = tokens[pos] else { break }
            pos += 1
            let right = try parsePrimary(tokens: tokens, pos: &pos, fields: fields)
            left = "\(left ?? "")\(right ?? "")"
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

            // Comparison?
            if pos < tokens.count {
                let isNE = { if case .ne = tokens[pos] { return true }; return false }()
                let isEQ = { if case .eq = tokens[pos] { return true }; return false }()
                if isNE || isEQ {
                    pos += 1
                    let rhs = try parsePrimary(tokens: tokens, pos: &pos, fields: fields)
                    let lhsStr = resolveField(name, fields: fields)
                    let rhsStr = "\(rhs ?? "")"
                    let equal = lhsStr == rhsStr
                    return isNE ? !equal : equal
                }
            }

            // Plain field reference
            return resolveField(name, fields: fields)

        case .ne, .eq, .amp, .comma, .rparen:
            return ""
        }
    }

    // MARK: – Built-in functions

    private static func evalFunction(_ name: String, args: [Any?], fields: [String: String]) -> Any? {
        func str(_ v: Any?) -> String { "\(v ?? "")" }
        func num(_ v: Any?) -> Int { Int(str(v)) ?? 0 }
        func bool(_ v: Any?) -> Bool {
            if let b = v as? Bool { return b }
            let s = str(v); return !s.isEmpty && s != "false" && s != "0"
        }

        switch name {
        case "IF":
            return bool(args.first) ? (args.count > 1 ? args[1] : "") : (args.count > 2 ? args[2] : "")
        case "LEFT":
            let s = str(args.first); let n = args.count > 1 ? num(args[1]) : 1
            return String(s.prefix(max(0, n)))
        case "RIGHT":
            let s = str(args.first); let n = args.count > 1 ? num(args[1]) : 1
            return String(s.suffix(max(0, n)))
        case "MID":
            let s = str(args.first)
            let start = max(0, (args.count > 1 ? num(args[1]) : 1) - 1)
            let length = args.count > 2 ? num(args[2]) : 1
            guard start < s.count else { return "" }
            let from = s.index(s.startIndex, offsetBy: start)
            let to   = s.index(from, offsetBy: min(length, s.count - start))
            return String(s[from..<to])
        case "LEN":
            return str(args.first).count
        case "UPPER":
            return str(args.first).uppercased()
        case "LOWER":
            return str(args.first).lowercased()
        case "TRIM":
            return str(args.first).trimmingCharacters(in: .whitespaces)
        default:
            return ""
        }
    }
}
