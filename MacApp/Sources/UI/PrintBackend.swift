import Foundation
import VectorLabelCore

/// Abstraction over wherever printer state lives and however print jobs are
/// submitted. Defined in terms of Core IPC types ONLY (no EngineKit / libusb), so
/// the UI layer that consumes it never links the USB stack.
///
/// Two implementations exist:
///   • `IPCPrintBackend` (Core-only) — reads/writes the file-based PrintQueue and
///     reads the Engine's published `printers.json` status. Used when the UI runs
///     as its own front-end process talking to a separate Engine.
///   • `LocalPrintBackend` (in the executable, may import EngineKit) — wraps the
///     in-process `PrinterManager`, so the single combined app prints exactly as
///     before but through this same surface.
@MainActor
public protocol PrintBackend: AnyObject {
    /// The most recent printer + cassette status, or nil if none is available yet.
    var status: PrinterStatusFile? { get }

    /// Invoked whenever the status changes. Consumers (e.g. the print window) push
    /// the new printer/cassette state into their UI here. Called on the main actor.
    var onStatusChange: ((PrinterStatusFile) -> Void)? { get set }

    /// Submit a fully-rendered job (labels are VGL byte buffers as `Data`).
    func submit(_ job: PrintJobFile) throws

    /// Ask the backend to re-read the loaded cassette for a printer (best-effort;
    /// may be a no-op). `printerID == nil` means "the current/sole printer".
    func requestCassetteRefresh(printerID: String?)

    /// Begin observing status and watching for changes.
    func start()

    /// Stop observing.
    func stop()
}
