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
        pacesByLabelsRemaining: true, ribbonLengthInches: 75 * 12)   // 75 ft ribbon

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
        case .afterJobLast: vglCut = isLastLabel ? .afterJob : .never
        }
        return BradyVGL.buildPrintJob(pixels: label.bytes, width: label.width,
                                      height: label.height, cutMode: vglCut)
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
}
