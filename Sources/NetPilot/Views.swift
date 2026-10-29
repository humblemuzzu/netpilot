import SwiftUI

enum PanelTab: String, CaseIterable {
    case status = "Status"
    case networks = "Networks"
    case links = "Links"
}

struct Diagnosis {
    let headline: String
    let detail: String
    let color: Color

    @MainActor
    init(_ model: AppModel) {
        let weakSignal = model.rssi != 0 && model.rssi <= -75
        let latest = model.history.last ?? 0
        if model.loss >= 100 {
            self = Diagnosis("Offline", "No reply from the internet.", Theme.poor)
        } else if model.history.isEmpty {
            self = Diagnosis("Measuring", "Taking the first readings…", .secondary)
        } else if weakSignal && (model.loss >= 3 || model.jitter > 30 || latest >= Theme.poorMs) {
            self = Diagnosis("Unstable", "Weak signal is the likely cause. Move closer to the router.", Theme.poor)
        } else if model.loss >= 5 {
            self = Diagnosis("Dropping packets", String(format: "%.0f%% of recent probes got no reply.", model.loss), Theme.poor)
        } else if latest >= Theme.poorMs {
            self = Diagnosis("Slow", "Latency is high right now.", Theme.poor)
        } else if model.jitter > 30 {
            self = Diagnosis("Choppy", "Latency is jumping around. Calls may stutter.", Theme.fair)
        } else if weakSignal {
            self = Diagnosis("Weak signal", "Fine for now, but speed may drop.", Theme.fair)
        } else if latest >= Theme.fairMs {
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
                case .networks: NetworksTab()
                case .links: LinksTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let target = model.pendingSSID { switchBar(target) }
            }
            .animation(.snappy(duration: 0.25), value: model.pendingSSID)
            .clipped()
            footer
        }
        .frame(width: 360, height: 580)
    }

    // MARK: - Hero

    private var shown: Double? {
        if let hover, model.history.indices.contains(hover) { return model.history[hover] }
        return model.history.last
    }

    private var readout: String {
        if let hover, model.history.indices.contains(hover) {
            let seconds = (model.history.count - 1 - hover) * 4
            return seconds == 0 ? "now" : "\(seconds)s ago"
        }
        return model.latency > 0 ? String(format: "avg %.0f ms", model.latency) : ""
    }

    private var hero: some View {
        let diagnosis = Diagnosis(model)
        return VStack(alignment: .leading, spacing: 0) {
            Text(model.currentSSID)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 18)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(shown.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 54, weight: .medium, design: .rounded))
                    .monospacedDigit()
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

    // MARK: - Switch prompt

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Metric(
                        label: "Signal",
                        value: model.rssi == 0 ? "—" : "\(model.rssi)",
                        unit: model.rssi == 0 ? "" : "dBm",
                        tint: model.rssi != 0 && model.rssi < -65 ? Theme.signal(model.rssi) : .primary
                    )
                    Metric(
                        label: "Loss",
                        value: String(format: "%.0f", model.loss),
                        unit: "%",
                        tint: model.loss < 1 ? .primary : (model.loss < 5 ? Theme.fair : Theme.poor)
                    )
                    Metric(
                        label: "Jitter",
                        value: String(format: "%.0f", model.jitter),
                        unit: "ms",
                        tint: model.jitter < 10 ? .primary : (model.jitter < 30 ? Theme.fair : Theme.poor)
                    )
                    Metric(
                        label: "Link",
                        value: model.linkRate == 0 ? "—" : "\(model.linkRate)",
                        unit: model.linkRate == 0 ? "" : "Mbps"
                    )
                }
                .padding(.top, 16)
                .padding(.bottom, 10)

                Text(activity)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 12)

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
                    subtitle: "Move to a better network when the link is idle",
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
