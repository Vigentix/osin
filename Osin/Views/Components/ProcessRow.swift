import AppKit
import OsinCore
import SwiftUI

/// One app (or process) with its memory and a Quit button for regular apps.
struct ProcessRow: View {
    let group: ProcessGroup

    private var runningApp: NSRunningApplication? {
        guard let bundlePath = group.bundlePath else { return nil }
        let url = URL(fileURLWithPath: bundlePath)
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && $0.activationPolicy == .regular
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
            Text(group.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(Format.memory(group.footprintBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let app = runningApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                Button("Quit") {
                    app.terminate()
                }
                .controlSize(.small)
                .accessibilityLabel(Text("Quit \(group.name)"))
            }
        }
        .frame(minHeight: 30)
    }

    @ViewBuilder private var icon: some View {
        if let bundlePath = group.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
