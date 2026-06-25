import XCTest
@testable import VectorLabelCore
@testable import PrinterM610

/// Guards the M610 raster orientation: the encoder must derive row-major vs column-major
/// from the renderer's `RenderedLabel.landscape` flag — NOT a catalog part-number lookup
/// (the build-342 regression) and NOT the SmartCell printable area (build 343, where
/// `printableWidthMils` is the label's own-frame width and `isDieCut` reads true even for
/// continuous tape). `landscape == true` (continuous-style) ⇒ row-major; `false` (die-cut
/// upright) ⇒ column-major.
final class M610OrientTests: XCTestCase {

    /// Count emitted raster-line commands (0x67 raw / 0x68 RLE) in a VGL stream.
    private func rasterLineCount(_ job: [UInt8]) -> Int {
        var i = 0, n = 0
        while i + 1 < job.count {
            guard job[i] == 0x1B else { i += 1; continue }
            switch job[i + 1] {
            case 0x58: i += 3
            case 0x5A: i += 4
            case 0x67, 0x68:
                guard i + 3 < job.count else { return n }
                let len = Int(job[i + 2]) | (Int(job[i + 3]) << 8)
                n += 1; i += 4 + len
            default: i += 2
            }
        }
        return n
    }

    /// Encode a raster whose TOP ROW is fully inked, at native 300 dpi (downscale is the
    /// identity), tagged with the given landscape flag, through the real M610 encoder.
    private func encodeTopRow(landscape: Bool, w: Int, h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h)
        for c in 0..<w { px[c] = 0xFF }            // row 0 only
        let label = RenderedLabel(pixels: px, width: w, height: h, dpi: 300, landscape: landscape)
        return M610Module().encode(label: label, status: nil, cut: .never, isLastLabel: true)
    }

    /// CONTINUOUS-style (landscape): row-major — the full top row is ONE across-head line.
    func testLandscapeIsRowMajor() {
        XCTAssertEqual(rasterLineCount(encodeTopRow(landscape: true, w: 16, h: 5)), 1,
                       "landscape ⇒ row-major: top row = one across-head line")
    }

    /// DIE-CUT (upright): column-major — the top row becomes one line PER column (= width).
    func testUprightIsColumnMajor() {
        XCTAssertEqual(rasterLineCount(encodeTopRow(landscape: false, w: 16, h: 5)), 16,
                       "upright ⇒ column-major: top row spans one line per feed column")
    }
}
