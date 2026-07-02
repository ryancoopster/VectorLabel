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

    /// The catalog must populate from the editable store's default seed (every app
    /// process loads it at launch / lazily). Spot-check the core supplies are present.
    func testDefaultCatalogPopulated() {
        XCTAssertGreaterThanOrEqual(BradyCatalog.sizes.count, 3)
        XCTAssertNotNil(BradyCatalog.size(forPartNumber: "M6-32-427"))
        XCTAssertNotNil(BradyCatalog.size(forPartNumber: "M6C-2000-595"))   // a continuous tape
    }

    /// Pin the exact physical + printable sizes and the feed rotation. These drive
    /// label rendering; any change here changes what prints. BM-33-427 is the
    /// tricky one: physical 1.5×4.0, printable 1.5×1.5, rotated 90°.
    func testBradyGeometryPinned() {
        // Pin against the BUNDLED factory catalog, not the developer's persisted catalog —
        // `feedRotationDeg`/`size` read SupplyCatalogStore.snapshot, which a user's "rotate
        // 90" edit (e.g. BM-32-427) would otherwise leak into this test.
        SupplyCatalogStore.setSnapshot(.makeDefault())
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
        // Buy URLs are per-part overrides now ("" ⇒ the buy buttons open a Brady
        // part-number search). The seed leaves them empty; unknown parts too (no crash).
        XCTAssertEqual(BradyCatalog.buyUrlRoll(forPartNumber: "BM-32-427"), "")
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

    /// The JS designer/print UIs no longer embed a static `BL` mirror of the
    /// catalog — they receive `window.__VL_CATALOG__` injected from the editable
    /// store (SupplyCatalogStore.webCatalogJSON), with a small hardcoded fallback
    /// for dev. So the old "BL mirrors BradyCatalog.json" sync test is retired.
    /// The default catalog's invariants are pinned by testBradyGeometryPinned,
    /// testLabelsPerRollKnownSizes and testSupplyTypeAndBuyURLs above.
    func testWebCatalogProjectionForModel() {
        let json = SupplyCatalogStore.webCatalogJSON(forModel: "M611")
        XCTAssertTrue(json.contains("\"bl\""), "projection must carry a bl array")
        XCTAssertTrue(json.contains("M6-32-427"), "projection must include seeded supplies")
        XCTAssertTrue(json.contains("\"categories\""), "projection must carry category names")
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

    /// Custom Designer reprint (Stage B): a "customdesigner" reprint request routes to
    /// the designer's OWN channel (never Auto Print's), and the design captured at print
    /// time in reprint.customDocJSON round-trips out of the done job so the Custom
    /// Designer can reopen the exact printed design.
    func testCustomDesignerReprintRoutingAndDesignRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vlqueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let q = PrintQueue(root: tmp)

        // The design captured at print time (the ".vlcus" model), serialized onto the job.
        let tpl = VLTemplate(id: "t1", version: 1, name: "Loop", specN: "BM-32-427",
                             objs: [TemplateObject(t: "tx")])
        let doc = CustomLabelDocument(name: "Loop", template: tpl, cutMode: .eachLabel, copies: 3)
        let docJSON = String(data: try JSONEncoder().encode(doc), encoding: .utf8)!

        // Land a done job carrying the captured design (write → claim → complete).
        let job = PrintJobFile(id: "JOB1", createdAt: "t", sourceApp: "customdesigner",
                               title: "Loop", templateName: "Loop",
                               labels: [Data([1, 2, 3])],
                               reprint: ReprintInfo(customDocJSON: docJSON))
        let written = try q.write(job)
        guard let claimed = q.claim(written) else { return XCTFail("claim failed") }
        q.complete(claimed.processingURL, success: true)

        // A customdesigner reprint request must route to the DESIGNER channel only.
        let recent = RecentPrint(date: Date(), title: "Loop", sourceFileName: "",
                                 templateName: "Loop", printerName: "M611", labelCount: 3,
                                 printRange: .all, selectedIndices: [], jobId: "JOB1",
                                 sourceApp: "customdesigner")
        try q.writeReprintRequest(recent)
        XCTAssertEqual(q.pendingCustomReprintURLs().count, 1, "should land in the designer channel")
        XCTAssertEqual(q.pendingReprintURLs().count, 0, "must NOT land in Auto Print's channel")

        // The designer reads the request → reads the done job → decodes the design.
        let reqURL = q.pendingCustomReprintURLs()[0]
        let readRecent = try XCTUnwrap(q.readReprintRequest(reqURL))
        XCTAssertEqual(readRecent.sourceApp, "customdesigner")
        let doneJob = try XCTUnwrap(q.readDoneJob(id: readRecent.jobId))
        let restoredJSON = try XCTUnwrap(doneJob.reprint?.customDocJSON)
        let restored = try JSONDecoder().decode(CustomLabelDocument.self, from: Data(restoredJSON.utf8))
        XCTAssertEqual(restored.name, "Loop")
        XCTAssertEqual(restored.specN, "BM-32-427")
        XCTAssertEqual(restored.copies, 3)
        XCTAssertEqual(restored.cutMode, .eachLabel)
        XCTAssertEqual(restored.template.objs.count, 1)

        // An autoprint reprint still routes to Auto Print's channel, untouched.
        let apRecent = RecentPrint(date: Date(), title: "AP", sourceFileName: "x.csv",
                                   templateName: "t", printerName: "M611", labelCount: 1,
                                   printRange: .all, selectedIndices: [], jobId: "JOB2",
                                   sourceApp: "autoprint")
        try q.writeReprintRequest(apRecent)
        XCTAssertEqual(q.pendingReprintURLs().count, 1, "autoprint routes to Auto Print's channel")
        XCTAssertEqual(q.pendingCustomReprintURLs().count, 1, "designer channel unchanged by an autoprint reprint")
    }

    /// done/ is retained for reprint but must be bounded so it can't grow without limit
    /// (custom-design jobs now embed the full .vlcus design). pruneDoneJobs(keep:) keeps
    /// the most-recent `keep` files and drops the rest; it's a no-op at/under `keep`.
    func testPruneDoneJobsBoundsArchive() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vlqueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let q = PrintQueue(root: tmp)
        func doneCount() -> Int {
            ((try? FileManager.default.contentsOfDirectory(at: q.doneDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.count
        }
        for i in 0..<6 {
            let job = PrintJobFile(id: "JOB\(i)", createdAt: "t", sourceApp: "autoprint",
                                   title: "x", templateName: "y", labels: [Data([UInt8(i)])])
            let w = try q.write(job)
            let c = try XCTUnwrap(q.claim(w))
            q.complete(c.processingURL, success: true)
        }
        XCTAssertEqual(doneCount(), 6)
        q.pruneDoneJobs(keep: 10)            // under the cap → no-op
        XCTAssertEqual(doneCount(), 6)
        q.pruneDoneJobs(keep: 3)             // bound it
        XCTAssertEqual(doneCount(), 3)
        q.pruneDoneJobs(keep: 0)
        XCTAssertEqual(doneCount(), 0)
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

    // MARK: – Table object ("tb") template coding

    /// A fully-populated table object (2×2, every cell field set, all locks on)
    /// must survive JSON encode→decode with every new field intact — both .vltmp
    /// and .vlcus ride on this VLTemplate coding.
    func testTableObjectRoundTrip() throws {
        let cellA = TableCell(mode: "static", text: "Hdr", field: "Number", f: "=Cable",
                              font: "Helvetica Neue", fs: 12, bold: true, italic: true,
                              underline: true, al: "center", valign: "top", wrapText: true,
                              tracking: 0.5, stretch: 110, autoScale: true, sized: true,
                              rs: 2, cs: 2)                  // merged-region anchor spans (v1.1)
        let cellB = TableCell(mode: "field", field: "Cable", fs: 9, al: "right", valign: "bottom")
        let cellC = TableCell(mode: "formula", f: #"=IF(Number<>"",Number,"")"#, stretch: 80)
        let cellD = TableCell()                              // empty cell stays empty
        let tb = TemplateObject(id: "o1", t: "tb", x: 0.1, y: 0.1, w: 0.9, h: 0.55, lw: 2,
                                cols: [0.45, 0.45], rows: [0.3, 0.25],
                                lockCols: true, lockRows: true, lockSize: true,
                                cells: [[cellA, cellB], [cellC, cellD]])
        let tpl = VLTemplate(id: "t1", version: 1, name: "Table", specN: "BM-32-427", objs: [tb])

        let data = try JSONEncoder().encode(tpl)
        let back = try JSONDecoder().decode(VLTemplate.self, from: data)
        XCTAssertEqual(back, tpl)                            // whole-template deep equality
        let o = try XCTUnwrap(back.objs.first)
        XCTAssertEqual(o.t, "tb")
        XCTAssertEqual(o.cols, [0.45, 0.45])
        XCTAssertEqual(o.rows, [0.3, 0.25])
        XCTAssertEqual(o.lockCols, true)
        XCTAssertEqual(o.lockRows, true)
        XCTAssertEqual(o.lockSize, true)
        XCTAssertEqual(o.lw, 2)
        XCTAssertEqual(o.cells?.count, 2)
        XCTAssertEqual(o.cells?[0].count, 2)
        XCTAssertEqual(o.cells?[0][0], cellA)                // every cell field round-trips
        XCTAssertEqual(o.cells?[0][1], cellB)
        XCTAssertEqual(o.cells?[1][0], cellC)
        XCTAssertEqual(o.cells?[1][1], cellD)
        XCTAssertEqual(o.cells?[0][0].rs, 2)                 // merge spans survive the trip
        XCTAssertEqual(o.cells?[0][0].cs, 2)
        XCTAssertNil(o.cells?[0][1].rs)                      // unmerged cells stay span-less
        XCTAssertNil(o.cells?[0][1].cs)
    }

    /// Pin the wire format: the JSON the HTML designers write (JS-style key names)
    /// must decode directly, so the Swift and JS sides never drift apart.
    func testTableObjectDecodesJSKeyNames() throws {
        let json = """
        {"id":"t9","version":1,"name":"tbl","specN":"BM-32-427","objs":[
          {"id":"o1","t":"tb","x":0.1,"y":0.1,"w":0.9,"h":0.55,"lw":2,
           "cols":[0.45,0.45],"rows":[0.3,0.25],
           "lockCols":true,"lockRows":false,"lockSize":true,
           "cells":[
             [{"mode":"static","text":"A","font":"Arial","fs":10,"bold":true,"italic":false,
               "underline":true,"al":"center","valign":"middle","wrapText":false,
               "tracking":0.5,"stretch":110,"autoScale":true,"rs":2,"cs":2},
              {"mode":"field","field":"Number"}],
             [{"mode":"formula","f":"=Cable"},{}]
           ]}
        ]}
        """
        let tpl = try JSONDecoder().decode(VLTemplate.self, from: Data(json.utf8))
        let o = try XCTUnwrap(tpl.objs.first)
        XCTAssertEqual(o.t, "tb")
        XCTAssertEqual(o.cols, [0.45, 0.45])
        XCTAssertEqual(o.rows, [0.3, 0.25])
        XCTAssertEqual(o.lockCols, true)
        XCTAssertEqual(o.lockRows, false)
        XCTAssertEqual(o.lockSize, true)
        let c00 = try XCTUnwrap(o.cells?[0][0])
        XCTAssertEqual(c00.mode, "static")
        XCTAssertEqual(c00.text, "A")
        XCTAssertEqual(c00.font, "Arial")
        XCTAssertEqual(c00.fs, 10)
        XCTAssertEqual(c00.bold, true)
        XCTAssertEqual(c00.italic, false)
        XCTAssertEqual(c00.underline, true)
        XCTAssertEqual(c00.al, "center")
        XCTAssertEqual(c00.valign, "middle")
        XCTAssertEqual(c00.wrapText, false)
        XCTAssertEqual(c00.tracking, 0.5)
        XCTAssertEqual(c00.stretch, 110)
        XCTAssertEqual(c00.autoScale, true)
        XCTAssertEqual(c00.rs, 2)                            // merge spans decode from JS keys
        XCTAssertEqual(c00.cs, 2)
        XCTAssertEqual(o.cells?[0][1].field, "Number")
        XCTAssertNil(o.cells?[0][1].rs)                      // pre-merge cells (no rs/cs) → nil
        XCTAssertNil(o.cells?[0][1].cs)
        XCTAssertEqual(o.cells?[1][0].f, "=Cable")
        XCTAssertEqual(o.cells?[1][1], TableCell())          // {} → all-nil cell
    }

    /// A template saved BEFORE tables existed (none of the new keys) must still
    /// decode, with every table field nil — the additions are strictly optional.
    func testTemplateWithoutTableKeysStillDecodes() throws {
        let legacy = """
        {"id":"old1","version":1,"name":"Legacy","specN":"BM-32-427","objs":[
          {"id":"o1","t":"tx","x":0.1,"y":0.1,"w":0.5,"h":0.2,"mode":"static","text":"hi"}
        ]}
        """
        let tpl = try JSONDecoder().decode(VLTemplate.self, from: Data(legacy.utf8))
        let o = try XCTUnwrap(tpl.objs.first)
        XCTAssertEqual(o.text, "hi")
        XCTAssertNil(o.cols)
        XCTAssertNil(o.rows)
        XCTAssertNil(o.lockCols)
        XCTAssertNil(o.lockRows)
        XCTAssertNil(o.lockSize)
        XCTAssertNil(o.cells)
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
