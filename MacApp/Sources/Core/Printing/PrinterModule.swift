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

/// One selectable cut option a driver advertises for its printer. `mode` is the
/// Core `CutMode` the job carries; `label` is the printer-specific display text
/// (the same `.afterJobLast` reads "End of Job" on a Brady but "Full cut at end of
/// job" on a Brother). The Engine relays these through the status file so each
/// front-end's cut dropdown matches the SELECTED printer's real capabilities.
public struct CutOption: Codable, Equatable, Hashable {
    public let mode: CutMode
    public let label: String
    public init(mode: CutMode, label: String) { self.mode = mode; self.label = label }

    /// The standard Brady set (M610/M611): full cut after each label, one cut at the
    /// end of the job, or no cut. No half-cut (the Brady shear cutter is full-cut only).
    public static let bradyStandard: [CutOption] = [
        CutOption(mode: .eachLabel, label: "Every Label"),
        CutOption(mode: .afterJobLast, label: "End of Job"),
        CutOption(mode: .never, label: "None"),
    ]
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
    /// Has a built-in AUTOMATIC cutter the Engine can actuate (M611). The M610 has only
    /// a manual cutter, so it can't auto-cut (a future "stop and prompt to cut" flow).
    public let hasAutoCutter: Bool
    /// Length of a full ribbon for this printer, in inches (a fixed, known per-driver
    /// value — Brady M610/M611 = 75 ft = 900"). 0 means no ribbon / unknown (e.g. a
    /// direct-thermal printer). Front-ends extrapolate remaining ribbon length from the
    /// telemetry ribbon % against this, to forecast whether a job will run the ribbon out.
    public let ribbonLengthInches: Double
    /// Whether the user's "one label at a time vs full job" choice applies to this driver.
    /// `.selectable` → the per-printer UI offers it (single = per-label progress + mid-run
    /// cancel; full = one fast send). `.fixed` → the driver
    /// always reports good progress (hardware counter / live job telemetry), so the choice
    /// is irrelevant and the UI greys it out — a future printer with proper feedback ships
    /// this in its driver with no engine changes.
    public let sendMode: SendModeSupport
    /// The cut options this printer offers, in display order. The Engine relays them
    /// to the front-ends so the per-job cut dropdown matches the selected printer
    /// (Brady = `bradyStandard`; Brother adds half-cut). Defaults to the Brady set so
    /// existing drivers need no change.
    public let cutOptions: [CutOption]

    public init(model: String, supportedTransports: Set<PrinterTransport>,
                hasLiveTelemetry: Bool,
                hasAutoCutter: Bool = false, ribbonLengthInches: Double = 0,
                sendMode: SendModeSupport = .selectable(defaultSingle: false),
                cutOptions: [CutOption] = CutOption.bradyStandard) {
        self.model = model
        self.supportedTransports = supportedTransports
        self.hasLiveTelemetry = hasLiveTelemetry
        self.hasAutoCutter = hasAutoCutter
        self.ribbonLengthInches = ribbonLengthInches
        self.sendMode = sendMode
        self.cutOptions = cutOptions
    }
}

/// Whether the user's single-vs-batch send choice is meaningful for a driver.
public enum SendModeSupport: Equatable {
    case fixed                              // driver always reports good progress → UI greys the toggle
    case selectable(defaultSingle: Bool)    // user picks one-at-a-time vs full job
}

/// One page of a print job, ready for the driver to encode + send. The Engine builds these
/// (feed-to-clear lead prepended, per-page cut resolved, last page flagged); the driver
/// only decides HOW to send them (one at a time vs batched) and reports progress.
public struct DriverPage {
    public let label: RenderedLabel
    public let cut: CutMode
    public let isLast: Bool
    public init(label: RenderedLabel, cut: CutMode, isLast: Bool) {
        self.label = label; self.cut = cut; self.isLast = isLast
    }
}

/// Progress a driver reports as it runs a job. The Engine maps `.counter` to a per-label
/// bar and `.printing` to an indeterminate "Printing…".
public enum JobProgress {
    case counter(done: Int, of: Int)
    case printing
    case done
}

/// A full print job handed to a driver's `run`. The Engine owns the job lifecycle (queue,
/// cancel, IPC, recents) and supplies an open connection, a cancel check, and a progress
/// sink; the driver owns the send strategy, pacing, and progress reporting.
public struct DriverJob {
    public let pages: [DriverPage]
    public let status: CassetteStatus?
    public let singleLabel: Bool          // user preference (ignored when sendMode == .fixed)
    public let estLabelMs: Int            // per-label print-time estimate (pacing fallback)
    public let connection: PrinterConnection
    public let isCancelled: () -> Bool
    public let progress: (JobProgress) -> Void
    /// Pause between labels on a printer WITHOUT an auto-cutter (cut-every-label): the
    /// driver calls this after each label so the host can prompt the user to cut/tear it,
    /// blocking until they continue. Returns true to keep printing, false to stop (the user
    /// cancelled). nil ⇒ no pause (auto-cutter, or the host didn't supply one).
    public let awaitCut: (() -> Bool)?
    public init(pages: [DriverPage], status: CassetteStatus?, singleLabel: Bool,
                estLabelMs: Int, connection: PrinterConnection,
                isCancelled: @escaping () -> Bool, progress: @escaping (JobProgress) -> Void,
                awaitCut: (() -> Bool)? = nil) {
        self.pages = pages; self.status = status; self.singleLabel = singleLabel
        self.estLabelMs = estLabelMs
        self.connection = connection; self.isCancelled = isCancelled; self.progress = progress
        self.awaitCut = awaitCut
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

    /// Run a whole print job: encode + send + pace + report progress. The driver owns the
    /// send strategy (one label at a time vs one batched job) and pacing, and MUST finish
    /// or drain any in-flight printing before returning so the Engine's connection close
    /// doesn't abort a label mid-print. Honors `job.isCancelled` to stop early.
    func run(_ job: DriverJob) throws

    /// Whether this driver reports a per-label `.counter` (vs coarse `.printing`) for a job
    /// sent in the given mode — lets the Engine set up the right progress UI up front.
    func reportsCounter(singleLabel: Bool) -> Bool
}

public extension PrinterModule {
    func handles(model: String) -> Bool { model == capabilities.model }
    func labelsRemaining(on connection: PrinterConnection) -> Int { -1 }
    func reportsCounter(singleLabel: Bool) -> Bool { false }
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
