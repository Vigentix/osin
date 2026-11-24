import SwiftUI

/// Rounded fill bar for 0...1 values. Unlike `ProgressView`, it keeps its colour in inactive windows.
struct UsageBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    private var clamped: Double {
        min(1, max(0, fraction))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(Format.percent(clamped)))
    }
}
