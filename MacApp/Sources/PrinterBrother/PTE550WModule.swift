import Foundation
import VectorLabelCore

/// Brother **PT-E550W** driver — classic-dialect raster over USB (`BrotherPT` +
/// `BrotherUSB`). Native 180 DPI; the front-end renders at the 900-DPI master, so
/// `encode()` downscales to 180 and transposes the reading-orientation raster into
/// the printer's tape frame (across-tape → print-head pins, along-tape → raster
/// lines) before framing the classic job.
///
/// No live per-label ack on this generation, so progress is coarse in full-job mode
/// (one half-cut strip) and a per-label counter in one-at-a-time mode (each label
/// fed + cut). The drain rule is honored by reading status until the printer goes
/// quiet before returning, so the Engine's connection-close can't abort a print.
public final class PTE550WModule: PrinterModule {
    public init() {}

    /// Supported classic-dialect PIDs this module instance drives. PT-E550W only for
    /// now; the PT-P750W shares the dialect and can be added once verified.
    static let productIDs: [UInt16: String] = [0x2060: "PT-E550W"]

    public let capabilities = PrinterCapabilities(
        model: "PT-E550W", supportedTransports: [.usb], hasLiveTelemetry: false,
        hasAutoCutter: true,            // built-in cutter (full + half cut)
        ribbonLengthInches: 0,          // TZe tape — no separate ribbon gauge
        // No hardware label counter / no live job ack: user picks one-at-a-time
        // (per-label cut + counter) vs one fast half-cut strip (coarse progress).
        sendMode: .selectable(defaultSingle: false))

    // Tape-frame orientation flips. The reading-orientation master raster is mapped
    // into the printer's tape frame here; if a hardware test prints mirrored or
    // upside-down along/across the tape, flip the corresponding flag. (Verify on a
    // real PT-E550W before production — orientation is the one thing tests can't pin.)
    static let mirrorAlong = false      // reverse tape-feed (raster-line) order
    static let mirrorAcross = false     // reverse across-tape (pin) order

    public func enumerate() -> [PrinterDevice] {
        let active = PrinterModelStore.enabledTransports(forName: capabilities.model,
                                                         productIDs: ["2060"])
            .intersection(capabilities.supportedTransports)
        guard active.contains(.usb) else { return [] }
        return BrotherUSB.enumerate(supportedPIDs: Self.productIDs)
    }

    // MARK: – Encode (master raster → classic-dialect single-label job)

    public func encode(label: RenderedLabel, status: CassetteStatus?,
                       cut: CutMode, isLastLabel: Bool) -> [UInt8] {
        guard let tr = tapeRaster(for: label) else { return [] }
        let wantsCut = cut == .eachLabel || (cut == .afterJobLast && isLastLabel)
        return BrotherPT.buildPrintJob(rasterData: tr.raster, tapeMm: tr.tapeMm,
                                       autocut: wantsCut, halfCut: false,
                                       nocut: !wantsCut, isLastPage: true)
    }

    /// Downscale the master raster to 180 dpi, transpose reading-orientation
    /// (width = across tape, height = along tape) into the Brother tape frame
    /// (height = print-head pins = printWidth, width = raster lines), centering the
    /// content across the head and padding the length up to the minimum. Returns the
    /// packed raster bytes + the resolved tape width, or nil on a degenerate label.
    func tapeRaster(for label: RenderedLabel) -> (raster: [UInt8], tapeMm: Double)? {
        let d = MonoRaster.downscale(pixels: label.bytes, width: label.width, height: label.height,
                                     fromDPI: label.dpi, toDPI: BrotherPT.nativeDPI)
        let across = d.width, along = d.height
        guard across > 0, along > 0 else { return nil }
        let tapeMm = BrotherPT.nearestTape(forAcrossPx: across)
        guard let pw = BrotherPT.printWidth(tapeMm: tapeMm) else { return nil }

        let alongLen = max(along, BrotherPT.minLabelDots)
        let offset = (pw - across) / 2          // center across the head (crop if wider than the head)
        // Brother-orientation buffer: row-major, width = alongLen, height = pw.
        var bro = [UInt8](repeating: 0, count: alongLen * pw)
        for a in 0 ..< across {
            let aSrc = Self.mirrorAcross ? (across - 1 - a) : a
            let pin = offset + aSrc
            if pin < 0 || pin >= pw { continue }
            for l in 0 ..< along where d.pixels[l * across + a] != 0 {
                let col = Self.mirrorAlong ? (along - 1 - l) : l
                bro[pin * alongLen + col] = 0xFF
            }
        }
        guard let raster = BrotherPT.imageToRaster(pixels: bro, width: alongLen, height: pw, tapeMm: tapeMm) else {
            return nil
        }
        return (raster, tapeMm)
    }

    // MARK: – Transport

    public func open(_ device: PrinterDevice) throws -> PrinterConnection {
        #if canImport(CLibUSB)
        return try BrotherUSB.open(deviceID: device.id, supportedPIDs: Self.productIDs)
        #else
        throw BrotherUSB.USBError.noContext
        #endif
    }

    public func send(_ bytes: [UInt8], on connection: PrinterConnection) throws {
        #if canImport(CLibUSB)
        guard let c = connection as? BrotherConnection else { return }
        try BrotherUSB.send(bytes, on: c)
        #endif
    }

    public func close(_ connection: PrinterConnection) {
        #if canImport(CLibUSB)
        guard let c = connection as? BrotherConnection else { return }
        BrotherUSB.close(c)
        #endif
    }

    public func readStatus(_ device: PrinterDevice) -> CassetteStatus? {
        #if canImport(CLibUSB)
        guard let conn = try? BrotherUSB.open(deviceID: device.id, supportedPIDs: Self.productIDs) else {
            return nil
        }
        defer { BrotherUSB.close(conn) }
        try? BrotherUSB.send(BrotherPT.statusRequest(), on: conn)
        guard let raw = BrotherUSB.readStatus(on: conn), let s = BrotherPT.parseStatus(raw) else {
            return nil
        }
        return Self.cassetteStatus(from: s)
        #else
        return nil
        #endif
    }

    /// Map a parsed Brother status into a `CassetteStatus`. Brother continuous tape
    /// has no supply gauge or part number over the wire, so those stay 0/"".
    static func cassetteStatus(from s: BrotherPT.Status) -> CassetteStatus? {
        guard s.tapeWidthMm > 0 || s.hasError else { return nil }
        let mm = Double(s.tapeWidthMm)
        let labelWmils = s.tapeWidthMm > 0 ? Int((mm / 25.4 * 1000).rounded()) : 0
        let pw = BrotherPT.printWidth(tapeMm: mm)
        let printableWmils = pw.map { Int((Double($0) / Double(BrotherPT.nativeDPI) * 1000).rounded()) } ?? labelWmils
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

    // MARK: – Run

    // One-at-a-time mode reports a per-label counter (each send blocks until the
    // printer accepts the bytes, by which point the label is essentially printed);
    // the full-job half-cut strip is coarse "Printing…".
    public func reportsCounter(singleLabel: Bool) -> Bool { singleLabel }

    public func run(_ job: DriverJob) throws {
        #if canImport(CLibUSB)
        guard let conn = job.connection as? BrotherConnection else { return }
        let count = job.pages.count
        guard count > 0 else { job.progress(.done); return }
        let perLabelMs = max(150, job.estLabelMs)

        if job.singleLabel {
            // Each label as its own job, with a real counter. Gate the cut by page
            // role, matching the M610/M611 contract: eachLabel → cut every label;
            // afterJobLast → cut only the final label; never → no cut. (Cut
            // SUPPRESSION on the classic dialect — the nocut bit — is hardware-
            // unverified; the 0x1A terminator may still feed+cut. Verify on a unit.)
            for (i, page) in job.pages.enumerated() {
                if job.isCancelled() { break }
                guard let tr = tapeRaster(for: page.label) else { continue }
                let wantsCut = page.cut == .eachLabel || (page.cut == .afterJobLast && page.isLast)
                let bytes = BrotherPT.buildPrintJob(rasterData: tr.raster, tapeMm: tr.tapeMm,
                                                    autocut: wantsCut, halfCut: false,
                                                    nocut: !wantsCut, isLastPage: true)
                try BrotherUSB.send(bytes, on: conn)
                job.progress(.counter(done: i + 1, of: count))
            }
            // Drain so the last label finishes before the Engine closes the port.
            BrotherUSB.drainStatus(on: conn, maxMs: perLabelMs * 3 + 6000)
            if !job.isCancelled() { job.progress(.done) }
            return
        }

        // Full job: ONE classic batch stream (init once, half-cut scored between
        // labels when the cut mode asks for per-label cuts, one feed+cut at the end).
        if job.isCancelled() { return }
        let rasters = job.pages.compactMap { tapeRaster(for: $0.label) }
        guard let tapeMm = rasters.first?.tapeMm else { job.progress(.done); return }
        let betweenHalfCut = job.pages.contains { $0.cut == .eachLabel }
        // Leave the strip on the roll only if EVERY page asked for no cut; otherwise
        // the trailing 0x1A releases the finished strip (the normal continuous case).
        let suppressEndCut = job.pages.allSatisfy { $0.cut == .never }
        let stream = BrotherPT.buildBatchStream(labelRasters: rasters.map { $0.raster },
                                                tapeMm: tapeMm, betweenHalfCut: betweenHalfCut,
                                                suppressEndCut: suppressEndCut)
        job.progress(.printing)
        try BrotherUSB.send(stream, on: conn)
        // Hold "Printing…" and drain until the strip finishes printing + cuts.
        BrotherUSB.drainStatus(on: conn, maxMs: count * perLabelMs * 3 + 8000)
        job.progress(.done)
        #endif
    }
}
