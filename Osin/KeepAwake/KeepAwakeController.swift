import AppKit
import IOKit.pwr_mgt
import Observation
import OsinCore

/// Keep Awake: holds a power assertion so the Mac does not idle-sleep while something runs.
///
/// Assertions belong to the process, so macOS drops them if Osin quits or crashes: the Mac can never
/// be left stuck awake. Only idle sleep is prevented; closing the lid, the Apple menu, a forced
/// restart or a dead battery still win (that is all user-space code can do).
@MainActor
@Observable
final class KeepAwakeController {
    private(set) var session: KeepAwakeSession?
    /// How the last session ended, shown until the next one starts.
    private(set) var lastEnd: (reason: KeepAwakeStopReason, session: KeepAwakeSession, at: Date)?
    /// "Require password after the display turns off", read from `sysadminctl`.
    private(set) var lockSetting: ScreenLockSetting = .unknown
    private(set) var updateStatus = SoftwareUpdateStatus(preferences: [:])
    /// Locking the screen failed: the display was only turned off and may not be locked.
    private(set) var lockFailed = false
    /// Ticks once a second while a session runs, for countdowns.
    private(set) var now = Date()
    /// Time since the session started, from a monotonic clock (immune to wall-clock changes).
    private(set) var elapsed: TimeInterval = 0

    /// The options offered next time (the last ones used, without one-off targets).
    var lastOptions: KeepAwakeOptions {
        didSet { save(lastOptions) }
    }

    /// Called when a session ends on its own or is stopped, for notifications.
    @ObservationIgnored var onEnded: ((KeepAwakeStopReason, KeepAwakeSession, Date) -> Void)?

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var startInstant = ContinuousClock.now
    @ObservationIgnored private var lastEvaluation: ContinuousClock.Instant?

    var isActive: Bool {
        session != nil
    }

    init() {
        lastOptions = Self.loadOptions()
    }

    // MARK: Start and stop

    /// Starts (or replaces) a session. Returns why it could not start, e.g. the battery is already low.
    @discardableResult
    func start(_ options: KeepAwakeOptions) -> KeepAwakeStopReason? {
        if let refusal = KeepAwakeEvaluator.safetyStop(power: Self.powerReading(), rules: Preferences.keepAwakeRules) {
            return refusal
        }
        let keepsDisplayOn = options.mode == .awake && options.keepDisplayOn
        let type = keepsDisplayOn ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let created = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Osin Keep Awake" as CFString,
            &id
        )
        // The new assertion is held before the old one goes, so updating a session never leaves a gap,
        // and a failure leaves the current session (and its assertion) as it was.
        guard created == kIOReturnSuccess else { return .stoppedByUser }
        releaseAssertion()
        assertion = id
        // Keeps Osin's own timers running on time while nothing of it is visible (App Nap).
        activity = activity ?? ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep Awake countdown"
        )
        let started = KeepAwakeSession(options: options, startedAt: Date())
        session = started
        lastEnd = nil
        lastOptions = options.forReuse(now: started.startedAt)
        lockFailed = false
        now = started.startedAt
        startInstant = clock.now
        elapsed = 0
        lastEvaluation = nil
        observeWake()
        startTicker()
        if options.mode == .lockScreen {
            lockFailed = !ScreenLock.lockAndTurnOffDisplay()
        }
        refreshSystemFacts()
        return nil
    }

    /// Starts with the last options, or stops when running (popover switch and global shortcut).
    func toggle() {
        if isActive {
            stop()
        } else {
            start(lastOptions.forReuse(now: Date()))
        }
    }

    func stop(_ reason: KeepAwakeStopReason = .stoppedByUser) {
        guard let ended = session else { return }
        session = nil
        ticker?.cancel()
        ticker = nil
        releaseAssertion()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        let end = Date()
        lastEnd = (reason, ended, end)
        onEnded?(reason, ended, end)
    }

    /// Reads the lock-screen setting and pending macOS updates (shown in the options).
    func refreshSystemFacts() {
        updateStatus = SoftwareUpdateStatus.current()
        Task {
            lockSetting = await ScreenLock.readSetting()
        }
    }

    // MARK: Internals

    private func releaseAssertion() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(300))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let session else { return }
        let instant = clock.now
        now = Date()
        elapsed = (instant - startInstant) / .seconds(1)
        // Rules and the watched process are checked every 5 s; the countdown updates every second.
        let timerDue = session.remaining(at: now, elapsed: elapsed) == 0
        if let lastEvaluation, instant - lastEvaluation < .seconds(5), !timerDue {
            return
        }
        lastEvaluation = instant
        let alive = session.watchedProcess.map(RunningProcesses.isAlive) ?? true
        if let reason = KeepAwakeEvaluator.stopReason(
            for: session, at: now, elapsed: elapsed, power: Self.powerReading(), processAlive: alive, rules: Preferences.keepAwakeRules
        ) {
            stop(reason)
        }
    }

    /// The Mac can still sleep (lid closed, Apple menu). Tell the user the session was interrupted.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.onSleptDuringSession?()
            }
        }
    }

    /// Called after the Mac woke up during a session.
    @ObservationIgnored var onSleptDuringSession: (() -> Void)?

    static func powerReading() -> PowerReading {
        let battery = BatteryReader.read()
        return PowerReading(
            batteryFraction: battery?.chargeFraction,
            onACPower: battery?.isOnACPower ?? true,
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState)
        )
    }

    // MARK: Persistence

    private static func loadOptions() -> KeepAwakeOptions {
        guard let data = UserDefaults.standard.data(forKey: Preferences.Key.keepAwakeOptions),
              let options = try? JSONDecoder().decode(KeepAwakeOptions.self, from: data)
        else { return KeepAwakeOptions() }
        return options.forReuse(now: Date())
    }

    private func save(_ options: KeepAwakeOptions) {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: Preferences.Key.keepAwakeOptions)
        }
    }
}

#if DEBUG
    extension KeepAwakeController {
        /// A running session for README screenshots, without holding an assertion.
        func loadDemo(_ options: KeepAwakeOptions, startedMinutesAgo minutes: Double) {
            let started = Date().addingTimeInterval(-minutes * 60)
            session = KeepAwakeSession(options: options, startedAt: started)
            now = Date()
            elapsed = minutes * 60
            lockSetting = .immediate
        }
    }
#endif
