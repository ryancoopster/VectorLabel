import XCTest
@testable import VectorLabelCore

/// Tests for RenderedLabel's IPC seam: the self-describing `dpi` field, the
/// DEFLATE-compressed `pixelsZ` payload, the validating decoder, legacy
/// compatibility, and the DPI-relative print-time estimate.
final class RenderedLabelCodableTests: XCTestCase {

    func testRoundTrip() throws {
        var px = [UInt8](repeating: 0, count: 40 * 30)
        for i in stride(from: 0, to: px.count, by: 7) { px[i] = 0xFF }
        let label = RenderedLabel(pixels: px, width: 40, height: 30, partNumber: "TZe-231", dpi: 900)
        let data = try JSONEncoder().encode(label)
        let back = try JSONDecoder().decode(RenderedLabel.self, from: data)
        XCTAssertEqual(back, label)
        XCTAssertEqual(back.dpi, 900)
        XCTAssertEqual(back.bytes, px)
    }

    func testEncodesCompressedNotRaw() throws {
        // The mono raster should ride as `pixelsZ` (compressed), not raw `pixels`.
        let px = [UInt8](repeating: 0xFF, count: 200 * 200)   // highly compressible
        let label = RenderedLabel(pixels: px, width: 200, height: 200)
        let data = try JSONEncoder().encode(label)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"pixelsZ\""))
        XCTAssertFalse(json.contains("\"pixels\""))
        // Compression should make the payload far smaller than the raw 40 000 bytes.
        XCTAssertLessThan(data.count, 40_000 / 4)
    }

    func testLegacyRawPixelsDecodeAsDpi300() throws {
        // A pre-compression / pre-dpi job file: raw base64 `pixels`, no `dpi`.
        let raw: [UInt8] = [0, 0, 0, 0]   // 2×2 white
        let b64 = Data(raw).base64EncodedString()
        let json = "{\"width\":2,\"height\":2,\"partNumber\":\"x\",\"pixels\":\"\(b64)\"}"
        let label = try JSONDecoder().decode(RenderedLabel.self, from: Data(json.utf8))
        XCTAssertEqual(label.dpi, 300)        // absent → legacy 300 dpi
        XCTAssertEqual(label.width, 2)
        XCTAssertEqual(label.bytes, raw)
        XCTAssertEqual(label.partNumber, "x")
    }

    func testRejectsPixelCountMismatch() {
        // Declared 3×3 (=9) but only 4 bytes of raw pixels → must throw.
        let b64 = Data([0, 0, 0, 0]).base64EncodedString()
        let json = "{\"width\":3,\"height\":3,\"pixels\":\"\(b64)\"}"
        XCTAssertThrowsError(try JSONDecoder().decode(RenderedLabel.self, from: Data(json.utf8)))
    }

    func testRejectsAbsurdDimensions() {
        let json = "{\"width\":999999,\"height\":999999,\"pixels\":\"\"}"
        XCTAssertThrowsError(try JSONDecoder().decode(RenderedLabel.self, from: Data(json.utf8)))
    }

    func testEstimateIsDPIRelative() {
        // A 1.5" label is the same physical print time whether measured at 300 or 900 dpi.
        let at300 = RenderedLabel.estimatedPrintMs(maxDimensionPx: 450, dpi: 300)
        let at900 = RenderedLabel.estimatedPrintMs(maxDimensionPx: 1350, dpi: 900)
        XCTAssertEqual(at300, at900)
        XCTAssertEqual(at300, Int(1.5 * 370) + 300)
    }
}
