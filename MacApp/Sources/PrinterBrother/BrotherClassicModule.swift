import Foundation
import VectorLabelCore

/// Shared implementation for a Brother **classic-dialect** PT printer (the PT-E550W /
/// PT-P750W generation): classic raster (`BrotherPT`) over USB (`BrotherUSB`) or raw
/// TCP 9100 (`BrotherNet`), native 180 DPI. Each concrete printer is its OWN
/// `PrinterModule` subclass (so the registry has one module per model) that supplies
/// only its name + USB product id(s); the dialect and transports are reused.
///
/// The front-end renders at the 900-DPI master, so the job path downscales to 180 and
/// transposes the reading-orientation raster into the tape frame (across-tape →
/// print-head pins, along-tape → raster lines) via `BrotherPT.tapeRaster`.
///
/// No live per-label ack on this generation, so progress is coarse in full-job mode
/// (one half-cut strip) and a per-label counter in one-at-a-time mode (each label fed
/// + cut). The drain rule is honored before returning so a connection-close can't
/// abort a print: USB reads the status channel until quiet; network waits ~the print
/// duration (a buffered job survives the TCP close).
public class BrotherClassicModule: PrinterModule {

    let productIDs: [UInt16: String]
    // Tape-frame orientation flips. `BrotherPT.tapeRaster` transposes the rendered
    // raster into the printer's tape frame; a bare transpose is a REFLECTION, so
    // exactly one axis must be reversed to make a clean 90° rotation (else mirrored).
    // mirrorAcross reverses the across-tape (pin) axis to undo that reflection. If a
    // hardware test shows the label upside-down instead, move the reversal to
    // mirrorAlong. Orientation is the one thing tests can't pin — verify per unit.
    let mirrorAlong: Bool
    let mirrorAcross: Bool
    public let capabilities: PrinterCapabilities

    init(model: String, productIDs: [UInt16: String],
         mirrorAlong: Bool = false, mirrorAcross: Bool = true) {
        self.productIDs = productIDs
        self.mirrorAlong = mirrorAlong
        self.mirrorAcross = mirrorAcross
        self.capabilities = PrinterCapabilities(
            model: model, supportedTransports: [.usb, .network], hasLiveTelemetry: false,
            hasAutoCutter: true,            // built-in cutter (full + half cut)
            ribbonLengthInches: 0,          // TZe tape — no separate ribbon gauge
            sendMode: .selectable(defaultSingle: false),
            // The PT cutter does full AND half (score) cuts; the selected cut mode
            // drives the print strategy in run() (full-cut-each = separate jobs;
            // half/no-cut = one strip).
            cutOptions: [
                CutOption(mode: .eachLabel,       label: "Full cut every label"),
                CutOption(mode: .halfEachFullEnd, label: "Half cut every label, full cut at end"),
                CutOption(mode: .afterJobLast,    label: "Full cut at end of job"),
                CutOption(mode: .never,           label: "None"),
            ])
    }

    /// Uppercase 4-hex-digit PID strings (e.g. "2060") for the per-model transport lookup.
    private var pidStrings: Set<String> { Set(productIDs.keys.map { String(format: "%04X", $0) }) }

    public func enumerate() -> [PrinterDevice] {
        let active = PrinterModelStore.enabledTransports(forName: capabilities.model, productIDs: pidStrings)
            .intersection(capabilities.supportedTransports)
        var out: [PrinterDevice] = []
        // Network printers: NetworkPrinterStore entries whose model is one of OURS (so
        // a different driver doesn't also claim them, and vice-versa). Raw TCP 9100.
        if active.contains(.network) {
            let models = Set(productIDs.values)
            out += NetworkPrinterStore.list()
                .filter { models.contains($0.model) }
                .map { e in
                    let online = BrotherNet.reachable(host: e.host)
                    return PrinterDevice(id: "net:\(e.host)", name: e.name, model: capabilities.model,
                                         serial: e.host, status: online ? .ready : .offline, host: e.host)
                }
        }
        if active.contains(.usb) { out += BrotherUSB.enumerate(supportedPIDs: productIDs) }
        return out
    }

    // MARK: – Encode (master raster → classic-dialect single-label job)

    public func encode(label: RenderedLabel, status: CassetteStatus?,
                       cut: CutMode, isLastLabel: Bool) -> [UInt8] {
        guard let tr = BrotherPT.tapeRaster(for: label, mirrorAlong: mirrorAlong, mirrorAcross: mirrorAcross) else { return [] }
        // A single standalone label: full-cut every label / at the end (no half-cut
        // applies to a lone label), never cut for .never.
        let wantsCut: Bool
        switch cut {
        case .eachLabel:                      wantsCut = true
        case .afterJobLast, .halfEachFullEnd: wantsCut = isLastLabel
        case .never:                          wantsCut = false
        }
        return BrotherPT.buildPrintJob(rasterData: tr.raster, tapeMm: tr.tapeMm,
                                       autocut: wantsCut, halfCut: false,
                                       nocut: !wantsCut, isLastPage: true)
    }

    // MARK: – Transport (network → TCP 9100; otherwise USB)

    public func open(_ device: PrinterDevice) throws -> PrinterConnection {
        if let host = device.host, !host.isEmpty {
            return BrotherNetConnection(fd: try BrotherNet.connect(host: host), host: host)
        }
        #if canImport(CLibUSB)
        return try BrotherUSB.open(deviceID: device.id, supportedPIDs: productIDs)
        #else
        throw BrotherNet.NetError.connectFailed
        #endif
    }

    public func send(_ bytes: [UInt8], on connection: PrinterConnection) throws {
        if let c = connection as? BrotherNetConnection { try BrotherNet.writeAll(fd: c.fd, bytes: bytes); return }
        #if canImport(CLibUSB)
        if let c = connection as? BrotherConnection { try BrotherUSB.send(bytes, on: c) }
        #endif
    }

    public func close(_ connection: PrinterConnection) {
        if let c = connection as? BrotherNetConnection { BrotherNet.close(c.fd); return }
        #if canImport(CLibUSB)
        if let c = connection as? BrotherConnection { BrotherUSB.close(c) }
        #endif
    }

    public func readStatus(_ device: PrinterDevice) -> CassetteStatus? {
        // Media auto-detect (ESC i S) reads the USB IN endpoint, not exposed over the
        // network — a network PT derives its tape from the rendered raster.
        if let host = device.host, !host.isEmpty { return nil }
        #if canImport(CLibUSB)
        guard let conn = try? BrotherUSB.open(deviceID: device.id, supportedPIDs: productIDs) else { return nil }
        defer { BrotherUSB.close(conn) }
        try? BrotherUSB.send(BrotherPT.statusRequest(), on: conn)
        guard let raw = BrotherUSB.readStatus(on: conn), let s = BrotherPT.parseStatus(raw) else { return nil }
        return BrotherPT.cassetteStatus(from: s)
        #else
        return nil
        #endif
    }

    // MARK: – Run

    // A per-label counter is only meaningful for the full-cut-every-label strategy
    // (separate jobs); the connected-strip strategies are one stream → coarse "Printing…".
    public func reportsCounter(singleLabel: Bool) -> Bool { singleLabel }

    /// The cut MODE drives the print strategy:
    ///   • Full cut every label (`.eachLabel`) → each label its own standalone full-cut
    ///     job → per-label counter + responsive cancel.
    ///   • Half cut every label, full cut end (`.halfEachFullEnd`) → ONE batch stream,
    ///     half-cut scored between labels, full cut at the end.
    ///   • Full cut at end only (`.afterJobLast`) → ONE batch stream, no inter-label
    ///     cut, full cut at the end.
    ///   • None (`.never`) → ONE batch stream, no cut at all (strip stays on the roll).
    public func run(_ job: DriverJob) throws {
        let conn = job.connection
        let count = job.pages.count
        guard count > 0 else { job.progress(.done); return }
        let perLabelMs = max(150, job.estLabelMs)
        let jobCut = job.pages.last?.cut ?? .afterJobLast

        func sendStandaloneFullCut(_ label: RenderedLabel) throws {
            guard let tr = BrotherPT.tapeRaster(for: label, mirrorAlong: mirrorAlong, mirrorAcross: mirrorAcross) else { return }
            try send(BrotherPT.buildPrintJob(rasterData: tr.raster, tapeMm: tr.tapeMm,
                                             autocut: true, halfCut: false, isLastPage: true), on: conn)
        }

        if jobCut == .eachLabel {
            for (i, page) in job.pages.enumerated() {
                if job.isCancelled() { break }
                try sendStandaloneFullCut(page.label)
                job.progress(.counter(done: i + 1, of: count))
            }
            drain(conn, count: count, perLabelMs: perLabelMs)
            if !job.isCancelled() { job.progress(.done) }
            return
        }

        // Connected-strip strategies → ONE batch stream. Send any feed-to-clear lead
        // (page 0 forced to a full cut while the job cut isn't every-label) first.
        if job.isCancelled() { return }
        var pages = job.pages
        if pages.count > 1, pages.first?.cut == .eachLabel {
            try sendStandaloneFullCut(pages[0].label)
            pages.removeFirst()
        }
        let rasters = pages.compactMap { BrotherPT.tapeRaster(for: $0.label, mirrorAlong: mirrorAlong, mirrorAcross: mirrorAcross) }
        guard let tapeMm = rasters.first?.tapeMm else {
            if !job.isCancelled() { job.progress(.done) }
            return
        }
        // A batch stream stamps EVERY page with one tape width; mixing widths would
        // mis-position/clip later pages. If the job's labels don't all snap to the same
        // width, fall back to one standalone full-cut job per label at its OWN width.
        if Set(rasters.map { $0.tapeMm }).count > 1 {
            for (i, tr) in rasters.enumerated() {
                if job.isCancelled() { break }
                try send(BrotherPT.buildPrintJob(rasterData: tr.raster, tapeMm: tr.tapeMm,
                                                 autocut: true, halfCut: false, isLastPage: true), on: conn)
                job.progress(.counter(done: i + 1, of: count))
            }
            drain(conn, count: count, perLabelMs: perLabelMs)
            if !job.isCancelled() { job.progress(.done) }
            return
        }
        // Cut SUPPRESSION on the classic dialect (the nocut bit, for `.never`) is
        // hardware-unverified — the 0x1A terminator may still feed+cut. Verify on a unit.
        let stream = BrotherPT.buildBatchStream(labelRasters: rasters.map { $0.raster }, tapeMm: tapeMm,
                                                betweenHalfCut: jobCut == .halfEachFullEnd,
                                                suppressEndCut: jobCut == .never)
        job.progress(.printing)
        try send(stream, on: conn)
        drain(conn, count: count, perLabelMs: perLabelMs)
        job.progress(.done)
    }

    /// Drain in-flight printing before the Engine closes the connection (the drain
    /// rule), sized to the job. USB: read the status channel until quiet (closing the
    /// interface mid-print ABORTS the job), bounded by a generous cap. Network: a TCP
    /// close won't abort a buffered job, so just hold "Printing…" ~the print duration
    /// (capped so a huge job can't block the device queue indefinitely).
    func drain(_ connection: PrinterConnection, count: Int, perLabelMs: Int) {
        #if canImport(CLibUSB)
        if let c = connection as? BrotherConnection {
            BrotherUSB.drainStatus(on: c, maxMs: count * perLabelMs * 3 + 8000)
            return
        }
        #endif
        let waitMs = min(max(count * perLabelMs + 1500, 800), 30_000)
        Thread.sleep(forTimeInterval: Double(waitMs) / 1000.0)
    }
}

// MARK: – Concrete classic-dialect printers (one module per model)

/// Brother **PT-E550W** — classic dialect, USB + raw TCP 9100.
public final class PTE550WModule: BrotherClassicModule {
    public init() { super.init(model: "PT-E550W", productIDs: [0x2060: "PT-E550W"]) }
}

/// Brother **PT-P750W** — classic dialect (shares the E550W raster family), USB + raw
/// TCP 9100. Doc-validated dialect; orientation/cut behavior is hardware-unverified.
public final class PTP750WModule: BrotherClassicModule {
    public init() { super.init(model: "PT-P750W", productIDs: [0x2062: "PT-P750W"]) }
}
