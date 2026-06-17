import Foundation
import CoreXLSX

/// Reads an `.xlsx` workbook into the same row/record shapes the CSV path uses,
/// so the Custom Designer can bind a spreadsheet exactly like a CSV export.
///
/// Core-only and libusb-free: CoreXLSX pulls in XMLCoder + ZIPFoundation, none of
/// which touch USB, so this stays inside the Engine's "no libusb in Core" rule.
///
/// Two entry points, mirroring `WireExportParser`:
///   • `rows(fileURL:)`        → `[[String]]`     (the raw grid, header row first)
///   • `records(fileURL:headerRow:)` → `[WireRecord]` (header- OR generic-mapped)
///
/// Generic headers ("Column 1", "Column 2", …) are produced when `headerRow` is
/// false, matching the designer's "first row is headers" toggle.
public enum ExcelRecordReader {

    public enum ReadError: Error {
        case cannotOpen
        case noWorksheet
        case empty
    }

    /// The full grid of the first worksheet as `[[String]]`, including the header
    /// row. Rectangular: every row is padded to the widest row so column indices
    /// line up (xlsx omits trailing/empty cells, so rows are otherwise ragged).
    /// Returns nil if the file can't be opened or has no usable sheet.
    public static func rows(fileURL: URL) -> [[String]]? {
        guard let file = XLSXFile(filepath: fileURL.path) else { return nil }
        // CoreXLSX returns nil (it does NOT throw) when xl/sharedStrings.xml is
        // absent — legal for numeric-only or inline-string sheets. `try?` flattens
        // that nil, so a `guard let` would reject a perfectly valid workbook. Keep
        // SharedStrings optional and let cellString fall back to inline/raw values.
        let shared = (try? file.parseSharedStrings()) ?? nil
        guard let paths = try? file.parseWorksheetPaths(),
              let firstPath = paths.first,
              let worksheet = try? file.parseWorksheet(at: firstPath)
        else { return nil }

        let sheetRows = worksheet.data?.rows ?? []
        if sheetRows.isEmpty { return nil }

        // Build each row as a sparse [col index → value], then flatten to a dense
        // array padded to the widest column seen anywhere in the sheet.
        var parsed: [[Int: String]] = []
        var maxCol = 0
        for row in sheetRows {
            var dict: [Int: String] = [:]
            for cell in row.cells {
                let col = columnIndex(cell.reference.column.value)   // 1-based
                let value = cellString(cell, sharedStrings: shared)
                if !value.isEmpty { dict[col] = value }
                if col > maxCol { maxCol = col }
            }
            parsed.append(dict)
        }
        if maxCol == 0 { return nil }

        var out: [[String]] = []
        out.reserveCapacity(parsed.count)
        for dict in parsed {
            var arr = [String](repeating: "", count: maxCol)
            for (col, value) in dict where col >= 1 && col <= maxCol {
                arr[col - 1] = value
            }
            out.append(arr)
        }
        return out
    }

    /// The worksheet as `[WireRecord]`, mirroring `WireExportParser.parseRecords`.
    ///
    /// `headerRow == true`  → the first row supplies column names (blank names get a
    ///                        generic "Column N" so no field is unnamed).
    /// `headerRow == false` → every row is data; columns are named "Column 1",
    ///                        "Column 2", … and the count comes from the widest row.
    ///
    /// Short rows are padded with empty strings (never dropped) so a row's index in
    /// the result always equals its position in the sheet — same guarantee the CSV
    /// parser makes so labels never shift.
    public static func records(fileURL: URL, headerRow: Bool) -> [WireRecord]? {
        guard let grid = rows(fileURL: fileURL), !grid.isEmpty else { return nil }
        return records(rows: grid, headerRow: headerRow)
    }

    /// Build records from an already-read `[[String]]` grid. Factored out so it can
    /// be unit-tested without a real `.xlsx` on disk, and reused by the CSV path's
    /// header-toggle behavior if needed.
    public static func records(rows grid: [[String]], headerRow: Bool) -> [WireRecord]? {
        guard !grid.isEmpty else { return nil }
        let width = grid.map(\.count).max() ?? 0
        guard width > 0 else { return nil }

        let headers: [String]
        let dataRows: ArraySlice<[String]>
        if headerRow {
            headers = normalizedHeaders(grid[0], width: width)
            dataRows = grid.dropFirst()
        } else {
            headers = (1...width).map { "Column \($0)" }
            dataRows = grid[...]
        }
        if dataRows.isEmpty { return nil }

        var records: [WireRecord] = []
        for values in dataRows {
            var row: [String: String] = [:]
            for (i, header) in headers.enumerated() {
                row[header] = i < values.count ? values[i] : ""   // pad short rows
            }
            let wireID = row["Number"] ?? UUID().uuidString
            let side   = row["_Side"]  ?? "Source"
            records.append(WireRecord(side: side, wireID: wireID, fields: row))
        }
        return records.isEmpty ? nil : records
    }

    // MARK: – Helpers

    /// Convert an Excel column label ("A", "B", …, "Z", "AA", "AB", …) to its
    /// 1-based index (A→1, Z→26, AA→27). CoreXLSX keeps the numeric index internal,
    /// so we derive it from the public letter reference (base-26 bijective).
    private static func columnIndex(_ letters: String) -> Int {
        var idx = 0
        for ch in letters.uppercased().unicodeScalars where ch.value >= 65 && ch.value <= 90 {
            idx = idx * 26 + Int(ch.value - 64)   // 'A' (65) → 1
        }
        return idx
    }

    /// Ensure every header is a non-empty, unique column name. A blank header
    /// becomes "Column N" (1-based); a duplicate gets a " (2)", " (3)", … suffix so
    /// two columns never collapse into one field.
    private static func normalizedHeaders(_ raw: [String], width: Int) -> [String] {
        var out: [String] = []
        var seen: [String: Int] = [:]
        for i in 0..<width {
            var name = i < raw.count ? raw[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if name.isEmpty { name = "Column \(i + 1)" }
            if let n = seen[name] {
                seen[name] = n + 1
                name = "\(name) (\(n + 1))"
            } else {
                seen[name] = 1
            }
            out.append(name)
        }
        return out
    }

    /// The display string for a cell: resolves shared strings (when the workbook
    /// has a shared-strings table), falls back to inline strings, then to the raw
    /// value (numbers/dates render as their stored text). `sharedStrings` is nil for
    /// numeric-only / inline-string workbooks that omit xl/sharedStrings.xml.
    private static func cellString(_ cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let ss = sharedStrings {
            if let s = cell.stringValue(ss) { return s }
            // A rich-text shared string has a nil plain `.text` (so stringValue is
            // nil) but carries its content in formatting runs. Join the runs'
            // `.text` BEFORE the cell.value fallback — otherwise cell.value returns
            // the raw shared-string INDEX (e.g. "3") for these cells.
            let runs = cell.richStringValue(ss).compactMap { $0.text }
            if !runs.isEmpty { return runs.joined() }
        }
        if let inline = cell.inlineString?.text { return inline }
        return cell.value ?? ""
    }
}
