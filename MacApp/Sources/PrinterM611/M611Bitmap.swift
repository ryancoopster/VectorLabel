import Foundation
import Compression

/// Builds Brady **M611** network print jobs.
///
/// The M611 does NOT speak VGL like the M610. It consumes a rendered **1-bpp
/// bitmap** wrapped in JSON "segments" sent to the printer's raw port (TCP:9100).
/// Reverse-engineered from Brady's published SDK and validated on real hardware
/// (see memory: m611-protocol). This encoder is the M611 sibling of `BradyVGL`.
///
/// Input is identical to `BradyVGL.buildPrintJob`: a 1-byte-per-pixel mono buffer,
/// row-major, top-left origin, **0xFF = ink (black), 0x00 = white**, width×height
/// — exactly what `LabelRenderer.render` produces. The only extra input is
/// `areaRotation`, the printer's raster-frame rotation (PICL "Area Rotation",
/// e.g. 270 for M6 die-cut wire labels), which maps the reading-orientation design
/// onto the physical tape.
public enum M611Bitmap {

    /// User cut intent, mirroring the Core IPC `CutMode` (raw string values).
    public enum CutMode: String {
        case afterJobLast
        case eachLabel
        case never
    }

    /// 16-byte segment magic that prefixes every job/page segment.
    static let segMagic: [UInt8] = [0x7F, 0x42, 0xEE, 0x41, 0xA9, 0x1D, 0x40, 0x90,
                                    0x9B, 0xEC, 0xFF, 0x7A, 0x66, 0x14, 0xCC, 0x22]
    static let dpi = 300

    /// Build one complete M611 print job (job-meta segment + one page segment) for
    /// a rendered label. Returns the raw bytes to write to TCP:9100.
    public static func buildPrintJob(pixels: [UInt8], width: Int, height: Int,
                                     areaRotation: Int = 0,
                                     substratePart: String = "",
                                     cut: CutMode = .afterJobLast,
                                     isLastPage: Bool = true,
                                     jobID: String = "VL0000000000000000000000000000",
                                     jobTime: String = "20000101000000") -> [UInt8] {
        // 1. Rotate the rendered raster into the printer's raster frame.
        let r = rotate(pixels: pixels, width: width, height: height, deg: areaRotation)
        // 2. Pack a 1-bpp BMP (palette idx0=black/idx1=white, ink = bit 0).
        let bmp = bmp1bpp(pixels: r.pixels, width: r.width, height: r.height)
        // 3. Raw LZ4 block (Apple Compression COMPRESSION_LZ4_RAW — the M611's format).
        let comp = lz4RawBlock(bmp)
        let b64 = Data(comp).base64EncodedString()
        // 4. Label dims, in MILS, in the printer's RASTER orientation (across-head × feed).
        let labelWmils = Int((Double(r.width)  / Double(dpi) * 1000).rounded())
        let labelHmils = Int((Double(r.height) / Double(dpi) * 1000).rounded())
        // 5. Two JSON segments: job metadata + the page.
        let segA = segment(jobMetaJSON(jobID: jobID, jobTime: jobTime, part: substratePart))
        let segB = segment(pageJSON(jobID: jobID, labelW: labelWmils, labelH: labelHmils,
                                    bitmapB64: b64, cut: cut, isLastPage: isLastPage))
        return segA + segB
    }

    // MARK: – Raster rotation (reading frame → printer raster frame)

    /// Rotate a mono raster clockwise by `deg` (0/90/180/270). Output `0xFF` = ink.
    static func rotate(pixels: [UInt8], width w: Int, height h: Int, deg: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let d = ((deg % 360) + 360) % 360
        let inkAt: (Int, Int) -> Bool = { col, row in pixels[row * w + col] != 0 }
        let (outW, outH): (Int, Int) = (d == 90 || d == 270) ? (h, w) : (w, h)
        var out = [UInt8](repeating: 0, count: outW * outH)
        for y in 0 ..< outH {
            for x in 0 ..< outW {
                let ink: Bool
                switch d {
                case 90:  ink = inkAt(y, h - 1 - x)          // get(X,Y)=g[h-1-X][Y]
                case 180: ink = inkAt(w - 1 - x, h - 1 - y)  // get(X,Y)=g[h-1-Y][w-1-X]
                case 270: ink = inkAt(w - 1 - y, x)          // get(X,Y)=g[X][w-1-Y]
                default:  ink = inkAt(x, y)                  // 0
                }
                out[y * outW + x] = ink ? 0xFF : 0x00
            }
        }
        return (out, outW, outH)
    }

    // MARK: – 1-bpp BMP

    /// Pack a mono raster (`0xFF` = ink) into a 1-bpp bottom-up Windows BMP.
    /// Palette: index0 = black, index1 = white; **a black pixel clears the bit
    /// (ink = bit 0)** — hardware-validated polarity.
    static func bmp1bpp(pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let rowBytes = ((width + 31) / 32) * 4
        var pix = [UInt8](repeating: 0xFF, count: rowBytes * height)   // all white (bit 1)
        for y in 0 ..< height {
            let row = height - 1 - y                                    // bottom-up
            for x in 0 ..< width where pixels[y * width + x] != 0 {     // ink → clear bit
                pix[row * rowBytes + (x >> 3)] &= ~(UInt8(0x80) >> (x & 7))
            }
        }
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        let off = 14 + 40 + 8
        var out: [UInt8] = []
        out += [0x42, 0x4D]; out += u32(off + pix.count); out += u16(0); out += u16(0); out += u32(off)   // BITMAPFILEHEADER
        out += u32(40); out += u32(width); out += u32(height)          // BITMAPINFOHEADER: +height = bottom-up
        out += u16(1); out += u16(1); out += u32(0); out += u32(pix.count)
        out += u32(0); out += u32(0); out += u32(0); out += u32(0)
        out += [0, 0, 0, 0]; out += [255, 255, 255, 0]                 // palette: idx0 black, idx1 white
        out += pix
        return out
    }

    // MARK: – LZ4 raw block

    static func lz4RawBlock(_ src: [UInt8]) -> [UInt8] {
        let cap = src.count + src.count / 2 + 256
        var dst = [UInt8](repeating: 0, count: cap)
        let n = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, cap, s.baseAddress!, src.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return Array(dst.prefix(n))
    }

    // MARK: – Segment framing + JSON

    /// `[16-byte magic][uint32 LE jsonLen][JSON]`
    static func segment(_ json: Data) -> [UInt8] {
        let len = UInt32(json.count)
        var out = segMagic
        out += [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF)]
        out += [UInt8](json)
        return out
    }

    static func jobMetaJSON(jobID: String, jobTime: String, part: String) -> Data {
        let dict: [String: Any] = [
            "JobID": jobID, "JobName": "VectorLabel Print", "JobTime": jobTime,
            "NumberOfPages": 1, "SubstratePart": part, "JobType": "Print", "JobSource": "VectorLabel",
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    static func pageJSON(jobID: String, labelW: Int, labelH: Int, bitmapB64: String,
                         cut: CutMode, isLastPage: Bool) -> Data {
        let layer: [String: Any] = ["Bitmap": bitmapB64, "Compression": "lz4"]
        let pages: [String: Any] = [
            "Layers": [layer], "PrePrintOperations": "",
            "PostPrintOperations": postPrintOps(cut: cut, isLastPage: isLastPage),
        ]
        let dict: [String: Any] = [
            "PrintFileName": "Page1.prn", "JobID": jobID, "PageNumber": 0,
            "LabelWidth": labelW, "LabelHeight": labelH, "Pages": pages,
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    /// Map cut intent to the M611 PostPrintOperations array. Defaults to
    /// `SetByPrinter` (defer to the printer's setting) — validated as safe on
    /// die-cut M6 stock. A shear cut is emitted only for continuous tape.
    static func postPrintOps(cut: CutMode, isLastPage: Bool) -> [[String: Any]] {
        switch cut {
        case .never:        return [["SetByPrinter": "SetByPrinter"]]
        case .eachLabel:    return [["Cut": "Shear"]]
        case .afterJobLast: return isLastPage ? [["Cut": "Shear"]] : [["SetByPrinter": "SetByPrinter"]]
        }
    }
}
