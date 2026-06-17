import XCTest
@testable import VectorLabelCore

/// First tests — establish the harness and pin a couple of pure, high-value
/// behaviors. The deeper golden-file tests (formula engine cross-checked against
/// the JS engines, CSV round-trip, render snapshots) are added with the
/// single-source-of-truth work; see the code-review report.
final class FoundationTests: XCTestCase {

    func testBuildStampPopulated() {
        XCTAssertFalse(BuildInfo.version.isEmpty)
        XCTAssertTrue(BuildInfo.display.contains("build"))
    }

    /// BradyCatalog.core() must apply the bulk-box → cartridge equivalence used by
    /// the renderer and supply matching (the 109-427 = 33-427 case). Regression
    /// guard for the calibration mis-sizing finding (H11).
    func testBradyCoreEquivalences() {
        XCTAssertEqual(BradyCatalog.core("BM-32-427"), "32-427")
        XCTAssertEqual(BradyCatalog.core("M6-32-427"), "32-427")
        XCTAssertEqual(BradyCatalog.core("M6-33-427"), "33-427")
        XCTAssertEqual(BradyCatalog.core("BM-109-427"), "33-427")   // bulk box maps to cartridge
    }

    func testLabelsPerRollKnownSizes() {
        XCTAssertEqual(BradyCatalog.labelsPerRoll(forPartNumber: "M6-31-427"), 250)
        XCTAssertEqual(BradyCatalog.labelsPerRoll(forPartNumber: "M6-32-427"), 250)
        XCTAssertEqual(BradyCatalog.labelsPerRoll(forPartNumber: "BM-109-427"), 100)  // via 33-427
        XCTAssertNil(BradyCatalog.labelsPerRoll(forPartNumber: "ZZ-999-000"))
    }

    // MARK: – Single-source catalog (M6)

    /// The catalog must come from the bundled BradyCatalog.json, not the built-in
    /// fallback — proves the resource path resolves in both `swift build` and the
    /// packaged .app.
    func testCatalogLoadsFromResource() {
        _ = BradyCatalog.sizes                       // force the lazy load
        XCTAssertTrue(BradyCatalog.loadedFromResource,
                      "BradyCatalog fell back to the built-in table — the bundled JSON did not load")
    }

    /// Pin the exact physical + printable sizes and the feed rotation. These drive
    /// label rendering; any change here changes what prints. BM-33-427 is the
    /// tricky one: physical 1.5×4.0, printable 1.5×1.5, rotated 90°.
    func testBradyGeometryPinned() {
        let expected: [String: (w: Double, h: Double, pw: Double, ph: Double, rot: Double)] = [
            "BM-31-427": (1.0, 1.5, 1.0, 0.5, 0),
            "BM-32-427": (1.5, 1.5, 1.5, 0.5, 0),
            "BM-33-427": (1.5, 4.0, 1.5, 1.5, 90),
        ]
        XCTAssertEqual(BradyCatalog.sizes.count, 3)
        for (pn, e) in expected {
            guard let s = BradyCatalog.size(forPartNumber: pn) else { return XCTFail("missing \(pn)") }
            XCTAssertEqual(s.widthInches, e.w, "physical width \(pn)")
            XCTAssertEqual(s.heightInches, e.h, "physical height \(pn)")
            XCTAssertEqual(s.printableWidthInches, e.pw, "printable width \(pn)")
            XCTAssertEqual(s.printableHeightInches, e.ph, "printable height \(pn)")
            XCTAssertEqual(BradyCatalog.feedRotationDeg(forPartNumber: pn), e.rot, "feed rotation \(pn)")
        }
        // Only the 33-427 family rotates, and it does so regardless of prefix
        // (matches the old core-based renderer gate).
        XCTAssertEqual(BradyCatalog.feedRotationDeg(forPartNumber: "BM-31-427"), 0)
        XCTAssertEqual(BradyCatalog.feedRotationDeg(forPartNumber: "M6-33-427"), 90)
        XCTAssertEqual(BradyCatalog.feedRotationDeg(forPartNumber: "BM-109-427"), 90)
    }

    /// The JS `BL` tables embedded in the two HTML UIs are mirrors of
    /// BradyCatalog.json's `js` projection. This fails if either HTML drifts from
    /// the catalog, or if the two HTML copies differ from each other — keeping the
    /// catalog single-sourced without runtime injection.
    func testJSCatalogMirrorsCatalogJSON() throws {
        struct JSProj: Codable { let tw: Double; let th: Double; let pw: Double; let ph: Double; let lb: String }
        struct SpecT: Codable {
            let partNumber: String
            let widthInches: Double; let heightInches: Double
            let printableWidthInches: Double; let printableHeightInches: Double
            let feedRotationDeg: Double
            let js: JSProj
        }
        struct FileT: Codable { let sizes: [SpecT] }

        let sourcesDir = URL(fileURLWithPath: #filePath)   // MacApp/Tests/FoundationTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Core")
        let json = try Data(contentsOf: sourcesDir.appendingPathComponent("BradyCatalog.json"))
        let catalog = try JSONDecoder().decode(FileT.self, from: json)

        // JS number formatting: integers without ".0", values <1 without a leading 0.
        func jsNum(_ v: Double) -> String {
            if v == v.rounded() { return String(Int(v)) }
            var s = String(v)
            if s.hasPrefix("0.") { s = String(s.dropFirst()) }
            return s
        }
        func entryLiteral(_ s: SpecT) -> String {
            "{n:\"\(s.partNumber)\",tw:\(jsNum(s.js.tw)),th:\(jsNum(s.js.th)),pw:\(jsNum(s.js.pw)),ph:\(jsNum(s.js.ph)),lb:'\(s.js.lb)'}"
        }

        let printHTML = try String(contentsOf: sourcesDir.appendingPathComponent("VectorLabelPrint.html"), encoding: .utf8)
        let designHTML = try String(contentsOf: sourcesDir.appendingPathComponent("VectorLabelDesigner.html"), encoding: .utf8)

        for s in catalog.sizes {
            let lit = entryLiteral(s)
            XCTAssertTrue(printHTML.contains(lit),
                          "VectorLabelPrint.html BL is out of sync with BradyCatalog.json. Expected entry:\n\(lit)")
            XCTAssertTrue(designHTML.contains(lit),
                          "VectorLabelDesigner.html BL is out of sync with BradyCatalog.json. Expected entry:\n\(lit)")
        }

        // Cross-view invariant: within one entry, the JS projection must agree
        // with the Swift fields, so editing one side without the other fails.
        for s in catalog.sizes {
            XCTAssertEqual(s.js.pw, s.printableWidthInches,  "\(s.partNumber): JS pw must equal Swift printableWidthInches")
            XCTAssertEqual(s.js.ph, s.printableHeightInches, "\(s.partNumber): JS ph must equal Swift printableHeightInches")
            if s.feedRotationDeg == 90 {   // rotated supplies present the long axis swapped
                XCTAssertEqual(s.js.tw, s.heightInches, "\(s.partNumber): rotated 90°, JS tw must equal Swift heightInches")
                XCTAssertEqual(s.js.th, s.widthInches,  "\(s.partNumber): rotated 90°, JS th must equal Swift widthInches")
            } else {
                XCTAssertEqual(s.js.tw, s.widthInches,  "\(s.partNumber): JS tw must equal Swift widthInches")
                XCTAssertEqual(s.js.th, s.heightInches, "\(s.partNumber): JS th must equal Swift heightInches")
            }
        }

        // The two HTML BL blocks must be identical to each other.
        func blBlock(_ html: String) -> Substring? {
            guard let start = html.range(of: "const BL=["),
                  let end = html.range(of: "];", range: start.upperBound..<html.endIndex) else { return nil }
            return html[start.lowerBound..<end.upperBound]
        }
        XCTAssertEqual(blBlock(printHTML), blBlock(designHTML),
                       "The BL catalog tables in the print and designer HTML differ from each other")
    }

    // MARK: – CSV parser (H1)

    func testCSVBasic() {
        let rows = WireExportParser.parseCSV("a,b,c\n1,2,3\n")
        XCTAssertEqual(rows, [["a","b","c"], ["1","2","3"]])
    }

    func testCSVQuotedCommaAndEscapedQuote() {
        let rows = WireExportParser.parseCSV("name,note\n\"Smith, J\",\"a \"\"quote\"\" here\"\n")
        XCTAssertEqual(rows, [["name","note"], ["Smith, J", "a \"quote\" here"]])
    }

    func testCSVEmbeddedNewlineDoesNotDropRows() {
        // A newline inside a quoted field must stay in the field, not split the row.
        let text = "Number,Cable\n\"A\nB\",RIO\nN045,LAN\n"
        let rows = WireExportParser.parseCSV(text)
        XCTAssertEqual(rows.count, 3)                 // header + 2 data rows (not 4)
        XCTAssertEqual(rows[1], ["A\nB", "RIO"])
        XCTAssertEqual(rows[2], ["N045", "LAN"])
    }

    func testCSVCRLFEndings() {
        let rows = WireExportParser.parseCSV("a,b\r\n1,2\r\n")
        XCTAssertEqual(rows, [["a","b"], ["1","2"]])
    }

    func testParseRecordsEmbeddedNewlineKeepsAllRows() {
        // The end-to-end record build: the embedded newline must not drop the
        // following record (which would shift absolute indices).
        let text = "_Side,Number,Cable\nSource,\"N1\nX\",A\nDestination,N1,A\n"
        let recs = WireExportParser.parseRecords(from: text)
        XCTAssertEqual(recs?.count, 2)
        XCTAssertEqual(recs?[0].fields["Cable"], "A")
        XCTAssertEqual(recs?[1].side, "Destination")
    }

    func testParseRecordsPadsShortRow() {
        // A ragged (short) row is padded, never dropped — index order preserved.
        let recs = WireExportParser.parseRecords(from: "_Side,Number,Cable\nSource,N1\nDestination,N1,A\n")
        XCTAssertEqual(recs?.count, 2)
        XCTAssertEqual(recs?[0].fields["Cable"], "")   // padded
        XCTAssertEqual(recs?[1].fields["Cable"], "A")
    }

    /// An inline edit must survive save → reload, including values with commas,
    /// quotes, and newlines. Pins the writer/parser symmetry (H3).
    func testCSVWriteReadRoundTrip() {
        let headers = ["_Side", "Number", "Cable"]
        let src = "_Side,Number,Cable\nSource,\"N,1\nX\",\"a\"\"b\"\nDestination,N1,LAN\n"
        let recs = WireExportParser.parseRecords(from: src)!
        let out = WireExportParser.csvText(records: recs, headers: headers)
        let recs2 = WireExportParser.parseRecords(from: out)!
        XCTAssertEqual(recs.count, recs2.count)
        XCTAssertEqual(recs2[0].fields["Number"], "N,1\nX")   // comma + embedded newline preserved
        XCTAssertEqual(recs2[0].fields["Cable"], "a\"b")       // doubled-quote preserved
        XCTAssertEqual(recs2[1].fields["Cable"], "LAN")
        XCTAssertEqual(recs2[1].side, "Destination")
    }

    // MARK: – Formula engine (H4–H6, M1, M2, L1) — Swift must match the JS preview

    func testFormulaRealTemplate() {
        let f = #"=IF(Number<>"",Number&IF(Cable<>""," - "&Cable,""),IF(Cable<>"",Cable,""))"#
        XCTAssertEqual(FormulaEngine.evaluate(f, fields: ["Number": "N044", "Cable": "RIO 1 PRI"]), "N044 - RIO 1 PRI")
        XCTAssertEqual(FormulaEngine.evaluate(f, fields: ["Number": "", "Cable": "X"]), "X")
        XCTAssertEqual(FormulaEngine.evaluate(f, fields: ["Number": "", "Cable": ""]), "")
    }

    func testFormulaFriendlyNames() {   // H6 — Swift had no friendly-name table
        XCTAssertEqual(FormulaEngine.evaluate("=Cable Name", fields: ["Cable": "RIO 1"]), "RIO 1")
        XCTAssertEqual(FormulaEngine.evaluate("=Device Name", fields: ["Device_Name": "SWITCH"]), "SWITCH")
        XCTAssertEqual(FormulaEngine.evaluate("=Rack U", fields: ["RackU": "22"]), "22")
    }

    func testFormulaUnknownIdentifierReturnsName() {   // H5 — was blank in Swift
        XCTAssertEqual(FormulaEngine.evaluate("=Bogus", fields: [:]), "Bogus")
    }

    func testFormulaZeroIsTruthy() {   // M1/L1 — Swift treated "0" as false
        XCTAssertEqual(FormulaEngine.evaluate(#"=IF(RackU,"y","n")"#, fields: ["RackU": "0"]), "y")
        XCTAssertEqual(FormulaEngine.evaluate(#"=IF(RackU,"y","n")"#, fields: ["RackU": ""]), "n")
    }

    func testFormulaComparison() {   // H4 — string equality, after a bare identifier
        XCTAssertEqual(FormulaEngine.evaluate(#"=IF(Signal="LAN","Y","N")"#, fields: ["Signal": "LAN"]), "Y")
        XCTAssertEqual(FormulaEngine.evaluate(#"=IF(Signal="LAN","Y","N")"#, fields: ["Signal": "MIDI"]), "N")
        XCTAssertEqual(FormulaEngine.evaluate(#"=IF(Number<>"","has","none")"#, fields: ["Number": "N1"]), "has")
    }

    func testFormulaNumberStringifyMatchesJS() {   // jsString: integral numbers print without ".0"
        XCTAssertEqual(FormulaEngine.evaluate(#"=IF(RackU=22,"y","n")"#, fields: ["RackU": "22"]), "y")
        XCTAssertEqual(FormulaEngine.evaluate(#"=LEN(Number)&" chars""#, fields: ["Number": "N044"]), "4 chars")
    }

    func testFormulaFunctions() {
        XCTAssertEqual(FormulaEngine.evaluate("=LEFT(Cable,3)", fields: ["Cable": "RIORIO"]), "RIO")
        XCTAssertEqual(FormulaEngine.evaluate("=UPPER(Signal)", fields: ["Signal": "lan"]), "LAN")
        XCTAssertEqual(FormulaEngine.evaluate("=TRIM(Cable)", fields: ["Cable": "  x  "]), "x")
    }

    /// jsonQuoted must neutralize JS-injection vectors when a value (e.g. a
    /// filename) is spliced into evaluateJavaScript. Regression guard for M4.
    func testJsonQuotedEscaping() {
        XCTAssertEqual("a\"b".jsonQuoted, "\"a\\\"b\"")
        XCTAssertEqual("c\\d".jsonQuoted, "\"c\\\\d\"")
        XCTAssertEqual("line\none".jsonQuoted, "\"line\\none\"")
        let sep = "x\u{2028}y\u{2029}z".jsonQuoted
        XCTAssertTrue(sep.contains("\\u2028") && sep.contains("\\u2029"))
        XCTAssertFalse(sep.contains("\u{2028}"))   // raw separators must be gone
        XCTAssertFalse(sep.contains("\u{2029}"))
    }
}
