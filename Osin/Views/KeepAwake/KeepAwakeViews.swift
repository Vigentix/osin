import AppKit
import OsinCore
import SwiftUI

// MARK: - Shared text

enum KeepAwakeText {
    /// "Screen on · 1:42:05 left", "Locked · until rsync finishes", "Screen may sleep · until you stop it".
    @MainActor
    static func status(_ keepAwake: KeepAwakeController) -> String {
        guard let session = keepAwake.session else { return "" }
        let mode = keepAwake.lockFailed ? String(localized: "Not locked") : modeTitle(session.options)
        let detail = if let process = session.watchedProcess {
            String(localized: "until \(process.name) finishes")
        } else if let remaining = session.remaining(at: keepAwake.now, elapsed: keepAwake.elapsed) {
            String(localized: "\(Format.countdown(remaining)) left")
        } else {
            String(localized: "until you stop it")
        }
        return "\(mode) · \(detail)"
    }

    static func modeTitle(_ options: KeepAwakeOptions) -> String {
        guard options.mode == .awake else { return String(localized: "Locked") }
        guard options.keepDisplayOn else { return String(localized: "Screen may sleep") }
        return String(localized: "Screen on")
    }

    static func lockNote(_ setting: ScreenLockSetting) -> String {
        switch setting {
        case .immediate: String(localized: "Your Mac locks as soon as the display turns off.")
        case let .after(seconds): String(localized: "Your Mac locks \(Format.duration(TimeInterval(seconds))) after the display turns off.")
        case .off: String(localized: "Your Mac does not lock when the display turns off.")
        case .unknown: String(localized: "Whether your Mac locks follows your Lock Screen settings.")
        }
    }
}

// MARK: - Popover row

/// The Keep Awake switch in the menu bar popover; the chevron opens the options.
struct KeepAwakeRow: View {
    @Environment(KeepAwakeController.self) private var keepAwake
    let showOptions: () -> Void
    @State private var refusal: String?

    var body: some View {
        HoverRow(radius: 10) { _ in
            HStack(spacing: 10) {
                IconTile(
                    systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                    tint: keepAwake.isActive ? Theme.accent : Theme.text2,
                    size: 30
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Awake").font(.system(size: 13, weight: .semibold))
                    Text(statusText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(refusal == nil ? Theme.text2 : Theme.fairText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Toggle("Keep Awake", isOn: Binding(
                    get: { keepAwake.isActive },
                    set: { isOn in
                        if isOn {
                            refusal = keepAwake.start(keepAwake.lastOptions.forReuse(now: Date()))?.refusal
                        } else {
                            refusal = nil
                            keepAwake.stop()
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accentButton)
                Button(action: showOptions) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityLabel(Text("Keep Awake options"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { keepAwake.refreshNow() }
    }

    private var statusText: String {
        if let refusal {
            return refusal
        }
        if keepAwake.isActive {
            return KeepAwakeText.status(keepAwake)
        }
        return String(localized: "Off · your Mac sleeps as usual")
    }
}

// MARK: - Options

/// Mode, duration and limits, shown in place of the popover content.
struct KeepAwakeOptionsView: View {
    enum DurationKind: Hashable {
        case indefinite
        case timer
        case untilTime
        case process
    }

    @Environment(KeepAwakeController.self) private var keepAwake
    let back: () -> Void

    @State private var mode: KeepAwakeMode = .awake
    @State private var keepDisplayOn = true
    @State private var kind: DurationKind = .indefinite
    @State private var minutes = 60
    @State private var untilTime = KeepAwakeOptionsView.nextMorning()
    @State private var process: WatchedProcess?
    @State private var capEnabled = false
    @State private var capHours = 6
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modeSection
                    durationSection
                    if kind == .indefinite || kind == .process {
                        capSection
                    }
                    notes
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            footer
        }
        .tint(Theme.accentButton)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Keep Awake").font(.system(size: 15, weight: .bold))
                }
            }
            .buttonStyle(GhostButtonStyle())
            Spacer()
            if keepAwake.isActive {
                Badge(text: LocalizedStringKey(KeepAwakeText.status(keepAwake)), color: Theme.accentText)
                    .lineLimit(1)
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Screen")
            SegmentedPicker(options: [(KeepAwakeMode.awake, "Keep unlocked"), (.lockScreen, "Lock screen")], selection: $mode)
            if mode == .awake {
                Toggle("Keep the display on", isOn: $keepDisplayOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
                if !keepDisplayOn {
                    note(KeepAwakeText.lockNote(keepAwake.lockSetting), icon: "lock")
                }
            } else {
                note(
                    String(localized: "Locks now and turns the display off. Apps, downloads and Terminal jobs keep running."),
                    icon: "lock.fill"
                )
            }
        }
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "For how long")
            SegmentedPicker(
                options: [(DurationKind.indefinite, "Until I stop"), (.timer, "Timer"), (.untilTime, "Until"), (.process, "Until done")],
                selection: $kind
            )
            switch kind {
            case .indefinite:
                note(String(localized: "Runs until you turn it off or a safety rule stops it."), icon: "infinity")
            case .timer:
                HStack(spacing: 6) {
                    ForEach([30, 60, 120, 240, 480], id: \.self) { value in
                        let selected = minutes == value
                        Button(Format.duration(TimeInterval(value * 60))) { minutes = value }
                            .buttonStyle(SecondaryButtonStyle(tint: selected ? Theme.accentText : Theme.text))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
                    }
                }
            case .untilTime:
                DatePicker("Until", selection: $untilTime, displayedComponents: [.hourAndMinute])
                    .datePickerStyle(.field)
                    .font(.system(size: 12))
            case .process:
                ProcessPicker(selection: $process)
            }
        }
    }

    private var capSection: some View {
        HStack {
            Toggle("Stop after at most", isOn: $capEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            Spacer()
            Stepper(value: $capHours, in: 1 ... 48) {
                Text(Format.duration(TimeInterval(capHours * 3600))).monospacedDigit().font(.system(size: 12))
            }
            .disabled(!capEnabled)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            note(
                String(localized: "Closing the lid still puts your Mac to sleep, unless an external display is connected."),
                icon: "laptopcomputer"
            )
            if keepAwake.updateStatus.mayRestartOnItsOwn, let update = keepAwake.updateStatus.pendingMacOSUpdate {
                note(
                    String(localized: "\(update) is waiting and macOS installs updates automatically, so your Mac may restart overnight."),
                    icon: "arrow.triangle.2.circlepath",
                    color: Theme.fairText
                )
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let refusal {
                Text(refusal).font(.system(size: 11)).foregroundStyle(Theme.fairText)
            }
            HStack(spacing: 8) {
                Button {
                    refusal = keepAwake.start(options)?.refusal
                    if refusal == nil {
                        back()
                    }
                } label: {
                    Text(keepAwake.isActive ? "Update" : "Start").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(kind == .process && process == nil)
                if keepAwake.isActive {
                    Button("Stop") {
                        keepAwake.stop()
                        back()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func note(_ text: String, icon: String, color: Color = Theme.text2) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 14).accessibilityHidden(true)
            Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: State

    private var options: KeepAwakeOptions {
        let duration: KeepAwakeDuration = switch kind {
        case .indefinite: .indefinite
        case .timer: .minutes(minutes)
        case .untilTime: .until(Self.nextOccurrence(of: untilTime))
        case .process: process.map { .process($0) } ?? .indefinite
        }
        let cap = (kind == .indefinite || kind == .process) && capEnabled ? Double(capHours) : nil
        return KeepAwakeOptions(mode: mode, keepDisplayOn: keepDisplayOn, duration: duration, maxHours: cap)
    }

    private func load() {
        keepAwake.refreshSystemFacts()
        let current = keepAwake.session?.options ?? keepAwake.lastOptions
        mode = current.mode
        keepDisplayOn = current.keepDisplayOn
        if let cap = current.maxHours {
            capEnabled = true
            capHours = max(1, Int(cap))
        }
        switch current.duration {
        case .indefinite: kind = .indefinite
        case let .minutes(value): kind = .timer
            minutes = value
        case let .until(date): kind = .untilTime
            untilTime = date
        case let .process(watched): kind = .process
            process = watched
        }
    }

    static func nextMorning() -> Date {
        nextOccurrence(of: Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date())
    }

    /// The next time the clock shows this hour and minute (today or tomorrow).
    static func nextOccurrence(of time: Date, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) ?? time
    }
}

// MARK: - Process picker

/// Running apps and terminal commands, busiest first, with search.
struct ProcessPicker: View {
    @Binding var selection: WatchedProcess?
    @State private var processes: [(process: RunningProcess, cpu: Double)] = []
    /// Remembers each process's command line between refreshes (most of a refresh's cost).
    @State private var catalog = RunningProcessCatalog()
    @State private var query = ""
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search apps and commands", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if filtered.isEmpty {
                Text("Nothing matches. Start the command first, then pick it here.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            } else {
                VStack(spacing: 2) {
                    if let selection, !processes.contains(where: { $0.process.watched == selection }) {
                        selectedOnly(selection)
                    }
                    ForEach(filtered.prefix(40), id: \.process.pid) { entry in
                        row(entry.process, cpu: entry.cpu)
                    }
                }
            }
        }
        // Refresh every few seconds, so a command started after opening the list shows up.
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The watched process when the list does not show it (it already ended, or is filtered out).
    private func selectedOnly(_ watched: WatchedProcess) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 20, height: 20)
            Text(watched.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var filtered: [(process: RunningProcess, cpu: Double)] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return processes }
        return processes.filter { $0.process.commandLine.lowercased().contains(text) || $0.process.name.lowercased().contains(text) }
    }

    private func row(_ process: RunningProcess, cpu: Double) -> some View {
        let selected = selection == process.watched
        return HoverRowButton(radius: 8, selected: selected, action: { selection = process.watched }, label: { _ in
            HStack(spacing: 8) {
                if let bundle = process.bundlePath {
                    AppAvatar(name: process.name, bundlePath: bundle, size: 20)
                } else {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !process.isApp {
                        Text(process.commandLine).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.text3).lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Text(Format.cpuShare(cpu)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.text3)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        })
    }

    /// Two readings half a second apart give each process's CPU share.
    private func load() async {
        let first = await catalog.refresh()
        try? await Task.sleep(for: .milliseconds(500))
        let second = await catalog.refresh()
        processes = Self.rank(second, previous: first, seconds: 0.5)
        loading = false
    }

    /// Apps once each (their main process) and commands run from a terminal or keeping busy;
    /// commands first, busiest first within each group.
    private static func rank(_ current: [RunningProcess], previous: [RunningProcess], seconds: Double) -> [(
        process: RunningProcess,
        cpu: Double
    )] {
        var before: [Int32: UInt64] = [:]
        for process in previous {
            before[process.pid] = process.cpuNanoseconds
        }
        var seenBundles: Set<String> = []
        var result: [(process: RunningProcess, cpu: Double)] = []
        for process in current {
            let earlier = before[process.pid] ?? process.cpuNanoseconds
            let used = process.cpuNanoseconds >= earlier ? process.cpuNanoseconds - earlier : 0
            let cpu = Double(used) / (seconds * 1_000_000_000)
            if let bundle = process.bundlePath {
                guard process.isMainAppProcess, seenBundles.insert(bundle).inserted else { continue }
            } else {
                guard !process.isIdleShell, process.hasTerminal || cpu > 0.05 else { continue }
            }
            result.append((process, cpu))
        }
        return result.sorted { lhs, rhs in
            if lhs.process.isApp != rhs.process.isApp {
                return !lhs.process.isApp
            }
            return lhs.cpu > rhs.cpu
        }
    }
}

// MARK: - Overview banner

/// Shown at the top of the Overview while Keep Awake runs.
struct KeepAwakeBanner: View {
    @Environment(KeepAwakeController.self) private var keepAwake

    var body: some View {
        if keepAwake.isActive {
            HStack(spacing: 12) {
                IconTile(systemName: "cup.and.saucer.fill", tint: Theme.accent, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keeping your Mac awake").font(.system(size: 14, weight: .semibold))
                    Text(KeepAwakeText.status(keepAwake))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text2)
                }
                Spacer()
                Button("Stop") { keepAwake.stop() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(14)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Settings

struct KeepAwakeSettings: View {
    @AppStorage(Preferences.Key.keepAwakeStopOnLowBattery) private var stopOnLowBattery = true
    @AppStorage(Preferences.Key.keepAwakeLowBatteryThreshold) private var threshold = 0.20
    @AppStorage(Preferences.Key.keepAwakeStopWhenHot) private var stopWhenHot = true
    @AppStorage(Preferences.Key.keepAwakeStopWhenUnplugged) private var stopWhenUnplugged = false
    @AppStorage(Preferences.Key.keepAwakeShortcut) private var shortcut = KeepAwakeShortcut.none.rawValue
    @Environment(KeepAwakeController.self) private var keepAwake
    @State private var shortcutFailed = false

    var body: some View {
        Form {
            Section {
                Toggle("Stop when the battery is low", isOn: $stopOnLowBattery)
                if stopOnLowBattery {
                    VStack(alignment: .leading) {
                        Text("Below \(Format.percent(threshold)) while not charging")
                        Slider(value: $threshold, in: 0.05 ... 0.50, step: 0.05) { Text("Battery level") }
                            .labelsHidden()
                    }
                }
                Toggle("Stop when the Mac runs hot", isOn: $stopWhenHot)
                Toggle("Only while connected to power", isOn: $stopWhenUnplugged)
            } header: {
                Text("Safety")
            } footer: {
                Text("Keep Awake prevents idle sleep only. Closing the lid, the Apple menu or a forced restart still win.")
            }
            Section {
                Picker("Shortcut", selection: $shortcut) {
                    ForEach(KeepAwakeShortcut.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .onChange(of: shortcut) { _, value in
                    shortcutFailed = !GlobalHotKey.shared.register(KeepAwakeShortcut(rawValue: value) ?? .none) { [keepAwake] in
                        keepAwake.toggle()
                    }
                }
                if shortcutFailed {
                    Text("This shortcut is already used by another app. Pick another.").font(.caption).foregroundStyle(Theme.fairText)
                }
            } footer: {
                Text("Turns Keep Awake on with your last choice, or off.")
            }
        }
        .formStyle(.grouped)
    }
}
