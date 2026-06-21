import Foundation
import VectorLabelCore
#if canImport(Darwin)
import Darwin
#endif

/// Opaque connection token wrapping an open TCP socket to the printer's raw print
/// port (9100). The M611 prints by streaming the bitmap-job segments to this socket.
final class TCPConnection: PrinterConnection {
    let fd: Int32
    let host: String   // kept so a job can open a SEPARATE telemetry socket (9102) mid-print
    init(fd: Int32, host: String) { self.fd = fd; self.host = host }
}

/// The M611 printer module: bitmap/LZ4 encoder (`M611Bitmap`) + TCP transport
/// (print on 9100, telemetry on 9102). Network-only, Foundation-only (no libusb).
public final class M611Module: PrinterModule {
    public init() {}

    // Network + USB. USB transport (M611USB) targets printer-class interface 0, bulk
    // OUT 0x01 / IN 0x82, same bitmap framing as network — recovered from the ETW capture
    // + descriptors (high confidence; pending a live on-device print). Telemetry over USB
    // is still TODO (readStatus is network-only), so a USB-only M611 prints without live %s.
    public let capabilities = PrinterCapabilities(
        model: "M611", supportedTransports: [.network, .usb], hasLiveTelemetry: true,
        hasAutoCutter: true,                                  // M611 has a built-in cutter
        ribbonLengthInches: 75 * 12,                          // 75 ft ribbon
        // No hardware label counter + no printer-side cancel, so the user picks: single =
        // per-label progress + responsive cancel; full job = fastest, coarse, no cancel.
        sendMode: .selectable(defaultSingle: false))

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
                let name = Self.friendlyName(host: e.host, model: e.model) ?? e.name
                return PrinterDevice(id: "net:\(e.host)", name: name, model: e.model,
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
        return M611Bitmap.buildPrintJob(
            pixels: label.bytes, width: label.width, height: label.height,
            areaRotation: rotation, substratePart: label.partNumber,
            cut: mapCut(cut), isLastPage: isLastLabel)
    }

    /// Map the Core `CutMode` to the M611 bitmap encoder's cut enum.
    private func mapCut(_ cut: CutMode) -> M611Bitmap.CutMode {
        switch cut {
        case .never:        return .never
        case .eachLabel:    return .eachLabel
        case .afterJobLast: return .afterJobLast
        }
    }

    public func open(_ device: PrinterDevice) throws -> PrinterConnection {
        // Network device → TCP socket to 9100; otherwise a USB-connected M611.
        if let host = device.host, !host.isEmpty {
            return TCPConnection(fd: try Self.connect(host: host, port: Self.printPort), host: host)
        }
        #if canImport(CLibUSB)
        return M611USBConnection(try M611USB.open(deviceID: device.id), deviceID: device.id)
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

    // Per-label progress only when streaming one label at a time (no hardware counter);
    // a full-job batch is coarse ("Printing…").
    public func reportsCounter(singleLabel: Bool) -> Bool { singleLabel }

    /// Run a job, then BLOCK until the printer reports it has actually finished printing —
    /// PICL "External Job Status" == "Print Complete", matched by the job's UNIQUE ExternalId
    /// on the telemetry channel (separate from the print pipe, so it can be polled mid-print).
    /// This keeps the menu status accurate to the real print instead of a time estimate; a
    /// generous time cap is the only fallback if job telemetry is unavailable.
    ///
    /// Full job: ONE multi-page job (continuous feed, one end-of-job cut), coarse "Printing…".
    /// One at a time: a separate job per label (per-label counter + look-ahead pacing so the
    /// printer never idles); cancel stops the stream and the in-flight labels still print.
    public func run(_ job: DriverJob) throws {
        let conn = job.connection
        let count = job.pages.count
        let perLabelMs = max(150, job.estLabelMs)
        let host = (conn as? TCPConnection)?.host
        #if canImport(CLibUSB)
        let deviceID = (conn as? M611USBConnection)?.deviceID ?? ""
        #else
        let deviceID = ""
        #endif
        let rotation = job.status?.areaRotation ?? 270
        // Unique-per-run token so a status poll never matches a PRIOR job of the same id still
        // sitting "Print Complete" in the printer's slot ring (which would report done at once).
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased().prefix(24))

        if !job.singleLabel {
            // FULL JOB: ONE multi-page M611 job (NumberOfPages = N) → the printer prints it as a
            // single job (continuous feed, one end-of-job cut for die-cut), not N back-to-back
            // single-label jobs. No mid-job cancel (the firmware has none); coarse "Printing…".
            if job.isCancelled() { return }
            let jobID = "VL" + token + "PRNT"   // 30 chars, unique per run
            let mpages = job.pages.map { p in
                M611Bitmap.Page(pixels: p.label.bytes, width: p.label.width, height: p.label.height,
                                cut: mapCut(p.cut), isLast: p.isLast)
            }
            let part = job.pages.first?.label.partNumber ?? ""
            job.progress(.printing)
            try send(M611Bitmap.buildMultiPageJob(pages: mpages, areaRotation: rotation,
                                                  substratePart: part, jobID: jobID), on: conn)
            // Hold the menu on "Printing…" until the printer reports the job complete — send()
            // returns when the bytes arrive, but it then prints for several seconds.
            awaitJobComplete(externalId: jobID, host: host, deviceID: deviceID,
                             capMs: count * perLabelMs * 3 + 8000, tick: { job.progress(.printing) })
            job.progress(.done)
            return
        }

        // ONE AT A TIME: a separate job per label, and report the counter from the printer's
        // REAL per-label completion — the menu ticks up as each label's job reaches "Print
        // Complete", not on a clock. Sending is gated on confirmed completions so at most
        // `maxAhead` labels are unconfirmed-in-flight (responsive cancel, no printer idle). If
        // job telemetry turns out unavailable, it falls back to time pacing so all labels still
        // print and the counter still advances (best effort).
        let t0 = DispatchTime.now().uptimeNanoseconds
        func elapsedMs() -> Int { Int((DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000) }
        func printedEst() -> Int { elapsedMs() / perLabelMs }
        let ids = (0..<count).map { "VL" + token + String(format: "%04d", $0) }   // 30 chars each, unique
        let maxAhead = 3
        let capMs = count * perLabelMs * 3 + 8000      // safety net only (telemetry unavailable)
        var nextToSend = 0
        var completed = 0                              // labels confirmed printed (monotonic)
        var started = Set<Int>()                       // indices seen actively printing / complete
        var observed = Set<Int>()                      // indices seen in ANY slot state (incl. queued)
        var telemetryDead = false
        var firstSendMs = -1
        var lastPollMs = Int.min

        func sendLabel(_ i: Int) throws {
            let p = job.pages[i]
            try send(M611Bitmap.buildPrintJob(pixels: p.label.bytes, width: p.label.width,
                                              height: p.label.height, areaRotation: rotation,
                                              substratePart: p.label.partNumber,
                                              cut: mapCut(p.cut), isLastPage: p.isLast,
                                              jobID: ids[i]), on: conn)
        }

        while true {
            // SEND: keep at most maxAhead labels beyond the confirmed-printed frontier (the time
            // frontier when telemetry is dead) so a backlog never builds and cancel stays prompt.
            let pace = telemetryDead ? printedEst() : completed
            while nextToSend < count && !job.isCancelled() && (nextToSend - pace) < maxAhead {
                try sendLabel(nextToSend)
                if firstSendMs < 0 { firstSendMs = elapsedMs() }
                nextToSend += 1
                if job.interLabelDelayMs > 0 && nextToSend < count {
                    var slept = 0
                    while slept < job.interLabelDelayMs && !job.isCancelled() { usleep(20_000); slept += 20 }
                }
            }
            // POLL real per-label status (rate-limited) and advance the confirmed count.
            if elapsedMs() - lastPollMs >= 500 {
                lastPollMs = elapsedMs()
                if let map = M611PICL.parse(piclRoundTrip(M611PICL.jobStatusRequest(), host: host,
                                                          deviceID: deviceID, connectTimeoutMs: 1000)) {
                    completed = max(completed, M611PICL.completedCount(in: map, ids: ids,
                                                                      started: &started, observed: &observed))
                }
                // Sent labels but never saw ANY of our jobs (in any slot state) after a few
                // seconds → job telemetry isn't reporting; fall back to the time estimate.
                if !telemetryDead && firstSendMs >= 0 && observed.isEmpty
                    && elapsedMs() - firstSendMs > max(4000, perLabelMs * 2) {
                    telemetryDead = true
                    NSLog("[M611] job status not reported — single-label progress falls back to time estimate")
                }
            }
            // COUNTER: real completed when telemetry works, else the time estimate.
            let shown = telemetryDead ? min(nextToSend, printedEst()) : completed
            job.progress(.counter(done: min(count, max(0, shown)), of: count))
            // DONE when every label we committed to (all of them, or up to a cancel) has finished.
            let committed = nextToSend
            if job.isCancelled() || nextToSend >= count {
                if telemetryDead { if printedEst() >= committed { break } }
                else if completed >= committed { break }
            }
            if elapsedMs() >= capMs { break }
            usleep(60_000)
        }
        // Clean finish → fill the bar to 100% (the job is done even if the last label's slot
        // aged out before a poll caught it). Cancelled → leave the real partial count.
        if job.isCancelled() {
            let shown = telemetryDead ? min(nextToSend, printedEst()) : completed
            job.progress(.counter(done: min(count, max(0, shown)), of: count))
        } else {
            job.progress(.done)
        }
    }

    /// Block until the printer reports the job with this ExternalId has finished printing, or
    /// `capMs` elapses (the safety net for when job telemetry is unavailable). Polls the
    /// telemetry channel (TCP:9102 / USB vendor iface) — separate from the print pipe, so it's
    /// safe mid-print — and calls `tick` each poll so the caller can refresh progress.
    ///
    /// Completion is concluded ONLY from a SUCCESSFUL poll: either the slot reports complete,
    /// or (after we've seen the job at least once) it's absent from a valid response for a few
    /// consecutive polls (it aged out of the ring = finished). A failed/empty round-trip is
    /// "unknown" — it never advances completion, so a single telemetry hiccup can't end the
    /// wait early and close the connection while the printer is still printing.
    func awaitJobComplete(externalId: String, host: String?, deviceID: String,
                          capMs: Int, tick: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        var everFound = false
        var absentStreak = 0
        var loggedSlots = false
        while Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000) < capMs {
            // Bounded connect + read so a stalled telemetry port can't hang the device queue.
            let resp = piclRoundTrip(M611PICL.jobStatusRequest(), host: host, deviceID: deviceID,
                                     connectTimeoutMs: 1200)
            if let map = M611PICL.parse(resp) {            // successful round-trip
                let state = M611PICL.jobState(in: map, externalId: externalId)
                if state == .complete { return }           // finished — done
                if state == .printing || state == .pending { everFound = true; absentStreak = 0 }
                else if everFound {                        // .absent after being seen → aging out
                    absentStreak += 1
                    if absentStreak >= 3 { return }        // gone for 3 valid polls → finished
                } else if !loggedSlots {                   // never seen: help diagnose an id/slot mismatch
                    loggedSlots = true
                    let slots = Set(map.keys.compactMap {
                        $0.hasPrefix("Job ") ? String($0.prefix { $0 != ":" }) : nil })
                    if !slots.isEmpty { NSLog("[M611] job \(externalId) not found; live slots \(slots.sorted())") }
                }
            }
            // else: transient failure (empty/partial response) — leave completion state untouched
            // so a single telemetry hiccup never ends the wait early (cap is the only fallback).
            tick()
            usleep(700_000)
        }
    }

    public func readStatus(_ device: PrinterDevice) -> CassetteStatus? {
        // Issue a PICL PropertyGetRequest for supply / ribbon / battery / substrate and
        // parse the response into CassetteStatus. Runs on the per-printer device queue,
        // so a short blocking round-trip is fine.
        let resp = piclRoundTrip(M611PICL.getRequest(), host: device.host, deviceID: device.id)
        guard !resp.isEmpty else { return nil }
        if let map = M611PICL.parse(resp) { return Self.cassetteStatus(from: map) }
        // Bytes but no plain JSON (unexpected — confirmed plain on hardware). Log a hex
        // preview so any future firmware that compresses can be decoded from the sample.
        let hex = resp.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")
        NSLog("[M611] PICL status → \(resp.count) bytes, no plain JSON. First 48: \(hex)")
        return nil
    }

    /// Send a PICL request on the telemetry channel and return the raw response bytes (empty
    /// on failure). Network → TCP:9102 (CONFIRMED: 9102 resolves the FirmwareDriver/spooler
    /// components; 9100 is the print datastream and returns "Invalid Value"). USB → the VENDOR
    /// interface (iface 1, EP 0x03/0x84), the USB analog of 9102. Either way it's SEPARATE from
    /// the print pipe, so it's safe to poll during a print. Same envelope as a print segment
    /// but a different magic: `[16-byte magic][uint32-LE len][plain JSON]`.
    func piclRoundTrip(_ request: [UInt8], host: String?, deviceID: String,
                       connectTimeoutMs: Int = 4000) -> [UInt8] {
        guard !request.isEmpty else { return [] }
        if let host, !host.isEmpty {
            guard let fd = try? Self.connect(host: host, port: Self.telemetryPort,
                                             timeoutMs: connectTimeoutMs) else { return [] }
            defer { Darwin.close(fd) }
            guard (try? Self.writeAll(fd: fd, bytes: request)) != nil else { return [] }
            return Self.readResponse(fd: fd, timeoutMs: 1500)
        }
        #if canImport(CLibUSB)
        return M611USB.readTelemetry(deviceID: deviceID, request: request)
        #else
        return []
        #endif
    }

    // MARK: – Synchronous TCP (runs on the per-printer serial queue, so blocking is fine)

    enum NetError: Error { case noHost, connectFailed, writeFailed }

    /// Connect with a BOUNDED wait (non-blocking connect + poll), so a stalled printer port
    /// can never block the per-printer serial queue on the OS default (~75s) — important now
    /// that a print polls the telemetry port every ~700ms while the printer is busy. Also sets
    /// SO_NOSIGPIPE so a write to a peer-closed socket throws instead of killing the process.
    static func connect(host: String, port: UInt16, timeoutMs: Int = 4000) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NetError.connectFailed }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd); throw NetError.connectFailed
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { Darwin.close(fd); throw NetError.connectFailed }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeoutMs)) > 0, (pfd.revents & Int16(POLLOUT)) != 0 else {
                Darwin.close(fd); throw NetError.connectFailed
            }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            guard soErr == 0 else { Darwin.close(fd); throw NetError.connectFailed }
        }
        _ = fcntl(fd, F_SETFL, flags)   // restore blocking mode for writeAll / readResponse
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
            // Stop as soon as a complete PICL object has arrived. parse() brace-matches, so it
            // succeeds even if there are trailing bytes after the closing '}' — don't gate on
            // the last byte being '}', or a frame with trailing padding would stall the full
            // timeout on every poll (the job-status frame is ~64 properties).
            if out.count > 24, M611PICL.parse(out) != nil { break }
            if out.count > 1_000_000 { break }   // safety cap
        }
        return out
    }

    /// Map a parsed PICL property map into a `CassetteStatus`. Returns nil unless at
    /// least one real telemetry value was reported.
    static func cassetteStatus(from map: [String: String]) -> CassetteStatus? {
        func v(_ g: String, _ p: String) -> String? { map["\(g):\(p)"] }
        func i(_ g: String, _ p: String) -> Int? { v(g, p).flatMap { Int($0) } }
        func b(_ g: String, _ p: String) -> Bool? {
            switch (v(g, p) ?? "").lowercased() {
            case "true", "1", "yes":  return true
            case "false", "0", "no":  return false
            default:                  return nil
            }
        }
        // PICL reports substrate dimensions in thousandths of an inch (mils) — use as-is
        // (confirmed on hardware: a 1.5" label reports "1500").
        func mils(_ g: String, _ p: String) -> Int {
            guard let s = v(g, p), let d = Double(s), d > 0 else { return 0 }
            return Int(d.rounded())
        }
        let part    = v(M611PICL.P.substrateGroup, M611PICL.P.partNumber) ?? ""
        let supply  = i(M611PICL.P.substrateGroup, M611PICL.P.supplyRemaining)
        let ribbon  = i(M611PICL.P.ribbonGroup,    M611PICL.P.ribbonRemaining)
        let battery = i(M611PICL.P.batteryGroup,   M611PICL.P.batteryCharge)
        guard supply != nil || ribbon != nil || battery != nil || !part.isEmpty else { return nil }

        let dpi = 300   // M611 is fixed 300 dpi (a DPI property isn't exposed over PICL)
        let w  = mils(M611PICL.P.substrateGroup, M611PICL.P.substrateWidth)
        let h  = mils(M611PICL.P.substrateGroup, M611PICL.P.substrateHeight)
        let pw = mils(M611PICL.P.substrateGroup, M611PICL.P.printableWidth)
        let ph = mils(M611PICL.P.substrateGroup, M611PICL.P.printableHeight)
        let dieCut = b(M611PICL.P.substrateGroup, M611PICL.P.isDieCut) ?? false
        func px(_ m: Int) -> Int { Int((Double(m) / 1000.0 * Double(dpi)).rounded()) }
        return CassetteStatus(
            partNumber: part,
            labelWidthMils: w, labelHeightMils: h,
            printableWidthMils: pw > 0 ? pw : w, printableHeightMils: ph > 0 ? ph : h,
            isDieCut: dieCut,
            supplyRemainingPct: supply ?? 0,
            labelsPerRoll: BradyCatalog.labelsPerRoll(forPartNumber: part),
            pixelWidth: px(w), pixelHeight: px(h),
            areaRotation: i(M611PICL.P.areaGroup, M611PICL.P.areaRotation),  // real value from telemetry
            ribbonRemainingPct: ribbon,
            ribbonPartNumber: v(M611PICL.P.ribbonGroup, M611PICL.P.ribbonName),
            batteryPct: battery,
            printerSerial: v(M611PICL.P.printerGroup, M611PICL.P.serial),
            firmwareVersion: v(M611PICL.P.printerGroup, M611PICL.P.firmware),
            isContinuous: b(M611PICL.P.substrateGroup, M611PICL.P.isContinuous),
            acConnected: b(M611PICL.P.batteryGroup, M611PICL.P.acConnected),
            printheadOpen: b(M611PICL.P.errorGroup, M611PICL.P.printheadOpen),
            substrateInvalid: b(M611PICL.P.errorGroup, M611PICL.P.substrateInvalid),
            ribbonInvalid: b(M611PICL.P.errorGroup, M611PICL.P.ribbonInvalid),
            substrateYNumber: v(M611PICL.P.substrateGroup, M611PICL.P.yNumber)
        )
    }

    // MARK: – Friendly name (reverse-DNS hostname)

    /// A network printer's friendly name, from its reverse-DNS hostname. The printer
    /// registers a DHCP hostname like "m611-ryanm611" (`<model>-<name>`, lowercased) —
    /// the BLE friendly name itself isn't exposed over TCP, so this hostname (with the
    /// leading "<model>-" stripped) is the best network-available name. nil when the
    /// host has no reverse-DNS record (caller falls back to the stored name).
    static func friendlyName(host: String, model: String) -> String? {
        guard let h = reverseDNSHostname(host) else { return nil }
        let prefix = "\(model)-".lowercased()
        let stripped = h.lowercased().hasPrefix(prefix) ? String(h.dropFirst(prefix.count)) : h
        return stripped.isEmpty ? nil : stripped
    }

    private static let rdnsLock = NSLock()
    private static var rdnsCache: [String: String] = [:]   // host → hostname label ("" = none)
    private static func reverseDNSHostname(_ host: String) -> String? {
        rdnsLock.lock()
        if let c = rdnsCache[host] { rdnsLock.unlock(); return c.isEmpty ? nil : c }
        rdnsLock.unlock()
        let resolved = resolveReverseDNS(host) ?? ""
        rdnsLock.lock(); rdnsCache[host] = resolved; rdnsLock.unlock()
        return resolved.isEmpty ? nil : resolved
    }
    private static func resolveReverseDNS(_ host: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        var nameBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                getnameinfo(sp, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &nameBuf, socklen_t(nameBuf.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        // First label only: "m611-ryanm611.lan" → "m611-ryanm611".
        return String(cString: nameBuf).split(separator: ".").first.map(String.init)
    }
}
