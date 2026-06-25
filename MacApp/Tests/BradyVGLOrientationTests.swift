import XCTest
@testable import VectorLabelCore

/// Guards the BradyVGL (M610) raster orientation: the encoder must be ROW-major —
/// each raster line is a row of `width` pixels ACROSS the head, with `height` lines
/// along the FEED — matching the renderer + the validated M611 encoder. A column-major
/// regression would transpose the image (the 2"x4"-continuous-prints-rotated-and-clipped
/// bug).
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

    /// Ink only in the TOP ROW (full width): row-major emits exactly ONE raster line
    /// (that row) + a skip for the rest. Column-major would emit one line per column.
    func testTopRowInkIsOneRasterLine() {
        let w = 16, h = 5
        var px = [UInt8](repeating: 0, count: w * h)
        for c in 0..<w { px[c] = 0xFF }   // row 0 only
        let job = BradyVGL.buildPrintJob(pixels: px, width: w, height: h)
        XCTAssertEqual(rasterLineCount(job), 1, "top-row ink must be a single across-head line (row-major)")
    }

    /// A fully-inked raster emits one raster line PER ROW (= height), confirming the line
    /// count tracks the feed dimension, not the width.
    func testFullRasterEmitsHeightLines() {
        let w = 3, h = 7
        let px = [UInt8](repeating: 0xFF, count: w * h)
        let job = BradyVGL.buildPrintJob(pixels: px, width: w, height: h)
        XCTAssertEqual(rasterLineCount(job), h, "one across-head line per feed row")
    }
}
