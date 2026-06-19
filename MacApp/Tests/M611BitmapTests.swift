import XCTest
import Compression
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
}
