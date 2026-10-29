import Foundation
import SwiftUI

struct RankedNet: Identifiable, Equatable {
    let ssid: String
    let band: String
    let signalPct: Int
    let score: Int
    let current: Bool
    let reasons: [String]
    var id: String { ssid }
}

struct IfaceResult: Identifiable {
    let service: String
    let device: String
    let ip: String
    var latencyMs: Double?
    var downMbps: Double?
    var id: String { service }
}

enum Shell {
    @discardableResult
    nonisolated static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    nonisolated static func which(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let dir = "/usr/local/etc/netpilot"
    static let flagPath = dir + "/awdl_off"
    static let requestPath = dir + "/request.txt"
    static let daemonPlist = "/Library/LaunchDaemons/local.netpilot.daemon.plist"

    @Published var nets: [RankedNet] = []
    @Published var currentSSID = "—"
    @Published var rssi = 0
    @Published var linkRate = 0
    @Published var latency: Double = 0
    @Published var jitter: Double = 0
    @Published var loss: Double = 0
    @Published var history: [Double] = []
    @Published var awdlOff = false
    @Published var ifaces: [IfaceResult] = []
    @Published var message = "" {
        didSet { messageSetAt = Date() }
    }
    @Published private(set) var messageSetAt = Date.distantPast
    @Published var busy = false
    @Published var daemonInstalled = false
    @Published var roamrMissing = false
    @Published var health: [String: Double] = [:]
    @Published var primaryService = ""
    @Published var staleLinks: [String] = []
    @Published var autoPrefer: Bool = UserDefaults.standard.bool(forKey: "netpilot.autoPrefer") {
        didSet { UserDefaults.standard.set(autoPrefer, forKey: "netpilot.autoPrefer") }
    }
    @Published var autoNetwork: Bool = UserDefaults.standard.bool(forKey: "netpilot.autoNetwork") {
        didSet { UserDefaults.standard.set(autoNetwork, forKey: "netpilot.autoNetwork") }
    }
    @Published var suggestedSSID: String?
    @Published var pendingSSID: String?
    @Published var switchCountdown = 0
    @Published var busyTraffic = false
    @Published var activeConnections = 0
    @Published var bytesPerSec: Double = 0

    private var healthTimer: Timer?
    private var badTicks = 0
    private var lastAutoJoin: Date?
    private var trafficTimer: Timer?
    private var countdownTimer: Timer?
    private var lastCounters: (bytes: Double, time: Date)?

    private var roamrTask: Process?
    private var roamrBuffer = Data()
    private var samples: [Double?] = []
    private var sysTimer: Timer?
    private var wifiDevice = "en0"
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        daemonInstalled = FileManager.default.fileExists(atPath: Self.daemonPlist)
        refreshAWDLFlag()
        wifiDevice = Self.detectWifiDevice()
        startRoamr()
        loadInterfaces()
        pollSystem()
        probeHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeHealth() }
        }
        RunLoop.main.add(healthTimer!, forMode: .common)
        sampleTraffic()
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleTraffic() }
        }
        RunLoop.main.add(trafficTimer!, forMode: .common)
        sysTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollSystem()
                self?.refreshAWDLFlag()
            }
        }
        RunLoop.main.add(sysTimer!, forMode: .common)
    }

    var qualityColor: Color { Theme.latency(latency) }

    var visibleMessage: String? {
        guard !message.isEmpty, Date().timeIntervalSince(messageSetAt) < 8 else { return nil }
        return message
    }

    var menuSymbol: String {
        latency >= 100 || loss >= 100 ? "exclamationmark.triangle" : "waveform.path.ecg"
    }

    func stop() {
        roamrTask?.terminate()
        sysTimer?.invalidate()
        healthTimer?.invalidate()
        trafficTimer?.invalidate()
        countdownTimer?.invalidate()
    }

    // MARK: - AWDL

    func refreshAWDLFlag() {
        awdlOff = FileManager.default.fileExists(atPath: Self.flagPath)
    }

    func toggleAWDL() {
        guard daemonInstalled else {
            message = "Helper not installed yet — run Scripts/install-daemon.sh first."
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.flagPath) {
            try? fm.removeItem(atPath: Self.flagPath)
        } else {
            fm.createFile(atPath: Self.flagPath, contents: Data())
        }
        refreshAWDLFlag()
        message = awdlOff
            ? "AWDL off: AirDrop/Handoff disabled, stutter gone."
            : "AWDL on: AirDrop works, stutter may return."
    }

    // MARK: - Roamr feed (ranking)

    private func startRoamr() {
        let candidates = ["/opt/homebrew/bin/roamr", "/usr/local/bin/roamr"]
        guard let path = candidates.first(where: { Shell.which($0) }) else {
            roamrMissing = true
            message = "roamr not found. Install: brew install --cask sourabh-khot65/tap/roamr"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["watch", "--json", "--interval", "5s"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingestRoamr(data) }
        }
        do { try p.run() } catch {
            roamrMissing = true
            message = "Could not start roamr."
            return
        }
        roamrTask = p
    }

    private func ingestRoamr(_ data: Data) {
        roamrBuffer.append(data)
        while let newline = roamrBuffer.firstIndex(of: 0x0A) {
            let lineData = roamrBuffer.subdata(in: 0..<newline)
            roamrBuffer.removeSubrange(0...newline)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            if let cur = obj["current"] as? [String: Any], let ssid = cur["ssid"] as? String {
                currentSSID = ssid
            }
            guard let raw = obj["networks"] as? [[String: Any]] else { continue }
            nets = raw.compactMap { dict -> RankedNet? in
                guard let ssid = dict["ssid"] as? String else { return nil }
                let score = (dict["score"] as? Int) ?? Int((dict["smoothed"] as? Double) ?? 0)
                return RankedNet(
                    ssid: ssid,
                    band: dict["band"] as? String ?? "",
                    signalPct: dict["signal_pct"] as? Int ?? 0,
                    score: score,
                    current: dict["current"] as? Bool ?? false,
                    reasons: dict["reasons"] as? [String] ?? []
                )
            }.sorted { $0.score > $1.score }

            let suggested = obj["suggested"] as? Bool ?? false
            if let best = obj["best"] as? [String: Any], let bestSSID = best["ssid"] as? String {
                suggestedSSID = suggested ? bestSSID : nil
            } else {
                suggestedSSID = nil
            }
            maybeAutoJoin()
        }
    }

    private func maybeAutoJoin() {
        guard autoNetwork else {
            pendingSSID = nil
            cancelCountdown()
            return
        }
        guard let target = suggestedSSID, target != currentSSID, !busy else {
            if suggestedSSID == nil {
                pendingSSID = nil
                cancelCountdown()
            }
            return
        }
        if let last = lastAutoJoin, Date().timeIntervalSince(last) < 300 { return }
        if pendingSSID != target {
            pendingSSID = target
            cancelCountdown()
        }
        guard !busyTraffic else {
            cancelCountdown()
            return
        }
        if switchCountdown == 0 { startCountdown() }
    }

    private func startCountdown() {
        switchCountdown = 10
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCountdown() }
        }
        RunLoop.main.add(countdownTimer!, forMode: .common)
    }

    private func tickCountdown() {
        guard let target = pendingSSID else {
            cancelCountdown()
            return
        }
        if busyTraffic {
            cancelCountdown()
            return
        }
        switchCountdown -= 1
        guard switchCountdown <= 0 else { return }
        cancelCountdown()
        pendingSSID = nil
        lastAutoJoin = Date()
        message = "Switched to \(target) — it was durably better and the link was idle."
        join(target)
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        switchCountdown = 0
    }

    func switchNow() {
        guard let target = pendingSSID else { return }
        cancelCountdown()
        pendingSSID = nil
        lastAutoJoin = Date()
        join(target)
    }

    func cancelPending() {
        cancelCountdown()
        pendingSSID = nil
        message = "Auto-switch cancelled — staying on \(currentSSID)."
    }

    func sampleTraffic() {
        let device = ifaces.first { $0.service == primaryService }?.device ?? wifiDevice
        DispatchQueue.global(qos: .utility).async {
            let counters = Traffic.read(interface: device)
            Task { @MainActor in
                let now = Date()
                if let previous = self.lastCounters {
                    let elapsed = now.timeIntervalSince(previous.time)
                    if elapsed > 0.5 {
                        self.bytesPerSec = max(0, (counters.bytes - previous.bytes) / elapsed)
                    }
                }
                self.lastCounters = (counters.bytes, now)
                self.activeConnections = counters.connections
                self.busyTraffic = counters.connections >= 1 || self.bytesPerSec > 5_000
                self.maybeAutoJoin()
            }
        }
    }

    // MARK: - Samples

    private func pushSample(_ value: Double?) {
        samples.append(value)
        if samples.count > 40 { samples.removeFirst() }
        let good = samples.compactMap { $0 }
        guard !good.isEmpty else {
            latency = 0; loss = 100; jitter = 0; history = []
            return
        }
        loss = Double(samples.count - good.count) / Double(samples.count) * 100
        latency = good.reduce(0, +) / Double(good.count)
        if good.count > 1 {
            let mean = latency
            let variance = good.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(good.count)
            jitter = variance.squareRoot()
        } else {
            jitter = 0
        }
        history = Array(good.suffix(40))
    }

    // MARK: - System state (RSSI, link rate)

    private func pollSystem() {
        DispatchQueue.global(qos: .utility).async {
            let (_, output) = Shell.run("/usr/sbin/system_profiler", ["SPAirPortDataType"])
            guard let marker = output.range(of: "Current Network Information:") else { return }
            let block = String(output[marker.upperBound...].prefix(1200))
            let rssi = Self.number(after: "Signal / Noise:", in: block)
            let rate = Self.number(after: "Transmit Rate:", in: block)
            Task { @MainActor in
                if let rssi { self.rssi = Int(rssi) }
                if let rate { self.linkRate = Int(rate) }
            }
        }
    }

    nonisolated private static func number(after key: String, in text: String) -> Double? {
        guard let range = text.range(of: key) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.drop { !"0123456789-".contains($0) }
        let token = digits.prefix { "0123456789.-".contains($0) }
        return Double(token)
    }

    nonisolated static func detectWifiDevice() -> String {
        let (_, output) = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        var sawWifi = false
        for line in output.components(separatedBy: "\n") {
            if line.contains("Hardware Port: Wi-Fi") { sawWifi = true; continue }
            if sawWifi, line.contains("Device:") {
                return line.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return "en0"
    }

    // MARK: - Switching

    func join(_ ssid: String) {
        busy = true
        message = "Joining \(ssid)…"
        let device = wifiDevice
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, output) = Shell.run("/usr/sbin/networksetup", ["-setairportnetwork", device, ssid])
            Task { @MainActor in
                self.busy = false
                if code == 0 {
                    self.message = "Joined \(ssid)."
                    self.currentSSID = ssid
                } else {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.contains("password") || trimmed.contains("-3925") {
                        self.requestJoin(ssid)
                        self.message = "Asked helper to join \(ssid) with the saved password."
                    } else {
                        self.message = trimmed.isEmpty ? "Could not join \(ssid)." : trimmed
                    }
                }
            }
        }
    }

    private func writeRequest(_ lines: [String]) {
        let body = "id \(UUID().uuidString)\n" + lines.joined(separator: "\n") + "\n"
        try? body.data(using: .utf8)?.write(to: URL(fileURLWithPath: Self.requestPath), options: .atomic)
    }

    private func requestJoin(_ ssid: String) {
        writeRequest(["action join", "ssid \(ssid)", "device \(wifiDevice)"])
    }

    private func requestOrder(_ services: [String]) {
        writeRequest(["action order"] + services.map { "service \($0)" })
    }

    // MARK: - Interfaces

    func loadInterfaces() {
        DispatchQueue.global(qos: .userInitiated).async {
            let (_, servicesOut) = Shell.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
            let (_, orderOut) = Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
            var deviceFor: [String: String] = [:]
            var pending: String?
            for line in orderOut.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let close = trimmed.range(of: ") ") {
                    let name = String(trimmed[close.upperBound...])
                    if !name.contains("Hardware Port:") { pending = name; continue }
                }
                if trimmed.contains("Device:") {
                    let device = trimmed
                        .replacingOccurrences(of: ")", with: "")
                        .components(separatedBy: "Device:")
                        .last?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    if let name = pending { deviceFor[name] = device; pending = nil }
                }
            }
            var results: [IfaceResult] = []
            for raw in servicesOut.components(separatedBy: "\n") {
                let name = raw.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.hasPrefix("*"), !name.contains("denotes") else { continue }
                guard let device = deviceFor[name] else { continue }
                let (_, ipOut) = Shell.run("/usr/sbin/ipconfig", ["getifaddr", device])
                let ip = ipOut.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ip.isEmpty, !device.hasPrefix("bridge") else { continue }
                results.append(IfaceResult(service: name, device: device, ip: ip))
            }
            var stale: [String] = []
            let (_, all) = Shell.run("/sbin/ifconfig", ["-a"])
            var current = ""
            for line in all.components(separatedBy: "\n") {
                if let marker = line.range(of: ": flags=") {
                    current = String(line[..<marker.lowerBound])
                }
                if line.contains("inet 169.254.") {
                    let ip = line.replacingOccurrences(of: "inet ", with: "")
                        .components(separatedBy: " ").first ?? ""
                    stale.append("\(current) \(ip)")
                }
            }
            Task { @MainActor in
                self.ifaces = results
                self.staleLinks = stale
            }
        }
    }

    func testInterfaces() {
        guard !ifaces.isEmpty else { loadInterfaces(); message = "No active interfaces found."; return }
        busy = true
        message = "Testing each connection…"
        let snapshot = ifaces
        DispatchQueue.global(qos: .userInitiated).async {
            var tested: [IfaceResult] = []
            for item in snapshot {
                let (_, out) = Shell.run("/usr/bin/curl", [
                    "--interface", item.ip,
                    "-s", "-o", "/dev/null", "-m", "10",
                    "-w", "%{time_connect} %{speed_download}",
                    "https://speed.cloudflare.com/__down?bytes=2000000"
                ])
                let parts = out.split(separator: " ")
                var result = item
                if parts.count >= 2 {
                    result.latencyMs = (Double(parts[0]) ?? 0) * 1000
                    result.downMbps = (Double(parts[1]) ?? 0) * 8 / 1_000_000
                }
                tested.append(result)
            }
            Task { @MainActor in
                self.ifaces = tested
                self.busy = false
                if let fastest = tested
                    .filter({ $0.downMbps != nil })
                    .max(by: { ($0.downMbps ?? 0) < ($1.downMbps ?? 0) }) {
                    self.message = String(format: "Fastest: %@ — %.1f Mbps", fastest.service, fastest.downMbps ?? 0)
                } else {
                    self.message = "Could not measure any interface."
                }
            }
        }
    }

    // MARK: - Dual link health

    func probeHealth() {
        let snapshot = ifaces.filter { !$0.service.lowercased().contains("tailscale") }
        guard !snapshot.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var results: [String: Double] = [:]
            for item in snapshot {
                let (_, out) = Shell.run("/usr/bin/curl", [
                    "--interface", item.ip, "-s", "-o", "/dev/null", "-m", "4",
                    "-w", "%{time_connect}",
                    "http://connectivitycheck.gstatic.com/generate_204"
                ])
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if let seconds = Double(trimmed), seconds > 0 {
                    results[item.service] = seconds * 1000
                }
            }
            let (_, routeOut) = Shell.run("/sbin/route", ["-n", "get", "default"])
            var activeDevice = ""
            for line in routeOut.components(separatedBy: "\n") where line.contains("interface:") {
                activeDevice = line.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            Task { @MainActor in
                self.health = results
                let primary = snapshot.first { $0.device == activeDevice }?.service ?? snapshot.first?.service
                self.primaryService = primary ?? ""
                if let primary { self.pushSample(results[primary]) }
                self.evaluateAutoSwitch()
            }
        }
    }

    private func evaluateAutoSwitch() {
        guard autoPrefer, ifaces.count >= 2, !primaryService.isEmpty else {
            badTicks = 0
            return
        }
        let others = health.filter { $0.key != primaryService }
        guard let best = others.min(by: { $0.value < $1.value }) else { return }
        let current = health[primaryService]
        let currentIsBad = current.map { $0 > max(80, best.value * 1.8) } ?? true
        guard currentIsBad else {
            badTicks = 0
            return
        }
        badTicks += 1
        guard badTicks >= 2 else { return }
        badTicks = 0
        let ordered = [best.key] + ifaces.map(\.service).filter { $0 != best.key }
        requestOrder(ordered)
        if let current {
            message = String(format: "Auto-switched to %@ (%.0f ms vs %.0f ms)", best.key, best.value, current)
        } else {
            message = "Auto-switched to \(best.key) — primary link stopped responding."
        }
    }

    func preferFastest() {
        guard daemonInstalled else {
            message = "Helper not installed yet — cannot reorder services."
            return
        }
        let ranked = ifaces
            .filter { $0.downMbps != nil }
            .sorted {
                let a = ($0.latencyMs ?? 999) - ($1.latencyMs ?? 999)
                if abs(a) > 5 { return a < 0 }
                return ($0.downMbps ?? 0) > ($1.downMbps ?? 0)
            }
            .map { $0.service }
        guard !ranked.isEmpty else {
            message = "Test the connections first."
            return
        }
        requestOrder(ranked)
        message = "Asked helper to prefer: " + ranked.joined(separator: " → ")
    }
}
