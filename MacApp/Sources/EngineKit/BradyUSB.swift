import Foundation
import VectorLabelCore
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
/// M610 PID 0x010B is confirmed on hardware.
///
/// M611 (Phase 6): the M611 USB product id is NOT yet hardware-confirmed. We list
/// 0x010C as a best guess so a known M611 maps to "M611", but to avoid missing a
/// real M611 whose PID differs, enumeration ALSO accepts ANY device on the Brady
/// VID (0x0E2E) and labels an unrecognised PID generically (see `modelFor`). This
/// is conservative: an unknown Brady device is still surfaced as a printer rather
/// than silently skipped.
/// TODO: confirm the M611 PID on real hardware (plug in an M611, read
/// `lsusb`/`system_profiler SPUSBDataType`, note its idProduct), then either fix
/// the 0x010C entry or add the real PID to `knownModels` and tighten enumeration
/// back to the known list if the generic fallback proves too broad.
public enum BradyUSB {

    static let vendorID: UInt16 = 0x0E2E
    static let knownModels: [(pid: UInt16, model: String)] = [
        (0x010B, "M610"),
        (0x010C, "M611"),   // UNVERIFIED PID — see header TODO
    ]

    /// Map a Brady-VID product id to a model name. Known PIDs map exactly; any
    /// other PID on the Brady VID falls back to a generic name so a connected
    /// Brady printer with an unconfirmed PID (e.g. an M611 whose id differs from
    /// our guess) is still detected and usable. Unknown → "M611" as the most
    /// likely current Brady wire-label printer, with the PID appended so the
    /// operator can report it for the TODO above.
    static func modelFor(productID: UInt16) -> String {
        // Prefer the user-editable registry (Preferences ▸ Printers ▸ Printer Models),
        // so registering a model + PID makes a connected printer report that name.
        if let m = PrinterModelStore.modelName(forProductID: String(format: "%04X", productID)) { return m }
        if let m = knownModels.first(where: { $0.pid == productID })?.model { return m }
        // Best-effort default for an unrecognised Brady device. We keep it as a
        // valid model string ("M611") so status/UI stay happy, and the generic
        // name is only used internally for the device "name".
        return "M611"
    }
#if canImport(CLibUSB)
    /// True if this Brady-VID device is an actual label printer that we should
    /// list / claim. A device qualifies if its PID is a known printer PID, OR it
    /// presents a USB printer-class interface (bInterfaceClass == 0x07) in its
    /// active config. This stops us from detaching/claiming non-printer Brady
    /// peripherals (which the old VID-only match would touch every 5 s).
    static func deviceIsPrinter(_ dev: OpaquePointer, desc: libusb_device_descriptor) -> Bool {
        // Known printer PID → definitely a printer (cheap, no descriptor read).
        if knownModels.contains(where: { $0.pid == desc.idProduct }) { return true }

        // Otherwise inspect the active configuration for a printer-class interface.
        var configPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(dev, &configPtr) == 0,
              let config = configPtr else { return false }
        defer { libusb_free_config_descriptor(config) }

        let cfg = config.pointee
        guard let interfaces = cfg.interface else { return false }
        for i in 0 ..< Int(cfg.bNumInterfaces) {
            let iface = interfaces[i]
            guard let altsettings = iface.altsetting else { continue }
            for a in 0 ..< Int(iface.num_altsetting) {
                if altsettings[a].bInterfaceClass == LIBUSB_CLASS_PRINTER.rawValue {
                    return true
                }
            }
        }
        return false
    }
#endif

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
    private static var deviceQueues: [String: DispatchQueue] = [:]
    /// One serial queue per printer. Serializes all device access to that printer
    /// (prints and cassette reads run one at a time) while different printers run
    /// concurrently — replacing the old DispatchSemaphore. Crucially this is a
    /// dedicated GCD queue, so the long blocking USB work + pacing sleeps no longer
    /// park threads in Swift's cooperative pool.
    static func deviceQueue(for id: String) -> DispatchQueue {
        locksLock.lock(); defer { locksLock.unlock() }
        if let q = deviceQueues[id] { return q }
        let q = DispatchQueue(label: "vectorlabel.printer.\(id)", qos: .utility)
        deviceQueues[id] = q
        return q
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

        for i in 0 ..< count {
            guard let dev = devices[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            // Brady VID, AND it must actually be a printer: a known printer PID,
            // or a device presenting a USB printer-class interface. A non-printer
            // Brady peripheral on the same VID is skipped (no longer surfaced or
            // — critically — claimed). A real M611 with an unconfirmed PID is still
            // found because it presents a printer-class interface.
            guard desc.idVendor == vendorID else { continue }
            guard deviceIsPrinter(dev, desc: desc) else { continue }

            let model = modelFor(productID: desc.idProduct)
            let isKnownPID = knownModels.contains { $0.pid == desc.idProduct }
            // For a known PID the name is just "Brady M610"/"Brady M611"; for an
            // unrecognised Brady device, include the hex PID so the operator can
            // report it (see the M611-PID TODO in the type header).
            let name  = isKnownPID
                ? "Brady \(model)"
                : "Brady \(model) (PID 0x\(String(desc.idProduct, radix: 16, uppercase: true)))"

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

        for i in 0 ..< count {
            guard let dev = devices[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            // Match enumeration: only an actual printer (known PID or printer-class
            // interface) is a candidate. This guard runs BEFORE libusb_open /
            // detach_kernel_driver / claim_interface, so a non-printer Brady device
            // is never touched even if its composite id were somehow requested.
            guard desc.idVendor == vendorID else { continue }
            guard deviceIsPrinter(dev, desc: desc) else { continue }

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
    public struct SmartCellInfo: Hashable {
        public let partNumber: String          // e.g. "M6-32-427"
        public let ribbonCode: String          // e.g. "R4310"
        public let labelWidthMils: Int         // thousandths of an inch
        public let labelHeightMils: Int
        public let printableWidthMils: Int
        public let linerWidthMils: Int
        public let isDieCut: Bool
        public let partsAcross: Int
        public let horizontalGapMils: Int
        public let verticalGapMils: Int
        public let supplyRemainingPct: Int

        /// Render pixel dimensions at 300 DPI (mils / 1000 * 300).
        public var pixelWidth: Int  { Int((Double(labelWidthMils) / 1000.0 * 300.0).rounded()) }
        public var pixelHeight: Int { Int((Double(labelHeightMils) / 1000.0 * 300.0).rounded()) }
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
