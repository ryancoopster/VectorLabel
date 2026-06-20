import Foundation

/// A model-agnostic rendered label: the 1-byte-per-pixel mono raster produced by
/// `LabelRenderer.render` (0xFF = ink/black, 0x00 = white), plus its dimensions.
///
/// This is the shared seam between the (printer-agnostic) front-end render and the
/// per-printer encoder in the Engine: front-ends submit `RenderedLabel`s over the
/// IPC queue, and the Engine encodes each one into the target printer's wire format
/// (VGL for the M610, bitmap/LZ4 for the M611). Codable for the IPC (pixels ride as
/// base64 `Data`).
public struct RenderedLabel: Codable, Equatable {
    public var pixels: Data        // row-major, 1 byte/pixel, 0xFF = ink
    public var width: Int
    public var height: Int
    /// The selected/loaded supply part number, carried for encoders that stamp it
    /// (M611 `SubstratePart`) and for geometry resolution. "" if unknown.
    public var partNumber: String

    public init(pixels: Data, width: Int, height: Int, partNumber: String = "") {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.partNumber = partNumber
    }

    /// Convenience initializer from a `[UInt8]` raster (the `LabelRenderer` output).
    public init(pixels: [UInt8], width: Int, height: Int, partNumber: String = "") {
        self.init(pixels: Data(pixels), width: width, height: height, partNumber: partNumber)
    }

    enum CodingKeys: String, CodingKey { case pixels, width, height, partNumber }

    /// Upper sanity bound on either decoded dimension (~333" at 300 dpi). Generous on
    /// purpose: it must clear the longest real continuous-tape strip, so it's only a
    /// guard against absurd values + `width*height` overflow — the actual integrity
    /// check is `pixels.count == width*height` below.
    static let maxDimension = 100_000

    /// Decode with the raster invariant enforced at the trust boundary. A
    /// `PrintJobFile` is read straight off the IPC queue (any local process can drop
    /// a file in `queue/`), so a label whose declared `width*height` doesn't match
    /// `pixels.count`, or whose dimensions are non-positive / absurd, would otherwise
    /// drive an out-of-bounds read or a multi-GB allocation in the encoders
    /// (`BradyVGL.buildPrintJob`, `M611Bitmap.rotate/bmp1bpp` all index
    /// `pixels[row*width+col]`). Reject it here so the offending job is routed to
    /// `failed/` instead of crashing the USB-owning Engine.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pixels = try c.decode(Data.self, forKey: .pixels)
        let width  = try c.decode(Int.self, forKey: .width)
        let height = try c.decode(Int.self, forKey: .height)
        let partNumber = (try? c.decode(String.self, forKey: .partNumber)) ?? ""
        guard width > 0, height > 0,
              width <= Self.maxDimension, height <= Self.maxDimension else {
            throw DecodingError.dataCorruptedError(
                forKey: .width, in: c,
                debugDescription: "RenderedLabel dimensions out of range: \(width)x\(height)")
        }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels.count == count else {
            throw DecodingError.dataCorruptedError(
                forKey: .pixels, in: c,
                debugDescription: "RenderedLabel pixel count \(pixels.count) != \(width)×\(height)")
        }
        self.pixels = pixels
        self.width = width
        self.height = height
        self.partNumber = partNumber
    }

    /// The raster as a `[UInt8]` for encoders.
    public var bytes: [UInt8] { [UInt8](pixels) }

    /// Per-label print-time estimate (ms) from the label's longest pixel dimension.
    /// Calibrated to hardware: a 1.5" label (~450 px @ 300 dpi) prints in ~0.85 s.
    /// Shared by the print controllers so the calibration constant lives in one place.
    public static func estimatedPrintMs(maxDimensionPx px: Int) -> Int {
        Int(Double(max(0, px)) / 300.0 * 370.0) + 300
    }

    /// A blank (all-white) "feed to clear" label for a supply size: one full label pitch
    /// for die-cut, or a 1-inch feed for continuous tape. Same orientation as a rendered
    /// label (width = printable width, height = feed length), so the per-printer encoder
    /// handles it identically to a real label. The Engine prepends this to a job when the
    /// user enables "Feed to clear before printing".
    public static func feedClearBlank(size: BradyLabelSize, partNumber: String) -> RenderedLabel {
        let dpi = size.dpi
        let w = max(1, size.printablePixelWidth)
        let h = max(1, size.isContinuous ? vlInchesToPixels(1.0, dpi: dpi)
                                         : vlInchesToPixels(size.printableHeightInches, dpi: dpi))
        return RenderedLabel(pixels: [UInt8](repeating: 0, count: w * h),
                             width: w, height: h, partNumber: partNumber)
    }
}
