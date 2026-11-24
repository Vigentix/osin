import SwiftUI

// Sections implemented in later milestones. Replaced by real views in M3 and M4.

struct SmartScanView: View {
    var body: some View {
        ContentUnavailableView("Smart Scan", systemImage: "sparkles", description: Text("This section is under construction."))
            .navigationTitle(Text("Smart Scan"))
    }
}

struct StorageView: View {
    var body: some View {
        ContentUnavailableView("Storage", systemImage: "internaldrive", description: Text("This section is under construction."))
            .navigationTitle(Text("Storage"))
    }
}

struct CleanupHistoryView: View {
    var body: some View {
        ContentUnavailableView("History", systemImage: "clock.arrow.circlepath", description: Text("This section is under construction."))
            .navigationTitle(Text("History"))
    }
}
