import AppKit
import OsinCore
import SwiftUI

/// Settings › Advanced › Project folders: where Smart Scan looks for cold projects and version pins,
/// besides the usual places (~/Projects, ~/Developer, …).
struct ProjectFoldersSection: View {
    @State private var folders = Preferences.projectRoots

    var body: some View {
        Section {
            ForEach(folders, id: \.path) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Remove") {
                        folders.removeAll { $0 == folder }
                        Preferences.projectRoots = folders
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            Button("Add Folder…") { add() }
                .buttonStyle(SecondaryButtonStyle())
        } header: {
            Text("Project folders")
        } footer: {
            Text(
                "Smart Scan looks for cold projects in \(Scanner.defaultProjectRoots.prefix(3).map { "~/\($0)" }.joined(separator: ", ")) and similar folders. Add others here. Folders outside your home folder or in protected places are ignored."
            )
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for url in panel.urls where url.standardizedFileURL.path.hasPrefix(home + "/") && !folders.contains(url) {
            folders.append(url)
        }
        Preferences.projectRoots = folders
    }
}
