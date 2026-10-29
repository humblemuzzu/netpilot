import CoreWLAN
import Foundation

struct Tick {
    var internet: [Double?]
    var gateway: Double?
}

struct WiFiReading: Equatable {
    var rssi = 0
    var noise = 0
    var txRate = 0
    var channel = 0
    var band = ""

    var snr: Int? { rssi != 0 && noise != 0 ? rssi - noise : nil }

    nonisolated static func read() -> WiFiReading {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else { return WiFiReading() }
        var reading = WiFiReading(rssi: iface.rssiValue(), noise: iface.noiseMeasurement(), txRate: Int(iface.transmitRate()))
        if let channel = iface.wlanChannel() {
            reading.channel = channel.channelNumber
            switch channel.channelBand {
            case .band2GHz: reading.band = "2.4 GHz"
            case .band5GHz: reading.band = "5 GHz"
            case .band6GHz: reading.band = "6 GHz"
            default: reading.band = ""
            }
        }
        return reading
    }
}

enum Layer: Equatable {
    case none
    case wifi
    case upstream
}

/// Rolling link statistics. Loss is only claimed when the evidence is strong enough: a 95% Wilson
/// lower bound of at least 2%, so two unlucky probes in a short window never turn the panel red.
struct LinkStats {
    static let window = 90

    private(set) var ticks: [Tick] = []
    private(set) var jitter: Double = 0
    private var lastRTT: Double?

    mutating func reset() {
        ticks = []
        jitter = 0
        lastRTT = nil
    }

    mutating func add(_ tick: Tick) {
        ticks.append(tick)
        if ticks.count > Self.window { ticks.removeFirst(ticks.count - Self.window) }
        if let rtt = best(tick) {
            if let lastRTT { jitter += (abs(rtt - lastRTT) - jitter) / 16 }
            lastRTT = rtt
        }
    }

    private func best(_ tick: Tick) -> Double? { tick.internet.compactMap { $0 }.min() }

    var history: [Double] { ticks.compactMap(best) }
    var latest: Double? { ticks.last.flatMap(best) }

    var median: Double {
        let recent = history.suffix(30).sorted()
        return recent.isEmpty ? 0 : recent[recent.count / 2]
    }

    var offline: Bool {
        let recent = ticks.suffix(3)
        return recent.count == 3 && recent.allSatisfy { best($0) == nil }
    }

    /// Targets that fail nearly always while another target works are that target's problem, not the link's.
    private var usableTargets: [Int] {
        guard let width = ticks.last?.internet.count else { return [] }
        let recent = ticks.suffix(15)
        let rates = (0..<width).map { target -> Double in
            let values = recent.compactMap { $0.internet.indices.contains(target) ? $0.internet[target] : nil as Double?? }
            let failures = values.filter { $0 == nil }.count
            return Double(failures) / Double(max(1, values.count))
        }
        let healthiest = rates.min() ?? 0
        return rates.indices.filter { rates[$0] < 0.8 || healthiest > 0.3 }
    }

    var internetCounts: (failed: Int, total: Int) {
        let targets = usableTargets
        var failed = 0
        var total = 0
        for tick in ticks {
            for target in targets where tick.internet.indices.contains(target) {
                total += 1
                if tick.internet[target] == nil { failed += 1 }
            }
        }
        return (failed, total)
    }

    var gatewayCounts: (failed: Int, total: Int) {
        let answered = ticks.filter { $0.gateway != nil }.count
        guard answered > 0 else { return (0, 0) }
        return (ticks.count - answered, ticks.count)
    }

    var loss: Double {
        let counts = internetCounts
        return counts.total == 0 ? 0 : Double(counts.failed) / Double(counts.total) * 100
    }

    var gatewayLoss: Double? {
        let counts = gatewayCounts
        return counts.total == 0 ? nil : Double(counts.failed) / Double(counts.total) * 100
    }

    var gatewayMedian: Double? {
        let values = ticks.suffix(30).compactMap(\.gateway).sorted()
        return values.isEmpty ? nil : values[values.count / 2]
    }

    static func wilsonLower(_ failed: Int, _ total: Int) -> Double {
        guard total > 0 else { return 0 }
        let z = 1.96, n = Double(total), p = Double(failed) / n
        let centre = p + z * z / (2 * n)
        let margin = z * ((p * (1 - p) + z * z / (4 * n)) / n).squareRoot()
        return max(0, (centre - margin) / (1 + z * z / n))
    }

    var losingPackets: Bool {
        let counts = internetCounts
        return counts.failed >= 3 && Self.wilsonLower(counts.failed, counts.total) >= 0.02
    }

    var gatewayLosing: Bool {
        let counts = gatewayCounts
        return counts.failed >= 3 && Self.wilsonLower(counts.failed, counts.total) >= 0.02
    }

    var lossLayer: Layer {
        guard losingPackets else { return .none }
        guard gatewayCounts.total > 0 else { return .none }
        return gatewayLosing ? .wifi : .upstream
    }
}
