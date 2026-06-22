import Foundation
import VectorLabelCore

/// Brother **PT-E560BT** driver — the **D460BT-generation** dialect over USB.
///
/// Despite the "E"-series name, the E560BT is firmware-wise a PT-D460BT device and
/// speaks a DIFFERENT raster dialect from the classic E550W/P750W (handoff §6/§7):
/// uncompressed raster, the load-bearing `ESC i z` page-index byte (n9=0x02), the
/// 7-byte magic margin, NO status auto-notify, and a TWO-job half-cut strip (a chained
/// scored series + a standalone release cut). Feeding it the classic dialect prints
/// one job then hangs forever (only the physical power button recovers it), so it is
/// routed exclusively to `BrotherPT`'s D460BT builders.
///
/// Connection is **USB only**: the unit is Bluetooth (not Wi-Fi), so there's no raw
/// TCP 9100, and the docs don't specify a Bluetooth transport. The E560BT also needs
/// the FULL post-print status drain (it pushes multiple blocks and wedges its IN pipe
/// if any are left undelivered at close) — handled by `BrotherUSB.drainStatus`.
public final class PTE560BTModule: PrinterModule {
    public init() {}

    static let productIDs: [UInt16: String] = BrotherPT.d460ProductIDs   // [0x2203: "PT-E560BT"]
    // Tape-frame orientation flips (see BrotherClassicModule) — verify on a real unit.
    static let mirrorAlong = false
    static let mirrorAcross = true

    public let capabilities = PrinterCapabilities(
        model: "PT-E560BT", supportedTransports: [.usb], hasLiveTelemetry: false,
        hasAutoCutter: true,            // built-in cutter (full + half/score cut)
        ribbonLengthInches: 0,          // TZe tape — no separate ribbon gauge
        sendMode: .selectable(defaultSingle: false),
        cutOptions: [
            CutOption(mode: .eachLabel,       label: "Full cut every label"),
            CutOption(mode: .halfEachFullEnd, label: "Half cut every label, full cut at end"),
            CutOption(mode: .afterJobLast,    label: "Full cut at end of job"),
            CutOption(mode: .never,           label: "None"),
        ])

    public func enumerate() -> [PrinterDevice] {
        let active = PrinterModelStore.enabledTransports(forName: capabilities.model, productIDs: ["2203"])
            .intersection(capabilities.supportedTransports)
        guard active.contains(.usb) else { return [] }
        return BrotherUSB.enumerate(supportedPIDs: Self.productIDs)
    }

    // MARK: – Encode (master raster → one standalone D460BT full-cut label)

    public func encode(label: RenderedLabel, status: CassetteStatus?,
                       cut: CutMode, isLastLabel: Bool) -> [UInt8] {
        guard let tr = BrotherPT.tapeRaster(for: label, mirrorAlong: Self.mirrorAlong,
                                            mirrorAcross: Self.mirrorAcross) else { return [] }
        // A lone standalone D460BT label cuts itself (n9=0x02 + 0x1A). There's no clean
        // single-label "no cut" on this dialect, so `.never` still cuts a single label.
        return BrotherPT.buildPrintJobD460BT(rasterData: tr.raster, tapeMm: tr.tapeMm)
    }

    // MARK: – Transport (USB only)

    public func open(_ device: PrinterDevice) throws -> PrinterConnection {
        #if canImport(CLibUSB)
        return try BrotherUSB.open(deviceID: device.id, supportedPIDs: Self.productIDs)
        #else
        throw BrotherNet.NetError.connectFailed
        #endif
    }

    public func send(_ bytes: [UInt8], on connection: PrinterConnection) throws {
        #if canImport(CLibUSB)
        if let c = connection as? BrotherConnection { try BrotherUSB.send(bytes, on: c) }
        #endif
    }

    public func close(_ connection: PrinterConnection) {
        #if canImport(CLibUSB)
        if let c = connection as? BrotherConnection { BrotherUSB.close(c) }
        #endif
    }

    public func readStatus(_ device: PrinterDevice) -> CassetteStatus? {
        #if canImport(CLibUSB)
        guard let conn = try? BrotherUSB.open(deviceID: device.id, supportedPIDs: Self.productIDs) else { return nil }
        defer { BrotherUSB.close(conn) }
        try? BrotherUSB.send(BrotherPT.statusRequest(), on: conn)
        guard let raw = BrotherUSB.readStatus(on: conn), let s = BrotherPT.parseStatus(raw) else { return nil }
        return BrotherPT.cassetteStatus(from: s)
        #else
        return nil
        #endif
    }

    // MARK: – Run

    public func reportsCounter(singleLabel: Bool) -> Bool { singleLabel }

    /// The cut MODE drives the D460BT print strategy:
    ///   • Full cut every label (`.eachLabel`) → one standalone full-cut job per label
    ///     (a lone D460BT label cuts itself) → per-label counter + responsive cancel.
    ///   • Half cut every label, full cut end (`.halfEachFullEnd`) → the two-job
    ///     half-cut strip (chained scored series + standalone release cut). HW-VERIFIED.
    ///   • Full cut at end only (`.afterJobLast`) → chained series with no inter-label
    ///     cut + a standalone release cut. (HW-unverified.)
    ///   • None (`.never`) → chained series, no release cut (strip stays). (HW-unverified.)
    /// A single label always prints as one standalone full-cut job.
    public func run(_ job: DriverJob) throws {
        let conn = job.connection
        let count = job.pages.count
        guard count > 0 else { job.progress(.done); return }
        let perLabelMs = max(150, job.estLabelMs)
        let jobCut = job.pages.last?.cut ?? .afterJobLast

        func sendStandaloneFullCut(_ label: RenderedLabel) throws {
            guard let tr = BrotherPT.tapeRaster(for: label, mirrorAlong: Self.mirrorAlong,
                                                mirrorAcross: Self.mirrorAcross) else { return }
            try send(BrotherPT.buildPrintJobD460BT(rasterData: tr.raster, tapeMm: tr.tapeMm), on: conn)
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

        // Connected-strip strategies → ONE byte stream. Send a feed-to-clear lead
        // (page 0 forced to a full cut) as its own standalone job first.
        if job.isCancelled() { return }
        var pages = job.pages
        if pages.count > 1, pages.first?.cut == .eachLabel {
            try sendStandaloneFullCut(pages[0].label)
            pages.removeFirst()
        }
        let rasters = pages.compactMap {
            BrotherPT.tapeRaster(for: $0.label, mirrorAlong: Self.mirrorAlong, mirrorAcross: Self.mirrorAcross)
        }
        guard let tapeMm = rasters.first?.tapeMm else {
            if !job.isCancelled() { job.progress(.done) }
            return
        }
        // Mixed tape widths can't share one D460BT stream (every page carries one width,
        // and a width mismatch is exactly what can wedge this dialect). Fall back to one
        // standalone full-cut job per label at its OWN width.
        if Set(rasters.map { $0.tapeMm }).count > 1 {
            for (i, tr) in rasters.enumerated() {
                if job.isCancelled() { break }
                try send(BrotherPT.buildPrintJobD460BT(rasterData: tr.raster, tapeMm: tr.tapeMm), on: conn)
                job.progress(.counter(done: i + 1, of: count))
            }
            drain(conn, count: count, perLabelMs: perLabelMs)
            if !job.isCancelled() { job.progress(.done) }
            return
        }
        let lr = rasters.map { $0.raster }
        let stream: [UInt8]
        if lr.count == 1 {
            // A lone label cuts itself; `.never` still cuts (no single-label suppress).
            stream = BrotherPT.buildPrintJobD460BT(rasterData: lr[0], tapeMm: tapeMm)
        } else {
            switch jobCut {
            case .halfEachFullEnd:                 // scored between + standalone release cut (HW-verified)
                stream = BrotherPT.buildHalfcutStripD460BT(labelRasters: lr, tapeMm: tapeMm, halfCutBetween: true)
            case .never:                           // chained, no release cut — strip stays (HW-unverified)
                stream = BrotherPT.buildHalfcutSeriesD460BT(labelRasters: lr, tapeMm: tapeMm, halfCutBetween: false)
            default:                               // .afterJobLast → chained no-cut + release cut (HW-unverified)
                stream = BrotherPT.buildHalfcutSeriesD460BT(labelRasters: lr, tapeMm: tapeMm, halfCutBetween: false)
                       + BrotherPT.buildCutterJobD460BT(tapeMm: tapeMm)
            }
        }
        job.progress(.printing)
        try send(stream, on: conn)
        drain(conn, count: count, perLabelMs: perLabelMs)
        job.progress(.done)
    }

    /// Drain after a print before the connection closes. The E560BT pushes multiple
    /// status blocks (phase-change, completed) and wedges its IN pipe if any are left
    /// undelivered at close, so read until quiet (bounded). USB only.
    private func drain(_ connection: PrinterConnection, count: Int, perLabelMs: Int) {
        #if canImport(CLibUSB)
        if let c = connection as? BrotherConnection {
            BrotherUSB.drainStatus(on: c, maxMs: count * perLabelMs * 3 + 8000)
        }
        #endif
    }
}
