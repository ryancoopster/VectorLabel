import Foundation
#if canImport(CLibUSB)
import CLibUSB
#endif

/// USB transport for the Brady M610/M611.
///
/// NOTE on macOS USB access:
/// IOKit's modern IOUSBHostDevice API requires a DriverKit extension and
/// entitlements to claim a USB interface from a regular app, which is a lot
/// of overhead for this use case. Instead we use libusb (the same approach
/// pyusb takes), which talks to the device via IOKit under the hood without
/// requiring a system extension - this matches how the reference Electron
/// implementation's node-usb print server worked.
///
/// Setup:
///   brew install libusb
///   Add a system library target "CLibUSB" with a module map pointing at
///   libusb-1.0 (pkg-config --cflags --libs libusb-1.0), then link it here.
///
/// USB identity (from Brady IEEE 1284 Device ID): VID 0x0E2E.
/// M610 PID is 0x010B. M611 PID should be verified on first connect - if it
/// differs, add it to `productIDs` below.
enum BradyUSB {
    static let vendorID: UInt16 = 0x0E2E
    static let productIDs: [UInt16] = [0x010B] // M610 confirmed; add M611 PID once verified
    static let outEndpoint: UInt8 = 0x01 // Endpoint 1 OUT
    static let chunkSize = 512
    static let chunkTimeoutMs: UInt32 = 10_000
    static let interLabelDelayMs: UInt32 = 50

    enum USBError: Error {
        case initFailed
        case deviceNotFound
        case openFailed
        case claimFailed
        case transferFailed(Int32)
    }

    /// Find and open the printer. Returns an opaque context to pass to send().
    static func openPrinter() throws -> OpaquePointer {
        #if canImport(CLibUSB)
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0, let context = ctx else { throw USBError.initFailed }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        defer { libusb_free_device_list(list, 1) }

        guard count > 0, let devices = list else {
            libusb_exit(context)
            throw USBError.deviceNotFound
        }

        for i in 0..<count {
            guard let dev = devices[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            if desc.idVendor == vendorID && productIDs.contains(desc.idProduct) {
                var handle: OpaquePointer?
                guard libusb_open(dev, &handle) == 0, let h = handle else {
                    throw USBError.openFailed
                }
                // Detach kernel driver if needed (macOS CUPS may have claimed it)
                _ = libusb_detach_kernel_driver(h, 0)
                guard libusb_claim_interface(h, 0) == 0 else {
                    libusb_close(h)
                    throw USBError.claimFailed
                }
                return h
            }
        }

        libusb_exit(context)
        throw USBError.deviceNotFound
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

    /// Send a single VGL job, chunked to 512 bytes. Fire-and-forget - the
    /// M610's status endpoint hangs, so we don't attempt to read it.
    static func sendJob(_ job: [UInt8], handle: OpaquePointer) throws {
        #if canImport(CLibUSB)
        var data = job
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let length = Int32(end - offset)
            var transferred: Int32 = 0
            let rc = data.withUnsafeMutableBufferPointer { buf -> Int32 in
                libusb_bulk_transfer(handle, outEndpoint, buf.baseAddress?.advanced(by: offset), length, &transferred, chunkTimeoutMs)
            }
            guard rc == 0 else { throw USBError.transferFailed(rc) }
            offset = end
        }
        #endif
    }

    /// Send multiple label jobs in sequence with a delay between each
    /// (prevents printer buffer overflow). Opens once, closes after.
    static func sendJobs(_ jobs: [[UInt8]]) throws {
        let handle = try openPrinter()
        defer { close(handle) }
        for (index, job) in jobs.enumerated() {
            try sendJob(job, handle: handle)
            if index < jobs.count - 1 {
                usleep(interLabelDelayMs * 1000)
            }
        }
    }
}
