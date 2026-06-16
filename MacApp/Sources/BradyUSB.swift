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
                return parseSmartCell(Array(readBuf.prefix(Int(readCount))))
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Like `querySmartCell` but returns the raw bytes of the first successful
    /// response (≥108 bytes) for diagnostics — so we can compare byte values
    /// against the printer's own front-panel readings (supply %, ribbon
    /// remaining) and identify undocumented fields. Caller must hold deviceLock.
    static func querySmartCellRaw(handle: OpaquePointer, maxAttempts: Int = 25) -> [UInt8]? {
        #if canImport(CLibUSB)
        var query: [UInt8] = [0x1B, 0x49, 0x00]
        var readBuf = [UInt8](repeating: 0, count: 512)
        for _ in 0 ..< maxAttempts {
            var transferred: Int32 = 0
            _ = query.withUnsafeMutableBufferPointer { buf in
                libusb_bulk_transfer(handle, outEndpoint, buf.baseAddress,
                                     Int32(buf.count), &transferred, 1_000)
            }
            usleep(50_000)
            var readCount: Int32 = 0
            let rc = readBuf.withUnsafeMutableBufferPointer { buf in
                libusb_bulk_transfer(handle, inEndpoint, buf.baseAddress,
                                     Int32(buf.count), &readCount, 500)
            }
            if rc == 0, readCount >= 108 {
                return Array(readBuf.prefix(Int(readCount)))
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Format a raw SmartCell response as an annotated hex dump for the log —
    /// offset column, hex bytes, and the values at each documented field so an
    /// undocumented byte (e.g. ribbon remaining) can be spotted by comparison.
    static func describeRaw(_ data: [UInt8]) -> String {
        func u16(_ o: Int) -> Int { o + 1 < data.count ? Int(data[o]) | (Int(data[o+1]) << 8) : -1 }
        var out = "SmartCell raw dump (\(data.count) bytes):\n"
        var i = 0
        while i < data.count {
            let row = data[i..<min(i+16, data.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            out += String(format: "0x%02X: %@\n", i, hex)
            i += 16
        }
        out += "Decoded fields:\n"
        out += "  0x22 horizontalGap = \(u16(0x22))\n"
        out += "  0x24 verticalGap   = \(u16(0x24))\n"
        out += "  0x26 supply %%      = \(u16(0x26))\n"
        out += "  0x2E linerWidth    = \(u16(0x2E))\n"
        out += "  0x36 labelWidth    = \(u16(0x36))\n"
        out += "  0x38 labelHeight   = \(u16(0x38))\n"
        out += "  0x3A printableW    = \(u16(0x3A))\n"
        // Candidate ribbon-remaining bytes: any u16 in 0..100 not already mapped.
        out += "  Bytes that look like a 0-100 percentage (candidate ribbon %):\n"
        for off in stride(from: 0, to: data.count - 1, by: 2) {
            let v = u16(off)
            if (0...100).contains(v) && ![0x22,0x24,0x26].contains(off) {
                out += String(format: "    0x%02X = %d\n", off, v)
            }
        }
        return out
    }

    /// Parse the 108-byte SmartCell response (all integers little-endian, §8).
    static func parseSmartCell(_ data: [UInt8]) -> SmartCellInfo? {
        guard data.count >= 108 else { return nil }
        func u16(_ off: Int) -> Int { Int(data[off]) | (Int(data[off + 1]) << 8) }
        func ascii(_ off: Int, _ maxLen: Int) -> String {
            var end = off
            while end < off + maxLen, end < data.count, data[end] != 0 { end += 1 }
            return String(bytes: data[off..<end], encoding: .ascii) ?? ""
        }
        return SmartCellInfo(
            partNumber:         ascii(0x06, 10),
            ribbonCode:         ascii(0x10, 6),
            labelWidthMils:     u16(0x36),
            labelHeightMils:    u16(0x38),
            printableWidthMils: u16(0x3A),
            linerWidthMils:     u16(0x2E),
            isDieCut:           u16(0x32) == 1,
            partsAcross:        u16(0x42),
            horizontalGapMils:  u16(0x22),
            verticalGapMils:    u16(0x24),
            supplyRemainingPct: u16(0x26)
        )
    }
}

// Helper for hex formatting
private extension String.StringInterpolation {
    mutating func appendInterpolation<T: BinaryInteger>(_ value: T, radix: Int, uppercase: Bool = false) {
        appendLiteral(String(value, radix: radix, uppercase: uppercase))
    }
}
