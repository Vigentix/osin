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

    private let steps: [LocalizedStringResource] = ["Welcome", "Access", "Startup"]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: access
                    default: startup
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 36)
                .padding(.top, 44)
                .id(step)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                footer
            }
        }
        .frame(width: 720, height: 520)
        .background(Theme.surface)
        .osinFocusStyle()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            LogoMark(size: 72, dot: Theme.good)
                .padding(.top, 28)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(index == step ? Theme.accentButton : (index < step ? Theme.good.opacity(0.18) : Theme.control))
                            if index < step {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.goodText)
                            } else {
                                Text(verbatim: "\(index + 1)").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(index == step ? .white : Theme.text3)
                            }
                        }
                        .frame(width: 20, height: 20)
                        Text(name)
                            .fontWeight(index == step ? .semibold : .regular)
                            .foregroundStyle(index == step ? Theme.text : Theme.text2)
                    }
                    .frame(height: 32)
                }
            }
            Spacer()
            Text("Open source · GPL-3.0\nNo account, no telemetry")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 22)
        .frame(width: 240, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Step \(step + 1) of 3").font(.system(size: 12)).foregroundStyle(Theme.text3)
            Spacer()
            if step > 0 {
                Button("Back") { go(step - 1) }.buttonStyle(SecondaryButtonStyle(large: true))
            }
            Button(step == 2 ? "Start using Osin" : "Continue") {
                if step == 2 {
                    complete()
                } else {
                    go(step + 1)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func go(_ next: Int) {
        if reduceMotion {
            step = next
        } else {
            withAnimation(.spring(duration: 0.26)) { step = next }
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
            Text("Your Mac, honestly.").font(.system(size: 28, weight: .bold)).tracking(-0.6)
            Text("Osin watches your Mac's health from the menu bar and frees space without surprises.")
                .foregroundStyle(Theme.text2)
            promise(
                "arrow.uturn.backward",
                Theme.good,
                "Nothing vanishes by surprise",
                "Only regenerable caches are deleted. Everything else goes to the Trash."
            )
            promise("memorychip", Theme.accent, "Honest about memory", "Pressure, not placebo. Osin tells you which app to quit.")
            promise("lock.shield", Theme.text2, "Private by design", "No telemetry. Nothing leaves this Mac.")
        }
    }

    private func promise(_ icon: String, _ tint: Color, _ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemName: icon, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(body).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("OPTIONAL").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.accentText)
            Text("See more of your disk").font(.system(size: 26, weight: .bold)).tracking(-0.5)
            Text("macOS protects some folders. Osin only reads paths listed in its open-source rules.")
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            accessRow("Full Disk Access", "Mail and Safari caches, device backups", granted: hasFullDiskAccess) {
                Button(hasFullDiskAccess ? "Granted" : "Open Settings") {
                    if let url = FullDiskAccess.settingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Check again") { hasFullDiskAccess = FullDiskAccess.isGranted() }
                    .buttonStyle(LinkButtonStyle())
                    .font(.system(size: 12))
            }
            accessRow("Downloads folder", "Old installers. macOS asks once; you can say no.", granted: downloadsAsked) {
                Button(downloadsAsked ? "Asked" : "Allow…") {
                    let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                    Task.detached {
                        _ = try? FileManager.default.contentsOfDirectory(atPath: downloads.path)
                        await MainActor.run { downloadsAsked = true }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(downloadsAsked)
            }
        }
    }

    private func accessRow(
        _ title: LocalizedStringKey,
        _ detail: LocalizedStringKey,
        granted: Bool,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(granted ? Theme.good : Theme.text3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            actions()
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var startup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quietly in the background").font(.system(size: 26, weight: .bold)).tracking(-0.5)
            Text("Osin checks every 30 seconds using about 0.1% CPU, and never cleans on its own.")
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            toggleRow("Open at login", "So the menu bar is always up to date", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    try? LaunchAtLogin.set(enabled)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            toggleRow("Alerts", "Disk almost full, memory running out", isOn: $alertsEnabled)
            Text("You can change these any time in Settings.").font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accentButton)
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
