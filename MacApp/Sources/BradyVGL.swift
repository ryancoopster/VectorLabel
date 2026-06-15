import Foundation

/// Builds Brady VGL (Vector Graphics Language) print jobs for the M610/M611.
/// Ported from the Electron reference implementation (brady-m610.ts).
///
/// Input: a 1-bit-per-pixel mono buffer, row-major, 1 byte per pixel
///        (0xFF = black/ink, 0x00 = white), width x height matching the
///        label's pixel dimensions from BradyCatalog.
enum BradyVGL {

    enum CutMode: UInt8 {
        case afterJob = 0   // single label
        case eachLabel = 1  // batches (not used here - each label is its own job)
        case never = 2
    }

    /// Build a complete VGL job for one label image.
    static func buildPrintJob(pixels: [UInt8], width: Int, height: Int, cutMode: CutMode = .afterJob) -> [UInt8] {
        var job: [UInt8] = []

        // Job Start
        job += [0x1B, 0x58, 0x00]
        // Set Cut Mode
        job += [0x1B, 0x4D, cutMode.rawValue, 0x00]

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
    static func compressRLELine(_ line: [UInt8]) -> [UInt8] {
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
    static func buildBatch(
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
}
