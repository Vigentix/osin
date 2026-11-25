import AppKit
import OsinCore
import SwiftUI

// MARK: - Containers

/// Rounded surface with a hairline border.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = Theme.cardRadius
    var borderColor: Color = Theme.border
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(borderColor, lineWidth: 1))
    }
}

/// Small uppercase label above a group.
struct SectionLabel: View {
    let text: LocalizedStringKey
    var color: Color = Theme.text2

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }
}

/// Large page title with a supporting line, used at the top of each section.
struct PageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: String?) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Buttons and hover

/// Hover timing shared by every interactive element: quick in, softer out.
enum HoverMotion {
    static func animation(entering: Bool) -> Animation {
        .easeOut(duration: entering ? 0.12 : 0.2)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, large: large)
    }

    private struct PrimaryBody: View {
        let configuration: Configuration
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let radius: CGFloat = large ? 11 : 9
            let active = hovering && isEnabled
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 22 : 14)
                .frame(minHeight: large ? 44 : 32)
                .background(Theme.accentButton, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(configuration.isPressed ? Color.black.opacity(0.12) : Color.white.opacity(active ? 0.10 : 0))
                )
                .shadow(color: Theme.accent.opacity(active ? 0.35 : 0), radius: active ? 10 : 0, y: active ? 3 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(.spring(duration: 0.18), value: configuration.isPressed)
                .contentShape(Rectangle())
                .onHover { inside in
                    withAnimation(HoverMotion.animation(entering: inside)) { hovering = inside }
                }
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var large = false
    var tint: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, large: large, tint: tint)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        let large: Bool
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let radius: CGFloat = large ? 9 : 7
            let active = hovering && isEnabled
            configuration.label
                .font(.system(size: large ? 13 : 12, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, large ? 16 : 11)
                .frame(minHeight: large ? 34 : 28)
                .background(
                    configuration.isPressed ? Theme.control : (active ? Theme.hover : Color.clear),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(active ? Theme.borderHover : Theme.borderStrong, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(.spring(duration: 0.18), value: configuration.isPressed)
                .contentShape(Rectangle())
                .onHover { inside in
                    withAnimation(HoverMotion.animation(entering: inside)) { hovering = inside }
                }
        }
    }
}

/// For rows and tiles that act as one big button: hover lightens the surface, selection outlines it.
struct HoverSurface: ViewModifier {
    var radius: CGFloat = 9
    var selected = false
    var restingFill: Color = .clear
    @Binding var hovering: Bool

    func body(content: Content) -> some View {
        content
            .background(
                selected ? Theme.raised : (hovering ? Theme.hover : restingFill),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.55) : (hovering ? Theme.border : .clear), lineWidth: 1)
            )
            .onHover { inside in
                withAnimation(HoverMotion.animation(entering: inside)) { hovering = inside }
            }
    }
}

extension View {
    func hoverSurface(radius: CGFloat = 9, selected: Bool = false, restingFill: Color = .clear, hovering: Binding<Bool>) -> some View {
        modifier(HoverSurface(radius: radius, selected: selected, restingFill: restingFill, hovering: hovering))
    }
}

/// Button style for whole-row buttons: no chrome of its own, a slight dip when pressed.
struct RowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.995 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Borderless button for quiet actions (footers, toolbars): text or icon that lifts on hover.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration)
    }

    private struct GhostBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.text2)
                .padding(.horizontal, 8)
                .frame(minWidth: 28, minHeight: 28)
                .background(
                    configuration.isPressed ? Theme.control : (hovering ? Theme.hover : .clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { inside in
                    withAnimation(HoverMotion.animation(entering: inside)) { hovering = inside }
                }
        }
    }
}

/// A whole row (or tile) that acts as one button, with hover and selection states.
/// The label receives `hovering` so it can reveal secondary actions on hover.
struct HoverRowButton<Label: View>: View {
    var radius: CGFloat = 9
    var selected = false
    var restingFill: Color = .clear
    let action: () -> Void
    @ViewBuilder let label: (_ hovering: Bool) -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label(hovering).contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .hoverSurface(radius: radius, selected: selected, restingFill: restingFill, hovering: $hovering)
    }
}

/// A row that is not itself a button but contains actions; hover lightens it and lets it reveal them.
struct HoverRow<Content: View>: View {
    var radius: CGFloat = 8
    @ViewBuilder let content: (_ hovering: Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).hoverSurface(radius: radius, hovering: $hovering)
    }
}

/// Segmented control matching the mockups.
struct SegmentedPicker<Value: Hashable>: View {
    let options: [(Value, LocalizedStringResource)]
    @Binding var selection: Value
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.0 == selection
                let hovering = hovered == index && !selected
                Button {
                    withAnimation(.spring(duration: 0.22)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected || hovering ? Theme.text : Theme.text2)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            selected ? Theme.control : (hovering ? Theme.hover : .clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .onHover { inside in
                    withAnimation(HoverMotion.animation(entering: inside)) { hovered = inside ? index : (hovered == index ? nil : hovered) }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Small pieces

struct KeyHint: View {
    let keys: String

    var body: some View {
        Text(verbatim: keys)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.text3)
            .accessibilityHidden(true)
    }
}

struct Badge: View {
    let text: LocalizedStringKey
    let color: Color
    var background: Color?

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background ?? color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Soft square holding an SF Symbol, used on recommendation cards.
struct IconTile: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Pulsing dot that marks live data.
struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.good)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// Rounded fill bar for 0...1 values.
struct UsageBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.5), value: fraction)
        .accessibilityElement()
        .accessibilityValue(Text(Format.percent(fraction)))
    }
}

/// Horizontal bar split into weighted segments.
struct StackedBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
        var hatched = false
    }

    let segments: [Segment]
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let total = max(segments.reduce(0) { $0 + $1.value }, 1)
            let gaps = CGFloat(max(segments.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color.opacity(segment.hatched ? 0.55 : 1))
                        .overlay {
                            if segment.hatched {
                                Hatch().stroke(segment.color, lineWidth: 1.5)
                            }
                        }
                        .clipped()
                        .frame(width: max(2, (proxy.size.width - gaps) * segment.value / total))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }

    private struct Hatch: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            var x = -rect.height
            while x < rect.width {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 5
            }
            return path
        }
    }
}

/// Coloured legend row: swatch, label, value.
struct LegendRow: View {
    let color: Color
    let label: LocalizedStringKey
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(Theme.text2)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(valueColor)
        }
        .font(.system(size: 12))
    }
}

/// App icon from the bundle, or a lettered tile for processes without one.
struct AppAvatar: View {
    let name: String
    let bundlePath: String?
    var size: CGFloat = 26

    var body: some View {
        if let bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Theme.text2)
                .frame(width: size, height: size)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Brand

/// The Osin mark: a ring with a gap at the top right and a status dot inside the gap.
struct LogoMark: View {
    var size: CGFloat = 22
    var ring: Color = Theme.accent
    var dot: Color? = Theme.good

    var body: some View {
        let line = size * 0.13
        let radius = (size - line) / 2 * 0.82
        ZStack {
            Circle()
                .trim(from: 0, to: 0.82)
                .stroke(ring, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.degrees(-12.5))
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: size * 0.17, height: size * 0.17)
                    .offset(x: radius * 0.707, y: -radius * 0.707)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
