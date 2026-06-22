import Foundation
import Compression

/// A model-agnostic rendered label: the 1-byte-per-pixel mono raster produced by
/// `LabelRenderer.render` (0xFF = ink/black, 0x00 = white), plus its dimensions.
///
/// This is the shared seam between the (printer-agnostic) front-end render and the
/// per-printer encoder in the Engine: front-ends submit `RenderedLabel`s over the
/// IPC queue, and the Engine encodes each one into the target printer's wire format
/// (VGL for the M610, bitmap/LZ4 for the M611, classic raster for the Brother
/// P-touch). The raster is produced at the master render DPI (`RenderDPI.master`);
/// each driver downscales it to its native resolution (`MonoRaster.downscale`)
/// using the `dpi` carried here. Codable for the IPC — and because a master-DPI
/// raster is ~9× the pixels of the old 300-dpi one, the pixel buffer is DEFLATE
/// compressed on the Codable boundary (a 1-bit-content mono raster compresses
/// heavily, so queue files stay small).
public struct RenderedLabel: Codable, Equatable {
    public var pixels: Data        // row-major, 1 byte/pixel, 0xFF = ink (UNCOMPRESSED in memory)
    public var width: Int
    public var height: Int
    /// The selected/loaded supply part number, carried for encoders that stamp it
    /// (M611 `SubstratePart`) and for geometry resolution. "" if unknown.
    public var partNumber: String
    /// The render DPI this raster was produced at (the master render DPI). Each
    /// driver downscales from this to its printer-native DPI before encoding.
    /// Legacy job files without it decode as 300 (the old fixed render DPI).
    public var dpi: Int

    public init(pixels: Data, width: Int, height: Int, partNumber: String = "",
                dpi: Int = RenderDPI.master) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.partNumber = partNumber
        self.dpi = dpi
    }

    /// Convenience initializer from a `[UInt8]` raster (the `LabelRenderer` output).
    public init(pixels: [UInt8], width: Int, height: Int, partNumber: String = "",
                dpi: Int = RenderDPI.master) {
        self.init(pixels: Data(pixels), width: width, height: height,
                  partNumber: partNumber, dpi: dpi)
    }

    enum CodingKeys: String, CodingKey { case pixels, pixelsZ, width, height, partNumber, dpi }

    /// Upper sanity bound on either decoded dimension. Generous on purpose: it must
    /// clear the longest real continuous-tape strip at the master render DPI, so it's
    /// only a guard against absurd values + `width*height` overflow — the actual
    /// integrity check is `pixels.count == width*height` below. Tracks the
    /// `vlInchesToPixels` clamp (≈222" at the 900-dpi master).
    static let maxDimension = 200_000

    /// Decode with the raster invariant enforced at the trust boundary. A
    /// `PrintJobFile` is read straight off the IPC queue (any local process can drop
    /// a file in `queue/`), so a label whose declared `width*height` doesn't match
    /// `pixels.count`, or whose dimensions are non-positive / absurd, would otherwise
    /// drive an out-of-bounds read or a multi-GB allocation in the encoders. Reject
    /// it here so the offending job is routed to `failed/` instead of crashing the
    /// USB-owning Engine. Pixels ride as DEFLATE-compressed base64 (`pixelsZ`); a
    /// legacy file with raw base64 `pixels` still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let width  = try c.decode(Int.self, forKey: .width)
        let height = try c.decode(Int.self, forKey: .height)
        let partNumber = (try? c.decode(String.self, forKey: .partNumber)) ?? ""
        let dpi = (try? c.decode(Int.self, forKey: .dpi)) ?? 300
        // dpi drives every driver's downscale (fromDPI: label.dpi); a 0/negative value
        // makes `fromDPI > toDPI` false → the 900-DPI master raster is sent UNSCALED to
        // the printer (giant/garbled). Validate it like the dimensions (absent → 300).
        guard width > 0, height > 0, dpi > 0, dpi <= 4800,
              width <= Self.maxDimension, height <= Self.maxDimension else {
            throw DecodingError.dataCorruptedError(
                forKey: .width, in: c,
                debugDescription: "RenderedLabel out of range: \(width)x\(height) @ \(dpi)dpi")
        }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else {
            throw DecodingError.dataCorruptedError(
                forKey: .width, in: c,
                debugDescription: "RenderedLabel dimensions overflow: \(width)x\(height)")
        }
        // Prefer the compressed payload; fall back to a legacy raw-pixels file.
        let pixels: Data
        if let z = try? c.decode(Data.self, forKey: .pixelsZ) {
            guard let inflated = Self.inflate(z, expectedCount: count) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .pixelsZ, in: c,
                    debugDescription: "RenderedLabel pixelsZ failed to inflate to \(count) bytes")
            }
            pixels = inflated
        } else {
            pixels = try c.decode(Data.self, forKey: .pixels)
        }
        guard pixels.count == count else {
            throw DecodingError.dataCorruptedError(
                forKey: .pixels, in: c,
                debugDescription: "RenderedLabel pixel count \(pixels.count) != \(width)×\(height)")
        }
        self.pixels = pixels
        self.width = width
        self.height = height
        self.partNumber = partNumber
        self.dpi = dpi
    }

    /// Encode with the pixel buffer DEFLATE-compressed under `pixelsZ`. Falls back to
    /// raw `pixels` only if compression fails (it shouldn't for a real raster).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(partNumber, forKey: .partNumber)
        try c.encode(dpi, forKey: .dpi)
        if let z = Self.deflate(pixels) {
            try c.encode(z, forKey: .pixelsZ)
        } else {
            try c.encode(pixels, forKey: .pixels)
        }
    }

    // MARK: – DEFLATE (Apple Compression, raw RFC-1951 stream)

    /// Compress with raw DEFLATE. Returns nil on failure (caller falls back to raw).
    static func deflate(_ src: Data) -> Data? {
        guard !src.isEmpty else { return Data() }   // empty raster → empty stream
        let cap = src.count + src.count / 2 + 256
        var dst = [UInt8](repeating: 0, count: cap)
        let n = src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
            dst.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, cap,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? Data(dst.prefix(n)) : nil
    }

    /// Inflate a raw-DEFLATE stream to exactly `expectedCount` bytes, or nil.
    static func inflate(_ z: Data, expectedCount: Int) -> Data? {
        if expectedCount == 0 { return Data() }
        var dst = [UInt8](repeating: 0, count: expectedCount)
        let n = z.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
            guard let base = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, expectedCount,
                                          base, z.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == expectedCount ? Data(dst) : nil
    }

    /// The raster as a `[UInt8]` for encoders.
    public var bytes: [UInt8] { [UInt8](pixels) }

    /// Per-label print-time estimate (ms) from the label's longest pixel dimension.
    /// Calibrated to hardware: ~370 ms per inch of tape + ~300 ms base (a 1.5" label
    /// prints in ~0.85 s). DPI-relative — pass the DPI the pixel count is measured at
    /// (the master render DPI by default), so a high-DPI raster isn't over-estimated.
    public static func estimatedPrintMs(maxDimensionPx px: Int, dpi: Int = RenderDPI.master) -> Int {
        Int(Double(max(0, px)) / Double(max(1, dpi)) * 370.0) + 300
    }
}
