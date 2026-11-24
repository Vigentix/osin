import OsinCore
import SwiftUI

/// One app (or process) with its memory and a Quit button for regular apps.
struct ProcessRow: View {
    let group: ProcessGroup

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(bundlePath: group.bundlePath)
                .frame(width: 22, height: 22)
            Text(group.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(Format.memory(group.footprintBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if AppControl.runningApp(for: group) != nil {
                Button("Quit") {
                    AppControl.quit(group)
                }
                .controlSize(.small)
                .accessibilityLabel(Text("Quit \(group.name)"))
            }
        }
        .frame(minHeight: 30)
    }
}
