import Foundation

enum Traffic {
    struct Counters {
        let bytes: Double
        let connections: Int
    }

    nonisolated static func read(interface: String) -> Counters {
        var bytes: Double = 0
        let (_, netstat) = Shell.run("/usr/sbin/netstat", ["-ib"])
        for line in netstat.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 10, cols[0] == Substring(interface), cols[2].hasPrefix("<Link#") else { continue }
            if let received = Double(cols[6]), let sent = Double(cols[9]) {
                bytes = received + sent
            }
            break
        }

        let (_, lsof) = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED"])
        let connections = lsof.components(separatedBy: "\n").dropFirst().filter { line in
            let lower = line.lowercased()
            guard lower.contains("established") else { return false }
            return !lower.contains("127.0.0.1")
                && !lower.contains("[::1]")
                && !lower.contains("tailscale")
                && !lower.contains("rapportd")
        }.count

        return Counters(bytes: bytes, connections: connections)
    }
}
