import Foundation
import VectorLabelCore

// MARK: – SmartCell → CassetteStatus
//
// Moved here from EngineKit/StatusMapping so the M610 module owns its own status
// mapping (the M611 module owns its PICL→CassetteStatus mapping likewise).
public extension BradyUSB.SmartCellInfo {
    /// A Codable `CassetteStatus` mirror of this SmartCell read. `labelsPerRoll` is
    /// resolved from the catalog here so front-ends don't have to. SmartCellInfo
    /// carries no `printableHeightMils`, so it's set equal to the label height.
    func asCassetteStatus() -> CassetteStatus {
        CassetteStatus(
            partNumber: partNumber,
            labelWidthMils: labelWidthMils,
            labelHeightMils: labelHeightMils,
            printableWidthMils: printableWidthMils,
            printableHeightMils: labelHeightMils,
            isDieCut: isDieCut,
            supplyRemainingPct: supplyRemainingPct,
            labelsPerRoll: BradyCatalog.labelsPerRoll(forPartNumber: partNumber),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            ribbonPartNumber: ribbonCode.isEmpty ? nil : ribbonCode
        )
    }
}

// MARK: – M610 driver

/// Opaque connection token wrapping the libusb device handle.
final class USBConnection: PrinterConnection {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
}

/// The M610 printer module: VGL encoder + USB transport + SmartCell cassette read.
/// A thin, behavior-preserving wrapper over the existing `BradyVGL` and `BradyUSB`.
public final class M610Module: PrinterModule {
    public init() {}

    public let capabilities = PrinterCapabilities(
        model: "M610", supportedTransports: [.usb], hasLiveTelemetry: false,
        ribbonLengthInches: 75 * 12,                   // 75 ft ribbon
        sendMode: .selectable(defaultSingle: true))    // single-label = per-label progress via SmartCell counter

    /// The M610 print head's native resolution. Labels are rendered at the master
    /// render DPI (`RenderDPI.master`) and downscaled to this in `encode()`.
    static let nativeDPI = 300

    // Only claim M610 USB devices. A USB-connected M611 (composite, PID 0x13) is NOT
    // handled here — the M611 speaks ECP, not VGL — so it's filtered out (M611 USB
    // support is a separate effort; the M611 is driven over the network for now).
    public func enumerate() -> [PrinterDevice] {
        // Enumerate only over transports BOTH enabled by the user AND supported by this
        // driver (M610 = USB only).
        let active = PrinterModelStore.enabledTransports(forName: capabilities.model, productIDs: ["010B"])
            .intersection(capabilities.supportedTransports)
        guard active.contains(.usb) else { return [] }
        return BradyUSB.enumeratePrinters().filter { $0.model == "M610" }
    }

    public func encode(label: RenderedLabel, status: CassetteStatus?,
                       cut: CutMode, isLastLabel: Bool) -> [UInt8] {
        let vglCut: BradyVGL.CutMode
        switch cut {
        case .never:        vglCut = .never
        case .eachLabel:    vglCut = .eachLabel
        // The M610 shear cutter is full-cut only (no half-cut), so a half-cut mode
        // degrades to a single full cut at the end of the job. (Not advertised.)
        case .afterJobLast, .halfEachFullEnd: vglCut = isLastLabel ? .afterJob : .never
        }
        // Downscale the master-DPI raster to the M610's native 300 dpi before VGL
        // packs it (one wire pixel = one print-head dot); VGL itself is DPI-agnostic.
        let d = MonoRaster.downscale(pixels: label.bytes, width: label.width,
                                     height: label.height, fromDPI: label.dpi, toDPI: Self.nativeDPI)
        // Orient the raster using the RENDERER'S OWN decision, carried on the label.
        // The renderer rotates CONTINUOUS-style stock 90° (its `landscape` flag: continuous
        // tape, a canvasRot-90 design, or a die-cut→continuous remap) and leaves DIE-CUT
        // upright — which is exactly the row-major vs column-major choice:
        //   landscape  → row-major   (design width runs across the head, length along feed)
        //   upright    → column-major (height across the head, width along feed)
        // Keyed on `label.landscape`, NOT a part-number lookup (build 342, which mis-resolved
        // unknown continuous parts → die-cut → clipped) and NOT the SmartCell printable area
        // (build 343 — printableWidthMils is the printable-zone width in the label's OWN
        // frame, not an across-head orientation, and isDieCut reads `true` even for the
        // continuous tape, so neither distinguishes orientation).
        // M610-only — the M611 (M611Bitmap/areaRotation) and Brother (BrotherPT) are untouched.
        let columnMajor = !label.landscape
        NSLog("[M610] orient raster=%dx%d landscape=%@ → columnMajor=%@",
              d.width, d.height, String(label.landscape), String(columnMajor))
        return BradyVGL.buildPrintJob(pixels: d.pixels, width: d.width,
                                      height: d.height, cutMode: vglCut, columnMajor: columnMajor)
    }

    public func open(_ device: PrinterDevice) throws -> PrinterConnection {
        USBConnection(try BradyUSB.openPrinterByID(device.id))
    }

    public func send(_ bytes: [UInt8], on connection: PrinterConnection) throws {
        guard let c = connection as? USBConnection else { return }
        try BradyUSB.sendJob(bytes, handle: c.handle)
    }

    public func close(_ connection: PrinterConnection) {
        guard let c = connection as? USBConnection else { return }
        BradyUSB.close(c.handle)
    }

    public func readStatus(_ device: PrinterDevice) -> CassetteStatus? {
        guard let h = try? BradyUSB.openPrinterByID(device.id) else { return nil }
        defer { BradyUSB.close(h) }
        return BradyUSB.querySmartCell(handle: h)?.asCassetteStatus()
    }

    public func labelsRemaining(on connection: PrinterConnection) -> Int {
        guard let c = connection as? USBConnection else { return -1 }
        return BradyUSB.labelsRemaining(handle: c.handle)
    }

    // The M610 has a SmartCell labels-remaining counter, so it reports an accurate per-label
    // counter in BOTH send modes.
    public func reportsCounter(singleLabel: Bool) -> Bool { true }

    /// Run a job: one label at a time (counter-paced via the SmartCell labels-remaining read) or one
    /// batched send, then settle on the counter so the connection isn't closed mid-print.
    public func run(_ job: DriverJob) throws {
        let conn = job.connection
        let count = job.pages.count
        let perLabelMs = max(150, job.estLabelMs)
        let initialRem = labelsRemaining(on: conn)
        // Labels printed so far = how far the SmartCell counter has fallen from its start.
        // Track the LOWEST remaining seen (not a raw `initialRem - rem`) so a counter that
        // drifts up across a roll change — or a momentarily stale, larger read — can't make
        // the delta go negative (which would stall the settle loop) or reset progress to 0.
        var minRem = initialRem
        func printedSoFar(_ rem: Int) -> Int {
            if rem >= 0 { minRem = min(minRem, rem) }
            return max(0, initialRem - minRem)
        }
        func bytes(_ p: DriverPage) -> [UInt8] {
            encode(label: p.label, status: job.status, cut: p.cut, isLastLabel: p.isLast)
        }
        // No auto-cutter + "cut every label": pause for a MANUAL cut between labels.
        // Force the one-at-a-time path (a batched send can't pause mid-stream).
        let manualCutPause = !capabilities.hasAutoCutter && job.awaitCut != nil
            && job.pages.contains { $0.cut == .eachLabel }
        if job.singleLabel || manualCutPause {
            for (i, page) in job.pages.enumerated() {
                if job.isCancelled() { break }
                try send(bytes(page), on: conn)
                var waited = 0
                while waited < perLabelMs && !job.isCancelled() {
                    if initialRem >= 0, waited % 120 == 0 {
                        let rem = labelsRemaining(on: conn)
                        if rem >= 0 && printedSoFar(rem) >= (i + 1) { break }   // this label printed
                    }
                    usleep(40_000); waited += 40
                }
                if job.isCancelled() { break }
                job.progress(.counter(done: i + 1, of: count))
                // Pause so the user cuts this label before the next feeds (not after the
                // last). awaitCut blocks until they continue; false ⇒ they stopped the job.
                if manualCutPause, page.cut == .eachLabel, i < count - 1, !job.isCancelled() {
                    if !(job.awaitCut?() ?? true) { break }
                }
            }
        } else {
            var batch: [UInt8] = []
            for page in job.pages { batch += bytes(page) }
            if !job.isCancelled() { try send(batch, on: conn) }
        }
        // Settle until the counter drops by the job's label count (bounded) so the in-flight
        // labels finish before the Engine closes the connection.
        if !job.isCancelled() && initialRem >= 0 {
            let startNs = DispatchTime.now().uptimeNanoseconds
            let capMs = count * perLabelMs * 2 + 8000
            while !job.isCancelled() {
                let rem = labelsRemaining(on: conn)
                if rem >= 0 {
                    let done = printedSoFar(rem)
                    job.progress(.counter(done: min(count, done), of: count))
                    if done >= count { break }
                }
                let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
                if elapsedMs >= capMs { break }
                usleep(200_000)
            }
        }
        // On cancel the settle loop above is skipped, so report the count the HARDWARE
        // actually printed (the SmartCell counter) — otherwise the recent shows the last
        // loop value, missing the label that printed as the user cancelled.
        if job.isCancelled(), initialRem >= 0 {
            let rem = labelsRemaining(on: conn)
            if rem >= 0 { job.progress(.counter(done: min(count, max(0, printedSoFar(rem))), of: count)) }
        }
        job.progress(.done)
    }
}
