import Foundation

/// Builds Brady VGL (Vector Graphics Language) print jobs for the M610/M611.
/// Ported from the Electron reference implementation (brady-m610.ts).
///
/// Input: a 1-bit-per-pixel mono buffer, row-major, 1 byte per pixel
///        (0xFF = black/ink, 0x00 = white), width x height matching the
///        label's pixel dimensions from BradyCatalog.
public enum BradyVGL {

    public enum CutMode: UInt8 {
        case afterJob = 0   // single label
        case eachLabel = 1  // batches (not used here - each label is its own job)
        case never = 2
    }

    // MARK: – Cut command (UNVERIFIED — confirm on M611 hardware before relying on this)
    //
    // ⚠️ UNVERIFIED — confirm on M611 hardware before relying on this. ⚠️
    //
    // The EXACT bytes the M610/M611 firmware uses to set the cut mode are not
    // hardware-confirmed. Historically this code emitted `ESC M <mode> 00`
    // (0x1B 0x4D <0|1|2> 0x00) as a "Set Cut Mode" command at the top of every
    // job. That sequence has NOT been validated against a real cutter-equipped
    // M611, so it lives here behind ONE function and can be corrected in exactly
    // one place once the byte sequence is confirmed on hardware.
    //
    // Conservative design: this returns the historical `ESC M <mode> 00` bytes,
    // which is what the renderer already sent for single labels — so behaviour is
    // unchanged from before this phase. If a future hardware test shows these
    // bytes can jam or damage the printer, change `cutCommandEnabled` to `false`
    // below (or fix the bytes) — the plumbing keeps working either way.
    //
    // The three modes we map onto the wire:
    //   .afterJob (0)  → cut once, after the (last) label of the job
    //   .eachLabel (1) → cut after every label (needed for continuous tape)
    //   .never (2)     → never actuate the cutter (die-cut stock is pre-cut)

    /// Master switch for emitting the cut command. Set to `false` to turn the cut
    /// command into a logged no-op (plumbing stays intact, no bytes reach the
    /// cutter) until the sequence is hardware-verified. Left `true` to preserve the
    /// pre-Phase-6 behaviour (renderer always sent `ESC M <mode> 00`).
    public static var cutCommandEnabled = true

    /// The single source of truth for the cut-mode byte sequence.
    /// ⚠️ UNVERIFIED — confirm on M611 hardware before relying on this. ⚠️
    /// Returns an empty array (a safe no-op) when disabled.
    public static func cutCommand(for mode: CutMode) -> [UInt8] {
        guard cutCommandEnabled else {
            // No-op stub: do not touch the cutter. Logged so a hardware test can
            // see the plumbing fired without risking a jam.
            print("[BradyVGL] cutCommand(\(mode)) suppressed — cutCommandEnabled == false (UNVERIFIED bytes)")
            return []
        }
        // ESC M <mode> 00  — historical "Set Cut Mode" (UNVERIFIED, see above).
        return [0x1B, 0x4D, mode.rawValue, 0x00]
    }

    // MARK: – Continuous feed length (UNVERIFIED — confirm on M611 hardware)
    //
    // ⚠️ UNVERIFIED — confirm on M611 hardware before relying on this. ⚠️
    //
    // On a CONTINUOUS supply the printer must be told how long each printed label
    // is so the cut/advance lands in the right place. The renderer already sizes
    // the raster to the user-chosen length (effectivePrintableHeightInches → pixel
    // height), so the image itself is correct; what is NOT confirmed is whether the
    // M611 also needs an explicit "feed length" / "label length" command in the job
    // stream, or what its bytes are. We expose the insertion point here as a no-op
    // by default so nothing unverified reaches the printer. When the command is
    // confirmed, fill in the bytes (length is the raster height in printer pixels,
    // i.e. lengthInches * dpi) and flip `feedLengthCommandEnabled`.

    /// Master switch for emitting a continuous feed-length command. Default `false`
    /// (no-op) because the byte sequence is unverified.
    public static var feedLengthCommandEnabled = false

    /// Where the continuous "feed length" command would go. No-op until verified.
    /// ⚠️ UNVERIFIED — confirm on M611 hardware before relying on this. ⚠️
    /// `lengthPixels` is the printed label length along the feed, in printer pixels
    /// (inches × dpi) — exactly the raster height the renderer produced.
    public static func feedLengthCommand(lengthPixels: Int) -> [UInt8] {
        guard feedLengthCommandEnabled, lengthPixels > 0 else {
            return []   // no-op: the raster height already encodes the length
        }
        // TODO (UNVERIFIED): emit the M611 feed/label-length command here once its
        // byte sequence is confirmed on hardware, e.g. ESC <op> <len-lo> <len-hi>.
        let _ = lengthPixels
        return []
    }

    /// Build a complete VGL job for one label image.
    public static func buildPrintJob(pixels: [UInt8], width: Int, height: Int, cutMode: CutMode = .afterJob) -> [UInt8] {
        var job: [UInt8] = []

        // Job Start
        job += [0x1B, 0x58, 0x00]
        // Continuous feed-length command would go here (no-op until verified).
        // `height` is the raster height in printer pixels = the printed label
        // length along the feed for continuous stock.
        job += feedLengthCommand(lengthPixels: height)
        // Set Cut Mode (UNVERIFIED bytes — see cutCommand).
        job += cutCommand(for: cutMode)

        let bytesPerLine = (height + 7) / 8

        var pendingSkips = 0

        // Iterate columns right-to-left; each column becomes one raster line.
        for col in stride(from: width - 1, through: 0, by: -1) {
            var lineBytes = [UInt8](repeating: 0, count: bytesPerLine)
            var hasInk = false

            for row in 0..<height {
                let pixel = pixels[row * width + col]
                if pixel != 0 {
                    hasInk = true
                    let byteIndex = row / 8
                    let bitIndex = 7 - (row % 8) // MSB first
                    lineBytes[byteIndex] |= (1 << bitIndex)
                }
            }

            // Trim trailing zero bytes
            var trimmedLen = lineBytes.count
            while trimmedLen > 0 && lineBytes[trimmedLen - 1] == 0 {
                trimmedLen -= 1
            }

            if trimmedLen == 0 {
                // Entirely blank line - accumulate as a skip
                pendingSkips += 1
                continue
            }

            // Flush any pending skip lines first
            if pendingSkips > 0 {
                job += skipLinesCommand(count: pendingSkips)
                pendingSkips = 0
            }

            let line = Array(lineBytes[0..<trimmedLen])
            let rle = compressRLELine(line)
            if rle.count < line.count {
                job += rasterCommand(opcode: 0x68, data: rle) // RLE Raster
            } else {
                job += rasterCommand(opcode: 0x67, data: line) // Raw Raster
            }

            _ = hasInk
        }

        // End Page, End Job
        job += [0x1B, 0x45]
        job += [0x1B, 0x44]

        return job
    }

    /// ESC Z <lo> <hi> - skip N blank raster lines (little-endian 16-bit)
    private static func skipLinesCommand(count: Int) -> [UInt8] {
        let lo = UInt8(count & 0xFF)
        let hi = UInt8((count >> 8) & 0xFF)
        return [0x1B, 0x5A, lo, hi]
    }

    /// ESC <opcode> <lo> <hi> [data] - raster line, length = lo + (hi << 8)
    private static func rasterCommand(opcode: UInt8, data: [UInt8]) -> [UInt8] {
        let len = data.count
        let lo = UInt8(len & 0xFF)
        let hi = UInt8((len >> 8) & 0xFF)
        return [0x1B, opcode, lo, hi] + data
    }

    /// RLE-encode a single raster line.
    ///
    /// Output byte: **bit 7 = color (`0x80` = black/ink run, `0x00` = white run)**,
    /// bits 0-6 = run length − 1 (max 128 pixels per byte; longer runs split).
    ///
    /// IMPORTANT: `0x80` is the *black* run flag. Brady's SDK comments document this
    /// backwards (`0x80` = white); the hardware-validated truth is `0x80` = black.
    /// Earlier versions of this method used the inverted polarity, which printed
    /// RLE-compressed lines (solid fills, borders) as negatives. See the M610
    /// handoff spec §5/§10 for test vectors.
    ///
    /// The trailing white run is omitted entirely — the printer treats the unsent
    /// remainder of a line as white.
    public static func compressRLELine(_ line: [UInt8]) -> [UInt8] {
        guard !line.isEmpty else { return [] }

        // Expand to pixels, MSB first within each byte (row 0 → bit 7 of byte 0).
        var bits: [UInt8] = []
        bits.reserveCapacity(line.count * 8)
        for byte in line {
            for bitIndex in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> bitIndex) & 1)
            }
        }

        // Collect (color, length) runs over the pixels.
        var runs: [(black: Bool, length: Int)] = []
        var i = 0
        while i < bits.count {
            let black = bits[i] == 1
            var length = 1
            while i + length < bits.count && (bits[i + length] == 1) == black {
                length += 1
            }
            runs.append((black, length))
            i += length
        }

        // Drop the trailing white run — printer renders the remainder as white.
        if let last = runs.last, !last.black { runs.removeLast() }

        // Encode, splitting runs longer than 128 px across multiple bytes.
        var out: [UInt8] = []
        for run in runs {
            var remaining = run.length
            let colorBit: UInt8 = run.black ? 0x80 : 0x00
            while remaining > 0 {
                let chunk = min(remaining, 128)
                out.append(colorBit | UInt8(chunk - 1))
                remaining -= chunk
            }
        }
        return out
    }

    /// Build a batch of complete VGL jobs (one job per label) using the cut-mode
    /// strategy from the M610 spec §7: every job is "never cut" (mode 2) except the
    /// last, which is "cut after job" (mode 0) — so a die-cut batch feeds as one
    /// strip and is cut once at the end. Pass `cutEachLabel: true` to separate every
    /// label instead (mode 1 on all jobs).
    public static func buildBatch(
        _ labels: [(pixels: [UInt8], width: Int, height: Int)],
        cutEachLabel: Bool = false
    ) -> [[UInt8]] {
        labels.enumerated().map { index, label in
            let mode: CutMode
            if cutEachLabel {
                mode = .eachLabel
            } else {
                mode = (index == labels.count - 1) ? .afterJob : .never
            }
            return buildPrintJob(pixels: label.pixels, width: label.width,
                                 height: label.height, cutMode: mode)
        }
    }

    /// The per-label `BradyVGL.CutMode` to stamp on label `index` of a `total`-label
    /// job for a given user-chosen `IPCCutMode`. This is the single place the
    /// end-to-end cut SETTING (carried in `PrintJobFile.cutMode`) is mapped onto the
    /// per-job wire mode, so the Engine and any future caller decide cut behaviour
    /// identically:
    ///   • `.never`        → every label `.never`  (die-cut / pre-cut stock)
    ///   • `.eachLabel`    → every label `.eachLabel` (continuous tape, separate labels)
    ///   • `.afterJobLast` → all `.never` except the last `.afterJob` (one cut at the end)
    ///
    /// `IPCCutMode` is the Core IPC `CutMode` (afterJobLast / eachLabel / never);
    /// it is passed in by raw value to keep BradyVGL free of an import cycle.
    public static func vglCutMode(forIPCRawValue raw: String, index: Int, total: Int) -> CutMode {
        switch raw {
        case "never":     return .never
        case "eachLabel": return .eachLabel
        default:          return (index == total - 1) ? .afterJob : .never   // afterJobLast
        }
    }
}
