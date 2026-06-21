import Foundation

/// Resampling helpers for 1-byte-per-pixel mono rasters — the `RenderedLabel`
/// format (row-major, `0xFF` = ink/black, `0x00` = white).
///
/// Each printer driver renders against the 900-DPI master raster
/// (`RenderDPI.master`) but the printer head is lower resolution (Brady 300,
/// Brother 180). `downscale` reduces the master raster to the driver's native
/// DPI before the driver's encoder packs it into wire bytes, so the printed
/// label is the correct physical size. Keeping this in Core (not in any one
/// encoder) means every driver — and its tests — share one validated resampler,
/// and the byte-exact encoders keep receiving native-resolution rasters.
public enum MonoRaster {

    /// Downscale a mono raster from `fromDPI` to `toDPI` using **area coverage**:
    /// each output pixel covers a (possibly fractional) rectangle of source
    /// pixels; it becomes ink when the ink-covered fraction of that rectangle is
    /// at least `inkThreshold`. Output is `0xFF` = ink / `0x00` = white.
    ///
    /// Returns the input unchanged when `fromDPI <= toDPI` (this never upscales),
    /// or on a degenerate/invalid size. The area model is exact for the integer
    /// ratios the app actually uses (900→300 = ÷3, 900→180 = ÷5) and remains
    /// correct for any fractional ratio (e.g. a 1200-DPI master → 180).
    ///
    /// `inkThreshold` (0…1) is the ink fraction that turns an output pixel on.
    /// Lower keeps thin strokes/small text visible after a large reduction;
    /// the default is tuned so a single 900-DPI hairline survives a ÷5 reduction.
    public static func downscale(pixels: [UInt8], width: Int, height: Int,
                                 fromDPI: Int, toDPI: Int,
                                 inkThreshold: Double = 0.18)
        -> (pixels: [UInt8], width: Int, height: Int) {
        guard fromDPI > toDPI, toDPI > 0, width > 0, height > 0,
              pixels.count >= width * height else {
            return (pixels, width, height)
        }
        let scale = Double(toDPI) / Double(fromDPI)
        let outW = max(1, Int((Double(width)  * scale).rounded()))
        let outH = max(1, Int((Double(height) * scale).rounded()))
        // Guard the no-op / grow cases the rounding could produce on tiny inputs.
        guard outW < width || outH < height else { return (pixels, width, height) }

        // Source span (in source pixels) of one output pixel along each axis.
        let sx = Double(width)  / Double(outW)
        let sy = Double(height) / Double(outH)
        var out = [UInt8](repeating: 0, count: outW * outH)

        pixels.withUnsafeBufferPointer { src in
            for oy in 0 ..< outH {
                let fy0 = Double(oy) * sy
                let fy1 = fy0 + sy
                let ry0 = Int(fy0)                     // first source row touched
                let ry1 = min(height - 1, Int(fy1.nextDown))  // last source row touched
                for ox in 0 ..< outW {
                    let fx0 = Double(ox) * sx
                    let fx1 = fx0 + sx
                    let rx0 = Int(fx0)
                    let rx1 = min(width - 1, Int(fx1.nextDown))
                    var inkArea = 0.0
                    var totalArea = 0.0
                    var ry = ry0
                    while ry <= ry1 {
                        // Vertical overlap of source row `ry` with [fy0, fy1).
                        let wy = min(Double(ry) + 1, fy1) - max(Double(ry), fy0)
                        if wy > 0 {
                            let rowBase = ry * width
                            var rx = rx0
                            while rx <= rx1 {
                                let wx = min(Double(rx) + 1, fx1) - max(Double(rx), fx0)
                                if wx > 0 {
                                    let a = wx * wy
                                    totalArea += a
                                    if src[rowBase + rx] != 0 { inkArea += a }
                                }
                                rx += 1
                            }
                        }
                        ry += 1
                    }
                    if totalArea > 0 && inkArea / totalArea >= inkThreshold {
                        out[oy * outW + ox] = 0xFF
                    }
                }
            }
        }
        return (out, outW, outH)
    }
}
