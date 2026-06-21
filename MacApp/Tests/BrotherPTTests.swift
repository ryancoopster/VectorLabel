import XCTest
@testable import PrinterBrother

/// Byte-exact golden tests for the Brother PT classic-dialect encoder, ported from
/// the hardware-validated Python reference's `_self_test()`. These run offline (no
/// hardware) and are the pre-hardware guard that the Swift port emits identical bytes.
final class BrotherPTTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next() {
            out.append(UInt8(String([a, b]), radix: 16)!)
        }
        return out
    }

    // MARK: – PackBits vectors

    func testPackBitsVectors() {
        XCTAssertEqual(BrotherPT.packbitsEncode([0, 0, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 11)),
                       hex("ff00fefff600"))
        XCTAssertEqual(BrotherPT.packbitsEncode([UInt8](repeating: 0xFF, count: 16)), hex("f1ff"))
        XCTAssertEqual(BrotherPT.packbitsEncode([0xAA]), hex("00aa"))
        XCTAssertEqual(BrotherPT.packbitsEncode([0x12, 0x34, 0x56]), hex("02123456"))
    }

    // MARK: – printWidth / margins

    func testPrintWidths() {
        XCTAssertEqual(BrotherPT.printWidth(tapeMm: 3.5), 24)
        XCTAssertEqual(BrotherPT.printWidth(tapeMm: 6), 32)
        XCTAssertEqual(BrotherPT.printWidth(tapeMm: 9), 50)
        XCTAssertEqual(BrotherPT.printWidth(tapeMm: 12), 70)
        XCTAssertEqual(BrotherPT.printWidth(tapeMm: 18), 112)
        XCTAssertEqual(BrotherPT.printWidth(tapeMm: 24), 128)
        XCTAssertNil(BrotherPT.printWidth(tapeMm: 10))
    }

    func testNearestTape() {
        XCTAssertEqual(BrotherPT.nearestTape(forAcrossPx: 70), 12)
        XCTAssertEqual(BrotherPT.nearestTape(forAcrossPx: 50), 9)
        XCTAssertEqual(BrotherPT.nearestTape(forAcrossPx: 128), 24)
        XCTAssertEqual(BrotherPT.nearestTape(forAcrossPx: 69), 12)   // off-by-one snaps to 12mm
    }

    // MARK: – The 171-byte golden job (12mm tape, 4px-wide image)

    func testGoldenPrintJob() {
        let h = BrotherPT.printWidth(tapeMm: 12)!   // 70
        XCTAssertEqual(h, 70)
        var img = [UInt8](repeating: 0, count: 4 * h)
        for row in 0 ..< h { img[row * 4 + 0] = 1 }  // col0 full black
        img[0 * 4 + 2] = 1                           // col2 row0
        img[69 * 4 + 3] = 1                          // col3 row69
        let raster = BrotherPT.imageToRaster(pixels: img, width: 4, height: h, tapeMm: 12)!
        let job = BrotherPT.buildPrintJob(rasterData: raster, tapeMm: 12, marginDots: 14,
                                          autocut: false, halfCut: true, chainPrinting: false,
                                          isLastPage: false, skipInit: false)
        let expected = [UInt8](repeating: 0, count: 100) + hex(
            "1b40" +
            "1b696101" +
            "1b692100" +
            "1b697a84000c00040000000000" +   // print info: media 0x0c=12, 4 lines, n9=0x00 (more pages)
            "1b694d00" +                     // set mode: autocut off
            "1b694b0c" +                     // advanced: half-cut (0x04) | no-chain (0x08)
            "1b69640e00" +                   // margin 14
            "4d02" +                         // compression on
            "470a00fe000007f9ff00e0fe00" +   // col0 (PackBits)
            "5a" +                           // col1 blank
            "470600fe000004f500" +           // col2
            "470600f5000020fe00" +           // col3
            "0c")                            // 0x0C = more pages (is_last_page=False)
        XCTAssertEqual(job.count, 171)
        XCTAssertEqual(job, expected)
    }

    func testLastPageTerminatorAndInit() {
        let h = BrotherPT.printWidth(tapeMm: 12)!
        let raster = BrotherPT.imageToRaster(pixels: [UInt8](repeating: 0, count: 4 * h),
                                             width: 4, height: h, tapeMm: 12)!
        let last = BrotherPT.buildPrintJob(rasterData: raster, tapeMm: 12, isLastPage: true)
        XCTAssertEqual(last.last, 0x1A)                       // last page → feed+cut
        XCTAssertEqual(Array(last.prefix(100)), [UInt8](repeating: 0, count: 100))  // invalidate
        XCTAssertEqual(Array(last[100..<102]), [0x1B, 0x40]) // ESC @ initialize

        let skipped = BrotherPT.buildPrintJob(rasterData: raster, tapeMm: 12, isLastPage: false, skipInit: true)
        XCTAssertEqual(skipped.last, 0x0C)                   // not last → more pages
        XCTAssertNotEqual(Array(skipped.prefix(2)), [UInt8](repeating: 0, count: 2)) // no invalidate
        XCTAssertEqual(Array(skipped.prefix(4)), [0x1B, 0x69, 0x61, 0x01])           // straight to raster-mode
    }

    // MARK: – Batch stream framing (half-cut strip)

    func testBatchStreamFraming() {
        let h = BrotherPT.printWidth(tapeMm: 12)!
        let raster = BrotherPT.imageToRaster(pixels: [UInt8](repeating: 0, count: 2 * h),
                                             width: 2, height: h, tapeMm: 12)!
        let stream = BrotherPT.buildBatchStream(labelRasters: [raster, raster, raster], tapeMm: 12,
                                                betweenHalfCut: true)
        // Exactly one init block (100 zero bytes) for the whole stream.
        XCTAssertEqual(Array(stream.prefix(100)), [UInt8](repeating: 0, count: 100))
        // 3 page preambles (ESC i a 01).
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x61, 0x01], in: stream), 3)
        // Half-cut advanced-mode (ESC i K with bit 0x04) on the 2 intermediate labels.
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x4B, 0x0C], in: stream), 2)
        // One trailing feed+cut.
        XCTAssertEqual(stream.last, 0x1A)
    }

    func testNocutSetsAdvancedModeBit() {
        let h = BrotherPT.printWidth(tapeMm: 12)!
        let raster = BrotherPT.imageToRaster(pixels: [UInt8](repeating: 0, count: 2 * h),
                                             width: 2, height: h, tapeMm: 12)!
        // nocut → advanced-mode (ESC i K) = no-chain (0x08) | nocut (0x10) = 0x18.
        let job = BrotherPT.buildPrintJob(rasterData: raster, tapeMm: 12,
                                          autocut: false, halfCut: false, nocut: true)
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x4B, 0x18], in: job), 1)
        // Default (no nocut) → just no-chain (0x08).
        let normal = BrotherPT.buildPrintJob(rasterData: raster, tapeMm: 12,
                                             autocut: false, halfCut: false)
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x4B, 0x08], in: normal), 1)
    }

    func testSuppressEndCutOnlyAffectsLastPage() {
        let h = BrotherPT.printWidth(tapeMm: 12)!
        let raster = BrotherPT.imageToRaster(pixels: [UInt8](repeating: 0, count: 2 * h),
                                             width: 2, height: h, tapeMm: 12)!
        let stream = BrotherPT.buildBatchStream(labelRasters: [raster, raster], tapeMm: 12,
                                                betweenHalfCut: false, suppressEndCut: true)
        // Last page carries the nocut bit (0x10); since betweenHalfCut is false the
        // intermediate is plain no-chain (0x08), so exactly one 0x18 (the last page).
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x4B, 0x18], in: stream), 1)
        XCTAssertEqual(stream.last, 0x1A)
    }

    // MARK: – Status parsing

    func testStatusParse() {
        // 32-byte block: byte10 = 12mm, byte11 = 0x01 (laminated), byte18 = 0x00 (reply, no error).
        var b = [UInt8](repeating: 0, count: 32)
        b[10] = 12; b[11] = 0x01
        let s = BrotherPT.parseStatus(b)!
        XCTAssertEqual(s.tapeWidthMm, 12)
        XCTAssertEqual(s.mediaType, "Laminated")
        XCTAssertFalse(s.hasError)

        // Error block: byte18 = 0x02, byte9 bit4 = cover open.
        var e = [UInt8](repeating: 0, count: 32)
        e[18] = 0x02; e[9] = 0x10
        let es = BrotherPT.parseStatus(e)!
        XCTAssertTrue(es.hasError)
        XCTAssertTrue(es.coverOpen)
        XCTAssertTrue(es.errors.contains("Cover open"))
    }

    private func count(of needle: [UInt8], in hay: [UInt8]) -> Int {
        guard needle.count <= hay.count else { return 0 }
        var n = 0
        for i in 0 ... (hay.count - needle.count) where Array(hay[i..<i+needle.count]) == needle { n += 1 }
        return n
    }
}
