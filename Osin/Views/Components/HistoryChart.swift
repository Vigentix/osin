import Charts
import OsinCore
import SwiftUI

/// Area + line chart of one 0...1 series from metrics history.
struct HistoryChart: View {
    enum Series {
        case cpu
        case memory
        case battery
    }

    let points: [HistoryPoint]
    let series: Series
    let color: Color
    var height: CGFloat = 140

    private var values: [(date: Date, value: Double)] {
        points.compactMap { point in
            switch series {
            case .cpu: (point.date, point.cpu)
            case .memory: (point.date, point.memoryUsed)
            case .battery: point.batteryCharge.map { (point.date, $0) }
            }
        }
    }

    var body: some View {
        Chart(values, id: \.date) { item in
            AreaMark(x: .value("Time", item.date), y: .value("Value", item.value))
                .foregroundStyle(color.opacity(0.18))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", item.date), y: .value("Value", item.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0 ... 1)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 0.5, 1]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Format.percent(number))
                    }
                }
            }
        }
        .frame(height: height)
        .overlay {
            if values.count < 2 {
                Text("Collecting data…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text("History chart"))
    }
}

/// Reload key for history-driven views: the range and the latest sample time.
struct HistoryReloadKey: Hashable {
    let range: SystemMonitor.HistoryRange
    let stamp: Date?
}
