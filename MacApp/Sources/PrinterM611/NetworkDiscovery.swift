import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Finds Brady network printers on the local subnet by probing each host for the
/// Brady control port (9102). Brady's M-series network printers listen on 9102
/// (PICL control) + 9100 (raw print), so an open 9102 is a strong signal.
///
/// The scan fires a whole chunk of non-blocking connects at once and `poll`s them
/// together, so a /24 finishes in a few poll-timeouts rather than 254 × timeout.
public enum NetworkDiscovery {

    /// Probe every local /24 subnet for hosts with `port` open. Blocking — call off
    /// the main thread. Returns reachable host IPs (sorted by last octet).
    public static func scanSubnet(port: UInt16 = 9102, timeoutMs: Int = 700) -> [String] {
        var found: [String] = []
        for base in localSubnetBases() {
            found += scanBase(base, port: port, timeoutMs: timeoutMs)
        }
        return found.sorted { (lastOctet($0) ?? 0) < (lastOctet($1) ?? 0) }
    }

    /// Keep concurrent fds well under the default RLIMIT_NOFILE (256).
    private static let chunkSize = 96

    private static func scanBase(_ base: String, port: UInt16, timeoutMs: Int) -> [String] {
        var found: [String] = []
        var lo = 1
        while lo <= 254 {
            let hi = min(lo + chunkSize - 1, 254)
            found += scanChunk(base: base, range: lo...hi, port: port, timeoutMs: timeoutMs)
            lo = hi + 1
        }
        return found
    }

    /// Fire non-blocking connects for `range` hosts, then poll them all until each
    /// resolves (connected / refused) or the deadline passes.
    private static func scanChunk(base: String, range: ClosedRange<Int>, port: UInt16, timeoutMs: Int) -> [String] {
        var fdHost: [Int32: String] = [:]
        var pfds: [pollfd] = []
        for i in range {
            let host = "\(base).\(i)"
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { continue }
            let fl = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { Darwin.close(fd); continue }
            let rc = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc != 0 && errno != EINPROGRESS { Darwin.close(fd); continue }
            fdHost[fd] = host
            pfds.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0))
        }
        var found: [String] = []
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while !pfds.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let n = poll(&pfds, nfds_t(pfds.count), Int32(remaining * 1000))
            if n <= 0 { break }
            var handled = Set<Int32>()
            for pfd in pfds where pfd.revents != 0 {
                handled.insert(pfd.fd)
                if (pfd.revents & Int16(POLLOUT)) != 0 {
                    var soErr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(pfd.fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                    if soErr == 0, let host = fdHost[pfd.fd] { found.append(host) }
                }
            }
            for fd in handled { Darwin.close(fd) }
            pfds.removeAll { handled.contains($0.fd) }
        }
        for pfd in pfds { Darwin.close(pfd.fd) }   // unreachable hosts that timed out
        return found
    }

    private static func lastOctet(_ ip: String) -> Int? { ip.split(separator: ".").last.flatMap { Int($0) } }

    /// The /24 base of each active, non-loopback, non-link-local IPv4 interface,
    /// e.g. "192.168.86" for a host at 192.168.86.24.
    static func localSubnetBases() -> [String] {
        var bases = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".")
            if octets.count == 4, !ip.hasPrefix("169.254") {
                bases.insert(octets.prefix(3).joined(separator: "."))
            }
        }
        return Array(bases)
    }

    /// Single-host non-blocking TCP connect with a timeout (via poll). Public so the
    /// Engine can classify a discovered raw-print host (e.g. probe 9102 to tell an
    /// M611 from a Brother PT during a subnet scan).
    public static func tcpReachable(host: String, port: UInt16, timeoutMs: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let fl = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        if errno != EINPROGRESS { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeoutMs)) > 0 else { return false }
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        return soErr == 0
    }
}
