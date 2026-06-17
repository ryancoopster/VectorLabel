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

    #if canImport(CLibUSB)
    /// One libusb context for the whole app lifetime (freed implicitly at process
    /// exit). Reusing a single context avoids leaking a context — each with its own
    /// event thread/fd set — on every printer open, which previously happened on the
    /// success and claim/open-failure paths of `openPrinterByID` (every print,
    /// calibration, and cassette read). Lazy `static let` init is thread-safe.
    static let sharedContext: OpaquePointer? = {
        var c: OpaquePointer?
        return libusb_init(&c) == 0 ? c : nil
    }()
    #endif

    /// Returns all connected Brady printers.
    static func enumeratePrinters() -> [PrinterDevice] {
        var results: [PrinterDevice] = []
        #if canImport(CLibUSB)
        guard let context = sharedContext else { return [] }

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
        guard let context = sharedContext else { throw USBError.initFailed }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        defer { libusb_free_device_list(list, 1) }

        guard count > 0, let devices = list else {
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

    /// Read the cassette's "labels remaining" counter, which decrements by the
    /// job's label count when a print physically completes — a reliable "done"
    /// signal over the USB back-channel. Returns -1 if unavailable. Located relative
    /// to the variable-length field block (fb), like parseSmartCell. Hold device lock.
    static func labelsRemaining(handle: OpaquePointer) -> Int {
        #if canImport(CLibUSB)
        var query: [UInt8] = [0x1B, 0x49, 0x00]
        var readBuf = [UInt8](repeating: 0, count: 256)
        for _ in 0 ..< 4 {
            var sent: Int32 = 0
            _ = query.withUnsafeMutableBufferPointer { buf in
                libusb_bulk_transfer(handle, outEndpoint, buf.baseAddress, Int32(buf.count), &sent, 300)
            }
            var got: Int32 = 0
            let rrc = readBuf.withUnsafeMutableBufferPointer { buf in
                libusb_bulk_transfer(handle, inEndpoint, buf.baseAddress, Int32(buf.count), &got, 300)
            }
            if rrc == 0 && got >= 0x16 {
                let data = Array(readBuf.prefix(Int(got)))
                func nulFrom(_ start: Int, _ maxLen: Int) -> Int {
                    var e = start
                    while e < data.count, e < start + maxLen, data[e] != 0 { e += 1 }
                    return e
                }
                let partNul = nulFrom(0x06, 16)
                let ribbonNul = nulFrom(partNul + 1, 32)
                let off = ribbonNul + 13 + 0x37   // labels-remaining counter (16-bit LE)
                if off + 1 < data.count { return Int(data[off]) | (Int(data[off + 1]) << 8) }
            }
            usleep(30_000)
        }
        return -1
        #else
        return -1
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
