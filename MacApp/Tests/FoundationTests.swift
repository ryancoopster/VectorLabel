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
        // The original 3 die-cut supplies must still be present with byte-identical
        // geometry/rotation (Phase 5 only ADDS supplies + metadata).
        XCTAssertGreaterThanOrEqual(BradyCatalog.sizes.count, 3)
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

    /// Phase 5 additive metadata: supply type (die-cut vs continuous) and buy URLs.
    /// The existing die-cut supplies must report dieCut; the M6C-* tapes continuous.
    func testSupplyTypeAndBuyURLs() {
        // Existing die-cut supplies unchanged.
        XCTAssertEqual(BradyCatalog.supplyType(forPartNumber: "BM-31-427"), .dieCut)
        XCTAssertFalse(BradyCatalog.isContinuous(forPartNumber: "BM-32-427"))
        XCTAssertEqual(BradyCatalog.supplyType(forPartNumber: "M6-33-427"), .dieCut)
        // Continuous tapes.
        XCTAssertTrue(BradyCatalog.isContinuous(forPartNumber: "M6C-1000-422"))
        XCTAssertEqual(BradyCatalog.supplyType(forPartNumber: "M6C-2000-595"), .continuous)
        // Unknown parts safely default to die-cut.
        XCTAssertEqual(BradyCatalog.supplyType(forPartNumber: "ZZ-999-000"), .dieCut)
        XCTAssertFalse(BradyCatalog.isContinuous(forPartNumber: "ZZ-999-000"))
        // Buy URLs are present for the original supplies and are https.
        let roll = BradyCatalog.buyUrlRoll(forPartNumber: "BM-32-427")
        XCTAssertTrue(roll.hasPrefix("https://"), "expected an https buy URL, got \(roll)")
        // Unknown part → empty URLs (no crash).
        XCTAssertEqual(BradyCatalog.buyUrlRoll(forPartNumber: "ZZ-999-000"), "")
    }

    /// Continuous supplies render at the user-chosen label length; die-cut keep the
    /// catalog's fixed printable height. effectivePrintableHeightInches drives the
    /// renderer's pixel height.
    func testContinuousLabelLength() {
        // Die-cut: labelLengthInches is ignored; printable height stays fixed.
        var dieCut = VLTemplate(name: "d", specN: "BM-32-427", objs: [])
        XCTAssertEqual(dieCut.effectivePrintableHeightInches, 0.5)
        dieCut.labelLengthInches = 3.0
        XCTAssertEqual(dieCut.effectivePrintableHeightInches, 0.5, "die-cut ignores labelLengthInches")
        // Continuous: with a chosen length, the printable height becomes that length.
        var cont = VLTemplate(name: "c", specN: "M6C-1000-422", objs: [])
        cont.labelLengthInches = 2.5
        XCTAssertEqual(cont.effectivePrintableHeightInches, 2.5)
        // Continuous with no chosen length falls back to the catalog default.
        let contDefault = VLTemplate(name: "c2", specN: "M6C-1000-422", objs: [])
        XCTAssertEqual(contDefault.effectivePrintableHeightInches,
                       BradyCatalog.size(forPartNumber: "M6C-1000-422")?.printableHeightInches)
    }

    /// The JS `BL` tables embedded in the two HTML UIs are mirrors of
    /// BradyCatalog.json's `js` projection. This fails if either HTML drifts from
    /// the catalog, or if the two HTML copies differ from each other — keeping the
    /// catalog single-sourced without runtime injection.
    func testJSCatalogMirrorsCatalogJSON() throws {
        struct JSProj: Codable {
            let tw: Double; let th: Double; let pw: Double; let ph: Double; let lb: String
            // Phase 5 additive projection: material, type, laminated, buy URLs.
            let mt: String; let ty: String; let lm: Bool; let br: String; let bb: String
        }
        struct SpecT: Codable {
            let partNumber: String
            let widthInches: Double; let heightInches: Double
            let printableWidthInches: Double; let printableHeightInches: Double
            let feedRotationDeg: Double
            let material: String; let type: String; let laminated: Bool
            let buyUrlRoll: String; let buyUrlBulk: String
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
            "{n:\"\(s.partNumber)\",tw:\(jsNum(s.js.tw)),th:\(jsNum(s.js.th)),pw:\(jsNum(s.js.pw)),ph:\(jsNum(s.js.ph)),lb:'\(s.js.lb)',mt:\"\(s.js.mt)\",ty:\"\(s.js.ty)\",lm:\(s.js.lm),br:\"\(s.js.br)\",bb:\"\(s.js.bb)\"}"
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
            // Phase 5: the JS projection must agree with the Swift metadata fields,
            // so editing one side without the other fails the test.
            XCTAssertEqual(s.js.mt, s.material,   "\(s.partNumber): JS mt must equal Swift material")
            XCTAssertEqual(s.js.ty, s.type,       "\(s.partNumber): JS ty must equal Swift type")
            XCTAssertEqual(s.js.lm, s.laminated,  "\(s.partNumber): JS lm must equal Swift laminated")
            XCTAssertEqual(s.js.br, s.buyUrlRoll, "\(s.partNumber): JS br must equal Swift buyUrlRoll")
            XCTAssertEqual(s.js.bb, s.buyUrlBulk, "\(s.partNumber): JS bb must equal Swift buyUrlBulk")
            XCTAssertTrue(s.type == "dieCut" || s.type == "continuous", "\(s.partNumber): type must be dieCut or continuous")
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

    // MARK: – ExcelRecordReader (Phase 3) — xlsx grid → records, header toggle

    /// With the header toggle ON, the first row names the columns and the rest are
    /// data — mirroring WireExportParser's record shape (Number/_Side surfaced).
    func testExcelRecordsWithHeaderRow() {
        let grid = [["_Side", "Number", "Cable"],
                    ["Source", "N1", "RIO 1"],
                    ["Destination", "N1", "RIO 1"]]
        let recs = ExcelRecordReader.records(rows: grid, headerRow: true)
        XCTAssertEqual(recs?.count, 2)
        XCTAssertEqual(recs?[0].wireID, "N1")
        XCTAssertEqual(recs?[0].side, "Source")
        XCTAssertEqual(recs?[0].fields["Cable"], "RIO 1")
        XCTAssertEqual(recs?[1].side, "Destination")
    }

    /// With the header toggle OFF, every row is data and columns become "Column N".
    func testExcelRecordsGenericHeaders() {
        let grid = [["A", "B"], ["C", "D"]]
        let recs = ExcelRecordReader.records(rows: grid, headerRow: false)
        XCTAssertEqual(recs?.count, 2)
        XCTAssertEqual(recs?[0].fields["Column 1"], "A")
        XCTAssertEqual(recs?[0].fields["Column 2"], "B")
        XCTAssertEqual(recs?[1].fields["Column 1"], "C")
    }

    /// Short rows are padded (never dropped) so a row's index stays put — the same
    /// guarantee the CSV parser makes.
    func testExcelRecordsPadsShortRow() {
        let grid = [["Number", "Cable", "Signal"],
                    ["N1"],                 // short
                    ["N2", "RIO", "LAN"]]
        let recs = ExcelRecordReader.records(rows: grid, headerRow: true)
        XCTAssertEqual(recs?.count, 2)
        XCTAssertEqual(recs?[0].fields["Cable"], "")    // padded
        XCTAssertEqual(recs?[0].fields["Signal"], "")
        XCTAssertEqual(recs?[1].fields["Signal"], "LAN")
    }

    /// Blank header cells get a "Column N" name and duplicates are disambiguated,
    /// so no two columns collapse into one field.
    func testExcelRecordsNormalizesHeaders() {
        let grid = [["Name", "", "Name"],
                    ["a", "b", "c"]]
        let recs = ExcelRecordReader.records(rows: grid, headerRow: true)
        XCTAssertEqual(recs?.count, 1)
        XCTAssertEqual(recs?[0].fields["Name"], "a")
        XCTAssertEqual(recs?[0].fields["Column 2"], "b")   // blank header → Column 2
        XCTAssertEqual(recs?[0].fields["Name (2)"], "c")   // duplicate disambiguated
    }

    /// A real `.xlsx` with NO xl/sharedStrings.xml (inline strings + a numeric cell)
    /// must still parse. CoreXLSX returns nil (not throws) for parseSharedStrings()
    /// when the table is absent, so the reader must tolerate a nil SharedStrings and
    /// fall back to inlineString / raw value. Fixture: a 2×2 sheet —
    /// header row "Number","Qty" (inline strings), data row "N1", 42 (number).
    func testExcelReaderToleratesMissingSharedStrings() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "inline-no-sharedstrings", withExtension: "xlsx"),
            "missing test fixture inline-no-sharedstrings.xlsx")
        let recs = try XCTUnwrap(
            ExcelRecordReader.records(fileURL: url, headerRow: true),
            "reader rejected a valid .xlsx that has no shared-strings table")
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].fields["Number"], "N1")   // inline string resolved
        XCTAssertEqual(recs[0].fields["Qty"], "42")      // numeric cell → raw value
    }

    /// A shared-string cell that points at a RICH-TEXT entry (formatting runs, no
    /// top-level <t>) must resolve to the joined run text, not the raw shared-string
    /// index. Fixture sharedStrings: 0="Name", 1="Tag", 2=rich-text "Hello "+"World".
    /// Sheet: header "Name","Tag"; data row references string 2 (rich) and string 1.
    func testExcelReaderResolvesRichTextSharedStrings() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "richtext-sharedstrings", withExtension: "xlsx"),
            "missing test fixture richtext-sharedstrings.xlsx")
        let recs = try XCTUnwrap(
            ExcelRecordReader.records(fileURL: url, headerRow: true),
            "reader rejected a valid .xlsx with rich-text shared strings")
        XCTAssertEqual(recs.count, 1)
        // The rich-text cell must join its runs, not print the index "2".
        XCTAssertEqual(recs[0].fields["Name"], "Hello World")
        XCTAssertEqual(recs[0].fields["Tag"], "Tag")
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

    // MARK: – IPC layer (Phase 1, Step 2)

    /// A print job must survive JSON encode→decode, with the VGL label buffers
    /// carried as base64 and the cut mode as a plain string.
    func testPrintJobFileRoundTrip() throws {
        let labels = [Data([0x1b, 0x58, 0x00, 0xff]), Data([0x00, 0x01, 0x02])]
        let job = PrintJobFile(id: "ABC123", createdAt: "2026-06-17T12:00:00Z",
                               sourceApp: "customdesigner", title: "Test", templateName: "T",
                               printerID: "p1", copies: 2, cutMode: .eachLabel,
                               estLabelMs: 850, labels: labels)
        let data = try JSONEncoder().encode(job)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"eachLabel\""))   // enum encodes as its string
        let back = try JSONDecoder().decode(PrintJobFile.self, from: data)
        XCTAssertEqual(back.id, "ABC123")
        XCTAssertEqual(back.cutMode, .eachLabel)
        XCTAssertEqual(back.copies, 2)
        XCTAssertEqual(back.labels, labels)
    }

    // MARK: – Phase 6: cut-mode plumbing

    /// `vglCutMode` maps the IPC cut SETTING onto the per-label BradyVGL.CutMode:
    ///   never → every label .never; eachLabel → every label .eachLabel;
    ///   afterJobLast → all .never except the last .afterJob.
    func testVGLCutModeMapping() {
        // never
        XCTAssertEqual(BradyVGL.vglCutMode(forIPCRawValue: "never", index: 0, total: 3), .never)
        XCTAssertEqual(BradyVGL.vglCutMode(forIPCRawValue: "never", index: 2, total: 3), .never)
        // eachLabel
        XCTAssertEqual(BradyVGL.vglCutMode(forIPCRawValue: "eachLabel", index: 0, total: 3), .eachLabel)
        XCTAssertEqual(BradyVGL.vglCutMode(forIPCRawValue: "eachLabel", index: 2, total: 3), .eachLabel)
        // afterJobLast: only the last index cuts
        XCTAssertEqual(BradyVGL.vglCutMode(forIPCRawValue: "afterJobLast", index: 0, total: 3), .never)
        XCTAssertEqual(BradyVGL.vglCutMode(forIPCRawValue: "afterJobLast", index: 1, total: 3), .never)
        XCTAssertEqual(BradyVGL.vglCutMode(forIPCRawValue: "afterJobLast", index: 2, total: 3), .afterJob)
        // unknown raw value defaults to the afterJobLast behaviour
        XCTAssertEqual(BradyVGL.vglCutMode(forIPCRawValue: "bogus", index: 2, total: 3), .afterJob)
        // single-label job: index 0 is the last, so it cuts
        XCTAssertEqual(BradyVGL.vglCutMode(forIPCRawValue: "afterJobLast", index: 0, total: 1), .afterJob)
    }

    /// The IPC `CutMode` raw values must exactly match the strings `vglCutMode`
    /// switches on, so the front-ends can pass `cutMode.rawValue` straight through.
    func testIPCCutModeRawValuesMatchVGLMapping() {
        XCTAssertEqual(CutMode.never.rawValue, "never")
        XCTAssertEqual(CutMode.eachLabel.rawValue, "eachLabel")
        XCTAssertEqual(CutMode.afterJobLast.rawValue, "afterJobLast")
    }

    /// The cut command lives behind one function. When enabled it emits the
    /// historical `ESC M <mode> 00`; when disabled it's a no-op (empty), and a
    /// built job then contains no cut bytes — proving the plumbing is testable
    /// without sending unverified bytes to hardware.
    func testCutCommandToggle() {
        let saved = BradyVGL.cutCommandEnabled
        defer { BradyVGL.cutCommandEnabled = saved }

        BradyVGL.cutCommandEnabled = true
        XCTAssertEqual(BradyVGL.cutCommand(for: .afterJob), [0x1B, 0x4D, 0x00, 0x00])
        XCTAssertEqual(BradyVGL.cutCommand(for: .eachLabel), [0x1B, 0x4D, 0x01, 0x00])
        XCTAssertEqual(BradyVGL.cutCommand(for: .never), [0x1B, 0x4D, 0x02, 0x00])

        BradyVGL.cutCommandEnabled = false
        XCTAssertEqual(BradyVGL.cutCommand(for: .eachLabel), [])

        // Build a tiny 1x8 all-white label both ways; the disabled job is exactly
        // the enabled job minus the 4 cut bytes.
        let px = [UInt8](repeating: 0x00, count: 8)   // 1 col x 8 rows, blank
        BradyVGL.cutCommandEnabled = true
        let withCut = BradyVGL.buildPrintJob(pixels: px, width: 1, height: 8, cutMode: .eachLabel)
        BradyVGL.cutCommandEnabled = false
        let noCut = BradyVGL.buildPrintJob(pixels: px, width: 1, height: 8, cutMode: .eachLabel)
        XCTAssertEqual(withCut.count - noCut.count, 4)
        // The no-cut job must not contain the ESC M (0x1B 0x4D) "set cut mode" pair.
        func containsESCM(_ bytes: [UInt8]) -> Bool {
            guard bytes.count >= 2 else { return false }
            for i in 0..<(bytes.count - 1) where bytes[i] == 0x1B && bytes[i + 1] == 0x4D { return true }
            return false
        }
        XCTAssertTrue(containsESCM(withCut))
        XCTAssertFalse(containsESCM(noCut))
    }

    /// The continuous feed-length command is a no-op by default (unverified bytes),
    /// so it must not alter a built job until explicitly enabled.
    func testFeedLengthCommandNoopByDefault() {
        XCTAssertFalse(BradyVGL.feedLengthCommandEnabled)
        XCTAssertEqual(BradyVGL.feedLengthCommand(lengthPixels: 450), [])
        XCTAssertEqual(BradyVGL.feedLengthCommand(lengthPixels: 0), [])
    }

    func testPrinterStatusFileRoundTrip() throws {
        let cas = CassetteStatus(partNumber: "M6-32-427", labelWidthMils: 1500, labelHeightMils: 1500,
                                 printableWidthMils: 1500, printableHeightMils: 500, isDieCut: true,
                                 supplyRemainingPct: 64, labelsPerRoll: 250, pixelWidth: 450, pixelHeight: 450)
        let status = PrinterStatusFile(updatedAt: "2026-06-17T12:00:00Z", engineRunning: true,
            printers: [PrinterStatusEntry(id: "p1", name: "Brady M611", model: "M611", serial: "S1",
                                          status: "ready", cassette: cas, activeJobCount: 0)])
        let data = try JSONEncoder().encode(status)
        let back = try JSONDecoder().decode(PrinterStatusFile.self, from: data)
        XCTAssertEqual(back.printers.first?.model, "M611")
        XCTAssertEqual(back.printers.first?.cassette?.partNumber, "M6-32-427")
        XCTAssertEqual(back.printers.first?.cassette?.labelsPerRoll, 250)
    }

    /// Write → claim (atomic move) → complete, plus status publish/read, against
    /// a temp directory (never the real Application Support tree).
    func testPrintQueueWriteClaimComplete() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vlqueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let q = PrintQueue(root: tmp)

        let job = PrintJobFile(id: "JOB1", createdAt: "t", sourceApp: "autoprint",
                               title: "x", templateName: "y", labels: [Data([1, 2, 3])])
        let written = try q.write(job)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(q.pendingJobURLs().count, 1)

        guard let claimed = q.claim(written) else { return XCTFail("claim failed") }
        XCTAssertEqual(claimed.job.id, "JOB1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.path))   // moved out of queue
        XCTAssertNil(q.claim(written))                                          // can't double-claim

        q.complete(claimed.processingURL, success: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: q.doneDir.appendingPathComponent("JOB1.json").path))

        let status = PrinterStatusFile(updatedAt: "t", engineRunning: true, printers: [])
        try q.publishStatus(status)
        XCTAssertEqual(q.readStatus()?.engineRunning, true)
    }

    // MARK: – Phase 4 file types (.vltmp / .vlcus)

    /// A custom-label document must survive JSON encode→decode with its canvas,
    /// embedded data snapshot, source path, and print settings intact.
    func testCustomLabelDocumentRoundTrip() throws {
        let tpl = VLTemplate(id: "t1", version: 1, name: "Loop", specN: "BM-32-427",
                             objs: [TemplateObject(t: "tx")])
        let doc = CustomLabelDocument(
            name: "Loop",
            template: tpl,
            headers: ["_Side", "Number", "Cable"],
            rows: [["_Side": "Source", "Number": "N1", "Cable": "RIO"],
                   ["_Side": "Destination", "Number": "N1", "Cable": "RIO"]],
            dataSourcePath: "/tmp/data.csv",
            dataSourceHeaderRow: true,
            cutMode: .eachLabel,
            copies: 3)
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(CustomLabelDocument.self, from: data)
        XCTAssertEqual(back.name, "Loop")
        XCTAssertEqual(back.specN, "BM-32-427")          // mirrored from the template
        XCTAssertEqual(back.template.objs.count, 1)
        XCTAssertEqual(back.headers, ["_Side", "Number", "Cable"])
        XCTAssertEqual(back.rows.count, 2)
        XCTAssertEqual(back.dataSourcePath, "/tmp/data.csv")
        XCTAssertEqual(back.cutMode, .eachLabel)
        XCTAssertEqual(back.copies, 3)
        // The embedded rows map back to WireRecords for the print path.
        XCTAssertEqual(back.records.count, 2)
        XCTAssertEqual(back.records[0].side, "Source")
        XCTAssertEqual(back.records[0].wireID, "N1")
        XCTAssertEqual(back.records[1].fields["Cable"], "RIO")
        XCTAssertEqual(back.dataSourceURL?.path, "/tmp/data.csv")
    }

    /// CustomLabelStore.load reads a written .vlcus and takes its name from the file
    /// stem (so renaming the file renames the label).
    func testCustomLabelStoreSaveLoad() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vlcus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tpl = VLTemplate(id: "t1", version: 1, name: "Original", specN: "BM-31-427", objs: [])
        let doc = CustomLabelDocument(name: "Original", template: tpl)
        let url = dir.appendingPathComponent("Renamed.vlcus")
        try CustomLabelStore.save(doc, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(CustomLabelStore.isCustomLabelFile(url))

        let loaded = try XCTUnwrap(CustomLabelStore.load(from: url))
        XCTAssertEqual(loaded.name, "Renamed")             // file stem wins
        XCTAssertEqual(loaded.template.name, "Renamed")
        XCTAssertEqual(loaded.specN, "BM-31-427")
    }

    /// TemplateStore.isTemplateFile recognises the new and legacy extensions.
    func testTemplateFileExtensionRecognition() {
        XCTAssertTrue(TemplateStore.isTemplateFile(URL(fileURLWithPath: "/x/Foo.vltmp")))
        XCTAssertTrue(TemplateStore.isTemplateFile(URL(fileURLWithPath: "/x/Foo.vlt.json")))
        XCTAssertTrue(TemplateStore.isTemplateFile(URL(fileURLWithPath: "/x/Foo.json")))
        XCTAssertFalse(TemplateStore.isTemplateFile(URL(fileURLWithPath: "/x/Foo.csv")))
        XCTAssertFalse(TemplateStore.isTemplateFile(URL(fileURLWithPath: "/x/Foo.vlcus")))
    }

    /// loadTemplate reads a .vltmp from any path and names it after the file stem.
    func testLoadTemplateFromVLTMP() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vltmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tpl = VLTemplate(id: "abc", version: 1, name: "Stored Name", specN: "BM-32-427",
                             objs: [TemplateObject(t: "rc")])
        let url = dir.appendingPathComponent("My Label.vltmp")
        try JSONEncoder().encode(tpl).write(to: url)

        let loaded = try XCTUnwrap(TemplateStore.loadTemplate(from: url))
        XCTAssertEqual(loaded.name, "My Label")            // file stem overrides stored name
        XCTAssertEqual(loaded.specN, "BM-32-427")
        XCTAssertEqual(loaded.objs.count, 1)
        XCTAssertEqual(loaded.id, "abc")
    }
}

// MARK: – Group 1: cross-process recents + reprint + progress/cancel IPC

/// The IPC plumbing that makes the Engine the single owner of recent prints,
/// reprint (re-read done/<id>.json), live job progress, and the cancel control
/// channel. All Core-only, so they run in the test target without EngineKit.
final class IPCGroup1Tests: XCTestCase {

    /// A fresh temp ipc root per test so nothing leaks into the real support dir.
    private func tempQueue() -> PrintQueue {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vl-ipc-\(UUID().uuidString)", isDirectory: true)
        let q = PrintQueue(root: root)
        q.ensureDirs()
        return q
    }

    // MARK: RecentPrint.jobId round-trips and tolerates older files.

    func testRecentPrintJobIDRoundTrip() throws {
        let r = RecentPrint(date: Date(), title: "T", sourceFileName: "",
                            templateName: "Tmpl", printerName: "M610",
                            labelCount: 3, printRange: .all, selectedIndices: [],
                            status: .printing, jobId: "abc-123")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RecentPrint.self, from: data)
        XCTAssertEqual(back.jobId, "abc-123")
        XCTAssertEqual(back.status, .printing)
    }

    func testRecentPrintDecodesWithoutJobID() throws {
        // A recent_prints.json written before the jobId field must still decode
        // (defaulting jobId to "") rather than wiping all history.
        let legacy = """
        [{"id":"\(UUID().uuidString)","date":0,"title":"Old","sourceFileName":"x.csv",
          "templateName":"T","printerName":"M610","labelCount":2,
          "printRange":"all","selectedIndices":[],"status":"complete"}]
        """
        let arr = try JSONDecoder().decode([RecentPrint].self, from: Data(legacy.utf8))
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0].jobId, "")           // missing → empty, not a decode failure
        XCTAssertEqual(arr[0].title, "Old")
    }

    // MARK: PrinterStatusFile.activeJobs round-trips and tolerates older files.

    func testStatusFileActiveJobsRoundTrip() throws {
        let job = ActiveJobStatus(id: "j1", title: "Run", sourceApp: "customdesigner",
                                  labelCount: 10, completed: 4, state: .printing)
        let status = PrinterStatusFile(updatedAt: "now", engineRunning: true,
                                       printers: [], activeJobs: [job])
        let data = try JSONEncoder().encode(status)
        let back = try JSONDecoder().decode(PrinterStatusFile.self, from: data)
        XCTAssertEqual(back.activeJobs.count, 1)
        XCTAssertEqual(back.activeJobs[0].id, "j1")
        XCTAssertEqual(back.activeJobs[0].completed, 4)
        XCTAssertEqual(back.activeJobs[0].state, .printing)
    }

    func testStatusFileDecodesWithoutActiveJobs() throws {
        // A printers.json from before activeJobs existed must still decode.
        let legacy = #"{"schema":1,"updatedAt":"now","engineRunning":true,"printers":[]}"#
        let back = try JSONDecoder().decode(PrinterStatusFile.self, from: Data(legacy.utf8))
        XCTAssertTrue(back.engineRunning)
        XCTAssertEqual(back.activeJobs, [])        // missing → empty
    }

    // MARK: Reprint reads a finished job's labels back from done/.

    func testReadDoneJobReturnsOriginalLabels() throws {
        let q = tempQueue()
        let original = PrintJobFile(
            id: "done-1", createdAt: "now", sourceApp: "autoprint",
            title: "Reprint me", templateName: "T", printerID: "v:p:s",
            copies: 1, cutMode: .afterJobLast, estLabelMs: 700,
            labels: [Data([1, 2, 3]), Data([4, 5, 6])])
        // Simulate a finished job by writing it straight into done/.
        let data = try JSONEncoder().encode(original)
        try data.write(to: q.doneDir.appendingPathComponent("done-1.json"))

        let read = try XCTUnwrap(q.readDoneJob(id: "done-1"))
        XCTAssertEqual(read.title, "Reprint me")
        XCTAssertEqual(read.labels, [Data([1, 2, 3]), Data([4, 5, 6])])
        XCTAssertEqual(read.cutMode, .afterJobLast)
        XCTAssertNil(q.readDoneJob(id: "missing"))   // no file → nil, no throw
    }

    // MARK: Control channel: write → drain → decode → delete.

    func testControlRequestRoundTripAndDrain() throws {
        let q = tempQueue()
        XCTAssertTrue(q.pendingControlURLs().isEmpty)

        let url = try q.writeControl(ControlRequest(action: .cancel, jobId: "job-9"))
        let pending = q.pendingControlURLs()
        XCTAssertEqual(pending.count, 1)

        let req = try XCTUnwrap(q.readControl(pending[0]))
        XCTAssertEqual(req.action, .cancel)
        XCTAssertEqual(req.jobId, "job-9")

        q.deleteControl(url)
        XCTAssertTrue(q.pendingControlURLs().isEmpty)  // handled requests are removed
    }

    /// The control dir is created by ensureDirs() and lives alongside the others.
    func testControlDirCreated() {
        let q = tempQueue()
        XCTAssertTrue(FileManager.default.fileExists(atPath: q.controlDir.path))
        XCTAssertEqual(q.controlDir.lastPathComponent, "control")
    }
}
