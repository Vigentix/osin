#if DEBUG
    import AppKit
    import SwiftUI

    /// Debug-only: `Osin --render-snapshots <dir>` renders the main screens with live data to PNG files and exits.
    /// Uses an offscreen window, so it works with a locked screen and in CI. Used for README screenshots.
    @MainActor
    enum SnapshotRenderer {
        private struct Screen {
            let name: String
            let view: AnyView
            let size: CGSize
        }

        static var outputDirectory: URL? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--render-snapshots"), arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }

        static func run(monitor: SystemMonitor, scan: ScanCoordinator, into directory: URL) async {
            monitor.setVisible(.dashboard, true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Let a few samples arrive so rates and sparklines have data.
            try? await Task.sleep(for: .seconds(7))

            let screens: [Screen] = [
                Screen(name: "popover", view: AnyView(PopoverView()), size: CGSize(width: 368, height: 640)),
                Screen(name: "overview", view: AnyView(OverviewView()), size: CGSize(width: 1000, height: 900)),
                Screen(name: "memory", view: AnyView(MemoryView()), size: CGSize(width: 1000, height: 1000)),
                Screen(name: "processes", view: AnyView(ProcessesView()), size: CGSize(width: 900, height: 600)),
                Screen(name: "battery", view: AnyView(BatteryView()), size: CGSize(width: 1000, height: 640))
            ]
            // Smart Scan is read-only; render its report too.
            scan.ruleFilter = { !$0.paths.contains { $0.hasPrefix("~/Downloads") } } // avoid the Downloads permission prompt
            scan.start()
            for _ in 0 ..< 240 where scan.phase == .scanning {
                try? await Task.sleep(for: .milliseconds(500))
            }
            let reportScreens = [
                Screen(name: "smartscan", view: AnyView(SmartScanView()), size: CGSize(width: 1000, height: 1100)),
                Screen(name: "storage", view: AnyView(StorageView()), size: CGSize(width: 1000, height: 800)),
                Screen(name: "history", view: AnyView(CleanupHistoryView()), size: CGSize(width: 900, height: 500)),
                Screen(name: "onboarding", view: AnyView(OnboardingView {}), size: CGSize(width: 640, height: 460)),
                Screen(name: "settings", view: AnyView(SettingsView()), size: CGSize(width: 520, height: 420))
            ]
            for scheme in [ColorScheme.dark, .light] {
                for screen in screens + reportScreens {
                    let (name, view, size) = (screen.name, screen.view, screen.size)
                    let content = view
                        .environment(monitor)
                        .environment(scan)
                        .environment(Navigator())
                        .environment(\.colorScheme, scheme)
                        .frame(width: size.width, height: size.height)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let suffix = scheme == .dark ? "dark" : "light"
                    await render(
                        content,
                        size: size,
                        appearance: scheme == .dark ? .darkAqua : .aqua,
                        to: directory.appendingPathComponent("\(name)-\(suffix).png")
                    )
                }
            }
            NSApp.terminate(nil)
        }

        private static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) async {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false // ARC owns it; the default would over-release on close()
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // Give SwiftUI a moment for tasks (history queries) and animations to settle.
            try? await Task.sleep(for: .seconds(2))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            window.close()
        }
    }
#endif
