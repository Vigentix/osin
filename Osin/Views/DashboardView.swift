import SwiftUI

/// Main window. Sections are placeholders until M2.
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
            ContentUnavailableView {
                Label {
                    Text(selection?.title ?? "Overview")
                } icon: {
                    Image(systemName: selection?.systemImage ?? "gauge.with.dots.needle.67percent")
                }
            } description: {
                Text("This section is under construction.")
            }
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

#Preview {
    DashboardView()
}
