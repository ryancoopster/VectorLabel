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
        return BradyVGL.buildPrintJob(pixels: d.pixels, width: d.width,
                                      height: d.height, cutMode: vglCut)
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
        if job.singleLabel {
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
