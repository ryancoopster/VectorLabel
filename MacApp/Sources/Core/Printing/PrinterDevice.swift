import Foundation

/// A Brady printer discovered by a `PrinterModule` (USB or network).
///
/// Moved to Core (from EngineKit) so the shared `PrinterModule` protocol and both
/// per-printer modules (M610 = USB, M611 = network) can refer to it without an
/// EngineKit dependency.
public struct PrinterDevice: Identifiable, Hashable {
    public let id: String          // "<vendorID>:<productID>:<serial>" (USB) or "net:<serial>" (network)
    public let name: String        // "Brady M610" / "Brady M611"
    public let model: String       // "M610" | "M611"
    public let serial: String
    public var status: Status
    /// For network printers, the host/IP the module connects to (nil for USB).
    public var host: String?

    public enum Status: String, Hashable {
        case ready, busy, offline
        public var displayName: String {
            switch self { case .ready: "Ready"; case .busy: "Busy"; case .offline: "Offline" }
        }
    }

    public init(id: String, name: String, model: String, serial: String,
                status: Status, host: String? = nil) {
        self.id = id; self.name = name; self.model = model
        self.serial = serial; self.status = status; self.host = host
    }
}
