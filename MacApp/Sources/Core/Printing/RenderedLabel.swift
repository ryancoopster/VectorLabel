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

    /// The raster as a `[UInt8]` for encoders.
    public var bytes: [UInt8] { [UInt8](pixels) }
}
