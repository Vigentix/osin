import SwiftUI

/// Main window: sidebar of sections, detail on the right.
struct DashboardView: View {
    @State private var selection: DashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.systemImage)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail(for: selection ?? .overview)
        }
    }

    @ViewBuilder private func detail(for section: DashboardSection) -> some View {
        switch section {
        case .overview:
            OverviewView()
        case .memory:
            MemoryView()
        case .processes:
            ProcessesView()
        case .battery:
            BatteryView()
        case .smartScan:
            SmartScanView()
        case .storage:
            StorageView()
        case .history:
            CleanupHistoryView()
        }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case smartScan
    case storage
    case memory
    case processes
    case battery
    case history

    var id: Self {
        self
    }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .smartScan: "Smart Scan"
        case .storage: "Storage"
        case .memory: "Memory"
        case .processes: "Processes"
        case .battery: "Battery"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .smartScan: "sparkles"
        case .storage: "internaldrive"
        case .memory: "memorychip"
        case .processes: "list.bullet.rectangle"
        case .battery: "battery.75percent"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// Shared rounded container for dashboard content.
struct Card<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
