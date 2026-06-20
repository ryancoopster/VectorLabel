import Foundation

/// An opaque, per-module connection handle (a USB device handle, a TCP socket, …).
/// The Engine holds it as an existential and hands it back to the owning module for
/// `send`/`labelsRemaining`/`close` — it never inspects the concrete type.
public protocol PrinterConnection: AnyObject {}

/// A communication method a printer can be driven over. Drivers report which they
/// SUPPORT (`PrinterCapabilities.supportedTransports`); the user enables which to USE
/// per printer (`PrinterModel.enabledTransports`). The Engine drives a printer only
/// over a transport that is BOTH supported by the driver and enabled by the user.
public enum PrinterTransport: String, Codable, Hashable, CaseIterable {
    case usb, network, bluetooth
    public var displayName: String {
        switch self {
        case .usb:       return "USB"
        case .network:   return "Network"
        case .bluetooth: return "Bluetooth"
        }
    }
}

/// Static capabilities of a printer model, so the Engine/UI route and gate features
/// without branching on the model string everywhere.
public struct PrinterCapabilities {
    public let model: String
    /// The communication methods this driver can actually drive the printer over. The
    /// Engine intersects this with the user's per-printer enabled transports.
    public let supportedTransports: Set<PrinterTransport>
    /// Live ribbon/label/battery + media telemetry over the wire (M611). M610 reads
    /// only the SmartCell cassette.
    public let hasLiveTelemetry: Bool
    /// Paces a batch off a hardware labels-remaining counter (M610 SmartCell). When
    /// false the Engine paces by time estimate (M611).
    public let pacesByLabelsRemaining: Bool
    /// Has a built-in AUTOMATIC cutter the Engine can actuate (M611). The M610 has only
    /// a manual cutter, so it can't auto-cut (a future "stop and prompt to cut" flow).
    public let hasAutoCutter: Bool

    public init(model: String, supportedTransports: Set<PrinterTransport>,
                hasLiveTelemetry: Bool, pacesByLabelsRemaining: Bool,
                hasAutoCutter: Bool = false) {
        self.model = model
        self.supportedTransports = supportedTransports
        self.hasLiveTelemetry = hasLiveTelemetry
        self.pacesByLabelsRemaining = pacesByLabelsRemaining
        self.hasAutoCutter = hasAutoCutter
    }
}

/// One self-contained printer driver: discovery, encode (raster → wire bytes),
/// transport, and status. The M610 (VGL/USB) and M611 (bitmap/network) each
/// implement this in their own module; the Engine drives them uniformly via the
/// registry, routing by `model`. This is the single seam where a new printer plugs
/// in — implement the protocol + register the module.
public protocol PrinterModule: AnyObject {
    var capabilities: PrinterCapabilities { get }

    /// Does this module drive the given model id ("M610" / "M611")?
    func handles(model: String) -> Bool

    /// Discover connected printers of this module's kind.
    func enumerate() -> [PrinterDevice]

    /// Encode one rendered label into this printer's wire format. `status` is the
    /// printer's last-known cassette/media (for the M611's rotation + part number);
    /// `isLastLabel` lets the encoder place an end-of-job cut.
    func encode(label: RenderedLabel, status: CassetteStatus?, cut: CutMode, isLastLabel: Bool) -> [UInt8]

    /// Open a connection to a device (for a print job or status read).
    func open(_ device: PrinterDevice) throws -> PrinterConnection

    /// Send one already-encoded label's bytes on an open connection.
    func send(_ bytes: [UInt8], on connection: PrinterConnection) throws

    /// Close a connection.
    func close(_ connection: PrinterConnection)

    /// Read the loaded cassette/media status, or nil if unavailable.
    func readStatus(_ device: PrinterDevice) -> CassetteStatus?

    /// Hardware labels-remaining counter for pacing, or -1 if the transport can't
    /// report it (the Engine then paces by time estimate).
    func labelsRemaining(on connection: PrinterConnection) -> Int
}

public extension PrinterModule {
    func handles(model: String) -> Bool { model == capabilities.model }
    func labelsRemaining(on connection: PrinterConnection) -> Int { -1 }
}

/// Registry of available printer modules. The Engine registers M610 + M611 at
/// startup; discovery, encode, transport, and status all route by `model` through
/// here, so nothing else branches on the printer kind.
public final class PrinterModuleRegistry {
    public static let shared = PrinterModuleRegistry()
    private let lock = NSLock()
    private var modules: [PrinterModule] = []

    public init() {}

    public func register(_ module: PrinterModule) {
        lock.lock(); defer { lock.unlock() }
        // Replace any existing module for the same model (idempotent registration).
        modules.removeAll { $0.capabilities.model == module.capabilities.model }
        modules.append(module)
    }

    public func module(forModel model: String) -> PrinterModule? {
        lock.lock(); defer { lock.unlock() }
        return modules.first { $0.handles(model: model) }
    }

    public func all() -> [PrinterModule] {
        lock.lock(); defer { lock.unlock() }
        return modules
    }
}
