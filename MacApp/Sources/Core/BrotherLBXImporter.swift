import Foundation
import Compression

// MARK: – Brother P-touch Editor template import (".lbx")
//
// A ".lbx" is a ZIP archive containing `label.xml` (the label content, clean XML in the
// http://schemas.brother.info/ptouch/2007/lbx namespaces) + `prop.xml` (metadata). This
// reader unzips label.xml (manual ZIP + the Compression framework, no dependency) and
// maps its objects onto VectorLabel's designer model:
//
//   • Geometry — the printable `style:backGround` rect (points → inches). Brother tapes
//     are continuous; the across-tape extent becomes the supply width and the along-feed
//     extent the label length (the design is laid out landscape).
//   • text:text   → a STATIC text object carrying the `pt:data` content (matching the
//     Brady importer), with font / size / alignment.
//   • barcode:barcode → a barcode object (protocol → symbology, QR eccLevel → ECC level),
//     encoding its `pt:data`.
//   • draw:poly (shape=LINE) → a line.
//   • Images / groups / unsupported barcode types are reported via `warnings`.
//
// Coordinates are in points (1/72") relative to the backGround origin.

public enum BrotherLBXImporter {

    public static func parse(_ data: Data) -> ImportedDesign? {
        guard let xmlData = readZipEntry(data, named: "label.xml"),
              let doc = try? XMLDocument(data: xmlData, options: []),
              let root = doc.rootElement(),
              let bg = firstDescendant(root, "backGround") else { return nil }
        let bgX = pt(bg, "x"), bgY = pt(bg, "y"), bgW = pt(bg, "width"), bgH = pt(bg, "height")
        guard bgW > 0, bgH > 0, bgW < 5000, bgH < 5000 else { return nil }

        // Continuous tape, laid out landscape: across-tape extent = bgH (tape width),
        // along-feed extent = bgW (label length). Objects sit in this bgW×bgH frame, which
        // is exactly the continuous-landscape (canvasRot 0) editor canvas.
        let tapeWidthIn = bgH / 72.0
        let lengthIn = bgW / 72.0

        guard let objsEl = firstDescendant(root, "objects") else { return nil }
        var objects: [[String: Any]] = []
        var fields: [String] = []
        var warnings: [String] = []
        for el in childElements(objsEl) {
            switch lname(el) {
            case "text":
                if let o = parseText(el, bgX, bgY) {
                    objects.append(o)
                    if let f = el.attribute(named: "dbMergeFieldStyleName"), !f.isEmpty { fields.append(f) }
                }
            case "barcode":
                if let o = parseBarcode(el, bgX, bgY, &warnings) { objects.append(o) }
            case "poly":
                if let o = parsePoly(el, bgX, bgY) { objects.append(o) }
            case "image":
                warnings.append("An image wasn't imported — add it manually.")
            case "group":
                warnings.append("A grouped object wasn't imported.")
            default:
                break
            }
        }
        guard !objects.isEmpty else { return nil }
        // style:paper autoLength="true" ⇒ the label auto-sizes its length to content.
        let autoLength = (firstDescendant(root, "paper")?.attribute(named: "autoLength") ?? "false") == "true"
        return ImportedDesign(name: "Imported Label", partNumber: "",
                              widthInches: tapeWidthIn, heightInches: lengthIn,
                              canvasRotation: 0, labelLengthInches: lengthIn, isContinuous: true,
                              objects: objects, fieldNames: fields, warnings: warnings,
                              supplyGroupHint: "ptouch", autoLength: autoLength)
    }

    // MARK: – Object parsers

    private static func parseText(_ el: XMLElement, _ bgX: Double, _ bgY: Double) -> [String: Any]? {
        guard let os = firstDescendant(el, "objectStyle") else { return nil }
        let x = (pt(os, "x") - bgX) / 72.0, y = (pt(os, "y") - bgY) / 72.0
        let w = pt(os, "width") / 72.0, h = pt(os, "height") / 72.0
        guard w > 0, h > 0 else { return nil }
        let text = firstDescendant(el, "data")?.stringValue ?? ""

        var font = "Helvetica Neue", bold = false, italic = false
        if let lf = firstDescendant(el, "logFont") {
            let nm = lf.attribute(named: "name") ?? ""
            font = mapFont(nm)
            bold = (Int(lf.attribute(named: "weight") ?? "400") ?? 400) >= 600
            italic = (lf.attribute(named: "italic") ?? "false") == "true"
        }
        var underline = false, fs = 14
        if let fe = firstDescendant(el, "fontExt") {
            underline = (fe.attribute(named: "underline") ?? "0") != "0"
            // Brother size is in points; the designer's fs is ~1/100 inch (fs/100 = inches).
            fs = max(4, Int((ptValue(fe.attribute(named: "size") ?? "14pt") * 100.0 / 72.0).rounded()))
        }
        var al = "left", valign = "middle"
        if let ta = firstDescendant(el, "textAlign") {
            switch ta.attribute(named: "horizontalAlignment") ?? "LEFT" {
            case "CENTER": al = "center"; case "RIGHT": al = "right"; case "JUSTIFY": al = "justify"; default: al = "left"
            }
            switch ta.attribute(named: "verticalAlignment") ?? "CENTER" {
            case "TOP": valign = "top"; case "BOTTOM": valign = "bottom"; default: valign = "middle"
            }
        }
        return ["t": "tx", "mode": "static", "text": text,
                "x": r4(x), "y": r4(y), "w": r4(w), "h": r4(h),
                "fs": fs, "al": al, "valign": valign, "font": font,
                "bold": bold, "italic": italic, "underline": underline,
                "wrapText": false, "tracking": 0, "stretch": 100]
    }

    private static func parseBarcode(_ el: XMLElement, _ bgX: Double, _ bgY: Double,
                                     _ warnings: inout [String]) -> [String: Any]? {
        guard let os = firstDescendant(el, "objectStyle") else { return nil }
        let x = (pt(os, "x") - bgX) / 72.0, y = (pt(os, "y") - bgY) / 72.0
        let w = pt(os, "width") / 72.0, h = pt(os, "height") / 72.0
        guard w > 0, h > 0 else { return nil }
        let text = firstDescendant(el, "data")?.stringValue ?? ""
        let proto = (firstDescendant(el, "barcodeStyle")?.attribute(named: "protocol") ?? "").uppercased()
        guard let bcType = BC_PROTO[proto] else {
            warnings.append("A \(proto.isEmpty ? "barcode" : proto) barcode wasn't imported — unsupported type.")
            return nil
        }
        var o: [String: Any] = ["t": "bc", "bcType": bcType, "mode": "static", "text": text,
                                "x": r4(x), "y": r4(y), "w": r4(w), "h": r4(h)]
        if bcType == "qrcode", let qs = firstDescendant(el, "qrcodeStyle") {
            switch qs.attribute(named: "eccLevel") ?? "" {
            case "7%":  o["eclevel"] = "L"
            case "15%": o["eclevel"] = "M"
            case "25%": o["eclevel"] = "Q"
            case "30%": o["eclevel"] = "H"
            default:    o["eclevel"] = "M"
            }
        }
        return o
    }

    private static func parsePoly(_ el: XMLElement, _ bgX: Double, _ bgY: Double) -> [String: Any]? {
        let shape = firstDescendant(el, "polyStyle")?.attribute(named: "shape") ?? ""
        guard shape == "LINE", let op = firstDescendant(el, "polyOrgPos") else { return nil }
        let x = (pt(op, "x") - bgX) / 72.0, y = (pt(op, "y") - bgY) / 72.0
        let w = pt(op, "width") / 72.0
        guard w > 0 else { return nil }
        return ["t": "ln", "x": r4(x), "y": r4(y), "w": r4(w), "h": 0, "lw": 1]
    }

    // MARK: – Mapping tables

    private static let FONTS: Set<String> = ["Helvetica Neue", "Arial", "Arial Narrow", "Verdana", "Tahoma", "Courier New", "Georgia", "Impact"]
    private static func mapFont(_ name: String) -> String {
        if FONTS.contains(name) { return name }
        let lower = name.lowercased()
        if lower.contains("narrow") { return "Arial Narrow" }
        if lower.contains("courier") { return "Courier New" }
        if lower.contains("times") || lower.contains("georgia") { return "Georgia" }
        if lower.contains("verdana") { return "Verdana" }
        if lower.contains("tahoma") || lower.contains("segoe") { return "Tahoma" }
        if lower.contains("arial") || lower.contains("helvetica") || lower.contains("sans") { return "Arial" }
        return "Helvetica Neue"
    }

    private static let BC_PROTO: [String: String] = [
        "QRCODE": "qrcode", "MICROQR": "microqrcode", "DATAMATRIX": "datamatrix",
        "PDF417": "pdf417", "AZTEC": "azteccode",
        "CODE128": "code128", "GS1-128": "gs1-128", "EAN128": "gs1-128",
        "CODE39": "code39", "CODE93": "code93",
        "EAN13": "ean13", "JAN13": "ean13", "EAN8": "ean8", "JAN8": "ean8",
        "UPCA": "upca", "UPCE": "upce",
        "ITF": "interleaved2of5", "ITF14": "interleaved2of5", "I-2/5": "interleaved2of5",
        "CODABAR": "codabar", "NW-7": "codabar",
    ]

    // MARK: – XML helpers

    private static func lname(_ n: XMLNode) -> String {
        if let l = n.localName, !l.isEmpty { return l }
        let nm = n.name ?? ""
        return nm.contains(":") ? String(nm.split(separator: ":").last ?? "") : nm
    }
    private static func childElements(_ el: XMLElement) -> [XMLElement] {
        (el.children ?? []).compactMap { $0 as? XMLElement }
    }
    /// First descendant element (depth-first) with the given local name.
    private static func firstDescendant(_ el: XMLElement, _ name: String) -> XMLElement? {
        for c in childElements(el) {
            if lname(c) == name { return c }
            if let f = firstDescendant(c, name) { return f }
        }
        return nil
    }
    private static func ptValue(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: "pt", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
    }
    private static func pt(_ el: XMLElement, _ attr: String) -> Double { ptValue(el.attribute(named: attr) ?? "0") }
    private static func r4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

    // MARK: – Minimal ZIP reader (central directory → inflate via Compression)

    static func readZipEntry(_ data: Data, named name: String) -> Data? {
        let b = [UInt8](data)
        guard b.count > 22 else { return nil }
        func u16(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24) }
        // End of central directory (PK\05\06), scanning back from the end.
        var eocd = -1, i = b.count - 22
        while i >= 0 {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var cd = u32(eocd + 16)
        for _ in 0..<count {
            guard cd + 46 <= b.count, b[cd] == 0x50, b[cd + 1] == 0x4B, b[cd + 2] == 0x01, b[cd + 3] == 0x02 else { break }
            let method = u16(cd + 10)
            let compSize = u32(cd + 20)
            let uncompSize = u32(cd + 24)
            let nameLen = u16(cd + 28), extraLen = u16(cd + 30), commentLen = u16(cd + 32)
            let localOff = u32(cd + 42)
            guard cd + 46 + nameLen <= b.count else { break }
            let entry = String(decoding: b[(cd + 46)..<(cd + 46 + nameLen)], as: UTF8.self)
            if entry == name {
                guard localOff + 30 <= b.count, b[localOff] == 0x50, b[localOff + 1] == 0x4B,
                      b[localOff + 2] == 0x03, b[localOff + 3] == 0x04 else { return nil }
                let lNameLen = u16(localOff + 26), lExtraLen = u16(localOff + 28)
                let start = localOff + 30 + lNameLen + lExtraLen
                guard start + compSize <= b.count else { return nil }
                let comp = Data(b[start..<(start + compSize)])
                if method == 0 { return comp }                       // stored
                if method == 8 { return inflateRaw(comp, uncompSize) } // DEFLATE
                return nil
            }
            cd += 46 + nameLen + extraLen + commentLen
        }
        return nil
    }

    private static func inflateRaw(_ data: Data, _ destSize: Int) -> Data? {
        guard destSize > 0, destSize < 50_000_000 else { return nil }
        var dst = Data(count: destSize)
        let n = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                guard let dp = d.bindMemory(to: UInt8.self).baseAddress,
                      let sp = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // Apple's COMPRESSION_ZLIB consumes RAW DEFLATE (no zlib wrapper), as ZIP stores.
                return compression_decode_buffer(dp, destSize, sp, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        return dst.prefix(n)
    }
}

private extension XMLElement {
    func attribute(named name: String) -> String? { attribute(forName: name)?.stringValue }
}
