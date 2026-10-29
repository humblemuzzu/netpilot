import Foundation
import os

let dnsLog = Logger(subsystem: "local.netpilot", category: "dns")

struct ResolverOption: Equatable {
    let id: String
    let name: String
    let addresses: [String]
    var isLocal: Bool { id == "local" }
}

struct ResolverResult: Identifiable, Equatable {
    let option: ResolverOption
    let answered: Int
    let failed: Int
    let median: Double
    let p90: Double
    let cost: Double
    var id: String { option.id }
    var failureRate: Double { Double(failed) / Double(max(1, answered + failed)) }
}

private struct Remembered: Codable {
    var servers: [String]
    var label: String
    var decidedAt: Date
}

/// Picks the DNS servers for whatever network the Mac is on, and keeps the choice honest.
///
/// macOS sends each lookup to the first server and only moves to the next after it stays silent
/// twice (about three seconds), then avoids the silent one for 60 seconds. So the order matters:
/// the first server must be the best one, and the second must be a working fallback.
///
/// Only servers NetPilot wrote itself are ever replaced or cleared. DNS servers you set yourself
/// are left alone, unless they point at a private address that no longer answers, which is what
/// a setting left over from another network looks like.
@MainActor
final class SmartDNS: ObservableObject {
    nonisolated static let publicOptions = [
        ResolverOption(id: "cloudflare", name: "Cloudflare", addresses: ["1.1.1.1", "1.0.0.1"]),
        ResolverOption(id: "google", name: "Google", addresses: ["8.8.8.8", "8.8.4.4"]),
        ResolverOption(id: "quad9", name: "Quad9", addresses: ["9.9.9.9", "149.112.112.112"]),
        ResolverOption(id: "opendns", name: "OpenDNS", addresses: ["208.67.222.222", "208.67.220.220"]),
    ]

    nonisolated private static let names = [
        "www.google.com", "www.apple.com", "github.com", "www.youtube.com", "www.wikipedia.org",
        "www.amazon.com", "www.instagram.com", "web.whatsapp.com", "www.netflix.com", "www.reddit.com",
        "open.spotify.com", "www.linkedin.com", "bun.sh", "htmx.org", "deno.com", "railway.app",
        "tailscale.com", "fly.io", "zed.dev", "linear.app",
    ]

    nonisolated private static let failureCost = 1500.0
    nonisolated private static let localBias = 0.85
    nonisolated private static let switchMargin = 0.8
    private static let retestInterval: TimeInterval = 20 * 60
    private static let writtenKey = "netpilot.dnsWritten"

    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "netpilot.smartDNS") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "netpilot.smartDNS")
            if enabled {
                refreshOwnership()
                retest()
                if userOverride { describe() }
            } else {
                restoreAutomatic(reason: "Smart DNS is off.")
            }
        }
    }
    @Published private(set) var headline = "Waiting for a network"
    @Published private(set) var detail = ""
    @Published private(set) var results: [ResolverResult] = []
    @Published private(set) var inEffect: [String] = []
    @Published private(set) var testing = false
    @Published private(set) var testedAt: Date?
    @Published private(set) var userOverride = false

    private var snapshot = NetSnapshot()
    private var portal: PortalState = .unknown
    private var generation = 0
    private var racing: Int?
    private var watchdogMisses = 0
    private var memory: [String: Remembered] = SmartDNS.loadMemory()
    private let writer = DispatchQueue(label: "local.netpilot.dns-writer")

    private var written: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: Self.writtenKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.writtenKey) }
    }

    // MARK: - Events

    /// A different network: drop the previous network's override at once, because a captive portal
    /// only works through the network's own DNS. The race starts once the portal check says we're online.
    func networkChanged(_ snap: NetSnapshot) {
        snapshot = snap
        portal = .unknown
        generation += 1
        watchdogMisses = 0
        results = []
        testedAt = nil
        testing = false

        for service in written.keys where service != snap.serviceName {
            write([], service: service)
        }
        refreshOwnership()
        guard enabled else { return describe() }
        guard snap.online else {
            headline = "No network"
            detail = ""
            inEffect = snap.dhcpDNS
            return
        }
        if userOverride {
            describe()
            clearIfStale()
            return
        }
        setAutomatic(headline: "Checking this network", detail: "Using its own DNS until the sign-in check finishes.")
    }

    func portalChanged(_ state: PortalState) {
        let was = portal
        portal = state
        guard enabled, snapshot.online, state != was, !userOverride else { return }
        switch state {
        case .signInRequired:
            setAutomatic(headline: "Using this network's DNS", detail: "Wi-Fi sign-in needs the network's own DNS. Smart DNS resumes after you sign in.")
        case .open:
            if let testedAt, Date().timeIntervalSince(testedAt) < 300 { return }
            if let remembered = memory[snapshot.networkKey] {
                apply(remembered.servers, label: remembered.label, detail: "Remembered from your last visit — re-checking.")
            }
            retest()
        case .unknown, .unreachable:
            break
        }
    }

    func dhcpOrManualChanged(_ snap: NetSnapshot) {
        let dhcpChanged = snap.dhcpDNS != snapshot.dhcpDNS
        let manualChanged = snap.manualDNS != snapshot.manualDNS
        snapshot = snap
        inEffect = snap.manualDNS.isEmpty ? snap.dhcpDNS : snap.manualDNS
        if manualChanged {
            let wasOverride = userOverride
            refreshOwnership()
            if userOverride && !wasOverride {
                dnsLog.info("manual DNS changed outside NetPilot: \(snap.manualDNS.joined(separator: ","), privacy: .public)")
                describe()
            } else if !userOverride && wasOverride && enabled {
                retest()
            }
        }
        if dhcpChanged && enabled { retest() }
    }

    /// Lets Smart DNS replace DNS servers that were set by hand.
    func takeOver() {
        guard userOverride else { return }
        userOverride = false
        setAutomatic(headline: "Checking this network", detail: "Your own DNS servers were removed.")
        retest()
    }

    /// Cheap health check of the server macOS is actually using; a sustained silence triggers a new race.
    func watchdog(internetUp: Bool) {
        guard enabled, !testing, !userOverride, snapshot.online, portal == .open, let first = inEffect.first else { return }
        if let testedAt, Date().timeIntervalSince(testedAt) > Self.retestInterval {
            retest()
            return
        }
        let name = Self.names.randomElement()!
        let interface = snapshot.interface
        let token = generation
        Task.detached(priority: .utility) {
            let answered = Probe.dns(first, name: name, timeout: 1.5, interface: interface).succeeded
                || Probe.dns(first, name: name, timeout: 1.5, interface: interface).succeeded
            await MainActor.run {
                guard token == self.generation else { return }
                if answered || !internetUp {
                    self.watchdogMisses = 0
                } else {
                    self.watchdogMisses += 1
                    if self.watchdogMisses >= 3 {
                        self.watchdogMisses = 0
                        dnsLog.info("watchdog: \(first, privacy: .public) stopped answering")
                        self.retest()
                    }
                }
            }
        }
    }

    func retest() {
        guard enabled, snapshot.online, portal == .open, !userOverride, racing != generation else { return }
        racing = generation
        testing = true
        let snap = snapshot
        let token = generation
        let remembered = memory[snap.networkKey]
        Task.detached(priority: .utility) {
            let verdict = Self.evaluate(snap, incumbent: remembered?.servers)
            await MainActor.run { self.finish(verdict, token: token) }
        }
    }

    /// Puts every service NetPilot changed back to the network's own DNS. Blocks, so it also works while quitting.
    func restoreAutomatic(reason: String) {
        for service in written.keys {
            writer.sync { _ = Self.run([], service: service) }
        }
        written = [:]
        snapshot.manualDNS = []
        inEffect = snapshot.dhcpDNS
        headline = "Using this network's DNS"
        detail = reason
    }

    // MARK: - Ownership

    private func refreshOwnership() {
        let service = snapshot.serviceName
        guard !service.isEmpty else {
            userOverride = false
            return
        }
        var legacy = UserDefaults.standard.stringArray(forKey: "netpilot.dnsTouched") ?? []
        if let index = legacy.firstIndex(of: service) {
            legacy.remove(at: index)
            UserDefaults.standard.set(legacy, forKey: "netpilot.dnsTouched")
            if !snapshot.manualDNS.isEmpty { written[service] = snapshot.manualDNS }
        }
        if snapshot.manualDNS.isEmpty {
            written[service] = nil
            userOverride = false
        } else if written[service] == snapshot.manualDNS {
            userOverride = false
        } else {
            written[service] = nil
            userOverride = true
        }
    }

    /// A hand-set private DNS server that doesn't answer here is a leftover from another network.
    private func clearIfStale() {
        let manual = snapshot.manualDNS
        let service = snapshot.serviceName
        let interface = snapshot.interface
        let token = generation
        Task.detached(priority: .utility) {
            let stale = manual.contains { server in
                Self.isPrivate(server)
                    && !Probe.dns(server, name: "www.apple.com", timeout: 1.5, interface: interface).succeeded
                    && !Probe.dns(server, name: "www.apple.com", timeout: 1.5, interface: interface).succeeded
            }
            guard stale else { return }
            await MainActor.run {
                guard token == self.generation, self.snapshot.manualDNS == manual else { return }
                dnsLog.info("clearing stale DNS on \(service, privacy: .public): \(manual.joined(separator: ","), privacy: .public)")
                self.userOverride = false
                self.write([], service: service)
                self.headline = "Checking this network"
                self.detail = "Removed DNS servers left over from another network."
                self.retest()
            }
        }
    }

    nonisolated private static func isPrivate(_ address: String) -> Bool {
        let p = address.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return address.lowercased().hasPrefix("fd") || address.lowercased().hasPrefix("fe80") }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
            || (p[0] == 100 && (64...127).contains(p[1]))
    }

    // MARK: - Decision

    private enum Verdict {
        case automatic(String, String, [ResolverResult])
        case use([String], String, String, [ResolverResult])
    }

    nonisolated private static func evaluate(_ snap: NetSnapshot, incumbent: [String]?) -> Verdict {
        let interface = snap.interface
        let impostor = Probe.dns("192.0.2.1", name: "example.com", timeout: 1.2, interface: interface)
        if impostor != .timeout && impostor != .unreachable {
            return .automatic("Using this network's DNS", "This network answers every DNS query itself, so other servers would only be imitated.", [])
        }
        let local = snap.dhcpDNS.filter { address in !publicOptions.contains { $0.addresses.contains(address) } }
        if let server = local.first,
           case .answered = Probe.dns(server, name: "ipv4only.arpa", type: 28, timeout: 1.5, interface: interface) {
            return .automatic("Using this network's DNS", "This is an IPv6 network that translates addresses through its own DNS.", [])
        }

        var options = publicOptions
        if !local.isEmpty {
            options.insert(ResolverOption(id: "local", name: "This network", addresses: local), at: 0)
        }
        let results = race(options, interface: interface)
        for r in results {
            dnsLog.info("race \(r.option.name, privacy: .public): median \(Int(r.median)) ms, p90 \(Int(r.p90)) ms, missed \(r.failed)/\(r.answered + r.failed), cost \(Int(r.cost))")
        }
        let floor = results.min { $0.failureRate < $1.failureRate }.map { (failed: $0.failed, total: $0.answered + $0.failed) } ?? (0, 1)
        let reliable = { (r: ResolverResult) in
            r.answered >= 4 && (r.failureRate <= 0.34 || !worse((r.failed, r.answered + r.failed), than: floor))
        }
        let eligible = results.filter(reliable).sorted { $0.cost < $1.cost }
        guard var best = eligible.first else {
            return .automatic("Using this network's DNS", "No DNS server answered reliably here, so nothing was changed.", results)
        }
        let privateDomain = snap.domain.contains(".") && !snap.domain.hasSuffix(".local") && !snap.domain.hasSuffix("home.arpa")
        if privateDomain, let localResult = eligible.first(where: { $0.option.isLocal }) {
            best = localResult
        }

        if privateDomain {
        } else if let incumbent, let current = eligible.first(where: { $0.option.addresses.first == incumbent.first }),
           current.option != best.option,
           !(best.cost <= current.cost * switchMargin && current.cost - best.cost >= 8) {
            best = current
        } else if incumbent == nil, let localResult = eligible.first(where: { $0.option.isLocal }), localResult.option != best.option,
                  !(best.cost <= localResult.cost * switchMargin && localResult.cost - best.cost >= 8) {
            best = localResult
        }

        let backup = eligible.first { $0.option != best.option }
        var servers = [best.option.addresses[0]]
        if let backup {
            servers.append(backup.option.addresses[0])
        } else if best.option.addresses.count > 1 {
            servers.append(best.option.addresses[1])
        }

        let speed = String(format: "%.0f ms typical", best.median)
        let backupText = backup.map { " · \($0.option.name) as backup" } ?? ""
        if best.option.isLocal && backup == nil {
            return .automatic("Using this network's DNS", "\(speed). It was the fastest and most reliable here.", results)
        }
        let label = best.option.isLocal ? "this network's DNS" : best.option.name
        return .use(servers, label, "\(speed)\(backupText)", results)
    }

    nonisolated private static func race(_ options: [ResolverOption], interface: String) -> [ResolverResult] {
        var samples = Array(repeating: [Double?](), count: options.count)
        let lock = NSLock()
        for name in (names + names.shuffled().prefix(4)).shuffled() {
            DispatchQueue.concurrentPerform(iterations: options.count) { index in
                let outcome = Probe.dns(options[index].addresses[0], name: name, timeout: 1.2, interface: interface)
                let value: Double?
                switch outcome {
                case .answered(let ms), .negative(let ms): value = ms
                default: value = nil
                }
                lock.lock()
                samples[index].append(value)
                lock.unlock()
            }
            usleep(120_000)
        }
        let counts = samples.map { (failed: $0.filter { $0 == nil }.count, total: $0.count) }
        let floor = counts.min { rate($0) < rate($1) } ?? (0, 1)
        return options.enumerated().map { index, option in
            let good = samples[index].compactMap { $0 }.sorted()
            let failed = counts[index].failed
            let median = good.isEmpty ? failureCost : good[good.count / 2]
            let p90 = good.isEmpty ? failureCost : good[min(good.count - 1, Int(Double(good.count) * 0.9))]
            let excess = worse(counts[index], than: floor) ? rate(counts[index]) - rate(floor) : 0
            let cost = (median + 0.25 * p90 + excess * failureCost) * (option.isLocal ? localBias : 1)
            return ResolverResult(option: option, answered: good.count, failed: failed, median: median, p90: p90, cost: cost)
        }.sorted { $0.cost < $1.cost }
    }

    nonisolated private static func rate(_ c: (failed: Int, total: Int)) -> Double {
        Double(c.failed) / Double(max(1, c.total))
    }

    /// Packet loss on the venue's line hits every resolver alike; only failures that are
    /// significantly above the most reliable resolver's (two-proportion z > 1.96) are the resolver's own.
    nonisolated private static func worse(_ a: (failed: Int, total: Int), than b: (failed: Int, total: Int)) -> Bool {
        let na = Double(max(1, a.total)), nb = Double(max(1, b.total))
        let pooled = Double(a.failed + b.failed) / (na + nb)
        let se = (pooled * (1 - pooled) * (1 / na + 1 / nb)).squareRoot()
        guard se > 0 else { return a.failed > b.failed }
        return (rate(a) - rate(b)) / se > 1.96
    }

    private func finish(_ verdict: Verdict, token: Int) {
        if racing == token { racing = nil }
        testing = racing == generation
        guard token == generation else { return retest() }
        guard enabled, !userOverride, portal == .open else { return }
        testedAt = Date()
        switch verdict {
        case .automatic(let title, let text, let results):
            dnsLog.info("decision: automatic — \(text, privacy: .public)")
            self.results = results
            memory[snapshot.networkKey] = nil
            setAutomatic(headline: title, detail: text)
        case .use(let servers, let label, let text, let results):
            dnsLog.info("decision: \(servers.joined(separator: ","), privacy: .public) (\(label, privacy: .public)) — \(text, privacy: .public)")
            self.results = results
            memory[snapshot.networkKey] = Remembered(servers: servers, label: label, decidedAt: Date())
            apply(servers, label: label, detail: text)
        }
        Self.saveMemory(memory)
    }

    private func setAutomatic(headline: String, detail: String) {
        if !snapshot.manualDNS.isEmpty, written[snapshot.serviceName] == snapshot.manualDNS {
            write([], service: snapshot.serviceName)
        }
        inEffect = snapshot.dhcpDNS
        self.headline = headline
        self.detail = detail
    }

    private func apply(_ servers: [String], label: String, detail: String) {
        guard !snapshot.serviceName.isEmpty else { return }
        if snapshot.manualDNS != servers {
            write(servers, service: snapshot.serviceName)
        }
        inEffect = servers
        headline = "Using \(label)"
        self.detail = detail
    }

    private func describe() {
        inEffect = snapshot.manualDNS.isEmpty ? snapshot.dhcpDNS : snapshot.manualDNS
        if userOverride {
            headline = "Using your own DNS servers"
            detail = "You set these yourself, so Smart DNS leaves them alone."
        } else {
            headline = "Using this network's DNS"
            detail = enabled ? "" : "Smart DNS is off."
        }
    }

    // MARK: - System

    /// Writes happen in order on one background queue. The record of what NetPilot wrote is updated
    /// up front so the configd notification for our own write is recognised as ours, and rolled back if it fails.
    private func write(_ servers: [String], service: String) {
        guard !service.isEmpty else { return }
        let previous = written[service]
        written[service] = servers.isEmpty ? nil : servers
        if service == snapshot.serviceName { snapshot.manualDNS = servers }
        writer.async {
            let (ok, output) = Self.run(servers, service: service)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !ok else { return }
                    dnsLog.error("networksetup failed for \(service, privacy: .public): \(output, privacy: .public)")
                    self.written[service] = previous
                    if service == self.snapshot.serviceName {
                        self.snapshot.manualDNS = NetWatcher.read().manualDNS
                        self.inEffect = self.snapshot.manualDNS.isEmpty ? self.snapshot.dhcpDNS : self.snapshot.manualDNS
                        self.detail = "macOS refused the DNS change: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }
                }
            }
        }
    }

    nonisolated private static func run(_ servers: [String], service: String) -> (Bool, String) {
        let (code, output) = Shell.run("/usr/sbin/networksetup", ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers))
        let failed = code != 0 || output.lowercased().contains("error")
        return (!failed, output)
    }

    nonisolated private static func loadMemory() -> [String: Remembered] {
        guard let data = UserDefaults.standard.data(forKey: "netpilot.dnsMemory"),
              let decoded = try? JSONDecoder().decode([String: Remembered].self, from: data)
        else { return [:] }
        return decoded
    }

    nonisolated private static func saveMemory(_ memory: [String: Remembered]) {
        if let data = try? JSONEncoder().encode(memory) {
            UserDefaults.standard.set(data, forKey: "netpilot.dnsMemory")
        }
    }
}
