import Foundation
import VectorLabelCore
#if canImport(Darwin)
import Darwin
#endif

/// Opaque connection token for a Brother PT printer over the network (raw TCP 9100).
/// The classic raster job bytes are transport-agnostic — byte-identical to the USB
/// stream — so only the open/write/close plumbing differs from `BrotherUSB`.
final class BrotherNetConnection: PrinterConnection {
    let fd: Int32
    let host: String
    init(fd: Int32, host: String) { self.fd = fd; self.host = host }
}

/// TCP transport for Brother PT printers — the printer's raw print port **9100**
/// (confirmed open on the PT-E550W's Wi-Fi). Mirrors the M611 network plumbing:
/// a bounded non-blocking connect (so a stalled printer can't hang the per-printer
/// serial queue), `SO_NOSIGPIPE`, and a blocking `writeAll`.
///
/// Print-only: status/media is read over the USB IN endpoint, which isn't exposed on
/// the network, so a network-connected PT derives its tape from the rendered raster
/// (the encoder's nearest-printable-width snap) rather than auto-detecting it.
enum BrotherNet {
    static let printPort: UInt16 = 9100

    enum NetError: Error { case connectFailed, writeFailed }

    /// Connect to `host:port` with a bounded wait. Resolves `host` via `getaddrinfo`, so
    /// an IPv4 literal, an IPv6 literal, OR a hostname all work (the old inet_pton path
    /// accepted numeric IPv4 only and silently failed otherwise). Sets `SO_NOSIGPIPE` so
    /// a write to a peer-closed socket throws instead of killing the process.
    static func connect(host: String, port: UInt16 = printPort, timeoutMs: Int = 4000) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC          // IPv4 or IPv6
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, res != nil else {
            throw NetError.connectFailed
        }
        defer { freeaddrinfo(res) }
        // Try each resolved address until one connects.
        var ai = res
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            guard let sa = a.pointee.ai_addr else { continue }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let rc = Darwin.connect(fd, sa, a.pointee.ai_addrlen)
            var ok = (rc == 0)
            if rc != 0 && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, Int32(timeoutMs)) > 0, (pfd.revents & Int16(POLLOUT)) != 0 {
                    var soErr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                    ok = (soErr == 0)
                }
            }
            if ok {
                _ = fcntl(fd, F_SETFL, flags)   // restore blocking mode for writeAll
                return fd
            }
            Darwin.close(fd)
        }
        throw NetError.connectFailed
    }

    /// Write all bytes to the socket (chunking handled by the kernel). 64-byte framing
    /// like the USB path isn't needed over TCP.
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

    static func close(_ fd: Int32) { Darwin.close(fd) }

    /// True if the printer accepts a TCP connection on 9100 — used by enumerate so an
    /// unreachable network printer reports `.offline` instead of a permanent `.ready`.
    static func reachable(host: String, timeoutMs: Int = 600) -> Bool {
        guard let fd = try? connect(host: host, timeoutMs: timeoutMs) else { return false }
        close(fd)
        return true
    }
}
