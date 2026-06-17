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
