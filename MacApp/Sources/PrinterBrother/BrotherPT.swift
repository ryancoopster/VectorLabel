import Foundation
import VectorLabelCore

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

    // PID → model routing lives on each PrinterModule (PTE550WModule / PTP750WModule /
    // PTE560BTModule), so the registry has one module per printer and the D460BT PID
    // can never be claimed by a classic module. `d460ProductIDs` (below) is the only
    // PID table kept here, shared by PTE560BTModule.

    static let headPins = 128
    static let lineLengthBytes = 16        // 128 pins / 8
    public static let nativeDPI = 180
    static let minLabelDots = 174          // shorter rasters misbehave; pad up to this

    /// Tape width (mm) → unprintable margin pins on EACH side of the head.
    /// Canonical table lives in Core (shared with the web overlay's
    /// `__VL_PRINTER_GEOMETRY__` projection) so driver and UI can never drift.
    static let tapeMargins = PrinterGeometry.brotherTapeMarginPins

    /// All supported TZe tape widths in mm, narrow → wide.
    public static let tapeWidthsMm: [Double] = tapeMargins.map { $0.mm }

    static func margin(forTapeMm mm: Double) -> Int? {
        tapeMargins.first { abs($0.mm - mm) < 0.001 }?.marginPins
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
            abs((headPins - lhs.marginPins * 2) - acrossPx) < abs((headPins - rhs.marginPins * 2) - acrossPx)
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
        // Require enough bytes to read EVERY field we report (media at 10/11, error
        // flags at 8/9, status type at 18). A 12–18 byte partial read would otherwise
        // report media as valid while silently skipping the error flags it can't reach.
        guard data.count >= 19 else { return nil }
        var errors: [String] = []
        var coverOpen = false, noMedia = false, incompatible = false
        let isError = data[18] == 0x02
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

    // MARK: – D460BT dialect (PT-E560BT) — uncompressed raster, n9=0x02, magic margin
    //
    // The PT-E560BT (PID 0x2203) is firmware-wise a "PT-D460BT-generation" device
    // despite the E-series name, and speaks a DIFFERENT dialect from the classic
    // E550W/P750W (handoff §6/§7). Feeding it the classic dialect prints one job then
    // hangs forever (power-cycle to recover) — so it MUST be routed to these builders.
    // Differences from classic: ESC i z page-index byte (n9) MUST be 0x02 even for a
    // single page; the margin command is the 7-byte magic `ESC i d <lo> <hi> 4D 00`;
    // raster lines are UNCOMPRESSED (`47 10 00` + 16 raw bytes, `5A` blank), no `M 02`;
    // no `ESC i !` status-notify; 200-zero invalidate. A byte-exact port of the
    // hardware-validated `brother_pt.py` (pinned by `BrotherPTTests`).

    /// USB product ids that speak the D460BT dialect.
    public static let d460ProductIDs: [UInt16: String] = [0x2203: "PT-E560BT"]

    /// D460BT print-information (ESC i z): byte 11 is the page index (n9). Single-page
    /// jobs MUST use 0x02 ("last page"); 0x00 leaves the printer waiting forever.
    static func d460PrintInformation(numRasterLines n: Int, mediaWidthMm: Int, pageIndex: UInt8) -> [UInt8] {
        [0x1B, 0x69, 0x7A, 0x84, 0x00, UInt8(truncatingIfNeeded: mediaWidthMm), 0x00,
         UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8),
         UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 24),
         pageIndex, 0x00]
    }

    /// D460BT margin "magic": `ESC i d <lo> <hi> 4D 00`. The trailing `4D 00` is
    /// mandatory or output corrupts (the `4D` is the raster compression-select).
    static func d460Margin(_ dots: Int) -> [UInt8] {
        [0x1B, 0x69, 0x64, UInt8(truncatingIfNeeded: dots), UInt8(truncatingIfNeeded: dots >> 8), 0x4D, 0x00]
    }

    /// D460BT raster lines: UNCOMPRESSED — each non-blank line is `47 10 00` + 16 raw
    /// bytes; a blank line is the single byte `5A`. (No PackBits on this dialect.)
    static func d460RasterLines(_ rasterData: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < rasterData.count {
            let end = min(i + lineLengthBytes, rasterData.count)
            let line = Array(rasterData[i..<end])
            if line.allSatisfy({ $0 == 0 }) {
                out.append(0x5A)
            } else {
                out += [0x47, 0x10, 0x00]
                out += line                 // raw 16 bytes, no trim
            }
            i += lineLengthBytes
        }
        return out
    }

    /// D460BT single-page job (standalone → full cut): 200×00 · ESC @ · ESC i a 1 ·
    /// ESC i z (n9=0x02) · magic margin · [leading ESC i K to chain] · raster · 0x1A.
    public static func buildPrintJobD460BT(rasterData: [UInt8], tapeMm: Double,
                                           marginDots: Int = 14,
                                           chainToNext: Bool = false,
                                           halfCut: Bool = false,
                                           skipInit: Bool = false) -> [UInt8] {
        let numLines = rasterData.count / lineLengthBytes
        var parts: [UInt8] = []
        if !skipInit { parts += [UInt8](repeating: 0, count: 200); parts += cmdInitialize() }
        parts += cmdEnterRasterMode()
        parts += d460PrintInformation(numRasterLines: numLines, mediaWidthMm: Int(tapeMm), pageIndex: 0x02)
        parts += d460Margin(marginDots)
        if chainToNext { parts += [0x1B, 0x69, 0x4B, halfCut ? 0x04 : 0x00] }   // leading K chains to next
        parts += d460RasterLines(rasterData)
        parts.append(0x1A)
        return parts
    }

    /// One label inside a D460BT half-cut stream, fully parameterized (order matches
    /// Brother's bsp22a driver disassembly): [init] · ESC i a 1 · ESC i z (n9) ·
    /// [ESC i M cut] · [ESC i K adv] · magic margin · raster · terminator.
    static func d460LabelBlock(rasterData: [UInt8], tapeMm: Double, marginDots: Int,
                               pageIndex: UInt8, cutMode: UInt8?, kByte: UInt8?,
                               terminator: UInt8, skipInit: Bool) -> [UInt8] {
        let numLines = rasterData.count / lineLengthBytes
        var parts: [UInt8] = []
        if !skipInit { parts += [UInt8](repeating: 0, count: 200); parts += cmdInitialize() }
        parts += cmdEnterRasterMode()
        parts += d460PrintInformation(numRasterLines: numLines, mediaWidthMm: Int(tapeMm), pageIndex: pageIndex)
        if let cm = cutMode { parts += [0x1B, 0x69, 0x4D, cm] }     // ESC i M cut mode
        if let kb = kByte   { parts += [0x1B, 0x69, 0x4B, kb] }     // ESC i K advanced (0x04 = half-cut)
        parts += d460Margin(marginDots)
        parts += d460RasterLines(rasterData)
        parts.append(terminator)
        return parts
    }

    /// D460BT half-cut series (job 1 of the strip): each inter-label boundary scored
    /// (label severed, backing intact) so the strip stays whole, terminated for a
    /// standalone cutter job to release. Intermediates: n9 0x00 first / 0x01 middle,
    /// `ESC i K 0x04` (when `halfCutBetween`), `0x0C` (print+advance, chained). LAST
    /// label: framed identically to a standalone full-cut label (n9=0x02, 0x1A, NO
    /// ESC i M, NO ESC i K) — cut/advanced-mode commands on the last page BLOCK the cut.
    /// `halfCutBetween=false` chains with no inter-label cut (full-cut-at-end strategy).
    public static func buildHalfcutSeriesD460BT(labelRasters: [[UInt8]], tapeMm: Double,
                                                marginDots: Int = 14,
                                                halfCutBetween: Bool = true) -> [UInt8] {
        let n = labelRasters.count
        var stream: [UInt8] = []
        for (i, raster) in labelRasters.enumerated() {
            let isLast = i == n - 1
            let pageIndex: UInt8, kByte: UInt8?, term: UInt8
            if isLast {
                pageIndex = 0x02; kByte = nil; term = 0x1A
            } else {
                pageIndex = (i == 0) ? 0x00 : 0x01
                // Intermediates ALWAYS carry an ESC i K (the bsp22a disassembly shows it
                // in every page preamble; omitting it risks "label 1 inks, the rest
                // blank"): 0x04 = half-cut score; 0x00 = chain to next with NO cut
                // (handoff §6.4 — a leading ESC i K 00 chains the page, no cut between).
                kByte = halfCutBetween ? 0x04 : 0x00
                term = 0x0C
            }
            stream += d460LabelBlock(rasterData: raster, tapeMm: tapeMm, marginDots: marginDots,
                                     pageIndex: pageIndex, cutMode: nil, kByte: kByte,
                                     terminator: term, skipInit: i > 0)
        }
        return stream
    }

    /// D460BT cutter job (job 2 of the strip): a STANDALONE full-cut job (its own
    /// 200×00 + ESC @ init, minimal blank raster, n9=0x02, 0x1A). The firmware won't
    /// full-cut from inside a chained series, but a standalone job cuts cleanly — so
    /// this releases the half-cut strip.
    public static func buildCutterJobD460BT(tapeMm: Double, marginDots: Int = 14,
                                            blankDots: Int = 8) -> [UInt8] {
        let raster = [UInt8](repeating: 0, count: blankDots * lineLengthBytes)
        return d460LabelBlock(rasterData: raster, tapeMm: tapeMm, marginDots: marginDots,
                              pageIndex: 0x02, cutMode: nil, kByte: nil, terminator: 0x1A, skipInit: false)
    }

    /// D460BT multi-label strip: the chained half-cut series + a standalone cutter job
    /// that releases it with a full cut. (A single label skips the cutter job — a lone
    /// standalone label cuts itself.)
    public static func buildHalfcutStripD460BT(labelRasters: [[UInt8]], tapeMm: Double,
                                               marginDots: Int = 14,
                                               halfCutBetween: Bool = true) -> [UInt8] {
        buildHalfcutSeriesD460BT(labelRasters: labelRasters, tapeMm: tapeMm,
                                 marginDots: marginDots, halfCutBetween: halfCutBetween)
            + buildCutterJobD460BT(tapeMm: tapeMm, marginDots: marginDots)
    }

    // MARK: – Shared raster prep + status mapping (used by every Brother PT module)

    /// Downscale a master raster to 180 DPI and transpose the reading-orientation
    /// raster (width = across tape, height = along tape) into the Brother tape frame
    /// (height = print-head pins = printWidth, width = raster lines), centering across
    /// the head and padding the length up to the minimum. A bare transpose is a
    /// REFLECTION, so exactly one axis is reversed (mirrorAcross/mirrorAlong) to make a
    /// clean 90° rotation. Returns the packed raster bytes + resolved tape width.
    public static func tapeRaster(for label: RenderedLabel, mirrorAlong: Bool, mirrorAcross: Bool)
        -> (raster: [UInt8], tapeMm: Double)? {
        let d = MonoRaster.downscale(pixels: label.bytes, width: label.width, height: label.height,
                                     fromDPI: label.dpi, toDPI: nativeDPI)
        let across = d.width, along = d.height
        guard across > 0, along > 0 else { return nil }
        let tapeMm = nearestTape(forAcrossPx: across)
        guard let pw = printWidth(tapeMm: tapeMm) else { return nil }
        let alongLen = max(along, minLabelDots)
        let offset = (pw - across) / 2          // center across the head (crop if wider than the head)
        // The label is wider across the tape than the head can print: content at both
        // edges is dropped by the pin-bounds guard below. Surface it rather than silently
        // cropping (the design is too wide for the snapped tape — pick a wider tape).
        if across > pw {
            NSLog("[BrotherPT] label across-tape (\(across)px) exceeds the \(tapeMm)mm tape's \(pw)px printable width — edges will be cropped")
        }
        var bro = [UInt8](repeating: 0, count: alongLen * pw)
        for a in 0 ..< across {
            let aSrc = mirrorAcross ? (across - 1 - a) : a
            let pin = offset + aSrc
            if pin < 0 || pin >= pw { continue }
            for l in 0 ..< along where d.pixels[l * across + a] != 0 {
                let col = mirrorAlong ? (along - 1 - l) : l
                bro[pin * alongLen + col] = 0xFF
            }
        }
        guard let raster = imageToRaster(pixels: bro, width: alongLen, height: pw, tapeMm: tapeMm) else {
            return nil
        }
        return (raster, tapeMm)
    }

    /// Map a parsed Brother status into a `CassetteStatus`. Brother continuous tape has
    /// no supply gauge or part number over the wire, so those stay 0/"".
    public static func cassetteStatus(from s: Status) -> CassetteStatus? {
        guard s.tapeWidthMm > 0 || s.hasError else { return nil }
        let mm = Double(s.tapeWidthMm)
        let labelWmils = s.tapeWidthMm > 0 ? Int((mm / 25.4 * 1000).rounded()) : 0
        let pw = printWidth(tapeMm: mm)
        let printableWmils = pw.map { Int((Double($0) / Double(nativeDPI) * 1000).rounded()) } ?? labelWmils
        return CassetteStatus(
            partNumber: "",
            labelWidthMils: labelWmils, labelHeightMils: 0,
            printableWidthMils: printableWmils, printableHeightMils: 0,
            isDieCut: false,
            supplyRemainingPct: 0,                 // continuous tape: no gauge
            labelsPerRoll: nil,
            pixelWidth: pw ?? 0, pixelHeight: 0,
            isContinuous: true,
            printheadOpen: s.coverOpen,
            substrateInvalid: s.noMedia || s.incompatibleMedia)
    }
}
