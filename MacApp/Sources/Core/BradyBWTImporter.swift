import Foundation

// MARK: – Brady Workstation template import (".BWT")
//
// Brady Workstation saves label templates as ".BWT" — a .NET-serialized object graph
// (BinaryFormatter) with an embedded PartInfo XML block (stored single-byte/ASCII
// despite its `encoding="utf-16"` declaration). This reader recovers the parts that
// map cleanly onto VectorLabel's designer model:
//
//   • Label geometry — the part's physical size + output orientation → a design frame
//     in inches (Landscape swaps the part's width/height, as Brady lays the design out
//     rotated to landscape).
//   • Text / prompt objects — each carries a bounding rect (4 little-endian doubles in
//     inches: Height, Width, X, Y at a fixed offset after its "TEXT n" layer name), a
//     prompt name (the variable-data field), and a font size. Each becomes a data-bound
//     text field so binding a data file whose columns match the prompt names fills them.
//
// Reverse-engineered from sample templates and validated against known files. Object
// types we don't decode yet (barcodes, images, shapes) are reported in `warnings` so a
// partial import is never silently mistaken for a complete one.

public enum BradyBWTImporter {

    /// The recovered design (shared shape across importers — see `ImportedDesign`).
    public typealias Imported = ImportedDesign

    /// Parse ".BWT" bytes. Returns nil only when the file isn't a recognizable BWT
    /// (no usable PartInfo geometry, or no decodable text objects).
    public static func parse(_ data: Data) -> Imported? {
        let b = [UInt8](data)
        guard let part = parsePartInfo(b) else { return nil }

        // Brady stores part dimensions in 1/10000 inch. The text rects below are already
        // in the laid-out design frame, so they need no transform — only the supply +
        // orientation differ by stock type:
        //  • Die-cut: supply keeps its PHYSICAL (portrait) size; a Landscape template is
        //    represented with canvasRot=90 (renderer rotates the design onto the label).
        //  • Continuous: the tape width is fixed and the length is the along-feed extent;
        //    the renderer's DEFAULT is landscape, so a landscape design is canvasRot=0 and
        //    a portrait design is the 90° override (opposite of die-cut).
        let pwIn = Double(part.w) / 10_000.0
        let phIn = Double(part.h) / 10_000.0
        // Reject obviously-corrupt geometry (real Brady supplies are well under ~60").
        guard pwIn > 0, phIn > 0, pwIn <= 60, phIn <= 60 else { return nil }
        let canvasRotation = part.continuous ? (part.landscape ? 0 : 90)
                                             : (part.landscape ? 90 : 0)
        // Continuous: tape width = the part's width, label length = the part's height.
        let labelLength = part.continuous ? phIn : 0

        var objects: [[String: Any]] = []
        var fields: [String] = []
        var warnings: [String] = []

        for t in findTextMarkers(b) {
            guard let rect = readRect(b, markerStart: t.start, nameLen: t.nameLen) else {
                warnings.append("Skipped \(t.name): position couldn't be read"); continue
            }
            guard let prompt = readPrompt(b, from: t.start, to: t.end) else {
                warnings.append("Skipped \(t.name): no field name"); continue
            }
            let (h, wd, x, y) = rect   // stored order: Height, Width, X, Y
            guard x.isFinite, y.isFinite, wd.isFinite, h.isFinite,
                  x > -1, y > -1, wd > 0, h > 0, wd < 100, h < 100 else {
                warnings.append("Skipped \(prompt): out-of-range geometry"); continue
            }
            let fs = readFontSize(b, from: t.start, to: t.end) ?? 12
            // Import as STATIC text whose content is the Brady prompt/field name (so the
            // imported label reads like the original layout; the user edits the text or
            // re-binds to data afterward).
            objects.append([
                "t": "tx", "mode": "static", "text": prompt,
                "x": round4(x), "y": round4(y), "w": round4(wd), "h": round4(h),
                "fs": Int(fs.rounded()), "al": "left", "valign": "middle",
                "font": "Helvetica Neue",
                "bold": false, "italic": false, "underline": false,
                "wrapText": false, "tracking": 0, "stretch": 100,
            ])
            fields.append(prompt)
        }

        // Flag element types we don't decode so a partial import is obvious.
        if contains(b, "Barcode") || contains(b, "BARCODE") || contains(b, "DataMatrix") {
            warnings.append("A barcode/2-D code wasn't imported — add it manually.")
        }
        if contains(b, "ImageObject") || contains(b, "GraphicObject") {
            warnings.append("An image/graphic wasn't imported — add it manually.")
        }

        guard !objects.isEmpty else { return nil }
        return Imported(name: part.name.isEmpty ? "Imported Label" : part.name,
                        partNumber: part.name,
                        widthInches: pwIn, heightInches: phIn,
                        canvasRotation: canvasRotation,
                        labelLengthInches: labelLength,
                        isContinuous: part.continuous,
                        objects: objects, fieldNames: fields, warnings: warnings,
                        autoLength: boolField(b, "IsAutoSizeLabel"))
    }

    // MARK: – PartInfo XML (ASCII, despite the utf-16 declaration)

    private struct PartInfo { var name: String; var w: Int; var h: Int; var landscape: Bool; var continuous: Bool }

    private static func parsePartInfo(_ b: [UInt8]) -> PartInfo? {
        guard let lo = indexOf(b, "<?xml"),
              let hi = indexOf(b, "</PartsDatabase>", from: lo) else { return nil }
        let xml = String(decoding: b[lo..<hi], as: UTF8.self)
        func tag(_ t: String) -> String? {
            guard let r = xml.range(of: "<\(t)>"),
                  let r2 = xml.range(of: "</\(t)>", range: r.upperBound..<xml.endIndex) else { return nil }
            return String(xml[r.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let w = Int(tag("Width") ?? "") ?? 0
        let h = Int(tag("Height") ?? "") ?? 0
        guard w > 0, h > 0 else { return nil }
        let orient = (tag("OutputOrientation") ?? "Portrait").lowercased()
        let cont = (tag("IsContinuous") ?? "False").lowercased() == "true"
        // The Name carries the part number plus a duplicate or a serial, separated by
        // "|" or " : " — e.g. "M6-173-593 | M6-173-593" or "BM-32-427 : Y5074516". Take
        // the leading part number so it resolves against the supply catalog.
        let nameRaw = tag("Name") ?? ""
        let part = nameRaw.components(separatedBy: CharacterSet(charactersIn: "|:"))
            .first?.trimmingCharacters(in: .whitespaces) ?? nameRaw
        return PartInfo(name: part, w: w, h: h, landscape: orient == "landscape", continuous: cont)
    }

    // MARK: – Text-object markers ("TEXT n" layer names)

    private struct TextMarker { var name: String; var start: Int; var nameLen: Int; var end: Int }

    private static func findTextMarkers(_ b: [UInt8]) -> [TextMarker] {
        let prefix = Array("TEXT ".utf8)
        var out: [TextMarker] = []
        var i = 0
        while i + prefix.count < b.count {
            if Array(b[i..<i + prefix.count]) == prefix, isDigit(b[i + prefix.count]) {
                var j = i + prefix.count
                while j < b.count, isDigit(b[j]) { j += 1 }
                let nameLen = j - i
                // .NET BinaryFormatter strings are length-prefixed, so the byte BEFORE the
                // "TEXT n" layer name equals its length. Requiring that match rejects a
                // literal "TEXT 5" appearing inside object data / a GUID / the preview PNG.
                if i > 0, Int(b[i - 1]) == nameLen {
                    let name = String(decoding: b[i..<j], as: UTF8.self)
                    out.append(TextMarker(name: name, start: i, nameLen: nameLen, end: b.count))
                }
                i = j
            } else {
                i += 1
            }
        }
        for k in out.indices { out[k].end = (k + 1 < out.count) ? out[k + 1].start : b.count }
        return out
    }

    // The bounding rect is 4 little-endian doubles (Height, Width, X, Y) at a fixed
    // offset after the "TEXT n" layer name. The base offset grows by one per extra name
    // character (longer names → the rect starts one byte later).
    private static func readRect(_ b: [UInt8], markerStart: Int, nameLen: Int) -> (Double, Double, Double, Double)? {
        let base = markerStart + 35 + (nameLen - 6)
        guard base >= 0, base + 32 <= b.count else { return nil }
        return (leDouble(b, base), leDouble(b, base + 8), leDouble(b, base + 16), leDouble(b, base + 24))
    }

    // The prompt (field) name: "TEMPLATE_PROMPT" + a 1-byte length + UTF-8 text. The
    // "TEMPLATE_PROMPT_ORDER" key is naturally excluded because its following byte ('_')
    // is outside the valid 2…40 length range.
    private static func readPrompt(_ b: [UInt8], from: Int, to: Int) -> String? {
        let needle = Array("TEMPLATE_PROMPT".utf8)
        var i = from
        while i + needle.count < to {
            if Array(b[i..<i + needle.count]) == needle {
                let o = i + needle.count
                if o < to {
                    let ln = Int(b[o])
                    if ln >= 2, ln <= 60, o + 1 + ln <= to {
                        let raw = String(decoding: b[(o + 1)..<(o + 1 + ln)], as: UTF8.self)
                        if let name = sanitizeFieldName(raw) { return name }
                    }
                }
                i = o
            } else {
                i += 1
            }
        }
        return nil
    }

    // Clean a decoded prompt into a usable name: take the first line (Brady appends a
    // "\r\n<ordinal>" to some names), drop control chars, trim. Returns nil only when
    // nothing real remains — so a name with newlines, foot/inch marks (225'), or other
    // punctuation is KEPT (the object is no longer discarded over stray characters).
    private static func sanitizeFieldName(_ s: String) -> String? {
        // Work on SCALARS (a CR/LF is a single grapheme cluster in Swift, so a Character
        // split would miss it). Take everything up to the first control character.
        var out = String.UnicodeScalarView()
        for sc in s.unicodeScalars {
            if sc.value < 0x20 || sc.value == 0x7f { break }
            out.append(sc)
        }
        let cleaned = String(out).trimmingCharacters(in: .whitespaces)
        guard cleaned.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return cleaned
    }

    // Font size: the first plausible double in the bytes after "AutosizeFontKey".
    private static func readFontSize(_ b: [UInt8], from: Int, to: Int) -> Double? {
        guard let k = indexOf(b, "AutosizeFontKey", from: from), k < to else { return nil }
        let s = k + Array("AutosizeFontKey".utf8).count
        var c = s
        while c + 8 <= b.count, c < s + 10 {
            let v = leDouble(b, c)
            if v > 1, v < 300 { return v }
            c += 1
        }
        return nil
    }

    // MARK: – Byte helpers

    private static func leDouble(_ b: [UInt8], _ off: Int) -> Double {
        var bits: UInt64 = 0
        for k in 0..<8 { bits |= UInt64(b[off + k]) << (8 * k) }
        return Double(bitPattern: bits)
    }

    private static func indexOf(_ b: [UInt8], _ s: String, from: Int = 0) -> Int? {
        let needle = Array(s.utf8)
        guard !needle.isEmpty, b.count >= needle.count else { return nil }
        var i = max(0, from)
        let last = b.count - needle.count
        while i <= last {
            if b[i] == needle[0], Array(b[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }

    private static func contains(_ b: [UInt8], _ s: String) -> Bool { indexOf(b, s) != nil }

    /// A ".BWT" boolean property is the key followed by a length-prefixed "True"/"False"
    /// string (e.g. IsAutoSizeLabel\x05False). Returns true only for an explicit "true".
    private static func boolField(_ b: [UInt8], _ key: String) -> Bool {
        guard let i = indexOf(b, key) else { return false }
        let o = i + key.utf8.count
        guard o < b.count else { return false }
        let ln = Int(b[o])
        guard ln >= 4, ln <= 5, o + 1 + ln <= b.count else { return false }
        return String(decoding: b[(o + 1)..<(o + 1 + ln)], as: UTF8.self).lowercased() == "true"
    }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
}
