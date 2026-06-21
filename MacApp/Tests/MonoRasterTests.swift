import XCTest
@testable import VectorLabelCore

/// Tests for the shared mono-raster downscaler each driver uses to reduce the
/// 900-DPI master raster to its printer-native resolution.
final class MonoRasterTests: XCTestCase {

    func testExactThirdAllInk() {
        // 6×6 all ink, 900 → 300 (÷3) → 2×2 all ink.
        let px = [UInt8](repeating: 0xFF, count: 36)
        let d = MonoRaster.downscale(pixels: px, width: 6, height: 6, fromDPI: 900, toDPI: 300)
        XCTAssertEqual(d.width, 2)
        XCTAssertEqual(d.height, 2)
        XCTAssertEqual(d.pixels, [UInt8](repeating: 0xFF, count: 4))
    }

    func testBrotherWidthsAreExactAfterDownscale() {
        // The Brother supplies are defined so printableWidthInches = printWidth/180.
        // At 900 dpi that's printWidth*5 px; ÷5 to 180 recovers printWidth exactly.
        for pins in [24, 32, 50, 70, 112, 128] {
            let masterW = pins * 5
            let px = [UInt8](repeating: 0xFF, count: masterW * 5)
            let d = MonoRaster.downscale(pixels: px, width: masterW, height: 5, fromDPI: 900, toDPI: 180)
            XCTAssertEqual(d.width, pins, "pins=\(pins)")
        }
    }

    func testDimensions900to180() {
        let px = [UInt8](repeating: 0, count: 350 * 900)
        let d = MonoRaster.downscale(pixels: px, width: 350, height: 900, fromDPI: 900, toDPI: 180)
        XCTAssertEqual(d.width, 70)
        XCTAssertEqual(d.height, 180)
    }

    func testHairlineSurvives() {
        // A single ink column (1/5 of the across span) must survive a ÷5 reduction.
        let w = 15, h = 5
        var px = [UInt8](repeating: 0, count: w * h)
        for row in 0 ..< h { px[row * w + 7] = 0xFF }  // ink column at x=7
        let d = MonoRaster.downscale(pixels: px, width: w, height: h, fromDPI: 900, toDPI: 180)
        XCTAssertEqual(d.width, 3)
        XCTAssertEqual(d.height, 1)
        XCTAssertEqual(d.pixels[0], 0x00)   // cols 0–4: white
        XCTAssertEqual(d.pixels[1], 0xFF)   // cols 5–9: contains the inked column
        XCTAssertEqual(d.pixels[2], 0x00)   // cols 10–14: white
    }

    func testNeverUpscales() {
        let px = [UInt8](repeating: 0xFF, count: 4)
        let same = MonoRaster.downscale(pixels: px, width: 2, height: 2, fromDPI: 180, toDPI: 300)
        XCTAssertEqual(same.width, 2)
        XCTAssertEqual(same.height, 2)
        XCTAssertEqual(same.pixels, px)
    }

    func testWhiteStaysWhite() {
        let px = [UInt8](repeating: 0, count: 900 * 90)
        let d = MonoRaster.downscale(pixels: px, width: 900, height: 90, fromDPI: 900, toDPI: 300)
        XCTAssertEqual(d.width, 300)
        XCTAssertEqual(d.height, 30)
        XCTAssertTrue(d.pixels.allSatisfy { $0 == 0 })
    }
}
