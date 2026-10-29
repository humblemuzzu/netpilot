import Darwin
import Foundation

enum DNSOutcome: Equatable {
    case answered(ms: Double)
    case negative(ms: Double)
    case serverFailure
    case refused
    case timeout
    case unreachable

    var ms: Double? {
        switch self {
        case .answered(let ms), .negative(let ms): return ms
        default: return nil
        }
    }

    var succeeded: Bool { ms != nil }
}

enum Probe {
    nonisolated static func now() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_MONOTONIC, &t)
        return Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1_000_000
    }

    nonisolated private static func address(_ host: String, port: UInt16) -> (family: Int32, storage: sockaddr_storage, length: socklen_t)? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var storage = sockaddr_storage()
        memcpy(&storage, info.pointee.ai_addr, Int(info.pointee.ai_addrlen))
        return (info.pointee.ai_family, storage, info.pointee.ai_addrlen)
    }

    nonisolated private static func bind(_ fd: Int32, family: Int32, interface: String?) {
        guard let interface, !interface.isEmpty else { return }
        var index = if_nametoindex(interface)
        guard index != 0 else { return }
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        } else {
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
    }

    nonisolated private static func connect(_ fd: Int32, to addr: sockaddr_storage, length: socklen_t) -> Int32 {
        var storage = addr
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
    }

    nonisolated private static func wait(_ fd: Int32, events: Int16, deadline: Double) -> Bool {
        while true {
            let remaining = Int32(deadline - now())
            guard remaining > 0 else { return false }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&pfd, 1, remaining)
            if n > 0 { return true }
            if n < 0 && errno == EINTR { continue }
            return false
        }
    }

    /// Time to complete a TCP handshake. A refused connection still proves the path works, so it counts.
    nonisolated static func tcpConnect(_ host: String, port: UInt16, interface: String? = nil, timeout: Double = 2) -> Double? {
        guard let addr = address(host, port: port) else { return nil }
        let fd = socket(addr.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        bind(fd, family: addr.family, interface: interface)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let start = now()
        let rc = connect(fd, to: addr.storage, length: addr.length)
        if rc != 0 && errno != EINPROGRESS {
            return errno == ECONNREFUSED ? now() - start : nil
        }
        guard rc == 0 || wait(fd, events: Int16(POLLOUT), deadline: start + timeout * 1000) else { return nil }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard err == 0 || err == ECONNREFUSED else { return nil }
        return now() - start
    }

    // MARK: - DNS

    nonisolated private static func query(for name: String, id: UInt16, type: UInt16 = 1) -> [UInt8] {
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0)
        packet.append(contentsOf: [UInt8(type >> 8), UInt8(type & 0xff), 0, 1])
        return packet
    }

    nonisolated private static func outcome(_ reply: ArraySlice<UInt8>, id: UInt16, elapsed: Double) -> DNSOutcome? {
        guard reply.count >= 12 else { return nil }
        let r = Array(reply)
        guard UInt16(r[0]) << 8 | UInt16(r[1]) == id, r[2] & 0x80 != 0 else { return nil }
        let answers = Int(r[6]) << 8 | Int(r[7])
        switch r[3] & 0x0f {
        case 0: return answers > 0 ? .answered(ms: elapsed) : .negative(ms: elapsed)
        case 3: return .negative(ms: elapsed)
        case 5: return .refused
        default: return .serverFailure
        }
    }

    /// One DNS question to one server, no retries, so a dropped packet shows up as a timeout.
    nonisolated static func dns(_ server: String, name: String, type: UInt16 = 1, timeout: Double = 2, tcp: Bool = false, interface: String? = nil) -> DNSOutcome {
        guard let addr = address(server, port: 53) else { return .unreachable }
        let fd = socket(addr.family, tcp ? SOCK_STREAM : SOCK_DGRAM, tcp ? IPPROTO_TCP : IPPROTO_UDP)
        guard fd >= 0 else { return .unreachable }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        bind(fd, family: addr.family, interface: interface)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let id = UInt16.random(in: 1...UInt16.max)
        var packet = query(for: name, id: id, type: type)
        if tcp { packet = [UInt8(packet.count >> 8), UInt8(packet.count & 0xff)] + packet }
        let start = now()
        let deadline = start + timeout * 1000

        let rc = connect(fd, to: addr.storage, length: addr.length)
        if rc != 0 && errno != EINPROGRESS { return .unreachable }
        if tcp {
            guard rc == 0 || wait(fd, events: Int16(POLLOUT), deadline: deadline) else { return .timeout }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return .unreachable }
        }
        guard send(fd, packet, packet.count, 0) == packet.count else { return .unreachable }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var filled = 0
        while wait(fd, events: Int16(POLLIN), deadline: deadline) {
            let n = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress! + filled, raw.count - filled, 0)
            }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return errno == ECONNREFUSED ? .unreachable : .timeout
            }
            if n == 0 { return .timeout }
            let elapsed = now() - start
            if tcp {
                filled += n
                guard filled >= 2 else { continue }
                let length = Int(buffer[0]) << 8 | Int(buffer[1])
                guard filled >= length + 2 else { continue }
                return outcome(buffer[2..<(2 + length)], id: id, elapsed: elapsed) ?? .serverFailure
            }
            if let result = outcome(buffer[0..<n], id: id, elapsed: elapsed) { return result }
        }
        return .timeout
    }

    // MARK: - ICMP

    nonisolated private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// ICMP echo over a datagram socket, which macOS allows without root.
    nonisolated static func ping(_ host: String, timeout: Double = 1) -> Double? {
        guard let addr = address(host, port: 0), addr.family == AF_INET else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let ident = UInt16.random(in: 1...UInt16.max)
        let sequence = UInt16.random(in: 1...UInt16.max)
        var packet: [UInt8] = [8, 0, 0, 0, UInt8(ident >> 8), UInt8(ident & 0xff), UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        packet += Array("netpilot-probe-0123456789abcdef".utf8)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)

        var storage = addr.storage
        let start = now()
        let sent = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, addr.length) }
        }
        guard sent == packet.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 1500)
        while wait(fd, events: Int16(POLLIN), deadline: start + timeout * 1000) {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard n > 0 else { return nil }
            let headerLength = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0f) * 4 : 0
            guard n >= headerLength + 8 else { continue }
            let icmp = buffer[headerLength..<n]
            let base = icmp.startIndex
            guard icmp[base] == 0,
                  UInt16(icmp[base + 6]) << 8 | UInt16(icmp[base + 7]) == sequence else { continue }
            return now() - start
        }
        return nil
    }
}
