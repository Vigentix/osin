import AppKit
import SwiftUI

/// Reports whether the hosting window can actually be seen: on screen, not minimised and not fully
/// covered by other windows, on another Space or behind a locked screen. `onAppear`/`onDisappear`
/// only fire when a window opens or closes, which would keep 2 s sampling running in the background.
struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context _: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context _: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var hasReported = false
        private var lastReported = false
        private weak var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            if let observedWindow {
                center.removeObserver(self, name: nil, object: observedWindow)
            }
            observedWindow = window
            guard let window else {
                report(false)
                return
            }
            for name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification
            ] {
                center.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
            evaluate()
        }

        @objc private func windowChanged(_ notification: Notification) {
            if notification.name == NSWindow.willCloseNotification {
                report(false)
            } else {
                evaluate()
            }
        }

        private func evaluate() {
            guard let window else { return }
            report(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard !hasReported || visible != lastReported else { return }
            hasReported = true
            lastReported = visible
            onChange?(visible)
        }
    }
}

extension View {
    /// Calls `onChange` when the window showing this view becomes visible or hidden.
    func onWindowVisibilityChange(_ onChange: @escaping (Bool) -> Void) -> some View {
        background(WindowVisibilityObserver(onChange: onChange).frame(width: 0, height: 0))
    }
}
