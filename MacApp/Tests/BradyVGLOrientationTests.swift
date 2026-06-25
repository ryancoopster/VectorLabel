import XCTest
@testable import VectorLabelCore

/// Guards the BradyVGL (M610) raster orientation, which is PER-STOCK because the renderer
/// rotates continuous 90° but not die-cut:
///   • row-major (continuous): width = across head, height = feed (the 2"x4"-continuous
///     fix — a long label's length runs along the feed, not clipped across the head).
///   • column-major (die-cut): height = across head, width = feed (the orientation that
///     printed correctly before the row-major change).
final class BradyVGLOrientationTests: XCTestCase {

    /// Count emitted raster-line commands (0x67 raw / 0x68 RLE) by walking the VGL stream.
    private func rasterLineCount(_ job: [UInt8]) -> Int {
        var i = 0, n = 0
        while i + 1 < job.count {
            guard job[i] == 0x1B else { i += 1; continue }
            switch job[i + 1] {
            case 0x58: i += 3                                   // job start (ESC X 00)
            case 0x5A: i += 4                                   // skip N lines (ESC Z lo hi)
            case 0x67, 0x68:                                    // raster line (ESC op lo hi data)
                guard i + 3 < job.count else { return n }
                let len = Int(job[i + 2]) | (Int(job[i + 3]) << 8)
                n += 1; i += 4 + len
            default: i += 2                                     // end page / end job / other
            }
        }
        return n
    }

    // ── Row-major (CONTINUOUS): width = across head, height = feed ──────────────────

    /// Ink only in the TOP ROW (full width): row-major emits exactly ONE raster line.
    func testRowMajorTopRowIsOneLine() {
        let w = 16, h = 5
        var px = [UInt8](repeating: 0, count: w * h)
        for c in 0..<w { px[c] = 0xFF }   // row 0 only
        let job = BradyVGL.buildPrintJob(pixels: px, width: w, height: h, columnMajor: false)
        XCTAssertEqual(rasterLineCount(job), 1, "top-row ink → one across-head line (row-major)")
    }

    /// A fully-inked raster emits one raster line PER ROW (= height) in row-major.
    func testRowMajorFullRasterEmitsHeightLines() {
        let w = 3, h = 7
        let px = [UInt8](repeating: 0xFF, count: w * h)
        let job = BradyVGL.buildPrintJob(pixels: px, width: w, height: h, columnMajor: false)
        XCTAssertEqual(rasterLineCount(job), h, "one across-head line per feed row (row-major)")
    }

    // ── Column-major (DIE-CUT): height = across head, width = feed ───────────────────

    /// Ink only in the LEFT COLUMN: column-major emits exactly ONE raster line. Guards the
    /// build-339 regression that flipped die-cut.
    func testColumnMajorLeftColumnIsOneLine() {
        let w = 16, h = 5
        var px = [UInt8](repeating: 0, count: w * h)
        for r in 0..<h { px[r * w] = 0xFF }   // column 0 only
        let job = BradyVGL.buildPrintJob(pixels: px, width: w, height: h, columnMajor: true)
        XCTAssertEqual(rasterLineCount(job), 1, "left-column ink → one across-head line (column-major)")
    }

    /// A fully-inked raster emits one raster line PER COLUMN (= width) in column-major.
    func testColumnMajorFullRasterEmitsWidthLines() {
        let w = 7, h = 3
        let px = [UInt8](repeating: 0xFF, count: w * h)
        let job = BradyVGL.buildPrintJob(pixels: px, width: w, height: h, columnMajor: true)
        XCTAssertEqual(rasterLineCount(job), w, "one across-head line per feed column (column-major)")
    }
}
