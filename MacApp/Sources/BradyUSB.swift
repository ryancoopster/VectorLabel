import Foundation
#if canImport(CLibUSB)
import CLibUSB
#endif

// MARK: – Device model

struct BradyUSBDevice: Identifiable, Hashable {
    let id: String          // "vendorID:productID:serialNumber"
    let name: String
    let model: String
    let serial: String
    var status: PrinterDevice.Status = .ready
}

// MARK: – BradyUSB

/// USB transport for Brady M610/M611 label printers.
///
/// Requires libusb: `brew install libusb`
/// Add a CLibUSB system library target in Package.swift (see module.modulemap).
///
/// VID 0x0E2E is confirmed for all Brady USB devices.
/// M610 PID 0x010B and M611 PID 0x010C are both confirmed on hardware.
enum BradyUSB {

    static let vendorID: UInt16 = 0x0E2E
    static let knownModels: [(pid: UInt16, model: String)] = [
        (0x010B, "M610"),
        (0x010C, "M611"),
    ]
    static let outEndpoint: UInt8  = 0x01   // bulk OUT — print data and queries
    static let inEndpoint: UInt8   = 0x82   // bulk IN — SmartCell responses
    static let chunkSize           = 512
    static let chunkTimeoutMs: UInt32 = 10_000

    /// Per-printer mutex. The M610 allows only one owner of a given device at a
    /// time (`LIBUSB_ERROR_ACCESS` otherwise), but *different* printers are
    /// independent — so locking per device id lets multiple printers print
    /// simultaneously while serializing jobs (and SmartCell polling) to the same
    /// printer. A semaphore (not NSLock) because the print task `await`s while
    /// holding it and may resume on a different thread.
    private static let locksLock = NSLock()
    private static var deviceLocks: [String: DispatchSemaphore] = [:]
    static func deviceLock(for id: String) -> DispatchSemaphore {
        locksLock.lock(); defer { locksLock.unlock() }
        if let s = deviceLocks[id] { return s }
        let s = DispatchSemaphore(value: 1)
        deviceLocks[id] = s
        return s
    }

    enum USBError: Error, LocalizedError {
        case initFailed
        case deviceNotFound(String)
        case openFailed
        case claimFailed
        case transferFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .initFailed:            return "libusb initialisation failed"
            case .deviceNotFound(let s): return "Brady printer not found: \(s)"
            case .openFailed:            return "Could not open printer (permissions?)"
            case .claimFailed:           return "Could not claim USB interface"
            case .transferFailed(let c): return "USB transfer error \(c)"
            }
        }
    }

    // MARK: – Enumeration

    /// Returns all connected Brady printers.
    static func enumeratePrinters() -> [PrinterDevice] {
        var results: [PrinterDevice] = []
        #if canImport(CLibUSB)
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0, let context = ctx else { return [] }
        defer { libusb_exit(context) }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        defer { libusb_free_device_list(list, 1) }
        guard count > 0, let devices = list else { return [] }

        let validPIDs = knownModels.map { $0.pid }

        for i in 0 ..< count {
            guard let dev = devices[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            guard desc.idVendor == vendorID, validPIDs.contains(desc.idProduct) else { continue }

            let model = knownModels.first { $0.pid == desc.idProduct }?.model ?? "M6xx"
            let name  = "Brady \(model)"

            // Try to read serial number
            var serial = "\(desc.idProduct, radix: 16, uppercase: true)"
            var handle: OpaquePointer?
            if libusb_open(dev, &handle) == 0, let h = handle {
                if desc.iSerialNumber != 0 {
                    var buf = [UInt8](repeating: 0, count: 64)
                    let n = libusb_get_string_descriptor_ascii(h, desc.iSerialNumber, &buf, 64)
                    if n > 0 { serial = String(bytes: buf.prefix(Int(n)), encoding: .ascii) ?? serial }
                }
                libusb_close(h)
            }

            let id = "\(String(desc.idVendor, radix: 16)):\(String(desc.idProduct, radix: 16)):\(serial)"
            results.append(PrinterDevice(id: id, name: name, model: model, serial: serial, status: .ready))
        }
        #endif
        return results
    }

    // MARK: – Open / close

    /// Open a specific printer by its composite ID.
    static func openPrinterByID(_ deviceID: String) throws -> OpaquePointer {
        #if canImport(CLibUSB)
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0, let context = ctx else { throw USBError.initFailed }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        defer { libusb_free_device_list(list, 1) }

        guard count > 0, let devices = list else {
            libusb_exit(context)
            throw USBError.deviceNotFound(deviceID)
        }

        let validPIDs = knownModels.map { $0.pid }

        for i in 0 ..< count {
            guard let dev = devices[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            guard desc.idVendor == vendorID, validPIDs.contains(desc.idProduct) else { continue }

            var handle: OpaquePointer?
            guard libusb_open(dev, &handle) == 0, let h = handle else { throw USBError.openFailed }

            // Check serial to match deviceID if possible
            var serial = ""
            if desc.iSerialNumber != 0 {
                var buf = [UInt8](repeating: 0, count: 64)
                let n = libusb_get_string_descriptor_ascii(h, desc.iSerialNumber, &buf, 64)
                if n > 0 { serial = String(bytes: buf.prefix(Int(n)), encoding: .ascii) ?? "" }
            }
            let id = "\(String(desc.idVendor, radix: 16)):\(String(desc.idProduct, radix: 16)):\(serial)"
            if !deviceID.isEmpty && id != deviceID {
                libusb_close(h); continue
            }

            _ = libusb_detach_kernel_driver(h, 0)   // detach CUPS if attached
            guard libusb_claim_interface(h, 0) == 0 else {
                libusb_close(h); throw USBError.claimFailed
            }
            return h
        }

        libusb_exit(context)
        throw USBError.deviceNotFound(deviceID)
        #else
        throw USBError.initFailed
        #endif
    }

    static func close(_ handle: OpaquePointer) {
        #if canImport(CLibUSB)
        libusb_release_interface(handle, 0)
        libusb_close(handle)
        #endif
    }

    // MARK: – Send

    /// Send one VGL job to an already-opened printer handle.
    static func sendJob(_ job: [UInt8], handle: OpaquePointer) throws {
        #if canImport(CLibUSB)
        var data = job
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            var transferred: Int32 = 0
            let rc = data.withUnsafeMutableBufferPointer { buf -> Int32 in
                libusb_bulk_transfer(
                    handle, outEndpoint,
                    buf.baseAddress?.advanced(by: offset),
                    Int32(end - offset),
                    &transferred, chunkTimeoutMs
                )
            }
            guard rc == 0 else { throw USBError.transferFailed(rc) }
            offset = end
        }
        #endif
    }

    /// Best-effort wait for the printer to finish physically printing the label
    /// whose job was just sent. The printer processes its command stream serially,
    /// so a status query (ESC I) issued right after a complete job is not answered
    /// until that job has finished printing — making "the printer replied" a proxy
    /// for "the label is done." Returns true if the printer replied within `maxMs`,
    /// false on timeout (or when no bidirectional channel is available).
    ///
    /// Safety: bounded by `maxMs` so it can never hang a job; only ever called
    /// BETWEEN complete jobs, so it can't corrupt an in-progress label. Caller must
    /// hold the device lock.
    static func waitForLabelDone(handle: OpaquePointer, maxMs: Int) -> Bool {
        #if canImport(CLibUSB)
        var query: [UInt8] = [0x1B, 0x49, 0x00]   // ESC I — info/status request
        var readBuf = [UInt8](repeating: 0, count: 256)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0, maxMs)) &* 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var sent: Int32 = 0
            _ = query.withUnsafeMutableBufferPointer { buf in
                libusb_bulk_transfer(handle, outEndpoint, buf.baseAddress, Int32(buf.count), &sent, 400)
            }
            var got: Int32 = 0
            let rrc = readBuf.withUnsafeMutableBufferPointer { buf in
                libusb_bulk_transfer(handle, inEndpoint, buf.baseAddress, Int32(buf.count), &got, 400)
            }
            if rrc == 0 && got > 0 { return true }   // printer answered → prior job has printed
            usleep(40_000)                           // 40 ms between polls
        }
        return false
        #else
        return false
        #endif
    }

    // MARK: – SmartCell cassette detection (§8)

    /// Decoded contents of a Brady cassette's SmartCell chip.
    struct SmartCellInfo: Hashable {
        let partNumber: String          // e.g. "M6-32-427"
        let ribbonCode: String          // e.g. "R4310"
        let labelWidthMils: Int         // thousandths of an inch
        let labelHeightMils: Int
        let printableWidthMils: Int
        let linerWidthMils: Int
        let isDieCut: Bool
        let partsAcross: Int
        let horizontalGapMils: Int
        let verticalGapMils: Int
        let supplyRemainingPct: Int

        /// Render pixel dimensions at 300 DPI (mils / 1000 * 300).
        var pixelWidth: Int  { Int((Double(labelWidthMils) / 1000.0 * 300.0).rounded()) }
        var pixelHeight: Int { Int((Double(labelHeightMils) / 1000.0 * 300.0).rounded()) }
    }

    /// Query the loaded cassette's SmartCell on an already-claimed handle.
    ///
    /// The bidirectional channel needs priming: the first ~16 write-then-read
    /// attempts time out before the controller starts answering (§8). We retry up
    /// to `maxAttempts` (typically succeeds around attempt 16). Returns nil if the
    /// cassette never answers. Caller must hold `deviceLock`.
    static func querySmartCell(handle: OpaquePointer, maxAttempts: Int = 25) -> SmartCellInfo? {
        #if canImport(CLibUSB)
        var query: [UInt8] = [0x1B, 0x49, 0x00]  // ESC I <any>
        var readBuf = [UInt8](repeating: 0, count: 512)

        for _ in 0 ..< maxAttempts {
            // Write the query to EP1 OUT.
            var transferred: Int32 = 0
            _ = query.withUnsafeMutableBufferPointer { buf in
                libusb_bulk_transfer(handle, outEndpoint, buf.baseAddress,
                                     Int32(buf.count), &transferred, 1_000)
            }
            usleep(50_000)  // 50 ms

            // Read the response from EP2 IN with a short timeout.
            var readCount: Int32 = 0
            let rc = readBuf.withUnsafeMutableBufferPointer { buf in
                libusb_bulk_transfer(handle, inEndpoint, buf.baseAddress,
                                     Int32(buf.count), &readCount, 500)
            }
            if rc == 0, readCount >= 108 {
                let raw = Array(readBuf.prefix(Int(readCount)))
                let parsed = parseSmartCell(raw)
                // Temporary diagnostics → /tmp/vectorlabel-smartcell.log (flushed).
                let hex = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
                debugLog("OK \(raw.count) bytes  part=\(parsed?.partNumber ?? "?")  ribbon=\(parsed?.ribbonCode ?? "?")  supply=\(parsed?.supplyRemainingPct ?? -1)%  label=\(parsed?.labelWidthMils ?? -1)x\(parsed?.labelHeightMils ?? -1)mil\n      raw: \(hex)")
                return parsed
            }
        }
        debugLog("read FAILED after \(maxAttempts) attempts (no ≥108-byte response)")
        return nil
        #else
        return nil
        #endif
    }

    /// Temporary diagnostic logger — appends a flushed line to a dedicated file
    /// so SmartCell reads are visible even when stdout is block-buffered.
    static func debugLog(_ msg: String) {
        let line = "[SmartCell] \(msg)\n"
        let url = URL(fileURLWithPath: "/tmp/vectorlabel-smartcell.log")
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Parse a SmartCell response (all integers little-endian, §8).
    ///
    /// IMPORTANT: BOTH the part number and the ribbon code are variable-length
    /// NUL-terminated strings (not fixed-width fields). A longer part number
    /// (e.g. "BM-109-427", 10 chars) or ribbon code (e.g. "R10010-WT") pushes
    /// every later field forward. So we parse the part number from 0x06, then
    /// the ribbon code immediately after its terminator, and locate the data/
    /// dimension block 13 bytes past the ribbon-code terminator.
    static func parseSmartCell(_ data: [UInt8]) -> SmartCellInfo? {
        guard data.count >= 0x16 else { return nil }
        func u16(_ off: Int) -> Int {
            (off >= 0 && off + 1 < data.count) ? Int(data[off]) | (Int(data[off + 1]) << 8) : 0
        }
        /// NUL-terminated ASCII starting at `start`; returns the string and the
        /// index of its terminator (or the scan limit).
        func cstr(_ start: Int, _ maxLen: Int) -> (String, Int) {
            var end = start
            while end < data.count, end < start + maxLen, data[end] != 0 { end += 1 }
            return (String(bytes: data[start..<end], encoding: .ascii) ?? "", end)
        }

        let (partNumber, partNul)   = cstr(0x06, 16)            // variable length
        let (ribbonCode, ribbonNul) = cstr(partNul + 1, 32)     // right after the part number

        // Field block begins 13 bytes past the ribbon-code terminator.
        let fb = ribbonNul + 13
        guard fb + 0x20 + 1 < data.count else { return nil }

        return SmartCellInfo(
            partNumber:         partNumber,
            ribbonCode:         ribbonCode,
            labelWidthMils:     u16(fb + 0x14),
            labelHeightMils:    u16(fb + 0x16),
            printableWidthMils: u16(fb + 0x18),
            linerWidthMils:     u16(fb + 0x0C),
            isDieCut:           u16(fb + 0x10) == 1,
            partsAcross:        u16(fb + 0x20),
            horizontalGapMils:  u16(fb + 0x00),
            verticalGapMils:    u16(fb + 0x02),
            supplyRemainingPct: u16(fb + 0x04)
        )
    }
}

// Helper for hex formatting
private extension String.StringInterpolation {
    mutating func appendInterpolation<T: BinaryInteger>(_ value: T, radix: Int, uppercase: Bool = false) {
        appendLiteral(String(value, radix: radix, uppercase: uppercase))
    }
}
