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
/// M610 PID 0x010B is confirmed. M611 PID should be verified on first connect;
/// set m611ProductIDOverride in AppSettings if it differs from 0x010C.
enum BradyUSB {

    static let vendorID: UInt16 = 0x0E2E
    static let knownModels: [(pid: UInt16, model: String)] = [
        (0x010B, "M610"),
        (0x010C, "M611"),   // assumed — verify and override in Preferences if wrong
    ]
    static let outEndpoint: UInt8  = 0x01
    static let chunkSize           = 512
    static let chunkTimeoutMs: UInt32 = 10_000

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

        // Check for PID override
        var validPIDs = knownModels.map { $0.pid }
        if let override = UInt16(AppSettings.shared.m611ProductIDOverride, radix: 16),
           override != 0, !validPIDs.contains(override) {
            validPIDs.append(override)
        }

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

        var validPIDs = knownModels.map { $0.pid }
        if let override = UInt16(AppSettings.shared.m611ProductIDOverride, radix: 16),
           override != 0, !validPIDs.contains(override) {
            validPIDs.append(override)
        }

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
}

// Helper for hex formatting
private extension String.StringInterpolation {
    mutating func appendInterpolation<T: BinaryInteger>(_ value: T, radix: Int, uppercase: Bool = false) {
        appendLiteral(String(value, radix: radix, uppercase: uppercase))
    }
}
