import AppKit
import OsinCore
import SwiftUI

/// Menu bar popover. Placeholder until M1 adds live metrics.
struct PopoverView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Osin")
                .font(.headline)
            Text("Health monitoring arrives in M1.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Version \(OsinCore.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            HStack {
                Button("Open Dashboard") {
                    openWindow(id: WindowID.dashboard)
                    NSApp.activate()
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("Settings"))
                Button("Quit Osin") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 360)
    }
}

#Preview {
    PopoverView()
}
