import SwiftUI

/// A compact metric card: label, big value, detail line and either a sparkline or a bar.
struct MetricTile<Value: View>: View {
    enum Trend {
        case sparkline([Double], Color)
        case bar(Double, Color)
        case none
    }

    let title: LocalizedStringKey
    let systemImage: String
    let detail: String
    let trend: Trend
    var highlight: Color?
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            value
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            trendView
                .frame(height: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if let highlight {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(highlight.opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trendView: some View {
        switch trend {
        case let .sparkline(values, color):
            Sparkline(values: values)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        case let .bar(fraction, color):
            VStack {
                Spacer(minLength: 0)
                UsageBar(fraction: fraction, color: color)
            }
        case .none:
            Color.clear
        }
    }
}

/// Line through values in 0...1, oldest on the left.
struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let clamped = CGFloat(min(1, max(0, value)))
            let point = CGPoint(x: CGFloat(index) * step, y: rect.maxY - clamped * rect.height)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}
