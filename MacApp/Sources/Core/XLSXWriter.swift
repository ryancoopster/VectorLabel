import Foundation

/// Minimal `.xlsx` writer: a STORED (uncompressed) ZIP of the OOXML parts, with every cell
/// emitted as an inline string (no shared-strings table). Enough for VectorLabel's flat data
/// export — Excel, Numbers, and LibreOffice all open it. The companion reader is
/// `ExcelRecordReader`; this is the write side.
public enum XLSXWriter {

    /// Build an .xlsx from a header row + records (one row each), columns in `headers` order.
    public static func data(headers: [String], rows: [[String: String]]) -> Data? {
        var grid: [[String]] = [headers]
        for r in rows { grid.append(headers.map { r[$0] ?? "" }) }
        let parts: [(String, String)] = [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", rootRels),
            ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", workbookRels),
            ("xl/worksheets/sheet1.xml", sheetXML(grid)),
        ]
        return zip(parts.map { ($0.0, Data($0.1.utf8)) })
    }

    // MARK: – Worksheet XML (inline strings)

    private static func sheetXML(_ grid: [[String]]) -> String {
        var sb = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        sb += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (ri, row) in grid.enumerated() {
            let r = ri + 1
            sb += "<row r=\"\(r)\">"
            for (ci, val) in row.enumerated() where !val.isEmpty {
                sb += "<c r=\"\(colRef(ci))\(r)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(val))</t></is></c>"
            }
            sb += "</row>"
        }
        sb += "</sheetData></worksheet>"
        return sb
    }

    /// 0 → A, 25 → Z, 26 → AA (Excel column reference).
    private static func colRef(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let m = (n - 1) % 26; s = String(UnicodeScalar(65 + m)!) + s; n = (n - 1) / 26 }
        return s
    }

    private static func xmlEscape(_ s: String) -> String {
        var o = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default:
                // Drop control chars XML 1.0 forbids (keep tab/newline/return).
                if u.value < 0x20 && u != "\t" && u != "\n" && u != "\r" { continue }
                o.unicodeScalars.append(u)
            }
        }
        return o
    }

    // MARK: – Static OOXML parts

    private static let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>"
    private static let rootRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
    private static let workbook = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
    private static let workbookRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"

    // MARK: – Minimal STORED ZIP container

    private static func zip(_ entries: [(name: String, data: Data)]) -> Data {
        func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
        func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        var out = Data(), central = Data()
        var offset: UInt32 = 0
        for e in entries {
            let nameData = Data(e.name.utf8)
            let crc = crc32(e.data), size = UInt32(e.data.count), nlen = UInt16(nameData.count)
            var lfh = Data()
            lfh.append(le32(0x04034b50)); lfh.append(le16(20)); lfh.append(le16(0)); lfh.append(le16(0))
            lfh.append(le16(0)); lfh.append(le16(0x21)); lfh.append(le32(crc)); lfh.append(le32(size)); lfh.append(le32(size))
            lfh.append(le16(nlen)); lfh.append(le16(0)); lfh.append(nameData)
            out.append(lfh); out.append(e.data)
            var cdh = Data()
            cdh.append(le32(0x02014b50)); cdh.append(le16(20)); cdh.append(le16(20)); cdh.append(le16(0)); cdh.append(le16(0))
            cdh.append(le16(0)); cdh.append(le16(0x21)); cdh.append(le32(crc)); cdh.append(le32(size)); cdh.append(le32(size))
            cdh.append(le16(nlen)); cdh.append(le16(0)); cdh.append(le16(0)); cdh.append(le16(0)); cdh.append(le16(0))
            cdh.append(le32(0)); cdh.append(le32(offset)); cdh.append(nameData)
            central.append(cdh)
            offset += UInt32(lfh.count + e.data.count)
        }
        let centralSize = UInt32(central.count), centralOffset = offset
        out.append(central)
        var eocd = Data()
        eocd.append(le32(0x06054b50)); eocd.append(le16(0)); eocd.append(le16(0))
        eocd.append(le16(UInt16(entries.count))); eocd.append(le16(UInt16(entries.count)))
        eocd.append(le32(centralSize)); eocd.append(le32(centralOffset)); eocd.append(le16(0))
        out.append(eocd)
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
