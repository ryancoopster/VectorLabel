import XCTest
@testable import VectorLabelCore
@testable import PrinterM610

/// Guards `M610Module.acrossHeadIsHeight` — the M610's raster orientation decision, which
/// MATCHES the rendered raster to the printer-reported printable area (SmartCell
/// `printableWidthMils`) instead of a catalog part-number lookup (the build-342 regression
/// that clipped continuous). Returns true = column-major (height across head), false =
/// row-major (width across head). All sizes are native 300-dpi pixels.
final class M610OrientTests: XCTestCase {

    /// Build a CassetteStatus carrying only the fields the orientation decision reads.
    private func status(printableWidthMils: Int, isDieCut: Bool) -> CassetteStatus {
        CassetteStatus(partNumber: "TEST", labelWidthMils: 0, labelHeightMils: 0,
                       printableWidthMils: printableWidthMils, printableHeightMils: 0,
                       isDieCut: isDieCut, supplyRemainingPct: 100, labelsPerRoll: nil,
                       pixelWidth: 0, pixelHeight: 0)
    }

    /// CONTINUOUS tape: a 2"x4" raster (600x1200 px) on a 2" tape (printableWidth 2000 mils →
    /// 600 px). Width matches across → row-major, so the 4" length runs along the feed
    /// (NOT clipped to the head). This is the case build 342 regressed.
    func testContinuousWidthMatchesAcross_rowMajor() {
        let s = status(printableWidthMils: 2000, isDieCut: false)
        XCTAssertFalse(M610Module.acrossHeadIsHeight(rasterWidth: 600, rasterHeight: 1200, status: s))
    }

    /// PORTRAIT die-cut (across = height): a 1.5"x0.5" printable (450x150 px) fed with the
    /// 0.5" dimension across the head (printableWidth 500 mils → 150 px). Height matches
    /// across → column-major.
    func testDieCutHeightMatchesAcross_columnMajor() {
        let s = status(printableWidthMils: 500, isDieCut: true)
        XCTAssertTrue(M610Module.acrossHeadIsHeight(rasterWidth: 450, rasterHeight: 150, status: s))
    }

    /// LANDSCAPE die-cut (across = width): the printable WIDTH matches the reported across-
    /// head width, so even a die-cut resolves to row-major. Proves the decision adapts
    /// per-supply to the hardware rather than assuming die-cut ⇒ column-major.
    func testDieCutWidthMatchesAcross_rowMajorOverridesDieCut() {
        let s = status(printableWidthMils: 2000, isDieCut: true)   // 2" across → 600 px
        XCTAssertFalse(M610Module.acrossHeadIsHeight(rasterWidth: 600, rasterHeight: 300, status: s))
    }

    /// SQUARE/ambiguous (both axes match the reported width): the dimension test can't
    /// decide, so fall back to the hardware die-cut bit.
    func testSquareAmbiguous_fallsBackToDieCutBit() {
        let dieCut = status(printableWidthMils: 1500, isDieCut: true)    // 450 px, raster 450x450
        XCTAssertTrue(M610Module.acrossHeadIsHeight(rasterWidth: 450, rasterHeight: 450, status: dieCut))
        let cont = status(printableWidthMils: 1500, isDieCut: false)
        XCTAssertFalse(M610Module.acrossHeadIsHeight(rasterWidth: 450, rasterHeight: 450, status: cont))
    }

    /// No reported width (0) → fall back to the die-cut bit, never compare against 0.
    func testZeroPrintableWidth_fallsBackToDieCutBit() {
        XCTAssertFalse(M610Module.acrossHeadIsHeight(rasterWidth: 600, rasterHeight: 1200,
                                                     status: status(printableWidthMils: 0, isDieCut: false)))
        XCTAssertTrue(M610Module.acrossHeadIsHeight(rasterWidth: 600, rasterHeight: 1200,
                                                    status: status(printableWidthMils: 0, isDieCut: true)))
    }

    /// No cassette status at all → die-cut default (column-major), the pre-339-safe choice.
    func testNilStatus_defaultsToColumnMajor() {
        XCTAssertTrue(M610Module.acrossHeadIsHeight(rasterWidth: 600, rasterHeight: 1200, status: nil))
    }
}
