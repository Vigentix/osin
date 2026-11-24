import OsinCore
import SwiftUI

/// The signature score ring. Animates in when it appears, unless Reduce Motion is on.
struct HealthRing: View {
    let score: Int?
    let level: HealthLevel?
    var diameter: CGFloat = 84
    var lineWidth: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0

    private var target: Double {
        Double(score ?? 0) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(level?.color ?? .secondary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "–")
                    .font(.system(size: diameter * 0.31, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("/ 100")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Health score"))
        .accessibilityValue(score.map { Text("\($0) out of 100") } ?? Text("Measuring"))
        .onAppear { animate(to: target, delay: 0.12) }
        .onChange(of: target) { _, newValue in animate(to: newValue, delay: 0) }
    }

    private func animate(to value: Double, delay: Double) {
        guard !reduceMotion else {
            progress = value
            return
        }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.9).delay(delay)) {
            progress = value
        }
    }
}
