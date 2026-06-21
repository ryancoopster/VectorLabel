import Foundation

/// Brother **PT-series** raster job builder — the "classic" dialect spoken by the
/// PT-E550W / PT-P750W generation. A byte-for-byte Swift port of the
/// hardware-validated Python reference (`brother_pt.py`); the golden test vectors
/// in `BrotherPTTests` pin it to the same bytes.
///
/// Native resolution is **180 DPI, 128-pin head → 16 bytes per raster line**. The
/// printable height (pins) depends on the tape width because each width has an
/// unprintable margin on both sides of the head. Input to `imageToRaster` is the
/// Brother-orientation raster: row-major, 1 byte/px, `0xFF` = ink, with
/// **height == printWidth(tapeMm)** (across the tape) and width = label length
/// (along the tape). The `PTE550WModule` produces that orientation by downscaling
/// the 900-DPI master raster to 180 and transposing into the tape frame.
///
/// Job layout (one label): invalidate(100×00) · ESC @ · ESC i a 1 · ESC i ! n ·
/// ESC i z <print info> · ESC i M <cut> · [ESC i A] · ESC i K <adv> · ESC i d
/// <margin> · M 02 · <raster lines> · 0x0C (more) | 0x1A (last: feed+cut).
public enum BrotherPT {

    public static let vendorID: UInt16 = 0x04F9

    /// USB product ids this classic-dialect builder drives. (The PT-E560BT, PID
    /// 0x2203, is a different "D460BT" dialect and is intentionally not here.)
    public static let classicProductIDs: [UInt16: String] = [
        0x2060: "PT-E550W",
        0x2062: "PT-P750W",
    ]

    static let headPins = 128
    static let lineLengthBytes = 16        // 128 pins / 8
    public static let nativeDPI = 180
    static let minLabelDots = 174          // shorter rasters misbehave; pad up to this

    /// Tape width (mm) → unprintable margin pins on EACH side of the head.
    static let tapeMargins: [(mm: Double, margin: Int)] = [
        (3.5, 52), (6, 48), (9, 39), (12, 29), (18, 8), (24, 0),
    ]

    /// All supported TZe tape widths in mm, narrow → wide.
    public static let tapeWidthsMm: [Double] = tapeMargins.map { $0.mm }

    static func margin(forTapeMm mm: Double) -> Int? {
        tapeMargins.first { abs($0.mm - mm) < 0.001 }?.margin
    }

    /// Printable height in pins for a tape width (`128 - margin*2`), or nil if the
    /// width isn't a known TZe size.
    public static func printWidth(tapeMm mm: Double) -> Int? {
        margin(forTapeMm: mm).map { headPins - $0 * 2 }
    }

    /// The TZe width whose printable pin-height is closest to `acrossPx` — used to
    /// recover the tape from a rendered+downscaled raster's across-tape dimension.
    public static func nearestTape(forAcrossPx acrossPx: Int) -> Double {
        tapeMargins.min { lhs, rhs in
            abs((headPins - lhs.margin * 2) - acrossPx) < abs((headPins - rhs.margin * 2) - acrossPx)
        }!.mm
    }

    // MARK: – Protocol commands

    static func cmdInvalidate() -> [UInt8] { [UInt8](repeating: 0, count: 100) }
    static func cmdInitialize() -> [UInt8] { [0x1B, 0x40] }
    static func cmdEnterRasterMode() -> [UInt8] { [0x1B, 0x69, 0x61, 0x01] }

    /// 0 = printer auto-pushes status; 1 = do not auto-send. Classic models are fine
    /// with auto-push (the wedge is a D460BT-only problem).
    static func cmdEnableStatusNotification(_ notify: Bool) -> [UInt8] {
        [0x1B, 0x69, 0x21, notify ? 0x00 : 0x01]
    }

    static func cmdPrintInformation(numRasterLines n: Int, mediaWidthMm: Int) -> [UInt8] {
        [0x1B, 0x69, 0x7A, 0x84, 0x00, UInt8(truncatingIfNeeded: mediaWidthMm), 0x00,
         UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8),
         UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 24),
         0x00, 0x00]
    }

    static func cmdSetMode(autocut: Bool, mirror: Bool) -> [UInt8] {
        var mode: UInt8 = 0
        if autocut { mode |= 0x40 }
        if mirror  { mode |= 0x80 }
        return [0x1B, 0x69, 0x4D, mode]
    }

    static func cmdCutEveryN(_ n: Int) -> [UInt8] {
        [0x1B, 0x69, 0x41, UInt8(max(1, min(99, n)))]
    }

    /// Advanced mode. NOTE the inversion: SETTING bit 3 (0x08) means NO chain =
    /// feed+cut after the last page. Leaving it clear (chain mode) LOCKS the printer,
    /// so `chainPrinting` is kept false.
    static func cmdSetAdvancedMode(halfCut: Bool, chainPrinting: Bool,
                                   nocut: Bool = false, highRes: Bool = false) -> [UInt8] {
        var mode: UInt8 = 0
        if halfCut          { mode |= 0x04 }
        if !chainPrinting   { mode |= 0x08 }
        if nocut            { mode |= 0x10 }
        if highRes          { mode |= 0x40 }
        return [0x1B, 0x69, 0x4B, mode]
    }

    static func cmdMarginAmount(_ dots: Int) -> [UInt8] {
        [0x1B, 0x69, 0x64, UInt8(truncatingIfNeeded: dots), UInt8(truncatingIfNeeded: dots >> 8)]
    }

    static func cmdSetCompression() -> [UInt8] { [0x4D, 0x02] }

    // MARK: – PackBits (standard TIFF scheme)

    static func packbitsEncode(_ data: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var i = 0
        let n = data.count
        while i < n {
            let runStart = i
            while i + 1 < n && data[i] == data[i + 1] && i - runStart < 127 { i += 1 }
            if i > runStart {
                result.append(UInt8(truncatingIfNeeded: -(i - runStart)))   // run of (i-runStart+1) copies
                result.append(data[runStart])
                i += 1
            } else {
                let litStart = i
                while i < n && (i + 1 >= n || data[i] != data[i + 1]) && i - litStart < 127 { i += 1 }
                result.append(UInt8(i - litStart - 1))
                result.append(contentsOf: data[litStart..<i])
            }
        }
        return result
    }

    // MARK: – Raster line commands

    static func genRasterCommands(_ rasterData: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < rasterData.count {
            let end = min(i + lineLengthBytes, rasterData.count)
            let line = Array(rasterData[i..<end])
            if line.allSatisfy({ $0 == 0 }) {
                out.append(0x5A)                            // blank-line idiom
            } else {
                let packed = packbitsEncode(line)
                out.append(0x47)
                out.append(UInt8(truncatingIfNeeded: packed.count))
                out.append(UInt8(truncatingIfNeeded: packed.count >> 8))
                out.append(contentsOf: packed)
            }
            i += lineLengthBytes
        }
        return out
    }

    // MARK: – Image → raster (Brother orientation: height == printWidth, width = length)

    /// Pack a Brother-orientation mono raster into raster bytes (`width × 16`).
    /// `height` MUST equal `printWidth(tapeMm)`. Walks columns left-to-right (no
    /// mirroring); each column becomes one raster line. For each ink pixel, sets the
    /// bit at `pin = row + margin`, MSB-first. Returns nil on a size/width mismatch.
    public static func imageToRaster(pixels: [UInt8], width: Int, height: Int,
                                     tapeMm: Double) -> [UInt8]? {
        guard let margin = margin(forTapeMm: tapeMm),
              let pw = printWidth(tapeMm: tapeMm),
              height == pw, width > 0, pixels.count >= width * height else { return nil }
        var raster = [UInt8](repeating: 0, count: width * lineLengthBytes)
        for col in 0 ..< width {
            let lineOffset = col * lineLengthBytes
            for row in 0 ..< height where pixels[row * width + col] > 0 {
                let pin = row + margin
                let byteIdx = pin >> 3
                if byteIdx >= lineLengthBytes { continue }
                raster[lineOffset + byteIdx] |= UInt8(1) << (7 - (pin & 7))
            }
        }
        return raster
    }

    // MARK: – Job builders

    /// Build one classic-dialect print job for a label's raster bytes.
    public static func buildPrintJob(rasterData: [UInt8], tapeMm: Double,
                                     marginDots: Int = 14,
                                     autocut: Bool = true,
                                     halfCut: Bool = true,
                                     chainPrinting: Bool = false,   // keep false — chain locks the printer
                                     nocut: Bool = false,           // advanced-mode 0x10: suppress the cut (HW-unverified on classic)
                                     cutEveryN: Int = 1,
                                     mirror: Bool = false,
                                     highRes: Bool = false,
                                     isLastPage: Bool = true,
                                     skipInit: Bool = false,
                                     notify: Bool = true) -> [UInt8] {
        let numLines = rasterData.count / lineLengthBytes
        var parts: [UInt8] = []
        if !skipInit { parts += cmdInvalidate(); parts += cmdInitialize() }
        parts += cmdEnterRasterMode()
        parts += cmdEnableStatusNotification(notify)
        parts += cmdPrintInformation(numRasterLines: numLines, mediaWidthMm: Int(tapeMm))
        parts += cmdSetMode(autocut: autocut, mirror: mirror)
        if autocut && cutEveryN > 1 { parts += cmdCutEveryN(cutEveryN) }
        parts += cmdSetAdvancedMode(halfCut: halfCut, chainPrinting: chainPrinting,
                                    nocut: nocut, highRes: highRes)
        parts += cmdMarginAmount(marginDots)
        parts += cmdSetCompression()
        parts += genRasterCommands(rasterData)
        parts.append(isLastPage ? 0x1A : 0x0C)
        return parts
    }

    /// N labels as ONE stream — init once, half-cut score between labels, `0x0C` on
    /// intermediates, `0x1A` (feed+cut) on the last, never chain. On the classic
    /// models this prints the whole half-cut strip + final cut natively in one stream.
    /// `labels` are (rasterBytes) already in Brother orientation; `betweenHalfCut`
    /// scores between labels (a connected strip) vs leaving them whole.
    public static func buildBatchStream(labelRasters: [[UInt8]], tapeMm: Double,
                                        marginDots: Int = 14,
                                        betweenHalfCut: Bool = true,
                                        suppressEndCut: Bool = false) -> [UInt8] {
        var stream: [UInt8] = []
        for (i, raster) in labelRasters.enumerated() {
            let isLast = i == labelRasters.count - 1
            stream += buildPrintJob(
                rasterData: raster, tapeMm: tapeMm, marginDots: marginDots,
                autocut: false,                 // end-of-batch cut comes from the 0x1A feed+cut
                halfCut: betweenHalfCut && !isLast,
                chainPrinting: false,
                nocut: suppressEndCut && isLast,  // CutMode.never → leave the strip on the roll
                isLastPage: isLast,
                skipInit: i > 0)                // invalidate+initialize ONLY on the first page
        }
        return stream
    }

    // MARK: – Status parsing (32-byte block)

    public static let mediaTypes: [UInt8: String] = [
        0x00: "No tape", 0x01: "Laminated", 0x03: "Non-laminated",
        0x11: "Heat Shrink 2:1", 0x17: "Heat Shrink 3:1", 0xFF: "Incompatible",
    ]

    /// ESC i S status request: invalidate(100) · ESC @ · ESC i S.
    public static func statusRequest() -> [UInt8] {
        cmdInvalidate() + cmdInitialize() + [0x1B, 0x69, 0x53]
    }

    public struct Status {
        public var tapeWidthMm: Int        // 0 if none reported
        public var mediaType: String
        public var errors: [String]
        public var hasError: Bool
        public var coverOpen: Bool
        public var noMedia: Bool
        public var incompatibleMedia: Bool
    }

    /// Parse a 32-byte status block (offsets per the handoff): byte10 = tape width
    /// mm, byte11 = media type, byte18 = status type (0x02 = error). nil if too short.
    public static func parseStatus(_ data: [UInt8]) -> Status? {
        guard data.count >= 12 else { return nil }
        var errors: [String] = []
        var coverOpen = false, noMedia = false, incompatible = false
        let isError = data.count > 18 && data[18] == 0x02
        if isError {
            if data[8] & 0x01 != 0 { errors.append("No media"); noMedia = true }
            if data[8] & 0x04 != 0 { errors.append("Cutter jam") }
            if data[9] & 0x01 != 0 { errors.append("Wrong media"); incompatible = true }
            if data[9] & 0x10 != 0 { errors.append("Cover open"); coverOpen = true }
            if data[9] & 0x20 != 0 { errors.append("Overheating") }
        }
        let widthMm = Int(data[10])
        let mediaType = mediaTypes[data[11]] ?? "Unknown"
        if data[11] == 0xFF { incompatible = true }
        return Status(tapeWidthMm: widthMm, mediaType: mediaType, errors: errors,
                      hasError: isError, coverOpen: coverOpen, noMedia: noMedia,
                      incompatibleMedia: incompatible)
    }
}
