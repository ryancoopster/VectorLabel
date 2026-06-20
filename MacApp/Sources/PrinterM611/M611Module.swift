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
        // Network telemetry (USB telemetry will ride M611USB.request once USB lands).
        // Issue a PICL PropertyGetRequest for supply / ribbon / battery / substrate and
        // parse the response into CassetteStatus. Runs on the per-printer device queue,
        // so a short blocking connect+read is fine.
        guard let host = device.host, !host.isEmpty else { return nil }
        let req = M611PICL.getRequest()
        guard !req.isEmpty else { return nil }
        // The PICL-over-TCP port is unconfirmed (Brady's SDK carries PICL over BLE), so
        // try the control port (9102) first, then the bidirectional print socket (9100).
        for port in [Self.telemetryPort, Self.printPort] {
            guard let fd = try? Self.connect(host: host, port: port) else { continue }
            defer { Darwin.close(fd) }
            guard (try? Self.writeAll(fd: fd, bytes: req)) != nil else { continue }
            let resp = Self.readResponse(fd: fd, timeoutMs: 1500)
            if resp.isEmpty { continue }
            if let map = M611PICL.parse(resp), let status = Self.cassetteStatus(from: map) {
                return status
            }
            // Got bytes but no plain-text JSON — likely an LZ4-framed response whose exact
            // framing isn't confirmed yet. Log a hex preview so we can decode it from a
            // real-hardware sample, then try the next port.
            let hex = resp.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")
            NSLog("[M611] PICL status on :\(port) → \(resp.count) bytes, no plain JSON (likely compressed). First 48: \(hex)")
        }
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

    /// Read a PICL response with a timeout (poll-based; the other socket helpers are
    /// write-only). Accumulates until the socket goes quiet or the deadline passes.
    static func readResponse(fd: Int32, timeoutMs: Int) -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(remaining * 1000)) > 0,
                  (pfd.revents & Int16(POLLIN)) != 0 else { break }
            let r = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if r <= 0 { break }   // EOF / error
            out += buf.prefix(r)
            if out.count > 24, out.last == UInt8(ascii: "}"), M611PICL.parse(out) != nil { break }
            if out.count > 1_000_000 { break }   // safety cap
        }
        return out
    }

    /// Map a parsed PICL property map into a `CassetteStatus`. Returns nil unless at
    /// least one real telemetry value was reported.
    static func cassetteStatus(from map: [String: String]) -> CassetteStatus? {
        func v(_ g: String, _ p: String) -> String? { map["\(g):\(p)"] }
        func i(_ g: String, _ p: String) -> Int? { v(g, p).flatMap { Int($0) } }
        // Dimensions: units unconfirmed (the SDK getters return inches). Treat a small
        // value as inches → mils, a large one as already-mils. Confirm on capture.
        func mils(_ g: String, _ p: String) -> Int {
            guard let s = v(g, p), let d = Double(s), d > 0 else { return 0 }
            return Int((d < 100 ? d * 1000 : d).rounded())
        }
        let part    = v(M611PICL.P.substrateGroup, M611PICL.P.partNumber) ?? ""
        let supply  = i(M611PICL.P.substrateGroup, M611PICL.P.supplyRemaining)
        let ribbon  = i(M611PICL.P.ribbonGroup,    M611PICL.P.ribbonRemaining)
        let battery = i(M611PICL.P.batteryGroup,   M611PICL.P.batteryCharge)
        guard supply != nil || ribbon != nil || battery != nil || !part.isEmpty else { return nil }

        let dpi = i(M611PICL.P.substrateGroup, M611PICL.P.dpi) ?? 300
        let w  = mils(M611PICL.P.substrateGroup, M611PICL.P.substrateWidth)
        let h  = mils(M611PICL.P.substrateGroup, M611PICL.P.substrateHeight)
        let pw = mils(M611PICL.P.substrateGroup, M611PICL.P.printableWidth)
        let ph = mils(M611PICL.P.substrateGroup, M611PICL.P.printableHeight)
        let dieCut = (v(M611PICL.P.substrateGroup, M611PICL.P.isDieCut) ?? "").lowercased() == "true"
        func px(_ m: Int) -> Int { Int((Double(m) / 1000.0 * Double(dpi)).rounded()) }
        return CassetteStatus(
            partNumber: part,
            labelWidthMils: w, labelHeightMils: h,
            printableWidthMils: pw > 0 ? pw : w, printableHeightMils: ph > 0 ? ph : h,
            isDieCut: dieCut,
            supplyRemainingPct: supply ?? 0,
            labelsPerRoll: BradyCatalog.labelsPerRoll(forPartNumber: part),
            pixelWidth: px(w), pixelHeight: px(h),
            areaRotation: nil,   // per-area group GUID needs the boot packet → encode keeps 270
            ribbonRemainingPct: ribbon,
            ribbonPartNumber: nil,
            batteryPct: battery
        )
    }
}
