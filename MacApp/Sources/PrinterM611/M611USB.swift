import Foundation
import VectorLabelCore
#if canImport(CLibUSB)
import CLibUSB
#endif

#if canImport(CLibUSB)
/// Opaque connection token wrapping the libusb handle for an M611 USB device.
final class M611USBConnection: PrinterConnection {
    let handle: OpaquePointer
    let deviceID: String   // kept so a job can poll telemetry (vendor iface) mid-print
    init(_ handle: OpaquePointer, deviceID: String) { self.handle = handle; self.deviceID = deviceID }
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
    static let iface: Int32 = 0               // printer-class interface (07/01/02) — PRINT
    static let epOut: UInt8 = 0x01            // bulk OUT (print)
    static let epIn: UInt8 = 0x82             // bulk IN (print)
    // Telemetry rides the VENDOR interface (iface 1, EP 0x03/0x84) — the USB analog of
    // network TCP:9102 (the FirmwareDriver/PICL channel). Confirmed live on hardware:
    // iface 1 answers the FirmwareDriver component (supply/ribbon/battery/substrate);
    // iface 0 answers the Job Handler (print). Separate channel ⇒ polling it can't misprint.
    static let telIface: Int32 = 1
    static let telEpOut: UInt8 = 0x03
    static let telEpIn: UInt8 = 0x84
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
            // No host ⇒ USB. The user-set name isn't retrievable over USB (it's only a
            // DHCP hostname on the network), so the name is just the model; the UI shows
            // "USB" where a network printer shows its IP.
            out.append(PrinterDevice(id: "usb:\(serial)", name: "M611",
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

    /// Open a PERSISTENT job-status subscription on the vendor interface (iface 1): claim it and
    /// write the "subscribe to all" request. The printer then PUSHES small status frames (read
    /// via `readSubFrame`) as jobs change state — far lighter than re-polling the full enumerate.
    /// Returns the open handle (caller must `closeSubscription`), or nil on failure.
    static func openSubscription(deviceID: String, request: [UInt8]) -> OpaquePointer? {
        guard let ctx else { return nil }
        let wantSerial = deviceID.hasPrefix("usb:") ? String(deviceID.dropFirst(4)) : deviceID
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        defer { libusb_free_device_list(list, 1) }
        guard n > 0, let devs = list else { return nil }
        for i in 0 ..< n {
            guard let dev = devs[Int(i)] else { continue }
            var d = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &d) == 0,
                  d.idVendor == vendorID, d.idProduct == productID else { continue }
            var h: OpaquePointer?
            guard libusb_open(dev, &h) == 0, let handle = h else { return nil }
            if wantSerial != "usb", readSerial(dev, desc: d) != wantSerial { libusb_close(handle); continue }
            _ = libusb_set_auto_detach_kernel_driver(handle, 1)
            guard libusb_claim_interface(handle, telIface) == 0 else { libusb_close(handle); return nil }
            _ = libusb_clear_halt(handle, telEpOut)
            _ = libusb_clear_halt(handle, telEpIn)
            var out = request, off = 0
            while off < out.count {
                let end = min(off + chunkSize, out.count); var sent: Int32 = 0
                let rc = out.withUnsafeMutableBufferPointer {
                    libusb_bulk_transfer(handle, telEpOut, $0.baseAddress?.advanced(by: off),
                                         Int32(end - off), &sent, chunkTimeoutMs)
                }
                guard rc == 0, sent > 0 else {
                    libusb_release_interface(handle, telIface); libusb_close(handle); return nil
                }
                off += Int(sent)
            }
            return handle
        }
        return nil
    }

    /// Read one pushed PICL frame ([16 magic][4 LE len][JSON]) from the subscription, waiting up
    /// to ~`capMs` for a push to begin. [] if none arrives in time. The first frame after
    /// `openSubscription` is the (large) initial snapshot; subsequent frames are small deltas.
    static func readSubFrame(handle: OpaquePointer, capMs: Int) -> [UInt8] {
        var resp: [UInt8] = []
        var rbuf = [UInt8](repeating: 0, count: 16384)
        var waited = 0
        while true {
            var got: Int32 = 0
            let rc = rbuf.withUnsafeMutableBufferPointer {
                libusb_bulk_transfer(handle, telEpIn, $0.baseAddress, Int32($0.count), &got, 300)
            }
            if got > 0 {
                resp += rbuf.prefix(Int(got))
                if resp.count >= 20, Array(resp.prefix(16)) == M611PICL.magic {
                    let len = Int(resp[16]) | Int(resp[17]) << 8 | Int(resp[18]) << 16 | Int(resp[19]) << 24
                    if len > 0 && resp.count >= 20 + len { return Array(resp.prefix(20 + len)) }
                }
            } else {
                if !resp.isEmpty { break }            // mid-frame gap → return what we have
                waited += 300
                if waited >= capMs { break }           // no push started in time
            }
            if rc != 0 && rc != -7 { break }
        }
        return resp
    }

    static func closeSubscription(_ handle: OpaquePointer) {
        libusb_release_interface(handle, telIface)
        libusb_close(handle)
    }

    /// One PICL request/response over the M611's VENDOR interface (iface 1, EP 0x03/0x84)
    /// — the USB analog of network TCP:9102 (the FirmwareDriver/telemetry channel, separate
    /// from the print pipe on iface 0). Self-contained: open → claim iface 1 → write request
    /// → read response → release. Returns the raw response bytes ([] on failure); the caller
    /// parses with M611PICL. Runs on the per-printer device queue (blocking is fine).
    static func readTelemetry(deviceID: String, request req: [UInt8]) -> [UInt8] {
        guard let ctx else { return [] }
        let wantSerial = deviceID.hasPrefix("usb:") ? String(deviceID.dropFirst(4)) : deviceID
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        defer { libusb_free_device_list(list, 1) }
        guard n > 0, let devs = list else { return [] }
        for i in 0 ..< n {
            guard let dev = devs[Int(i)] else { continue }
            var d = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &d) == 0,
                  d.idVendor == vendorID, d.idProduct == productID else { continue }
            var h: OpaquePointer?
            guard libusb_open(dev, &h) == 0, let handle = h else { return [] }
            if wantSerial != "usb", readSerial(dev, desc: d) != wantSerial { libusb_close(handle); continue }
            _ = libusb_set_auto_detach_kernel_driver(handle, 1)
            guard libusb_claim_interface(handle, telIface) == 0 else { libusb_close(handle); return [] }
            defer { libusb_release_interface(handle, telIface); libusb_close(handle) }
            _ = libusb_clear_halt(handle, telEpOut)
            _ = libusb_clear_halt(handle, telEpIn)
            // Write the PICL request to the telemetry OUT endpoint (chunked).
            var out = req; var off = 0
            while off < out.count {
                let end = min(off + chunkSize, out.count); var sent: Int32 = 0
                let rc = out.withUnsafeMutableBufferPointer { b in
                    libusb_bulk_transfer(handle, telEpOut, b.baseAddress?.advanced(by: off),
                                         Int32(end - off), &sent, chunkTimeoutMs)
                }
                guard rc == 0, sent > 0 else { return [] }
                off += Int(sent)
            }
            // Read the response, ACCUMULATING bulk packets until a complete PICL frame has
            // arrived. A small telemetry reply fits one read, but the job-status reply (many
            // slots) spans several reads and exceeds a single buffer — a one-shot read
            // truncates it and the JSON won't parse. Return as soon as the accumulated bytes
            // parse (mirrors the network readResponse), or on a timeout/error.
            var resp: [UInt8] = []
            var rbuf = [UInt8](repeating: 0, count: 16384)
            var idle = 0
            for _ in 0 ..< 60 {
                var got: Int32 = 0
                let rc = rbuf.withUnsafeMutableBufferPointer { b in
                    libusb_bulk_transfer(handle, telEpIn, b.baseAddress, Int32(b.count), &got, 300)
                }
                if got > 0 {
                    resp += rbuf.prefix(Int(got)); idle = 0
                    // Complete via the frame's length prefix ([16 magic][4 LE len][JSON]) — robust
                    // for the large enumerate reply; trim any trailing pushed bytes. Else once a
                    // full JSON object has accumulated.
                    if resp.count >= 20, Array(resp.prefix(16)) == M611PICL.magic {
                        let len = Int(resp[16]) | Int(resp[17]) << 8 | Int(resp[18]) << 16 | Int(resp[19]) << 24
                        if len > 0 && resp.count >= 20 + len { return Array(resp.prefix(20 + len)) }
                    } else if resp.count > 24, M611PICL.parse(resp) != nil {
                        return resp
                    }
                } else {
                    idle += 1
                    if idle >= 6 { break }   // ~1.8s with no data → stop
                }
                // A timeout (-7) is EXPECTED between bursts of a large reply — keep reading;
                // only a real transfer error aborts. (Bailing on -7 truncated the reply before.)
                if rc != 0 && rc != -7 { break }
            }
            return resp
        }
        return []
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
