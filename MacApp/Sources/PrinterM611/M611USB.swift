import Foundation
import VectorLabelCore
#if canImport(CLibUSB)
import CLibUSB
#endif

#if canImport(CLibUSB)
/// Opaque connection token wrapping the libusb handle for an M611 USB device.
final class M611USBConnection: PrinterConnection {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
}
#endif

/// USB transport for the M611 composite device (VID 0x0E2E, PID 0x13). The M611
/// speaks the SAME bitmap/PICL protocol over USB as over the network — no USB-specific
/// reframing — on its **printer-class interface 0 (07/01/02), bulk OUT 0x01 / IN 0x82**
/// (matches the M610's BradyUSB and the recovered ETW capture of Brady Workstation;
/// endpoints inferred from the capture + descriptors, pending a live on-device print).
/// A transparent byte pipe for `M611Bitmap` jobs + PICL packets; only the open/read/
/// write plumbing differs from the network transport.
enum M611USB {
    static let vendorID: UInt16 = 0x0E2E
    static let productID: UInt16 = 0x13      // M611 composite device
    static let iface: Int32 = 0               // printer-class interface (07/01/02)
    static let epOut: UInt8 = 0x01            // bulk OUT
    static let epIn: UInt8 = 0x82             // bulk IN
    static let chunkSize = 512
    static let chunkTimeoutMs: UInt32 = 10_000

    #if canImport(CLibUSB)
    /// One libusb context for the M611 USB transport (separate from the M610's).
    static let ctx: OpaquePointer? = { var c: OpaquePointer?; return libusb_init(&c) == 0 ? c : nil }()

    enum USBError: Error { case noContext, notFound, openFailed, claimFailed, transferFailed(Int32) }

    /// Connected M611 composite devices, as `PrinterDevice`s (id "usb:<serial>").
    static func enumerate() -> [PrinterDevice] {
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
                  d.idVendor == vendorID, d.idProduct == productID else { continue }
            let serial = readSerial(dev, desc: d)
            out.append(PrinterDevice(id: "usb:\(serial)", name: "Brady M611 (USB)",
                                     model: "M611", serial: serial, status: .ready, host: nil))
        }
        return out
    }

    /// Open the M611 matching `deviceID` ("usb:<serial>"), claiming the vendor iface.
    static func open(deviceID: String) throws -> OpaquePointer {
        guard let ctx else { throw USBError.noContext }
        let wantSerial = deviceID.hasPrefix("usb:") ? String(deviceID.dropFirst(4)) : deviceID
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        defer { libusb_free_device_list(list, 1) }
        guard n > 0, let devs = list else { throw USBError.notFound }
        for i in 0 ..< n {
            guard let dev = devs[Int(i)] else { continue }
            var d = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &d) == 0,
                  d.idVendor == vendorID, d.idProduct == productID else { continue }
            var h: OpaquePointer?
            guard libusb_open(dev, &h) == 0, let handle = h else { throw USBError.openFailed }
            if wantSerial != "usb", readSerial(dev, desc: d) != wantSerial { libusb_close(handle); continue }
            // Auto-detach the OS/CUPS driver on claim and RE-ATTACH it on release/close,
            // so we never strand the printer for other apps (mirrors M610 BradyUSB).
            _ = libusb_set_auto_detach_kernel_driver(handle, 1)
            guard libusb_claim_interface(handle, iface) == 0 else { libusb_close(handle); throw USBError.claimFailed }
            // Recover any stalled bulk endpoints before streaming a job.
            _ = libusb_clear_halt(handle, epOut)
            _ = libusb_clear_halt(handle, epIn)
            return handle
        }
        throw USBError.notFound
    }

    /// Send bytes to the printer's bulk OUT, chunked.
    static func send(_ bytes: [UInt8], handle: OpaquePointer) throws {
        var data = bytes
        var off = 0
        while off < data.count {
            let end = min(off + chunkSize, data.count)
            var transferred: Int32 = 0
            let rc = data.withUnsafeMutableBufferPointer { buf -> Int32 in
                libusb_bulk_transfer(handle, epOut, buf.baseAddress?.advanced(by: off),
                                     Int32(end - off), &transferred, chunkTimeoutMs)
            }
            guard rc == 0 else { throw USBError.transferFailed(rc) }
            // Advance by bytes ACTUALLY transferred — libusb may report a short transfer on
            // success; skipping the unsent tail would punch a hole in the segment stream.
            // Treat zero progress as a stall so we don't spin forever.
            guard transferred > 0 else { throw USBError.transferFailed(rc) }
            off += Int(transferred)
        }
    }

    /// Write a PICL request packet and read one response (for telemetry, Phase 3).
    static func request(_ packet: [UInt8], handle: OpaquePointer, timeoutMs: UInt32 = 1000) -> [UInt8] {
        try? send(packet, handle: handle)
        var buf = [UInt8](repeating: 0, count: 8192)
        var got: Int32 = 0
        let rc = buf.withUnsafeMutableBufferPointer { b in
            libusb_bulk_transfer(handle, epIn, b.baseAddress, Int32(b.count), &got, timeoutMs)
        }
        return rc == 0 && got > 0 ? Array(buf.prefix(Int(got))) : []
    }

    static func close(_ handle: OpaquePointer) {
        libusb_release_interface(handle, iface)
        libusb_close(handle)
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
    static func enumerate() -> [PrinterDevice] { [] }
    #endif
}
