import Foundation
import VectorLabelCore
#if canImport(Darwin)
import Darwin
#endif

/// Opaque connection token wrapping an open TCP socket to the printer's raw print
/// port (9100). The M611 prints by streaming the bitmap-job segments to this socket.
final class TCPConnection: PrinterConnection {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
}

/// The M611 printer module: bitmap/LZ4 encoder (`M611Bitmap`) + TCP transport
/// (print on 9100, telemetry on 9102). Network-only, Foundation-only (no libusb).
public final class M611Module: PrinterModule {
    public init() {}

    // M611 currently supports NETWORK only. The USB transport (M611USB) is written but
    // unverified/parked — add `.usb` here (and it lights up everywhere automatically)
    // once the M611 USB capture confirms the PID/interface/endpoints/framing.
    public let capabilities = PrinterCapabilities(
        model: "M611", supportedTransports: [.network], hasLiveTelemetry: true, pacesByLabelsRemaining: false)

    static let printPort: UInt16 = 9100
    static let telemetryPort: UInt16 = 9102

    public func enumerate() -> [PrinterDevice] {
        // Enumerate only over transports that are BOTH enabled by the user AND supported
        // by this driver. The M611 currently supports network only, so `active` won't
        // include .usb until capabilities.supportedTransports gains it. Each enabled
        // network printer's control port (9102) is probed so an unreachable one reports
        // .offline instead of a permanent .ready. Runs on the background scan task, so a
        // short blocking connect is fine here.
        let enabled = PrinterModelStore.enabledTransports(forName: capabilities.model, productIDs: ["010C"])
        let active = enabled.intersection(capabilities.supportedTransports)
        let net: [PrinterDevice] = active.contains(.network)
            ? NetworkPrinterStore.list().map { e -> PrinterDevice in
                let online = NetworkDiscovery.tcpReachable(host: e.host, port: Self.telemetryPort, timeoutMs: 600)
                return PrinterDevice(id: "net:\(e.host)", name: e.name, model: e.model,
                                     serial: e.host, status: online ? .ready : .offline, host: e.host)
              }
            : []
        let usb = active.contains(.usb) ? M611USB.enumerate() : []
        return net + usb
    }

    public func encode(label: RenderedLabel, status: CassetteStatus?,
                       cut: CutMode, isLastLabel: Bool) -> [UInt8] {
        // Rotation comes from the printer's reported Area Rotation when known;
        // 270 is the M6 die-cut default until Phase-3 telemetry fills it in.
        let rotation = status?.areaRotation ?? 270
        let m611Cut: M611Bitmap.CutMode
        switch cut {
        case .never:        m611Cut = .never
        case .eachLabel:    m611Cut = .eachLabel
        case .afterJobLast: m611Cut = .afterJobLast
        }
        return M611Bitmap.buildPrintJob(
            pixels: label.bytes, width: label.width, height: label.height,
            areaRotation: rotation, substratePart: label.partNumber,
            cut: m611Cut, isLastPage: isLastLabel)
    }

    public func open(_ device: PrinterDevice) throws -> PrinterConnection {
        // Network device → TCP socket to 9100; otherwise a USB-connected M611.
        if let host = device.host, !host.isEmpty {
            return TCPConnection(fd: try Self.connect(host: host, port: Self.printPort))
        }
        #if canImport(CLibUSB)
        return M611USBConnection(try M611USB.open(deviceID: device.id))
        #else
        throw NetError.noHost
        #endif
    }

    public func send(_ bytes: [UInt8], on connection: PrinterConnection) throws {
        if let c = connection as? TCPConnection { try Self.writeAll(fd: c.fd, bytes: bytes); return }
        #if canImport(CLibUSB)
        if let c = connection as? M611USBConnection { try M611USB.send(bytes, handle: c.handle); return }
        #endif
    }

    public func close(_ connection: PrinterConnection) {
        if let c = connection as? TCPConnection { Darwin.close(c.fd); return }
        #if canImport(CLibUSB)
        if let c = connection as? M611USBConnection { M611USB.close(c.handle); return }
        #endif
    }

    public func readStatus(_ device: PrinterDevice) -> CassetteStatus? {
        // Phase 3: PICL telemetry handshake (9102 / USB ep 0x03+0x84) → CassetteStatus.
        return nil
    }

    // MARK: – Synchronous TCP (runs on the per-printer serial queue, so blocking is fine)

    enum NetError: Error { case noHost, connectFailed, writeFailed }

    static func connect(host: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NetError.connectFailed }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd); throw NetError.connectFailed
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { Darwin.close(fd); throw NetError.connectFailed }
        return fd
    }

    static func writeAll(fd: Int32, bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        try bytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < bytes.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: off), bytes.count - off)
                if n <= 0 { throw NetError.writeFailed }
                off += n
            }
        }
    }
}
