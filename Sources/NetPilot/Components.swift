import SwiftUI

enum Theme {
    static let good = Color(red: 0.25, green: 0.80, blue: 0.50)
    static let fair = Color(red: 1.00, green: 0.74, blue: 0.25)
    static let poor = Color(red: 1.00, green: 0.38, blue: 0.34)

    static let fairMs = 40.0
    static let poorMs = 100.0

    static func latency(_ ms: Double) -> Color {
        if ms <= 0 { return .secondary }
        if ms < fairMs { return good }
        if ms < poorMs { return fair }
        return poor
    }

    static func signal(_ dbm: Int) -> Color {
        if dbm == 0 { return .secondary }
        if dbm >= -65 { return good }
        if dbm >= -75 { return fair }
        return poor
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.5)
    }
}

struct LatencyGraph: View {
    let values: [Double]
    @Binding var hover: Int?

    private let trailingInset: CGFloat = 10
    private let topInset: CGFloat = 12
    private let bottomInset: CGFloat = 6

    private var ceiling: Double { max(120, (values.max() ?? 0) * 1.15) }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = index(at: point.x, width: geo.size.width)
                case .ended: hover = nil
                }
            }
        }
        .overlay {
            if values.isEmpty {
                Text("Measuring…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.smooth(duration: 0.35), value: values)
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        guard values.count > 1 else { return nil }
        let span = max(1, width - trailingInset)
        let raw = Int((x / span * CGFloat(values.count - 1)).rounded())
        return min(max(raw, 0), values.count - 1)
    }

    private func point(_ i: Int, _ value: Double, size: CGSize) -> CGPoint {
        let span = size.width - trailingInset
        let x = values.count > 1 ? span * CGFloat(i) / CGFloat(values.count - 1) : span
        let usable = size.height - topInset - bottomInset
        let y = size.height - bottomInset - CGFloat(value / ceiling) * usable
        return CGPoint(x: x, y: y)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let yPoor = point(0, Theme.poorMs, size: size).y
        let yFair = point(0, Theme.fairMs, size: size).y

        var guide = Path()
        guide.move(to: CGPoint(x: 0, y: yPoor))
        guide.addLine(to: CGPoint(x: size.width, y: yPoor))
        context.stroke(guide, with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        context.draw(
            Text("100 ms").font(.system(size: 9, weight: .medium)).foregroundColor(.primary.opacity(0.35)),
            at: CGPoint(x: 16, y: yPoor - 7), anchor: .leading
        )

        guard !values.isEmpty else { return }
        let points = values.enumerated().map { point($0.offset, $0.element, size: size) }

        let h = size.height
        let mid = (yPoor + yFair) / 2
        let stops: [(Color, CGFloat)] = [
            (Theme.poor, 0), (Theme.poor, yPoor / h), (Theme.fair, mid / h), (Theme.good, yFair / h), (Theme.good, 1)
        ]
        let line = Gradient(stops: stops.map { .init(color: $0.0, location: $0.1) })
        let fade = Gradient(stops: [
            .init(color: Theme.poor.opacity(0.28), location: 0),
            .init(color: Theme.poor.opacity(0.18), location: yPoor / h),
            .init(color: Theme.fair.opacity(0.10), location: mid / h),
            .init(color: Theme.good.opacity(0.05), location: yFair / h),
            .init(color: Theme.good.opacity(0.0), location: 1)
        ])
        let down = (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: h))

        if points.count > 1 {
            let stroke = Self.smooth(points)
            var area = stroke
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: h))
            area.addLine(to: CGPoint(x: points[0].x, y: h))
            area.closeSubpath()
            context.drawLayer { layer in
                layer.clip(to: area)
                layer.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(fade, startPoint: down.0, endPoint: down.1))
            }
            context.stroke(
                stroke,
                with: .linearGradient(line, startPoint: down.0, endPoint: down.1),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }

        let focus = hover ?? (points.count - 1)
        guard points.indices.contains(focus) else { return }
        let p = points[focus]
        let color = Theme.latency(values[focus])
        if hover != nil {
            var rule = Path()
            rule.move(to: CGPoint(x: p.x, y: 0))
            rule.addLine(to: CGPoint(x: p.x, y: h))
            context.stroke(rule, with: .color(.primary.opacity(0.18)), lineWidth: 0.5)
        }
        context.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(color.opacity(0.22)))
        context.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(color))
    }

    static func smooth(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        let n = pts.count
        guard n > 1 else { return path }
        var slope = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<n - 1 { slope[i] = (pts[i + 1].y - pts[i].y) / (pts[i + 1].x - pts[i].x) }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = slope[0]
        m[n - 1] = slope[n - 2]
        if n > 2 {
            for i in 1..<n - 1 {
                m[i] = slope[i - 1] * slope[i] <= 0 ? 0 : (slope[i - 1] + slope[i]) / 2
            }
        }
        for i in 0..<n - 1 {
            if slope[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / slope[i]
            let b = m[i + 1] / slope[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * slope[i]
                m[i + 1] = t * b * slope[i]
            }
        }
        for i in 0..<n - 1 {
            let dx = (pts[i + 1].x - pts[i].x) / 3
            path.addCurve(
                to: pts[i + 1],
                control1: CGPoint(x: pts[i].x + dx, y: pts[i].y + m[i] * dx),
                control2: CGPoint(x: pts[i + 1].x - dx, y: pts[i + 1].y - m[i + 1] * dx)
            )
        }
        return path
    }
}

struct SignalBars: View {
    let level: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(level >= (index + 1) * 25 - 12 ? Color.primary.opacity(0.85) : Color.primary.opacity(0.2))
                    .frame(width: 3, height: 5 + CGFloat(index) * 3)
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}

struct Metric: View {
    let label: String
    let value: String
    var unit: String = ""
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(disabled)
        }
        .padding(.vertical, 10)
    }
}

struct TextAction: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

struct TabBar<Tab: Hashable & CaseIterable>: View where Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    let title: (Tab) -> String
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 20) {
            ForEach(Array(Tab.allCases), id: \.self) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = tab }
                } label: {
                    Text(title(tab))
                        .font(.system(size: 12.5, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            if selection == tab {
                                Rectangle()
                                    .fill(Color.primary)
                                    .frame(height: 1.5)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .background(alignment: .bottom) { Hairline() }
    }
}
