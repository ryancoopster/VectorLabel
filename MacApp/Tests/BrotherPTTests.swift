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

    // MARK: – D460BT dialect (PT-E560BT)

    /// Byte-exact D460BT single-page job: 2-column 12mm image (col0 full black, col1
    /// blank). Uncompressed raster, n9=0x02, the 7-byte magic margin, 200-zero init.
    func testGoldenD460BTPrintJob() {
        let h = BrotherPT.printWidth(tapeMm: 12)!   // 70
        var img = [UInt8](repeating: 0, count: 2 * h)
        for row in 0 ..< h { img[row * 2 + 0] = 1 }   // col0 full black, col1 blank
        let raster = BrotherPT.imageToRaster(pixels: img, width: 2, height: h, tapeMm: 12)!
        let job = BrotherPT.buildPrintJobD460BT(rasterData: raster, tapeMm: 12)
        let expected = [UInt8](repeating: 0, count: 200) + hex(
            "1b40" +
            "1b696101" +
            "1b697a84000c00020000000200" +   // print info: media 0x0c=12, 2 lines, n9=0x02 (last page)
            "1b69640e004d00" +               // magic margin: 14 dots + mandatory 4D 00
            "471000" + "00000007ffffffffffffffffe0000000" +   // col0 uncompressed (47 10 00 + 16 raw)
            "5a" +                           // col1 blank
            "1a")                            // feed+cut
        XCTAssertEqual(job, expected)
    }

    /// D460BT half-cut series framing for a 3-label strip (structural invariants from
    /// the reference self-test): one init, 3 page preambles, half-cut K only on the two
    /// intermediates, page-index sequence 00,01,02, NO ESC i M anywhere, single 1A.
    func testD460BTHalfcutSeriesFraming() {
        let h = BrotherPT.printWidth(tapeMm: 12)!
        var labels: [[UInt8]] = []
        for tag in 0 ..< 3 {
            var img = [UInt8](repeating: 0, count: 4 * h)
            for row in 0 ..< h { img[row * 4 + tag] = 1 }   // distinct inked column per label
            labels.append(BrotherPT.imageToRaster(pixels: img, width: 4, height: h, tapeMm: 12)!)
        }
        let series = BrotherPT.buildHalfcutSeriesD460BT(labelRasters: labels, tapeMm: 12)
        let init200 = [UInt8](repeating: 0, count: 200)
        XCTAssertEqual(Array(series.prefix(200)), init200, "must start with one 200-byte invalidate")
        XCTAssertEqual(count(of: init200, in: series), 1, "exactly one init block for the whole stream")
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x61, 0x01], in: series), 3, "3 page preambles")
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x4B, 0x04], in: series), 2, "half-cut K on the 2 intermediates")
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x4D], in: series), 0, "NO ESC i M (it blocks the final cut)")
        XCTAssertEqual(pageIndexSequence(series), [0x00, 0x01, 0x02])
        XCTAssertEqual(series.last, 0x1A, "single trailing feed+cut")
    }

    /// halfCutBetween:false (the `.afterJobLast` / `.never` framing): intermediates
    /// carry `ESC i K 0x00` (chain to next, NO cut) — NOT omitted and NOT half-cut —
    /// matching the disassembly ground truth that an ESC i K is present in every page
    /// preamble (handoff §6.4: a leading ESC i K 00 chains the page with no cut).
    func testD460BTSeriesNoHalfCutFraming() {
        let h = BrotherPT.printWidth(tapeMm: 12)!
        var labels: [[UInt8]] = []
        for tag in 0 ..< 3 {
            var img = [UInt8](repeating: 0, count: 4 * h)
            for row in 0 ..< h { img[row * 4 + tag] = 1 }
            labels.append(BrotherPT.imageToRaster(pixels: img, width: 4, height: h, tapeMm: 12)!)
        }
        let series = BrotherPT.buildHalfcutSeriesD460BT(labelRasters: labels, tapeMm: 12, halfCutBetween: false)
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x4B, 0x00], in: series), 2, "chain-no-cut K on the 2 intermediates")
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x4B, 0x04], in: series), 0, "no half-cut score when halfCutBetween:false")
        XCTAssertEqual(count(of: [0x1B, 0x69, 0x4D], in: series), 0, "still NO ESC i M anywhere")
        XCTAssertEqual(pageIndexSequence(series), [0x00, 0x01, 0x02])
        XCTAssertEqual(series.last, 0x1A)
    }

    /// The production strip = the chained series + a STANDALONE cutter job (its own
    /// 200-byte init), so the strip carries two init blocks and ends with a 1A.
    func testD460BTStripAddsStandaloneCutter() {
        let h = BrotherPT.printWidth(tapeMm: 12)!
        let raster = BrotherPT.imageToRaster(pixels: [UInt8](repeating: 0, count: 2 * h),
                                             width: 2, height: h, tapeMm: 12)!
        let strip = BrotherPT.buildHalfcutStripD460BT(labelRasters: [raster, raster], tapeMm: 12)
        XCTAssertEqual(count(of: [UInt8](repeating: 0, count: 200), in: strip), 2,
                       "series init + standalone cutter-job init")
        XCTAssertEqual(strip.last, 0x1A)
    }

    /// Find each ESC i z (1B 69 7A) and return its page-index byte (n9, offset +11).
    private func pageIndexSequence(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i + 12 < data.count {
            if data[i] == 0x1B, data[i + 1] == 0x69, data[i + 2] == 0x7A {
                out.append(data[i + 11]); i += 13
            } else { i += 1 }
        }
        return out
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
