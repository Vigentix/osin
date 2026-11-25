import AppKit
import OsinCore
import SwiftUI

/// Main window: four sections in a native sidebar, content on the themed background.
struct DashboardView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(ScanCoordinator.self) private var scan
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    LogoMark(size: 22, dot: monitor.snapshot?.health.level.color ?? Theme.text3)
                    Text(verbatim: "Osin").font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

                List(DashboardSection.allCases, selection: Binding(
                    get: { navigator.section },
                    set: {
                        if let value = $0 {
                            navigator.section = value
                        }
                    }
                )) { section in
                    HStack(spacing: 10) {
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.systemImage)
                        }
                        Spacer(minLength: 4)
                        trailing(for: section)
                    }
                    .tag(section)
                }
                .listStyle(.sidebar)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(FullDiskAccess.isGranted() ? Theme.good : Theme.text3).frame(width: 6, height: 6)
                        Text(FullDiskAccess.isGranted() ? "Full Disk Access on" : "Full Disk Access off")
                    }
                    Text("No telemetry · data stays on this Mac").foregroundStyle(Theme.text3)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            ZStack {
                Theme.background.ignoresSafeArea()
                detail(for: navigator.section)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
    }

    @ViewBuilder private func trailing(for section: DashboardSection) -> some View {
        if section == .cleanup, let bytes = scan.safeReclaimableBytes, bytes >= Recommendations.minimumCleanBytes {
            Text(Format.storage(bytes))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.fairText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.fair.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
        } else {
            KeyHint(keys: section.shortcut)
        }
    }

    @ViewBuilder private func detail(for section: DashboardSection) -> some View {
        switch section {
        case .overview: OverviewView()
        case .cleanup: CleanupView()
        case .activity: ActivityView()
        case .system: SystemView()
        }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case cleanup
    case activity
    case system

    var id: Self {
        self
    }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .activity: "Activity"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cleanup: "sparkles"
        case .activity: "waveform.path.ecg"
        case .system: "cpu"
        }
    }

    var shortcut: String {
        switch self {
        case .overview: "⌘1"
        case .cleanup: "⌘2"
        case .activity: "⌘3"
        case .system: "⌘4"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .overview: "1"
        case .cleanup: "2"
        case .activity: "3"
        case .system: "4"
        }
    }
}

enum CleanupTab: String, CaseIterable, Identifiable {
    case smartScan
    case largeFiles
    case history

    var id: Self {
        self
    }

    var title: LocalizedStringResource {
        switch self {
        case .smartScan: "Smart Scan"
        case .largeFiles: "Large files"
        case .history: "History"
        }
    }
}

/// Finds and quits the app behind a process group. Only regular apps are offered.
enum AppControl {
    static func runningApp(for group: ProcessGroup) -> NSRunningApplication? {
        guard let bundlePath = group.bundlePath else { return nil }
        let url = URL(fileURLWithPath: bundlePath).standardizedFileURL
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == url
                && $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    static func quit(_ group: ProcessGroup) {
        runningApp(for: group)?.terminate()
    }

    static func forceQuit(_ group: ProcessGroup) {
        runningApp(for: group)?.forceTerminate()
    }
}
