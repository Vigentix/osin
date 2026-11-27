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
    /// Draw in from empty when first shown (false: appear already filled).
    var animatesIn = true

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
                    .rollingNumber(Double(score ?? 0))
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
        .onAppear {
            if animatesIn {
                animate(to: target, delay: 0.12)
            } else {
                progress = target
            }
        }
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
        // No animation: new samples arrive every 2 s, and animating each one kept SwiftUI re-laying out
        // the whole page most of the time.
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
    /// Changes when a new set of data arrives (e.g. another range): the lines then draw in from
    /// the left. Regular reloads of the same range just update in place.
    var revealKey: AnyHashable = 0
    let series: [Series]
    var domain: ClosedRange<Double>? = 0 ... 1
    var bands: [(ClosedRange<Double>, Color)] = []
    var format: (Double) -> String = { Format.percent($0) }
    var height: CGFloat = 150
    var filled = true

    @State private var hovered: Date?
    /// The data set last drawn in; a new value gives the mask a new identity, which draws in from zero.
    @State private var revealedKey: AnyHashable?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One plotted value. Flattened up front so the chart builder stays simple for the type checker.
    private struct Sample: Identifiable {
        let id: Int
        let date: Date
        let value: Double
        let series: Int
    }

    private var samples: [Sample] {
        var result: [Sample] = []
        for (index, item) in series.enumerated() {
            for point in points {
                if let value = item.value(point) {
                    result.append(Sample(id: result.count, date: point.date, value: value, series: index))
                }
            }
        }
        return result
    }

    private var yDomain: ClosedRange<Double> {
        if let domain {
            return domain
        }
        let peak = samples.map(\.value).max() ?? 1
        return 0 ... peak * 1.15 + 1
    }

    @ChartContentBuilder private func bandMarks() -> some ChartContent {
        ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
            RectangleMark(yStart: .value("From", band.0.lowerBound), yEnd: .value("To", band.0.upperBound))
                .foregroundStyle(band.1.opacity(0.07))
        }
    }

    @ChartContentBuilder private func areaMarks(_ data: [Sample]) -> some ChartContent {
        ForEach(data.filter { $0.series == 0 }) { sample in
            AreaMark(x: .value("Time", sample.date), y: .value("Value", sample.value), series: .value("Series", sample.series))
                .foregroundStyle(series[0].color.opacity(0.16))
                .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder private func lineMarks(_ data: [Sample]) -> some ChartContent {
        ForEach(data) { sample in
            LineMark(x: .value("Time", sample.date), y: .value("Value", sample.value), series: .value("Series", sample.series))
                .foregroundStyle(series[sample.series].color)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder private func hoverMark() -> some ChartContent {
        if let hovered, let point = nearest(to: hovered) {
            RuleMark(x: .value("Time", point.date))
                .foregroundStyle(Theme.borderStrong)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                    readout(point)
                }
        }
    }

    private var chart: some View {
        let data = samples
        return Chart {
            bandMarks()
            if filled {
                areaMarks(data)
            }
            lineMarks(data)
            hoverMark()
        }
    }

    var body: some View {
        chart
            .chartYScale(domain: yDomain)
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
            .chartPlotStyle { plot in
                plot.mask(alignment: .leading) {
                    RevealMask(animated: !reduceMotion).id(revealedKey)
                }
            }
            .frame(height: height)
            .overlay {
                if points.count < 2 {
                    Text("Collecting data…").font(.callout).foregroundStyle(Theme.text2)
                }
            }
            .accessibilityLabel(Text("History chart"))
            .onAppear(perform: revealIfNeeded)
            .onChange(of: revealKey) { _, _ in revealIfNeeded() }
            .onChange(of: points.count >= 2) { _, _ in revealIfNeeded() }
    }

    /// Draws the lines in once per data set, when there is something to draw.
    private func revealIfNeeded() {
        guard points.count >= 2, revealedKey != revealKey else { return }
        revealedKey = revealKey
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

/// A mask that grows from the left edge to full width when it appears (instantly with Reduce Motion).
private struct RevealMask: View {
    let animated: Bool
    @State private var fraction: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Rectangle().frame(width: proxy.size.width * fraction)
        }
        .onAppear {
            guard animated else {
                fraction = 1
                return
            }
            withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.6)) { fraction = 1 }
        }
    }
}
