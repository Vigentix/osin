import AppKit
import SwiftUI

/// Osin's motion language: one curve, three durations, a light spring. Quiet and quick, like the
/// rest of the UI. Everything here turns into an instant change when Reduce Motion is on.
enum Motion {
    /// Decisive ease-out used for most movement (Material's "standard" curve).
    private static func curve(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0, 0, 1, duration: duration)
    }

    /// Feedback and small state changes.
    static let quick = curve(0.12)
    /// Most transitions: content swaps, rows, numbers.
    static let standard = curve(0.2)
    /// Larger reveals: charts drawing in, result lists.
    static let slow = curve(0.35)
    /// Switching dashboard pages.
    static let page = curve(0.18)
    /// Things that slide into place (sidebar selection, segmented controls).
    static let spring = Animation.spring(duration: 0.25, bounce: 0.08)

    /// The system setting, readable outside views (e.g. before `withAnimation`).
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `withAnimation`, or a plain change when Reduce Motion is on.
    static func animate(_ animation: Animation = standard, _ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(animation, body)
        }
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct RollingNumberModifier: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .animation(reduceMotion ? nil : Motion.standard, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that respects Reduce Motion.
    func motion(_ animation: Animation = Motion.standard, value: some Equatable) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// Digits roll to the new value (key figures only: score, CPU, free space, network, Clean).
    func rollingNumber(_ value: Double) -> some View {
        modifier(RollingNumberModifier(value: value))
    }
}

// MARK: - Condensing header

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports how far the enclosing scroll view is scrolled, straight from AppKit. SwiftUI on macOS 14
/// does not re-deliver geometry preferences while a `ScrollView` scrolls, and has no scroll-geometry
/// API before macOS 15, so this observes the `NSScrollView`'s clip view instead.
struct ScrollOffsetObserver: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context _: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context _: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private weak var observedClipView: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        private func attach() {
            guard let scrollView = enclosingScrollView, scrollView.contentView !== observedClipView else { return }
            if let observedClipView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
            }
            let clipView = scrollView.contentView
            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clipView
            )
            boundsChanged()
        }

        @objc private func boundsChanged() {
            guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.documentVisibleRect
            let offset = document.isFlipped ? visible.minY : document.bounds.height - visible.maxY
            onChange?(offset + scrollView.contentInsets.top)
        }
    }
}

extension View {
    /// Calls `action` with the scroll offset of the enclosing `ScrollView` (0 at the top).
    /// Attach it to the scroll view's content.
    func onScrollOffsetChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(ScrollOffsetObserver(onChange: action).frame(width: 0, height: 0))
    }
}

/// A page whose header stays pinned and condenses as the content scrolls: the 28 pt title
/// shrinks to 15 pt, the subtitle fades out, and a frosted bar with a hairline appears.
/// The trailing controls (pickers, buttons) stay visible throughout.
struct CondensingPage<Trailing: View, Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: String?
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    /// Scroll distance over which the header condenses.
    static var distance: CGFloat {
        40
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var expandedHeight: CGFloat = 96

    private var progress: CGFloat {
        let raw = min(max(offset / Self.distance, 0), 1)
        return reduceMotion ? (raw >= 0.5 ? 1 : 0) : raw
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: expandedHeight)
                    content
                        .padding(.horizontal, 32)
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
                .onScrollOffsetChange { value in
                    // Past the condensing distance nothing changes: stop updating state there.
                    let clamped = min(max(value, 0), Self.distance)
                    if clamped != offset {
                        offset = clamped
                    }
                }
            }
            header
        }
    }

    private var header: some View {
        CondensingHeader(title: title, subtitle: subtitle, progress: progress) { trailing }
            .background(alignment: .top) {
                GeometryReader { proxy in
                    Color.clear.preference(key: HeaderHeightKey.self, value: progress == 0 ? proxy.size.height : 0)
                }
            }
            .onPreferenceChange(HeaderHeightKey.self) { height in
                if height > 0 {
                    expandedHeight = height
                }
            }
    }
}

extension CondensingPage where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// The header of a `CondensingPage` at a given condensing `progress` (0 = expanded, 1 = compact).
struct CondensingHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: String?
    let progress: CGFloat
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4 * (1 - progress)) {
                Text(title)
                    .font(.system(size: 28 - 13 * progress, weight: .bold))
                    .tracking(-0.6 + 0.4 * progress)
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .opacity(Double(max(0, 1 - progress * 2.5)))
                        .frame(height: 17 * (1 - progress), alignment: .top)
                        .clipped()
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 32)
        .padding(.top, 28 - 16 * progress)
        .padding(.bottom, 18 - 8 * progress)
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .bottom) {
                Rectangle().fill(.regularMaterial)
                Theme.background.opacity(0.92)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            .opacity(Double(progress))
        }
    }
}
