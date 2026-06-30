import XCTest
@testable import VectorLabelCore

/// Regression guards for the senior-review fixes.
final class ReviewFixRegressionTests: XCTestCase {

    // MARK: – VGL skip-line chunking (a >65535 blank gap must not wrap the 16-bit field)

    /// Sum every ESC Z (0x1B 0x5A lo hi) skip count in a VGL stream.
    private func totalSkippedLines(_ job: [UInt8]) -> (sum: Int, commands: Int) {
        var sum = 0, count = 0, i = 0
        while i + 3 < job.count {
            if job[i] == 0x1B, job[i + 1] == 0x5A {
                sum += Int(job[i + 2]) | (Int(job[i + 3]) << 8)
                count += 1
                i += 4
            } else { i += 1 }
        }
        return (sum, count)
    }

    func testLongBlankGapIsChunkedNotTruncated() {
        // A 1px-wide, 66_000-line raster (row-major: height = feed) with ink ONLY on the
        // first and last line → a 65_998-line interior blank gap, above the 16-bit ceiling.
        let height = 66_000
        var pixels = [UInt8](repeating: 0, count: height)   // width = 1
        pixels[0] = 1
        pixels[height - 1] = 1

        let job = BradyVGL.buildPrintJob(pixels: pixels, width: 1, height: height, columnMajor: false)
        let (sum, commands) = totalSkippedLines(job)

        // The gap must be represented exactly (not 65_998 mod 65_536 = 462), which forces
        // more than one ESC Z command.
        XCTAssertEqual(sum, 65_998, "skip-line total must equal the true gap, not a wrapped value")
        XCTAssertGreaterThanOrEqual(commands, 2, "a >65535 gap must be split into multiple ESC Z chunks")
    }

    func testShortBlankGapStaysSingleChunk() {
        // Ink, 100 blank, ink → a single 100-line skip (no behavior change for normal labels).
        var pixels = [UInt8](repeating: 0, count: 102)
        pixels[0] = 1
        pixels[101] = 1
        let job = BradyVGL.buildPrintJob(pixels: pixels, width: 1, height: 102, columnMajor: false)
        let (sum, commands) = totalSkippedLines(job)
        XCTAssertEqual(sum, 100)
        XCTAssertEqual(commands, 1)
    }

    // MARK: – Supply sanitization (untrusted import / on-disk load)

    private func supply(_ w: Double, _ h: Double, pw: Double? = nil, ph: Double? = nil,
                        parts: [SupplyPartNumber] = []) -> Supply {
        Supply(name: "S", kind: .dieCut, selfLaminating: false, materialFamily: "",
               widthInches: w, heightInches: h,
               printableWidthInches: pw ?? w, printableHeightInches: ph ?? h, parts: parts)
    }

    func testSanitizedClampsDegenerateDimensions() {
        let zero = supply(0, -3).sanitized()
        XCTAssertGreaterThan(zero.widthInches, 0)
        XCTAssertGreaterThan(zero.heightInches, 0)

        let nan = supply(.nan, .infinity).sanitized()
        XCTAssertTrue(nan.widthInches.isFinite && nan.widthInches > 0)
        XCTAssertTrue(nan.heightInches.isFinite && nan.heightInches > 0)

        let huge = supply(99_999, 0.5).sanitized()
        XCTAssertLessThanOrEqual(huge.widthInches, 60.0, "absurd dimensions are clamped to the ceiling")
        XCTAssertEqual(huge.heightInches, 0.5, accuracy: 1e-9, "valid dimensions pass through unchanged")
    }

    func testSanitizedDropsBlankPartNumbers() {
        let parts = [
            SupplyPartNumber(partNumber: "M6-123", quantityPerRoll: 100),
            SupplyPartNumber(partNumber: "   ", quantityPerRoll: 100),
            SupplyPartNumber(partNumber: "", quantityPerRoll: 100),
        ]
        let s = supply(1, 1, parts: parts).sanitized()
        XCTAssertEqual(s.parts.map { $0.partNumber }, ["M6-123"])
    }

    func testSanitizedPreservesIdentity() {
        let s = supply(1, 1)
        XCTAssertEqual(s.sanitized().id, s.id, "sanitize must preserve ids (safe on the on-disk load path)")
    }

    // MARK: – Export version gate

    func testExportStampsCurrentVersion() {
        XCTAssertEqual(SupplyExport(category: SupplyCategory(name: "c", supplies: [])).version,
                       SupplyExport.currentVersion)
    }
}
