import Charts
import OsinCore
import SwiftUI

/// The signature score ring. Draws in when it appears and follows score changes.
struct HealthRing: View {
    let score: Int?
    let level: HealthLevel?
    var diameter: CGFloat = 120
    var lineWidth: CGFloat = 10
    var showsLabel = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0

    private var target: Double {
        Double(score ?? 0) / 100
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(level?.color ?? Theme.text3, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(score.map(String.init) ?? "–")
                    .font(.system(size: diameter * 0.35, weight: .bold, design: .rounded))
                    .tracking(-1)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(score ?? 0)))
                    .foregroundStyle(Theme.text)
                if showsLabel, let level {
                    Text(level.title)
                        .font(.system(size: max(10, diameter * 0.09), weight: .semibold))
                        .foregroundStyle(level.textColor)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Health score"))
        .accessibilityValue(score.map { Text("\($0) out of 100") } ?? Text("Measuring"))
        .onAppear { animate(to: target, delay: 0.12) }
        .onChange(of: target) { _, value in animate(to: value, delay: 0) }
    }

    private func animate(to value: Double, delay: Double) {
        guard !reduceMotion else {
            progress = value
            return
        }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 1).delay(delay)) { progress = value }
    }
}

/// Line through values, scaled to the given range, oldest on the left.
struct Sparkline: Shape {
    let values: [Double]
    var range: ClosedRange<Double>?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let low = range?.lowerBound ?? (values.min() ?? 0)
        let high = range?.upperBound ?? max(values.max() ?? 1, low + 1)
        let span = max(high - low, .ulpOfOne)
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let y = rect.maxY - CGFloat((min(high, max(low, value)) - low) / span) * rect.height
            let point = CGPoint(x: CGFloat(index) * step, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// Area under a sparkline, for the filled look in metric tiles.
struct SparkArea: Shape {
    let values: [Double]
    var range: ClosedRange<Double>?

    func path(in rect: CGRect) -> Path {
        var path = Sparkline(values: values, range: range).path(in: rect)
        guard values.count > 1 else { return path }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct SparkChart: View {
    let values: [Double]
    let color: Color
    var range: ClosedRange<Double>? = 0 ... 1
    var filled = true

    var body: some View {
        ZStack {
            if filled {
                SparkArea(values: values, range: range).fill(color.opacity(0.16))
            }
            Sparkline(values: values, range: range).stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        .animation(.easeOut(duration: 0.4), value: values)
        .accessibilityHidden(true)
    }
}

/// History chart with an optional second series, threshold bands and a hover readout.
struct TimeSeriesChart: View {
    struct Series {
        let name: LocalizedStringResource
        let color: Color
        let value: (HistoryPoint) -> Double?
    }

    let points: [HistoryPoint]
    let series: [Series]
    var domain: ClosedRange<Double>? = 0 ... 1
    var bands: [(ClosedRange<Double>, Color)] = []
    var format: (Double) -> String = { Format.percent($0) }
    var height: CGFloat = 150
    var filled = true

    @State private var hovered: Date?

    var body: some View {
        Chart {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                RectangleMark(yStart: .value("From", band.0.lowerBound), yEnd: .value("To", band.0.upperBound))
                    .foregroundStyle(band.1.opacity(0.07))
            }
            ForEach(Array(series.enumerated()), id: \.offset) { index, item in
                ForEach(points, id: \.date) { point in
                    if let value = item.value(point) {
                        if filled, index == 0 {
                            AreaMark(x: .value("Time", point.date), y: .value("Value", value), series: .value("Series", index))
                                .foregroundStyle(item.color.opacity(0.16))
                                .interpolationMethod(.monotone)
                        }
                        LineMark(x: .value("Time", point.date), y: .value("Value", value), series: .value("Series", index))
                            .foregroundStyle(item.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            if let hovered, let point = nearest(to: hovered) {
                RuleMark(x: .value("Time", point.date))
                    .foregroundStyle(Theme.borderStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        readout(point)
                    }
            }
        }
        .chartYScale(domain: domain ?? 0 ... (points.flatMap { point in series.compactMap { $0.value(point) } }.max() ?? 1) * 1.15 + 1)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(format(number)).font(.system(size: 10)).foregroundStyle(Theme.text3)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(Theme.text3)
            }
        }
        .chartOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location): hovered = proxy.value(atX: location.x, as: Date.self)
                    case .ended: hovered = nil
                    }
                }
        }
        .frame(height: height)
        .overlay {
            if points.count < 2 {
                Text("Collecting data…").font(.callout).foregroundStyle(Theme.text2)
            }
        }
        .accessibilityLabel(Text("History chart"))
    }

    private func nearest(to date: Date) -> HistoryPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func readout(_ point: HistoryPoint) -> some View {
        HStack(spacing: 8) {
            Text(point.date, format: .dateTime.hour().minute())
                .foregroundStyle(Theme.text2)
            ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                if let value = item.value(point) {
                    Text(format(value)).foregroundStyle(item.color)
                }
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Reload key for history-driven views: the range and the latest sample time.
struct HistoryReloadKey: Hashable {
    let range: SystemMonitor.HistoryRange
    let stamp: Date?
}
