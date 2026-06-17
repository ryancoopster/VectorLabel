import XCTest
@testable import VectorLabel

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
        XCTAssertEqual(BradyCatalog.labelsPerRoll(forPartNumber: "BM-109-427"), 100)  // via 33-427
        XCTAssertNil(BradyCatalog.labelsPerRoll(forPartNumber: "ZZ-999-000"))
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
