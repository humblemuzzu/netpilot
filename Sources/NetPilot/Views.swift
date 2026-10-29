import SwiftUI

enum PanelTab: String, CaseIterable {
    case status = "Status"
    case dns = "DNS"
    case networks = "Networks"
    case links = "Links"
}

struct Diagnosis {
    let headline: String
    let detail: String
    let color: Color

    @MainActor
    init(_ model: AppModel) {
        let rssi = model.wifi.rssi
        let weakSignal = rssi != 0 && (rssi <= -72 || (model.wifi.snr ?? 99) < 20)
        let routerSlow = (model.gatewayMs ?? 0) > 25 && !weakSignal
        if model.portal.needsSignIn {
            self = Diagnosis("Sign-in needed", "This Wi-Fi wants you to sign in before the internet works.", Theme.fair)
        } else if model.offline {
            let lanUp = model.gatewayMs != nil
            self = Diagnosis("Offline", lanUp ? "Connected to Wi-Fi, but its internet isn't reachable." : "No reply from the network.", Theme.poor)
        } else if model.history.isEmpty {
            self = Diagnosis("Measuring", "Taking the first readings…", .secondary)
        } else if model.losingPackets {
            switch model.lossLayer {
            case .wifi where weakSignal:
                self = Diagnosis("Dropping packets", "Weak signal is losing them. Move closer to the router.", Theme.poor)
            case .wifi:
                self = Diagnosis("Dropping packets", "Between your Mac and the router — the Wi-Fi is congested.", Theme.poor)
            case .upstream:
                self = Diagnosis("Dropping packets", "Your Wi-Fi is fine; this network's internet line is losing them.", Theme.poor)
            case .none:
                self = Diagnosis("Dropping packets", String(format: "About %.0f%% of probes got no reply.", model.loss), Theme.poor)
            }
        } else if model.latency >= Theme.poorMs {
            self = Diagnosis("Slow", routerSlow ? "The router itself is slow to answer — it's overloaded." : "This network's internet is slow right now.", Theme.poor)
        } else if model.jitter > 30 {
            self = Diagnosis("Choppy", routerSlow ? "The router is busy, so delays jump around. Calls may stutter." : "Delays are jumping around. Calls may stutter.", Theme.fair)
        } else if weakSignal {
            self = Diagnosis("Weak signal", "Fine for now, but speed may drop.", Theme.fair)
        } else if model.latency >= Theme.fairMs {
            self = Diagnosis("Good", "Responsive and steady.", Theme.fair)
        } else {
            self = Diagnosis("Excellent", "Fast and steady.", Theme.good)
        }
    }

    private init(_ headline: String, _ detail: String, _ color: Color) {
        self.headline = headline
        self.detail = detail
        self.color = color
    }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: PanelTab = .status
    @State private var hover: Int?

    var body: some View {
        VStack(spacing: 0) {
            hero
            TabBar(selection: $tab) { $0.rawValue }
            Group {
                switch tab {
                case .status: StatusTab()
                case .dns: DNSTab()
                case .networks: NetworksTab()
                case .links: LinksTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.portal.needsSignIn {
                    signInBar
                } else if let target = model.pendingSSID {
                    switchBar(target)
                }
            }
            .animation(.snappy(duration: 0.25), value: model.pendingSSID)
            .animation(.snappy(duration: 0.25), value: model.portal)
            .clipped()
            footer
        }
        .frame(width: 360, height: 600)
    }

    // MARK: - Hero

    private var shown: Double? {
        if let hover, model.history.indices.contains(hover) { return model.history[hover] }
        return model.current ?? model.history.last
    }

    private var readout: String {
        if let hover, model.history.indices.contains(hover) {
            let seconds = (model.history.count - 1 - hover) * 2
            return seconds == 0 ? "now" : "\(seconds)s ago"
        }
        return model.latency > 0 ? String(format: "typical %.0f ms", model.latency) : ""
    }

    private var hero: some View {
        let diagnosis = Diagnosis(model)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if model.network.isPhoneHotspot {
                    Text("Hotspot")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.fair)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.fair.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal, 18)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(shown.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 54, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("ms")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(readout)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 18)
            .padding(.top, 2)
            (Text(diagnosis.headline).font(.system(size: 12.5, weight: .semibold)).foregroundColor(diagnosis.color)
                + Text("  " + diagnosis.detail).font(.system(size: 12.5)).foregroundColor(.secondary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .frame(minHeight: 36, alignment: .topLeading)
            LatencyGraph(values: model.history, hover: $hover)
                .frame(height: 88)
                .padding(.top, 6)
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    // MARK: - Bottom bars

    private var signInBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to \(model.displayName)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text("DNS is on the network's own server so the page can load.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Sign in") { model.openSignIn() }
                .buttonStyle(TextAction())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func switchBar(_ target: String) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Switch to \(target)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(model.switchCountdown > 0
                     ? "Better network · automatic in \(model.switchCountdown)s"
                     : "Better network · waiting for the link to idle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Cancel") { model.cancelPending() }
                .buttonStyle(TextAction(tint: .secondary))
            Button("Switch") { model.switchNow() }
                .buttonStyle(TextAction())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let note = model.visibleMessage, !model.roamrMissing {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(2)
                    .help(note)
            } else {
                Text(model.daemonInstalled ? "Helper running" : "Helper not installed")
                    .font(.system(size: 11))
                    .foregroundStyle(model.daemonInstalled ? Color.secondary : Theme.fair)
            }
            Spacer(minLength: 8)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(TextAction(tint: .secondary))
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .overlay(alignment: .top) { Hairline() }
        .animation(.snappy(duration: 0.2), value: model.visibleMessage)
    }
}

// MARK: - Status

struct StatusTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var dns: SmartDNS

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Metric(
                        label: "Signal",
                        value: model.wifi.rssi == 0 ? "—" : "\(model.wifi.rssi)",
                        unit: model.wifi.rssi == 0 ? "" : "dBm",
                        tint: model.wifi.rssi != 0 && model.wifi.rssi < -65 ? Theme.signal(model.wifi.rssi) : .primary
                    )
                    Metric(
                        label: "Loss",
                        value: lossText,
                        unit: "%",
                        tint: model.losingPackets ? Theme.poor : .primary
                    )
                    Metric(
                        label: "Jitter",
                        value: String(format: "%.0f", model.jitter),
                        unit: "ms",
                        tint: model.jitter < 10 ? .primary : (model.jitter < 30 ? Theme.fair : Theme.poor)
                    )
                    Metric(
                        label: "Router",
                        value: model.gatewayMs.map { String(format: "%.0f", $0) } ?? "—",
                        unit: model.gatewayMs == nil ? "" : "ms",
                        tint: (model.gatewayMs ?? 0) > 25 ? Theme.fair : .primary
                    )
                }
                .padding(.top, 16)
                .padding(.bottom, 8)

                Text(linkLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(activity)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .padding(.bottom, 12)

                Hairline()
                SettingRow(
                    title: "Smart DNS",
                    subtitle: dns.enabled ? dns.headline : "Off — using the network's own DNS",
                    isOn: Binding(get: { dns.enabled }, set: { dns.enabled = $0 })
                )
                Hairline()
                SettingRow(
                    title: "Stutter fix",
                    subtitle: stutterDetail,
                    isOn: Binding(get: { model.awdlOff }, set: { _ in model.toggleAWDL() }),
                    disabled: !model.daemonInstalled
                )
                Hairline()
                SettingRow(
                    title: "Switch networks automatically",
                    subtitle: "Move to a better saved network when the link is idle",
                    isOn: Binding(get: { model.autoNetwork }, set: { model.autoNetwork = $0 })
                )
                if model.ifaces.count > 1 {
                    Hairline()
                    SettingRow(
                        title: "Fail over between links",
                        subtitle: "Use the faster link when the main one degrades",
                        isOn: Binding(get: { model.autoPrefer }, set: { model.autoPrefer = $0 })
                    )
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
    }

    private var lossText: String {
        if model.loss == 0 { return "0" }
        return model.loss < 1 ? "<1" : String(format: "%.0f", model.loss)
    }

    private var linkLine: String {
        var parts: [String] = []
        let wifi = model.wifi
        if !wifi.band.isEmpty { parts.append("\(wifi.band) · ch \(wifi.channel)") }
        if wifi.txRate > 0 { parts.append("\(wifi.txRate) Mbps") }
        if let snr = wifi.snr { parts.append("SNR \(snr) dB") }
        if let left = model.portalSession?.secondsRemaining {
            parts.append(left >= 3600 ? "session \(left / 3600)h \((left % 3600) / 60)m left" : "session \(left / 60)m left")
        }
        if model.network.isPhoneHotspot { parts.append("metered") }
        return parts.isEmpty ? model.network.serviceName : parts.joined(separator: " · ")
    }

    private var activity: String {
        let rate = model.bytesPerSec
        let speed: String
        if rate >= 1_000_000 { speed = String(format: "%.1f MB/s", rate / 1_000_000) }
        else if rate >= 1_000 { speed = String(format: "%.0f KB/s", rate / 1_000) }
        else { speed = "idle" }
        let count = model.activeConnections
        return "\(speed) · \(count) open connection\(count == 1 ? "" : "s")"
    }

    private var stutterDetail: String {
        if !model.daemonInstalled { return "Install the helper to enable" }
        return model.awdlOff ? "On. AirDrop and Handoff are paused." : "Off. AirDrop works, latency may spike."
    }
}

// MARK: - DNS

struct DNSTab: View {
    @EnvironmentObject var dns: SmartDNS

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dns.enabled ? dns.headline : "Smart DNS is off")
                        .font(.system(size: 13, weight: .medium))
                    if !dns.detail.isEmpty {
                        Text(dns.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !dns.inEffect.isEmpty {
                        Text(dns.inEffect.joined(separator: "  ·  "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 14)

                if !dns.results.isEmpty {
                    Hairline()
                    HStack {
                        Text("Server").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Typical").frame(width: 64, alignment: .trailing)
                        Text("Missed").frame(width: 56, alignment: .trailing)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    ForEach(dns.results) { result in
                        row(result)
                    }
                }

                Hairline().padding(.top, 4)
                HStack(spacing: 18) {
                    if dns.userOverride {
                        Button("Let Smart DNS manage") { dns.takeOver() }
                            .buttonStyle(TextAction())
                            .disabled(!dns.enabled)
                    } else {
                        Button("Test again") { dns.retest() }
                            .buttonStyle(TextAction())
                            .disabled(!dns.enabled || dns.testing)
                    }
                    Spacer()
                    if dns.testing {
                        ProgressView().controlSize(.small)
                    } else if let at = dns.testedAt {
                        Text("Tested \(at.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ result: ResolverResult) -> some View {
        let active = dns.inEffect.first.map { result.option.addresses.contains($0) } ?? false
        let backup = dns.inEffect.dropFirst().contains { result.option.addresses.contains($0) }
        return HStack {
            HStack(spacing: 6) {
                Text(result.option.name)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                if active {
                    Text("in use").font(.system(size: 10)).foregroundStyle(Theme.good)
                } else if backup {
                    Text("backup").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(result.answered == 0 ? "—" : String(format: "%.0f ms", result.median))
                .frame(width: 64, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(Theme.latency(result.median))
            Text("\(result.failed)/\(result.answered + result.failed)")
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(result.failed == 0 ? Color.secondary : (result.failureRate > 0.1 ? Theme.poor : Theme.fair))
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 6)
    }
}

// MARK: - Networks

struct NetworksTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.roamrMissing {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("roamr is not installed")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.fair)
                        Text("brew install --cask sourabh-khot65/tap/roamr")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    Hairline()
                }
                ForEach(Array(model.nets.enumerated()), id: \.element.id) { index, net in
                    if index > 0 { Hairline() }
                    row(net)
                }
                if model.nets.isEmpty && !model.roamrMissing {
                    Text("Scanning for networks…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ net: RankedNet) -> some View {
        HStack(spacing: 12) {
            SignalBars(level: net.signalPct)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(net.ssid)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(net))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if net.current {
                Text("Connected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("Join") { model.join(net.ssid) }
                    .buttonStyle(TextAction())
                    .disabled(model.busy)
            }
        }
        .padding(.vertical, 11)
    }

    private func subtitle(_ net: RankedNet) -> String {
        var parts: [String] = []
        if !net.band.isEmpty { parts.append(bandLabel(net.band)) }
        if let reason = net.reasons.first { parts.append(reason) }
        return parts.isEmpty ? "Score \(net.score)" : parts.joined(separator: " · ")
    }

    private func bandLabel(_ band: String) -> String {
        switch band {
        case "6GHz": return "6 GHz"
        case "5GHz": return "5 GHz"
        case "2.4GHz": return "2.4 GHz"
        default: return band
        }
    }
}

// MARK: - Links

struct LinksTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.ifaces.enumerated()), id: \.element.id) { index, iface in
                    if index > 0 { Hairline() }
                    row(iface)
                }
                if model.ifaces.isEmpty {
                    Text("Looking for active connections…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
                ForEach(model.staleLinks, id: \.self) { link in
                    Text("\(link) has no IP. Check the cable and the Trust prompt.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.fair)
                        .padding(.top, 10)
                }
                if !model.ifaces.isEmpty {
                    Hairline().padding(.top, 4)
                    HStack(spacing: 18) {
                        Button("Test speeds") { model.testInterfaces() }
                            .buttonStyle(TextAction())
                        Button("Prefer fastest") { model.preferFastest() }
                            .buttonStyle(TextAction())
                        Spacer()
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                    .disabled(model.busy)
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ iface: IfaceResult) -> some View {
        let ms = model.health[iface.service]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(iface.service)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if iface.service == model.primaryService {
                        Text("Primary")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(iface.device) · \(iface.ip)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let ms {
                    Text("\(Int(ms)) ms")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ms < Theme.fairMs ? Color.primary : Theme.latency(ms))
                } else {
                    Text("—").font(.system(size: 15)).foregroundStyle(.tertiary)
                }
                if let mbps = iface.downMbps {
                    Text(String(format: "%.1f Mbps", mbps))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 11)
    }
}
