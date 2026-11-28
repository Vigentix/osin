import AppKit
import OsinCore
import SwiftUI

/// Cleanup › Space Lens: what takes up space in the home folder, as a treemap and a list.
struct SpaceLensView: View {
    @Environment(SpaceLensModel.self) private var lens
    @State private var selection: String?
    @State private var confirmTrash: SpaceNode?

    var body: some View {
        Group {
            if let current = lens.current {
                content(current)
            } else if lens.isScanning {
                scanningState
            } else {
                emptyState
            }
        }
        .onAppear { lens.loadCache() }
        .confirmationDialog(
            Text("Move “\(confirmTrash?.name ?? "")” to the Trash?"),
            isPresented: Binding(get: { confirmTrash != nil }, set: {
                if !$0 {
                    confirmTrash = nil
                }
            })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let node = confirmTrash {
                    Task { await lens.trash(node) }
                }
                confirmTrash = nil
            }
            Button("Cancel", role: .cancel) { confirmTrash = nil }
        } message: {
            Text("\(Format.storage(confirmTrash?.bytes ?? 0)). You can put it back from the Trash or from History.")
        }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 14) {
            IconTile(systemName: "square.grid.3x3.square", tint: Theme.accent, size: 56)
            Text("See what takes up space").font(.system(size: 22, weight: .bold)).tracking(-0.3)
            Text(
                "Space Lens measures your home folder, which takes about a minute. Folders macOS protects are skipped unless Osin has Full Disk Access."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.text2)
            .frame(maxWidth: 420)
            Button("Scan Home Folder") { lens.scan() }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Measuring your home folder…").font(.system(size: 17, weight: .semibold))
            Text("\(lens.seen.formatted()) items so far").monospacedDigit().foregroundStyle(Theme.text2)
            Button("Cancel") { lens.cancel() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Content

    private func content(_ current: SpaceNode) -> some View {
        VStack(spacing: 0) {
            breadcrumb
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            Divider().overlay(Theme.border)
            HStack(spacing: 0) {
                Treemap(nodes: current.children, total: current.bytes, selection: $selection) { lens.open($0) }
                    .padding(16)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Theme.border)
                list(current)
                    .frame(width: 440)
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(lens.breadcrumb.enumerated()), id: \.element.path) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                }
                Button {
                    lens.go(to: node)
                    selection = nil
                } label: {
                    Text(index == 0 ? String(localized: "Home") : node.name)
                        .fontWeight(index == lens.breadcrumb.count - 1 ? .semibold : .regular)
                        .lineLimit(1)
                }
                .buttonStyle(GhostButtonStyle())
            }
            Spacer()
            if let current = lens.current {
                Text(Format.storage(current.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
        }
    }

    private func list(_ current: SpaceNode) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if let error = lens.trashError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.poorText)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(current.children) { node in
                        SpaceRow(
                            node: node,
                            total: current.bytes,
                            selected: selection == node.path,
                            select: { selection = node.path },
                            open: { lens.open(node); selection = nil },
                            trash: { confirmTrash = node }
                        )
                        .id(node.path)
                    }
                    if current.otherCount > 0 {
                        HStack {
                            Text("\(current.otherCount) smaller items").foregroundStyle(Theme.text3)
                            Spacer()
                            Text(Format.storage(current.otherBytes)).monospacedDigit().foregroundStyle(Theme.text3)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selection) { _, path in
                if let path {
                    withAnimation(Motion.standard) { proxy.scrollTo(path, anchor: .center) }
                }
            }
        }
    }
}

/// One entry in the Space Lens list: name, what it is (for known folders), size and actions.
private struct SpaceRow: View {
    let node: SpaceNode
    let total: UInt64
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    let trash: () -> Void
    @State private var hovering = false

    private var guide: FolderGuide.Entry? {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard node.path.hasPrefix(home + "/") else { return nil }
        return FolderGuide.bundled.describe(relativePath: String(node.path.dropFirst(home.count + 1)))
    }

    private var canOpen: Bool {
        node.isDirectory && !node.isSkipped && !node.children.isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.isSkipped ? "lock.fill" : (node.isDirectory ? "folder.fill" : "doc.fill"))
                .foregroundStyle(SpaceColors.tint(for: guide?.advice, skipped: node.isSkipped))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if node.isSkipped {
                    Text("Needs Full Disk Access to measure").font(.system(size: 11)).foregroundStyle(Theme.text3)
                } else if let guide {
                    Text(String(localized: String.LocalizationValue(guide.title)) + " · " + SpaceColors.adviceText(guide.advice))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .help(String(localized: String.LocalizationValue(guide.detail)))
                }
            }
            Spacer(minLength: 8)
            if hovering || selected, !node.isSkipped {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                } label: {
                    Image(systemName: "magnifyingglass").frame(width: 22, height: 22)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel(Text("Show in Finder"))
                if node.canTrash {
                    Button(action: trash) {
                        Image(systemName: "trash").frame(width: 22, height: 22)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel(Text("Move \(node.name) to the Trash"))
                }
            }
            VStack(alignment: .trailing, spacing: 4) {
                if node.isSkipped {
                    Text(verbatim: "—").foregroundStyle(Theme.text3)
                } else {
                    Text(Format.storage(node.bytes)).monospacedDigit().fontWeight(.semibold)
                    UsageBar(fraction: total > 0 ? Double(node.bytes) / Double(total) : 0, color: Theme.accent, height: 3)
                        .frame(width: 64)
                }
            }
            .frame(width: 80, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .opacity(canOpen ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .contentShape(Rectangle())
        .hoverSurface(radius: 0, selected: selected, hovering: $hovering)
        .onTapGesture(count: 2) {
            if canOpen {
                open()
            }
        }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canOpen ? .isButton : [])
    }
}

enum SpaceColors {
    static func tint(for advice: FolderGuide.Advice?, skipped: Bool) -> Color {
        if skipped {
            return Theme.text3
        }
        switch advice {
        case .safe: return Theme.good
        case .review: return Theme.fair
        case .keep: return Theme.text3
        case nil: return Theme.accent
        }
    }

    static func adviceText(_ advice: FolderGuide.Advice) -> String {
        switch advice {
        case .safe: String(localized: "rebuilt automatically")
        case .review: String(localized: "your call")
        case .keep: String(localized: "keep")
        }
    }
}

/// Squarified treemap of a folder's largest entries. Click selects, double-click opens a folder.
private struct Treemap: View {
    let nodes: [SpaceNode]
    let total: UInt64
    @Binding var selection: String?
    let open: (SpaceNode) -> Void

    var body: some View {
        GeometryReader { proxy in
            let shown = nodes.filter { $0.bytes > 0 }
            let rects = TreemapLayout.squarify(shown.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(shown, rects)), id: \.0.path) { node, rect in
                    tile(node, rect: rect)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Treemap"))
    }

    private func tile(_ node: SpaceNode, rect: CGRect) -> some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let advice = node.path.hasPrefix(home + "/")
            ? FolderGuide.bundled.describe(relativePath: String(node.path.dropFirst(home.count + 1)))?.advice : nil
        let tint = SpaceColors.tint(for: advice, skipped: node.isSkipped)
        let selected = selection == node.path
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.opacity(selected ? 0.45 : 0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? tint : tint.opacity(0.35), lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .topLeading) {
                if inset.width > 70, inset.height > 34 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(Format.storage(node.bytes)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.text2)
                    }
                    .padding(6)
                }
            }
            .frame(width: max(0, inset.width), height: max(0, inset.height))
            .offset(x: inset.minX, y: inset.minY)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(node) }
            .onTapGesture { selection = node.path }
            .help("\(node.name) · \(Format.storage(node.bytes))")
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk): rows of tiles kept close to square.
enum TreemapLayout {
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: areas.count)
        var remaining = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            while end < areas.count, worst(areas[start ... end], side: side) <= worst(areas[start ..< end], side: side) {
                end += 1
            }
            let row = areas[start ..< end]
            let rowArea = row.reduce(0, +)
            if remaining.width >= remaining.height {
                // A column on the left.
                let width = CGFloat(rowArea / Double(remaining.height))
                var y = remaining.minY
                for (offset, area) in row.enumerated() {
                    let height = CGFloat(area) / max(width, 0.0001)
                    result[start + offset] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: remaining.width - width, height: remaining.height)
            } else {
                // A row along the top.
                let height = CGFloat(rowArea / Double(remaining.width))
                var x = remaining.minX
                for (offset, area) in row.enumerated() {
                    let width = CGFloat(area) / max(height, 0.0001)
                    result[start + offset] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: remaining.height - height)
            }
            start = end
        }
        return result
    }

    /// The worst aspect ratio in a row laid along a side of length `side`.
    private static func worst(_ row: ArraySlice<Double>, side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard let largest = row.max(), let smallest = row.min(), sum > 0, smallest > 0 else { return .infinity }
        let squared = side * side
        return max(squared * largest / (sum * sum), (sum * sum) / (squared * smallest))
    }
}
