import SwiftUI

/// Settings window. Real options arrive in M5.
struct SettingsView: View {
    var body: some View {
        TabView {
            Form {
                Text("Settings arrive in M5.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
        }
        .frame(width: 480, height: 320)
    }
}

#Preview {
    SettingsView()
}
