import AppKit
import OsinCore
import SwiftUI

/// First-run walkthrough (PRD §6.10): promises, access, startup.
struct OnboardingView: View {
    let finish: () -> Void

    @State private var step = 0
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted()
    @State private var downloadsAsked = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage(Preferences.Key.alertsEnabled) private var alertsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: access
                default: startup
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(36)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .id(step)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0 ..< 3) { index in
                        Capsule()
                            .fill(index == step ? Brand.accent : Color.secondary.opacity(0.4))
                            .frame(width: index == step ? 18 : 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(Text("Step \(step + 1) of 3"))
                Spacer()
                if step > 0 {
                    Button("Back") { go(step - 1) }
                }
                Button(step == 2 ? "Done" : "Continue") {
                    if step == 2 {
                        complete()
                    } else {
                        go(step + 1)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 640, height: 460)
    }

    private func go(_ next: Int) {
        if reduceMotion {
            step = next
        } else {
            withAnimation(.spring(duration: 0.25)) { step = next }
        }
    }

    private func complete() {
        if alertsEnabled {
            Task { _ = await Notifier.requestAuthorization() }
        }
        finish()
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 40))
                .foregroundStyle(Brand.accent)
                .accessibilityHidden(true)
            Text("Welcome to Osin").font(.largeTitle.bold())
            Text("Osin watches your Mac's health from the menu bar and helps you reclaim disk space safely.")
                .foregroundStyle(.secondary)
            promise(
                "No surprise deletions",
                "Only regenerable caches are deleted. Everything else goes to the Trash and can be restored.",
                "arrow.uturn.backward.circle"
            )
            promise("Honest about memory", "No placebo “Free RAM” button. Osin shows memory pressure and which app to quit.", "memorychip")
            promise("Private", "No telemetry. Nothing leaves your Mac.", "lock.shield")
        }
    }

    private func promise(_ title: LocalizedStringKey, _ body: LocalizedStringKey, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OPTIONAL").font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
            Text("Let Osin see more of your disk").font(.title.bold())
            Text(
                // swiftlint:disable:next line_length
                "macOS protects some folders. Granting access lets Smart Scan measure caches there. Osin only reads paths listed in its open-source rules."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            accessRow(
                title: "Full Disk Access",
                detail: "Mail, Safari and other apps' caches, device backups.",
                granted: hasFullDiskAccess
            ) {
                Button("Open System Settings") {
                    if let url = FullDiskAccess.settingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check again") { hasFullDiskAccess = FullDiskAccess.isGranted() }
            }
            accessRow(
                title: "Downloads folder",
                detail: "Old installers and downloads. macOS asks once; you can say no.",
                granted: downloadsAsked
            ) {
                Button("Allow access…") {
                    let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                    Task.detached {
                        _ = try? FileManager.default.contentsOfDirectory(atPath: downloads.path)
                        await MainActor.run { downloadsAsked = true }
                    }
                }
            }
            Text("Without access, those places are skipped and marked in the report.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func accessRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        granted: Bool,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                actions()
            }
        }
        .padding(12)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var startup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Stay in the loop").font(.title.bold())
            Text("Osin uses very little energy in the background: it checks every 30 seconds and never cleans by itself.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open Osin at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    try? LaunchAtLogin.set(enabled)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            Toggle("Notify me when the disk is almost full or memory runs out", isOn: $alertsEnabled)
            Text("You can change these any time in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
    }
}

/// Hosts onboarding in a plain window, opened from the app delegate on first launch.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    /// Since macOS 14, activation is cooperative: `NSApp.activate()` is ignored unless the user started it,
    /// which left the window behind other apps. `orderFrontRegardless` shows it on top anyway.
    private func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    func show(onFinish: @escaping () -> Void) {
        if let window {
            bringToFront(window)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "Welcome to Osin")
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            onFinish()
            self?.window?.close()
            self?.window = nil
        })
        window.center()
        self.window = window
        bringToFront(window)
    }
}
