import Foundation

/// The master render resolution for the whole app.
///
/// Front-ends render every label to a 1-byte-per-pixel mono raster
/// (`LabelRenderer.render` → `RenderedLabel`) at this DPI, and **each printer
/// driver downscales** that master raster to its own native resolution inside
/// `encode()` — Brady M610/M611 = 300 dpi, Brother P-touch = 180 dpi. The
/// downscale is a shared, unit-tested `MonoRaster.downscale`.
///
/// 900 is the least common multiple of 300 and 180, so the downscale to *both*
/// printer families is an exact integer box-filter (÷3 to Brady, ÷5 to Brother)
/// with no fractional resampling. A high master DPI keeps small text crisp on
/// every printer; the raster size cost (≈9× the pixels of 300 dpi) is absorbed
/// by `RenderedLabel`'s deflate compression on the IPC seam.
///
/// This is the ONLY render-DPI knob. `BradyLabelSize.dpi` returns it, so the
/// whole already-DPI-relative render path follows automatically. Printer-native
/// DPI is a per-driver concern and is NOT this value.
public enum RenderDPI {
    public static let master = 900

    /// The reference DPI that per-printer **calibration offsets** are expressed in.
    /// Offsets are stored (and shown in Preferences) as pixels at this DPI; the
    /// renderer scales them to the master DPI when applying them (`offset * master /
    /// calibrationReference`), so existing saved calibrations keep their physical
    /// shift. Kept separate from `master` so the master DPI can change without
    /// silently rescaling every stored offset. Must match the historical render DPI.
    public static let calibrationReference = 300
}
