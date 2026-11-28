#if DEBUG
    import AppKit
    import OsinCore
    import SwiftUI

    /// Debug-only: `Osin --render-snapshots <dir> [--demo]` renders the main screens to PNG files and exits.
    /// Uses an offscreen window, so it works with a locked screen and in CI. Live data by default; `--demo`
    /// uses `DemoData` instead, which is what the README screenshots use (no personal apps or paths).
    @MainActor
    enum SnapshotRenderer {
        private struct Screen {
            let name: String
            let section: DashboardSection?
            let size: CGSize
            let view: AnyView?
            /// Scroll the page this far before capturing (checks pinned and condensing headers).
            var scrollY: CGFloat = 0
            var cleanupTab: CleanupTab = .smartScan
        }

        static var outputDirectory: URL? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--render-snapshots"), arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }

        // swiftlint:disable:next function_parameter_count
        static func run(
            monitor: SystemMonitor, scan: ScanCoordinator, keepAwake: KeepAwakeController, housekeeper: Housekeeper,
            spaceLens: SpaceLensModel, into directory: URL
        ) async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if DemoData.isActive {
                monitor.loadDemo()
                scan.loadDemo()
                keepAwake.loadDemo(KeepAwakeOptions(mode: .awake, keepDisplayOn: true, duration: .minutes(120)), startedMinutesAgo: 18)
                monitor.refreshStorage(reclaimable: scan.safeReclaimableBytes ?? 0)
                housekeeper.loadDemo(DemoData.weeklySummaries())
                spaceLens.loadDemo(DemoData.spaceTree())
            } else {
                monitor.setVisible(.dashboard, true)
                // Smart Scan is read-only; skip Downloads to avoid a permission prompt.
                scan.ruleFilter = { !$0.paths.contains { $0.hasPrefix("~/Downloads") } }
                scan.start()
                for _ in 0 ..< 240 where scan.phase == .scanning {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                monitor.refreshStorage(reclaimable: scan.safeReclaimableBytes ?? 0)
                try? await Task.sleep(for: .seconds(6))
            }

            let navigator = Navigator()
            let screens = [
                Screen(name: "overview", section: .overview, size: CGSize(width: 1200, height: 1200), view: nil),
                Screen(name: "cleanup", section: .cleanup, size: CGSize(width: 1200, height: 780), view: nil),
                Screen(name: "space-lens", section: .cleanup, size: CGSize(width: 1200, height: 780), view: nil, cleanupTab: .spaceLens),
                Screen(name: "activity", section: .activity, size: CGSize(width: 1200, height: 780), view: nil),
                Screen(name: "system", section: .system, size: CGSize(width: 1200, height: 940), view: nil),
                Screen(name: "system-scrolled", section: .system, size: CGSize(width: 1200, height: 700), view: nil, scrollY: 320),
                Screen(name: "overview-scrolled", section: .overview, size: CGSize(width: 1200, height: 700), view: nil, scrollY: 520),
                Screen(name: "popover", section: nil, size: CGSize(width: 376, height: PopoverView.height), view: AnyView(PopoverView())),
                Screen(
                    name: "keepawake", section: nil, size: CGSize(width: 376, height: PopoverView.height),
                    view: AnyView(KeepAwakeOptionsView {}.padding(16).frame(width: 376, height: PopoverView.height, alignment: .top))
                ),
                Screen(name: "header-states", section: nil, size: CGSize(width: 900, height: 330), view: AnyView(
                    VStack(spacing: 18) {
                        ForEach([0.0, 0.5, 1.0], id: \.self) { progress in
                            CondensingHeader(title: "System", subtitle: "Apple M1 · 8 cores · 16 GB · macOS 26.6", progress: progress) {
                                SegmentedPicker(
                                    options: SystemMonitor.HistoryRange.allCases.map { ($0, $0.title) },
                                    selection: .constant(.hour)
                                )
                            }
                        }
                    }
                    .padding(.vertical, 12)
                )),
                Screen(name: "weekly-report", section: nil, size: CGSize(width: 620, height: 760), view: AnyView(WeeklyReportSheet())),
                Screen(name: "settings-chores", section: nil, size: CGSize(width: 520, height: 720), view: AnyView(ChoresSettings())),
                Screen(name: "onboarding", section: nil, size: CGSize(width: 720, height: 520), view: AnyView(OnboardingView {})),
                Screen(name: "settings", section: nil, size: CGSize(width: 520, height: 420), view: AnyView(SettingsView()))
            ]
            for scheme in [ColorScheme.dark, .light] {
                for screen in screens {
                    if let section = screen.section {
                        navigator.section = section
                    }
                    navigator.cleanupTab = screen.cleanupTab
                    let root = screen.view ?? AnyView(DashboardView())
                    let content = root
                        .environment(monitor)
                        .environment(scan)
                        .environment(navigator)
                        .environment(keepAwake)
                        .environment(housekeeper)
                        .environment(spaceLens)
                        .environment(Updater())
                        .environment(\.colorScheme, scheme)
                        .frame(width: screen.size.width, height: screen.size.height)
                        .background(Theme.background)
                    let suffix = scheme == .dark ? "dark" : "light"
                    await render(
                        content,
                        size: screen.size,
                        appearance: scheme == .dark ? .darkAqua : .aqua,
                        scrollY: screen.scrollY,
                        to: directory.appendingPathComponent("\(screen.name)-\(suffix).png")
                    )
                }
            }
            NSApp.terminate(nil)
        }

        /// The page's main scroll view (the largest one, so side panes are skipped).
        private static func firstScrollView(in view: NSView) -> NSScrollView? {
            var found: [NSScrollView] = []
            func walk(_ node: NSView) {
                if let scroll = node as? NSScrollView {
                    found.append(scroll)
                }
                node.subviews.forEach(walk)
            }
            walk(view)
            return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }

        private static func render(
            _ view: some View,
            size: CGSize,
            appearance: NSAppearance.Name,
            scrollY: CGFloat = 0,
            to url: URL
        ) async {
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
            if scrollY > 0, let scrollView = firstScrollView(in: host) {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                try? await Task.sleep(for: .milliseconds(900))
                host.layoutSubtreeIfNeeded()
            }
            // Always 2x, whatever display is attached, so README images stay sharp on Retina screens.
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2),
                pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return }
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            window.close()
        }
    }
#endif
