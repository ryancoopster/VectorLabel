import Foundation
import VectorLabelCore
#if canImport(CLibUSB)
import CLibUSB
#endif

#if canImport(CLibUSB)
/// Opaque connection token for an open Brother PT device: the libusb handle plus
/// the bulk endpoints discovered by DIRECTION (never hardcoded numbers).
final class BrotherConnection: PrinterConnection {
    let handle: OpaquePointer
    let epOut: UInt8
    let epIn: UInt8
    init(handle: OpaquePointer, epOut: UInt8, epIn: UInt8) {
        self.handle = handle; self.epOut = epOut; self.epIn = epIn
    }
}
#endif

/// USB transport for Brother PT label printers (VID 0x04F9). Mirrors the
/// hardware-validated Python `pt_usb.py`:
///   - claim interface 0, detaching the macOS `AppleUSBPrinter` kext;
///   - pick the bulk OUT/IN endpoints by direction, not by number;
///   - write in **64-byte** chunks (Brother's size; the Brady M610/M611 use 512);
///   - long (30 s) write timeout — multi-page half-cut jobs pause to print + score
///     each page, filling the USB buffer and blocking the bulk write;
///   - on close, do NOT reattach the kernel driver (it can wedge the status channel).
enum BrotherUSB {
    static let vendorID: UInt16 = 0x04F9
    static let chunk = 64
    static let writeTimeoutMs: UInt32 = 30_000
    static let statusTimeoutMs: UInt32 = 5_000

    #if canImport(CLibUSB)
    /// One libusb context for the Brother transport (separate from the Brady ones).
    static let ctx: OpaquePointer? = { var c: OpaquePointer?; return libusb_init(&c) == 0 ? c : nil }()

    enum USBError: Error { case noContext, notFound, openFailed, claimFailed, noEndpoints, transferFailed(Int32) }

    /// Connected Brother PT printers of the given supported-PID set, as PrinterDevices
    /// (id "usb:<vid>:<pid>:<serial>", model from the PID table).
    static func enumerate(supportedPIDs: [UInt16: String]) -> [PrinterDevice] {
        guard let ctx else { return [] }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        defer { libusb_free_device_list(list, 1) }
        guard n > 0, let devs = list else { return [] }
        var out: [PrinterDevice] = []
        for i in 0 ..< n {
            guard let dev = devs[Int(i)] else { continue }
            var d = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &d) == 0,
                  d.idVendor == vendorID, let model = supportedPIDs[d.idProduct] else { continue }
            let serial = readSerial(dev, desc: d)
            let id = "usb:\(String(format: "%04x", d.idVendor)):\(String(format: "%04x", d.idProduct)):\(serial)"
            out.append(PrinterDevice(id: id, name: "Brother \(model)", model: model,
                                     serial: serial, status: .ready, host: nil))
        }
        return out
    }

    /// Open the Brother matching `deviceID`, detaching the kernel driver and claiming
    /// interface 0; locates the bulk OUT/IN endpoints by direction.
    static func open(deviceID: String, supportedPIDs: [UInt16: String]) throws -> BrotherConnection {
        guard let ctx else { throw USBError.noContext }
        let wantSerial = serialComponent(of: deviceID)
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        defer { libusb_free_device_list(list, 1) }
        guard n > 0, let devs = list else { throw USBError.notFound }
        for i in 0 ..< n {
            guard let dev = devs[Int(i)] else { continue }
            var d = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &d) == 0,
                  d.idVendor == vendorID, supportedPIDs[d.idProduct] != nil else { continue }
            if !wantSerial.isEmpty, readSerial(dev, desc: d) != wantSerial { continue }
            var h: OpaquePointer?
            guard libusb_open(dev, &h) == 0, let handle = h else { throw USBError.openFailed }
            // Detach the macOS AppleUSBPrinter kext (if bound) but DO NOT auto-reattach
            // on release — handing the device back between sessions can wedge the
            // Brother status channel (per the handoff). So manual detach, no reattach.
            if libusb_kernel_driver_active(handle, 0) == 1 {
                _ = libusb_detach_kernel_driver(handle, 0)
            }
            guard libusb_claim_interface(handle, 0) == 0 else {
                libusb_close(handle); throw USBError.claimFailed
            }
            guard let (epOut, epIn) = bulkEndpoints(dev) else {
                libusb_release_interface(handle, 0); libusb_close(handle); throw USBError.noEndpoints
            }
            _ = libusb_clear_halt(handle, epOut)
            _ = libusb_clear_halt(handle, epIn)
            return BrotherConnection(handle: handle, epOut: epOut, epIn: epIn)
        }
        throw USBError.notFound
    }

    /// Write bytes to the bulk OUT endpoint in 64-byte chunks with a long timeout.
    static func send(_ bytes: [UInt8], on conn: BrotherConnection) throws {
        var data = bytes
        var off = 0
        while off < data.count {
            let end = min(off + chunk, data.count)
            var transferred: Int32 = 0
            let rc = data.withUnsafeMutableBufferPointer { buf -> Int32 in
                libusb_bulk_transfer(conn.handle, conn.epOut, buf.baseAddress?.advanced(by: off),
                                     Int32(end - off), &transferred, writeTimeoutMs)
            }
            guard rc == 0 else { throw USBError.transferFailed(rc) }
            guard transferred > 0 else { throw USBError.transferFailed(rc) }   // stall guard
            off += Int(transferred)
        }
    }

    /// Read one 32-byte status block with the empty-read retry (up to `attempts`
    /// reads, ~300 ms apart); a 0-byte/short transfer means "not ready yet". nil if
    /// the printer never answers.
    static func readStatus(on conn: BrotherConnection, attempts: Int = 5) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 32)
        for _ in 0 ..< attempts {
            usleep(300_000)
            var got: Int32 = 0
            let rc = buf.withUnsafeMutableBufferPointer {
                libusb_bulk_transfer(conn.handle, conn.epIn, $0.baseAddress, Int32($0.count), &got, statusTimeoutMs)
            }
            if rc == 0 && got >= 12 { return Array(buf.prefix(Int(got))) }
        }
        return nil
    }

    /// Drain queued/incoming status blocks until the printer goes quiet, so in-flight
    /// printing completes before the Engine closes the connection (the "drain rule").
    /// Bounded by `maxMs` wall-clock and `quietReads` consecutive empty reads.
    @discardableResult
    static func drainStatus(on conn: BrotherConnection, maxMs: Int, quietReads: Int = 2) -> [[UInt8]] {
        var blocks: [[UInt8]] = []
        var quiet = 0
        let start = DispatchTime.now().uptimeNanoseconds
        var buf = [UInt8](repeating: 0, count: 32)
        while quiet < quietReads {
            if Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000) > maxMs { break }
            var got: Int32 = 0
            let rc = buf.withUnsafeMutableBufferPointer {
                libusb_bulk_transfer(conn.handle, conn.epIn, $0.baseAddress, Int32($0.count), &got, 1_200)
            }
            if rc == 0 && got >= 12 {
                blocks.append(Array(buf.prefix(Int(got)))); quiet = 0
            } else {
                quiet += 1
                usleep(200_000)
            }
        }
        return blocks
    }

    /// Release the interface and close. Deliberately does NOT reattach the kernel
    /// driver (matches the Python reference; reattaching wedges the status channel).
    static func close(_ conn: BrotherConnection) {
        libusb_release_interface(conn.handle, 0)
        libusb_close(conn.handle)
    }

    // MARK: – Helpers

    /// Find the bulk OUT and bulk IN endpoint addresses on interface 0, alt 0.
    private static func bulkEndpoints(_ dev: OpaquePointer) -> (out: UInt8, in: UInt8)? {
        var cfgPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(dev, &cfgPtr) == 0, let cfg = cfgPtr else { return nil }
        defer { libusb_free_config_descriptor(cfg) }
        let c = cfg.pointee
        guard let interfaces = c.interface, c.bNumInterfaces > 0 else { return nil }
        let iface = interfaces[0]
        guard let alts = iface.altsetting, iface.num_altsetting > 0 else { return nil }
        let alt = alts[0]
        guard let eps = alt.endpoint else { return nil }
        var epOut: UInt8?, epIn: UInt8?
        for e in 0 ..< Int(alt.bNumEndpoints) {
            let ep = eps[e]
            let isBulk = (ep.bmAttributes & 0x03) == LIBUSB_TRANSFER_TYPE_BULK.rawValue
            guard isBulk else { continue }
            if ep.bEndpointAddress & 0x80 != 0 { epIn = epIn ?? ep.bEndpointAddress }
            else { epOut = epOut ?? ep.bEndpointAddress }
        }
        if let o = epOut, let i = epIn { return (o, i) }
        return nil
    }

    private static func serialComponent(of deviceID: String) -> String {
        // "usb:<vid>:<pid>:<serial>" → serial (may be empty / "usb").
        let parts = deviceID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return "" }
        let s = parts[3...].joined(separator: ":")
        return s == "usb" ? "" : s
    }

    private static func readSerial(_ dev: OpaquePointer, desc d: libusb_device_descriptor) -> String {
        guard d.iSerialNumber != 0 else { return "usb" }
        var h: OpaquePointer?
        guard libusb_open(dev, &h) == 0, let handle = h else { return "usb" }
        defer { libusb_close(handle) }
        var buf = [UInt8](repeating: 0, count: 64)
        let r = libusb_get_string_descriptor_ascii(handle, d.iSerialNumber, &buf, 64)
        return r > 0 ? (String(bytes: buf.prefix(Int(r)), encoding: .ascii) ?? "usb") : "usb"
    }
    #else
    static func enumerate(supportedPIDs: [UInt16: String]) -> [PrinterDevice] { [] }
    #endif
}
