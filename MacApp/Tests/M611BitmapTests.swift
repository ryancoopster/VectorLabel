import XCTest
import Compression
import VectorLabelCore
@testable import PrinterM611

/// Golden / round-trip tests for the M611 bitmap encoder. These run offline in the
/// Core test target (no hardware): they pin the segment framing + BMP layout and
/// prove the LZ4 block round-trips, the only pre-hardware guard for the M611 bytes.
final class M611BitmapTests: XCTestCase {

    func testRotate270() {
        // 2 wide × 1 tall: ink at (col 0, row 0) only.
        let px: [UInt8] = [0xFF, 0x00]
        let r = M611Bitmap.rotate(pixels: px, width: 2, height: 1, deg: 270)
        XCTAssertEqual(r.width, 1)
        XCTAssertEqual(r.height, 2)
        // 270: out(X,Y) = ink(col = w-1-Y, row = X). out is 1 wide × 2 tall.
        XCTAssertEqual(r.pixels[0], 0x00)   // (X0,Y0) → ink(col1,row0) = white
        XCTAssertEqual(r.pixels[1], 0xFF)   // (X0,Y1) → ink(col0,row0) = ink
    }

    func testBMPHeaderAndPalette() {
        let px: [UInt8] = [0xFF, 0x00, 0x00, 0xFF] // 2×2
        let bmp = M611Bitmap.bmp1bpp(pixels: px, width: 2, height: 2)
        XCTAssertEqual(bmp[0], 0x42); XCTAssertEqual(bmp[1], 0x4D)              // "BM"
        func i32(_ o: Int) -> Int { Int(bmp[o]) | Int(bmp[o+1])<<8 | Int(bmp[o+2])<<16 | Int(bmp[o+3])<<24 }
        XCTAssertEqual(i32(18), 2)                                              // width
        XCTAssertEqual(i32(22), 2)                                             // height (+ = bottom-up)
        XCTAssertEqual(Int(bmp[28]) | Int(bmp[29])<<8, 1)                      // bitCount = 1
        XCTAssertEqual(Array(bmp[54..<58]), [0, 0, 0, 0])                      // palette idx0 = black
        XCTAssertEqual(Array(bmp[58..<62]), [255, 255, 255, 0])               // palette idx1 = white
    }

    func testBuildJobFramingAndLZ4RoundTrip() {
        let w = 16, h = 8
        var px = [UInt8](repeating: 0, count: w * h)
        px[0] = 0xFF; px[w * h - 1] = 0xFF; px[w * 3 + 5] = 0xFF
        let job = M611Bitmap.buildPrintJob(pixels: px, width: w, height: h,
                                           areaRotation: 270, substratePart: "M6-32-427")

        // Segment A
        XCTAssertEqual(Array(job[0..<16]), M611Bitmap.segMagic)
        let lenA = Int(job[16]) | Int(job[17])<<8 | Int(job[18])<<16 | Int(job[19])<<24
        let jsonA = try! JSONSerialization.jsonObject(with: Data(job[20..<20+lenA])) as! [String: Any]
        XCTAssertEqual(jsonA["JobType"] as? String, "Print")
        XCTAssertEqual(jsonA["SubstratePart"] as? String, "M6-32-427")
        XCTAssertEqual(jsonA["NumberOfPages"] as? Int, 1)

        // Segment B
        let bStart = 20 + lenA
        XCTAssertEqual(Array(job[bStart..<bStart+16]), M611Bitmap.segMagic)
        let lenB = Int(job[bStart+16]) | Int(job[bStart+17])<<8 | Int(job[bStart+18])<<16 | Int(job[bStart+19])<<24
        XCTAssertEqual(bStart + 20 + lenB, job.count)                          // no trailing bytes
        let jsonB = try! JSONSerialization.jsonObject(with: Data(job[bStart+20..<bStart+20+lenB])) as! [String: Any]
        // 270° rotation swaps dims: rendered 16×8 → raster 8×16; mils @300dpi.
        XCTAssertEqual(jsonB["LabelWidth"] as? Int, Int((8.0 / 300 * 1000).rounded()))
        XCTAssertEqual(jsonB["LabelHeight"] as? Int, Int((16.0 / 300 * 1000).rounded()))
        let pages = jsonB["Pages"] as! [String: Any]
        let layers = pages["Layers"] as! [[String: Any]]
        XCTAssertEqual(layers[0]["Compression"] as? String, "lz4")

        // LZ4 round-trip: the Bitmap must decompress back to exactly the BMP we'd build.
        let comp = Data(base64Encoded: layers[0]["Bitmap"] as! String)!
        let r = M611Bitmap.rotate(pixels: px, width: w, height: h, deg: 270)
        let expected = M611Bitmap.bmp1bpp(pixels: r.pixels, width: r.width, height: r.height)
        var dst = [UInt8](repeating: 0, count: expected.count)
        let n = comp.withUnsafeBytes { cp in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, expected.count,
                                          cp.bindMemory(to: UInt8.self).baseAddress!, comp.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        XCTAssertEqual(n, expected.count)
        XCTAssertEqual(dst, expected)
    }

    /// Pins the M611's physical-cut trigger: the PostPrintOperations JSON must follow
    /// the job's cutMode, not fire unconditionally. (The analogous M610/VGL mapping is
    /// covered in FoundationTests; this is the M611 equivalent.)
    func testPostPrintOpsCutModes() {
        // never → defer to the printer (no shear), regardless of page position.
        XCTAssertEqual(M611Bitmap.postPrintOps(cut: .never, isLastPage: true)[0]["SetByPrinter"] as? String, "SetByPrinter")
        XCTAssertNil(M611Bitmap.postPrintOps(cut: .never, isLastPage: true)[0]["Cut"])
        // eachLabel → shear on every page.
        XCTAssertEqual(M611Bitmap.postPrintOps(cut: .eachLabel, isLastPage: false)[0]["Cut"] as? String, "Shear")
        XCTAssertEqual(M611Bitmap.postPrintOps(cut: .eachLabel, isLastPage: true)[0]["Cut"] as? String, "Shear")
        // afterJobLast → shear only on the last page, defer otherwise.
        XCTAssertEqual(M611Bitmap.postPrintOps(cut: .afterJobLast, isLastPage: true)[0]["Cut"] as? String, "Shear")
        XCTAssertNil(M611Bitmap.postPrintOps(cut: .afterJobLast, isLastPage: false)[0]["Cut"])
        XCTAssertEqual(M611Bitmap.postPrintOps(cut: .afterJobLast, isLastPage: false)[0]["SetByPrinter"] as? String, "SetByPrinter")
    }

    /// A multi-page job is ONE job-meta segment (NumberOfPages = N) followed by N page
    /// segments (PageNumber 0…N-1) — a single printer job, not N concatenated jobs. With
    /// afterJobLast only the final page shears; the rest defer to the printer.
    func testBuildMultiPageJob() {
        let w = 8, h = 8, n = 3
        func raster(_ i: Int) -> [UInt8] { var p = [UInt8](repeating: 0, count: w*h); p[i] = 0xFF; return p }
        let pages = (0..<n).map { i in
            M611Bitmap.Page(pixels: raster(i), width: w, height: h, cut: .afterJobLast, isLast: i == n - 1)
        }
        let job = M611Bitmap.buildMultiPageJob(pages: pages, areaRotation: 0, substratePart: "M6-32-427")

        // Walk the framed segments: [16 magic][u32 LE len][json] × (1 meta + n pages).
        var off = 0
        func nextJSON() -> [String: Any] {
            XCTAssertEqual(Array(job[off..<off+16]), M611Bitmap.segMagic)
            let len = Int(job[off+16]) | Int(job[off+17])<<8 | Int(job[off+18])<<16 | Int(job[off+19])<<24
            let json = try! JSONSerialization.jsonObject(with: Data(job[off+20..<off+20+len])) as! [String: Any]
            off += 20 + len
            return json
        }
        // Meta segment first: NumberOfPages must reflect the real count.
        let meta = nextJSON()
        XCTAssertEqual(meta["JobType"] as? String, "Print")
        XCTAssertEqual(meta["NumberOfPages"] as? Int, n)
        XCTAssertEqual(meta["SubstratePart"] as? String, "M6-32-427")
        // Then n page segments: PageNumber 0…n-1, cut only on the last.
        for i in 0..<n {
            let page = nextJSON()
            XCTAssertEqual(page["PageNumber"] as? Int, i)
            XCTAssertEqual(page["JobID"] as? String, meta["JobID"] as? String)   // same job
            let ops = (page["Pages"] as! [String: Any])["PostPrintOperations"] as! [[String: Any]]
            if i == n - 1 { XCTAssertEqual(ops[0]["Cut"] as? String, "Shear") }
            else          { XCTAssertEqual(ops[0]["SetByPrinter"] as? String, "SetByPrinter") }
        }
        XCTAssertEqual(off, job.count)   // consumed exactly 1 meta + n pages, no trailing bytes
    }

    func testBuildMultiPageJobEmptyIsEmpty() {
        XCTAssertTrue(M611Bitmap.buildMultiPageJob(pages: []).isEmpty)
    }
}
