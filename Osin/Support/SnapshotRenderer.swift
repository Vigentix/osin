#if DEBUG
    import AppKit
    import SwiftUI

    /// Debug-only: `Osin --render-snapshots <dir>` renders the main screens with live data to PNG files and exits.
    /// Uses an offscreen window, so it works with a locked screen and in CI. Used for README screenshots.
    @MainActor
    enum SnapshotRenderer {
        private struct Screen {
            let name: String
            let section: DashboardSection?
            let size: CGSize
            let view: AnyView?
        }

        static var outputDirectory: URL? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--render-snapshots"), arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }

        static func run(monitor: SystemMonitor, scan: ScanCoordinator, into directory: URL) async {
            monitor.setVisible(.dashboard, true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Smart Scan is read-only; skip Downloads to avoid a permission prompt.
            scan.ruleFilter = { !$0.paths.contains { $0.hasPrefix("~/Downloads") } }
            scan.start()
            for _ in 0 ..< 240 where scan.phase == .scanning {
                try? await Task.sleep(for: .milliseconds(500))
            }
            monitor.refreshStorage(reclaimable: scan.safeReclaimableBytes ?? 0)
            try? await Task.sleep(for: .seconds(6))

            let navigator = Navigator()
            let screens = [
                Screen(name: "overview", section: .overview, size: CGSize(width: 1200, height: 1180), view: nil),
                Screen(name: "cleanup", section: .cleanup, size: CGSize(width: 1200, height: 780), view: nil),
                Screen(name: "activity", section: .activity, size: CGSize(width: 1200, height: 780), view: nil),
                Screen(name: "system", section: .system, size: CGSize(width: 1200, height: 1300), view: nil),
                Screen(name: "popover", section: nil, size: CGSize(width: 376, height: 640), view: AnyView(PopoverView())),
                Screen(name: "onboarding", section: nil, size: CGSize(width: 720, height: 520), view: AnyView(OnboardingView {})),
                Screen(name: "settings", section: nil, size: CGSize(width: 520, height: 420), view: AnyView(SettingsView()))
            ]
            for scheme in [ColorScheme.dark, .light] {
                for screen in screens {
                    if let section = screen.section {
                        navigator.section = section
                    }
                    let root = screen.view ?? AnyView(DashboardView())
                    let content = root
                        .environment(monitor)
                        .environment(scan)
                        .environment(navigator)
                        .environment(Updater())
                        .environment(\.colorScheme, scheme)
                        .frame(width: screen.size.width, height: screen.size.height)
                        .background(Theme.background)
                    let suffix = scheme == .dark ? "dark" : "light"
                    await render(
                        content,
                        size: screen.size,
                        appearance: scheme == .dark ? .darkAqua : .aqua,
                        to: directory.appendingPathComponent("\(screen.name)-\(suffix).png")
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
