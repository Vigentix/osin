import AppKit
import OsinCore
import SwiftUI

/// Main window: four sections in a native sidebar, content on the themed background.
struct DashboardView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(ScanCoordinator.self) private var scan
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sidebarSelection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .motion(Motion.spring, value: navigator.section)
            Rectangle().fill(Theme.border).frame(width: 1)
            ZStack {
                Theme.background
                // The new page fades in while rising 8 pt; the old one simply fades.
                detail(for: navigator.section)
                    .id(navigator.section)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)),
                        removal: .opacity
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .motion(Motion.page, value: navigator.section)
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .osinFocusStyle()
        .frame(minWidth: 960, minHeight: 640)
    }

    /// Solid sidebar drawn by Osin (the floating glass sidebar of `NavigationSplitView` does not
    /// render correctly over the app's own dark surfaces).
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                LogoMark(size: 22, dot: monitor.snapshot?.health.level.color ?? Theme.text3)
                Text(verbatim: "Osin").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 52) // clear the traffic lights
            .padding(.bottom, 16)

            ForEach(DashboardSection.allCases) { section in
                SidebarItem(section: section, selected: navigator.section == section, selectionNamespace: sidebarSelection) {
                    trailing(for: section)
                } action: {
                    navigator.section = section
                }
            }

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(FullDiskAccess.isGranted() ? Theme.good : Theme.text3).frame(width: 6, height: 6)
                    Text(FullDiskAccess.isGranted() ? "Full Disk Access on" : "Full Disk Access off")
                }
                Text("No telemetry · data stays on this Mac").foregroundStyle(Theme.text3)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.text2)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
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

/// One navigation row in the sidebar.
private struct SidebarItem<Trailing: View>: View {
    let section: DashboardSection
    let selected: Bool
    /// The selection highlight slides between rows instead of jumping.
    let selectionNamespace: Namespace.ID
    @ViewBuilder let trailing: Trailing
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.accentText : Theme.text2)
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected || hovering ? Theme.text : Theme.text2)
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accentSoft)
                        .matchedGeometryEffect(id: "sidebar-selection", in: selectionNamespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .focusEffectDisabled()
        .onHover { inside in
            withAnimation(HoverMotion.animation(entering: inside)) { hovering = inside }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    case spaceLens
    case cleanWithAI
    case largeFiles
    case history

    var id: Self {
        self
    }

    var title: LocalizedStringResource {
        switch self {
        case .smartScan: "Smart Scan"
        case .spaceLens: "Space Lens"
        case .cleanWithAI: "Clean with AI"
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

    /// Whether Osin offers Quit for this group: a regular app that is running.
    static func canQuit(_ group: ProcessGroup) -> Bool {
        #if DEBUG
            if DemoData.isActive {
                return group.bundlePath != nil
            }
        #endif
        return runningApp(for: group) != nil
    }

    static func quit(_ group: ProcessGroup) {
        runningApp(for: group)?.terminate()
    }

    static func forceQuit(_ group: ProcessGroup) {
        runningApp(for: group)?.forceTerminate()
    }
}
